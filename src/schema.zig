//! Avro schema model, `.avsc` parser, name resolution, and default checks.

const std = @import("std");
const diag = @import("diag.zig");
const json = @import("json.zig");

pub const Error = diag.Error;

pub const TypeKind = enum(u8) {
    null = 0,
    boolean = 1,
    int = 2,
    long = 3,
    float = 4,
    double = 5,
    bytes = 6,
    string = 7,
    record = 8,
    enum_type = 9,
    array = 10,
    map = 11,
    union_type = 12,
    fixed = 13,
    unresolved = 14,
};

pub const Order = enum(u8) { ascending, descending, ignore };

pub const Field = struct {
    name: []const u8,
    type_id: u32,
    has_default: bool = false,
    default_json: []const u8 = "",
    aliases: []const []const u8 = &.{},
    order: Order = .ascending,
    doc: []const u8 = "",
};

pub const SchemaNode = struct {
    kind: TypeKind,
    name: []const u8 = "",
    short_name: []const u8 = "",
    namespace: []const u8 = "",
    aliases: []const []const u8 = &.{},
    doc: []const u8 = "",
    logical_type: []const u8 = "",
    symbols: []const []const u8 = &.{},
    enum_default: []const u8 = "",
    fields: []const Field = &.{},
    item_id: u32 = 0,
    value_id: u32 = 0,
    branches: []const u32 = &.{},
    size: u32 = 0,
    attr_keys: []const []const u8 = &.{},
    attr_vals: []const []const u8 = &.{},
    is_error: bool = false,
};

pub const SchemaPool = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(SchemaNode),
    /// Parallel to `nodes`. Decode switches on this dense byte instead of the 200-byte node.
    kinds: std.ArrayList(u8) = .empty,
    by_name: std.StringHashMap(u32),
    prims: [8]?u32,
    root: u32 = 0,
    original_json: []const u8 = "",
    err_msg: []const u8 = "",
    /// Decode slab returned by the last Datum freed against this pool.
    /// One record at a time reuses it. Freed in `deinit`.
    decode_scratch: []align(8) u8 = &.{},

    pub fn init(gpa: std.mem.Allocator) SchemaPool {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .nodes = .empty,
            .by_name = std.StringHashMap(u32).init(gpa),
            .prims = .{ null, null, null, null, null, null, null, null },
        };
    }

    pub fn deinit(self: *SchemaPool) void {
        self.by_name.deinit();
        self.kinds.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
        self.arena.deinit();
        if (self.decode_scratch.len != 0) self.gpa.free(self.decode_scratch);
    }

    pub fn dupe(self: *SchemaPool, s: []const u8) Error![]u8 {
        return self.arena.allocator().dupe(u8, s) catch error.OutOfMemory;
    }

    pub fn failf(self: *SchemaPool, comptime fmt: []const u8, args: anytype) Error {
        self.err_msg = std.fmt.allocPrint(self.arena.allocator(), fmt, args) catch return error.OutOfMemory;
        return error.Schema;
    }

    pub fn addNode(self: *SchemaPool, n: SchemaNode) Error!u32 {
        const id: u32 = @intCast(self.nodes.items.len);
        self.nodes.append(self.gpa, n) catch return error.OutOfMemory;
        self.kinds.append(self.gpa, @intFromEnum(n.kind)) catch {
            self.nodes.shrinkRetainingCapacity(self.nodes.items.len - 1);
            return error.OutOfMemory;
        };
        return id;
    }

    pub fn resolveName(self: *SchemaPool, name: []const u8, enclosing: []const u8) Error!u32 {
        if (primitiveKind(name)) |k| return self.primitive(k);
        if (std.mem.eql(u8, name, "record") or std.mem.eql(u8, name, "enum") or std.mem.eql(u8, name, "array") or
            std.mem.eql(u8, name, "map") or std.mem.eql(u8, name, "fixed"))
        {
            return self.failf("bare complex type '{s}'", .{name});
        }
        const q = try self.qualify(name, null, enclosing);
        if (self.by_name.get(q.full)) |id| return id;
        const id = try self.addNode(.{
            .kind = .unresolved,
            .name = q.full,
            .short_name = q.short,
            .namespace = q.ns,
        });
        self.by_name.put(q.full, id) catch return error.OutOfMemory;
        return id;
    }

    pub fn declare(
        self: *SchemaPool,
        kind: TypeKind,
        name: []const u8,
        explicit_ns: ?[]const u8,
        enclosing: []const u8,
    ) Error!u32 {
        const q = try self.qualify(name, explicit_ns, enclosing);
        if (self.by_name.get(q.full)) |id| {
            if (self.nodes.items[id].kind != .unresolved) return self.failf("duplicate name '{s}'", .{q.full});
            self.nodes.items[id] = .{
                .kind = kind,
                .name = q.full,
                .short_name = q.short,
                .namespace = q.ns,
            };
            self.kinds.items[id] = @intFromEnum(kind);
            return id;
        }
        const id = try self.addNode(.{
            .kind = kind,
            .name = q.full,
            .short_name = q.short,
            .namespace = q.ns,
        });
        self.by_name.put(q.full, id) catch return error.OutOfMemory;
        return id;
    }

    pub fn primitive(self: *SchemaPool, kind: TypeKind) Error!u32 {
        const i: usize = @intFromEnum(kind);
        if (self.prims[i]) |id| return id;
        const name = kindName(kind);
        const id = try self.addNode(.{ .kind = kind, .name = name, .short_name = name });
        self.prims[i] = id;
        return id;
    }

    pub fn qualify(
        self: *SchemaPool,
        name: []const u8,
        explicit_ns: ?[]const u8,
        enclosing: []const u8,
    ) Error!struct { full: []const u8, ns: []const u8, short: []const u8 } {
        if (std.mem.indexOfScalar(u8, name, '.') != null) {
            if (!isDottedName(name)) return self.failf("illegal name '{s}'", .{name});
            const dot = std.mem.lastIndexOfScalar(u8, name, '.').?;
            const short = try self.dupe(name[dot + 1 ..]);
            const ns = try self.dupe(name[0..dot]);
            const full = try self.dupe(name);
            return .{ .full = full, .ns = ns, .short = short };
        }
        if (!isUnqualified(name)) return self.failf("illegal name '{s}'", .{name});
        const ns_src: []const u8 = if (explicit_ns) |n| n else enclosing;
        if (!isNamespace(ns_src)) return self.failf("illegal namespace '{s}'", .{ns_src});
        const short = try self.dupe(name);
        if (ns_src.len == 0) return .{ .full = short, .ns = "", .short = short };
        const ns = try self.dupe(ns_src);
        const full = std.fmt.allocPrint(self.arena.allocator(), "{s}.{s}", .{ ns, short }) catch return error.OutOfMemory;
        return .{ .full = full, .ns = ns, .short = short };
    }

    pub fn finish(self: *SchemaPool) Error!void {
        for (self.nodes.items) |n| {
            if (n.kind == .unresolved) return self.failf("unknown name '{s}'", .{n.name});
        }
        for (self.nodes.items) |n| {
            if (n.kind == .union_type) try self.validateUnion(n.branches);
        }
        for (self.nodes.items) |n| {
            if (n.kind == .enum_type and n.enum_default.len != 0) {
                if (symbolIndex(n.symbols, n.enum_default) == null) {
                    return self.failf("enum default '{s}' is not a symbol of '{s}'", .{ n.enum_default, n.name });
                }
            }
            if (n.kind != .record) continue;
            for (n.fields) |f| {
                if (f.has_default) try self.checkDefault(f.type_id, f.default_json);
            }
        }
    }

    pub fn validateUnion(self: *SchemaPool, branches: []const u32) Error!void {
        if (branches.len == 0) return self.failf("empty union", .{});
        for (branches, 0..) |b, i| {
            const bk = self.nodes.items[b].kind;
            if (bk == .union_type) return self.failf("nested union", .{});
            if (bk == .unresolved) return self.failf("unknown union branch", .{});
            for (branches[0..i]) |prev| {
                if (prev == b or sameBranch(self, prev, b)) return self.failf("duplicate union branch", .{});
            }
        }
    }

    pub fn checkDefault(self: *SchemaPool, type_id: u32, text: []const u8) Error!void {
        var doc = json.Doc.parse(self.gpa, text) catch return self.failf("default is not valid JSON", .{});
        defer doc.deinit();
        try self.checkDefaultNode(&doc, doc.root, type_id);
    }

    fn checkDefaultNode(self: *SchemaPool, doc: *const json.Doc, jid: u32, type_id: u32) Error!void {
        const n = self.nodes.items[type_id];
        const j = doc.node(jid);
        switch (n.kind) {
            .null => if (j.kind != .null) return self.failf("default is not null", .{}),
            .boolean => if (j.kind != .boolean) return self.failf("default is not a boolean", .{}),
            .int => {
                if (j.kind != .integer) return self.failf("default is not an int", .{});
                if (j.i < std.math.minInt(i32) or j.i > std.math.maxInt(i32)) return self.failf("int default out of range", .{});
            },
            .long => if (j.kind != .integer) return self.failf("default is not a long", .{}),
            .float, .double => {
                if (j.kind != .integer and j.kind != .float) return self.failf("default is not a number", .{});
                if (j.kind == .float and (std.math.isNan(j.f) or std.math.isInf(j.f))) return self.failf("non-finite default", .{});
            },
            .string => if (j.kind != .string) return self.failf("default is not a string", .{}),
            .bytes => {
                if (j.kind != .string) return self.failf("default is not bytes", .{});
                const latin = try json.latin1FromUtf8(self.gpa, j.s);
                self.gpa.free(latin);
            },
            .fixed => {
                if (j.kind != .string) return self.failf("default is not fixed bytes", .{});
                const latin = try json.latin1FromUtf8(self.gpa, j.s);
                defer self.gpa.free(latin);
                if (latin.len != n.size) return self.failf("fixed default has the wrong length", .{});
            },
            .enum_type => {
                if (j.kind != .string) return self.failf("default is not an enum symbol", .{});
                if (symbolIndex(n.symbols, j.s) == null) return self.failf("enum default symbol '{s}'", .{j.s});
            },
            .array => {
                if (j.kind != .array) return self.failf("default is not an array", .{});
                for (0..doc.arrayLen(jid)) |i| try self.checkDefaultNode(doc, doc.arrayAt(jid, i), n.item_id);
            },
            .map => {
                if (j.kind != .object) return self.failf("default is not a map", .{});
                for (0..doc.objectLen(jid)) |i| try self.checkDefaultNode(doc, doc.objectVal(jid, i), n.value_id);
            },
            .record => {
                if (j.kind != .object) return self.failf("default is not a record", .{});
                var seen = self.gpa.alloc(bool, n.fields.len) catch return error.OutOfMemory;
                defer self.gpa.free(seen);
                @memset(seen, false);
                for (0..doc.objectLen(jid)) |i| {
                    const key = doc.objectKey(jid, i);
                    var found = false;
                    for (n.fields, 0..) |f, fi| {
                        if (std.mem.eql(u8, f.name, key)) {
                            if (seen[fi]) return self.failf("duplicate default field '{s}'", .{key});
                            seen[fi] = true;
                            try self.checkDefaultNode(doc, doc.objectVal(jid, i), f.type_id);
                            found = true;
                            break;
                        }
                    }
                    if (!found) return self.failf("unknown default field '{s}'", .{key});
                }
                for (n.fields, 0..) |f, fi| {
                    if (!seen[fi] and !f.has_default) return self.failf("record default missing '{s}'", .{f.name});
                }
            },
            .union_type => {
                if (n.branches.len == 0) return self.failf("empty union default", .{});
                try self.checkDefaultNode(doc, jid, n.branches[0]);
            },
            .unresolved => return self.failf("unresolved default type", .{}),
        }
    }

    pub fn attr(self: *const SchemaPool, id: u32, key: []const u8) ?[]const u8 {
        const n = self.nodes.items[id];
        for (n.attr_keys, n.attr_vals) |k, v| {
            if (std.mem.eql(u8, k, key)) return v;
        }
        return null;
    }
};

pub fn kindName(kind: TypeKind) []const u8 {
    return switch (kind) {
        .null => "null",
        .boolean => "boolean",
        .int => "int",
        .long => "long",
        .float => "float",
        .double => "double",
        .bytes => "bytes",
        .string => "string",
        .record => "record",
        .enum_type => "enum",
        .array => "array",
        .map => "map",
        .union_type => "union",
        .fixed => "fixed",
        .unresolved => "unresolved",
    };
}

pub fn unqualified(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

pub fn symbolIndex(symbols: []const []const u8, name: []const u8) ?usize {
    for (symbols, 0..) |s, i| if (std.mem.eql(u8, s, name)) return i;
    return null;
}

fn sameBranch(pool: *const SchemaPool, a: u32, b: u32) bool {
    const na = pool.nodes.items[a];
    const nb = pool.nodes.items[b];
    if (na.kind != nb.kind) return false;
    return switch (na.kind) {
        .record, .enum_type, .fixed => std.mem.eql(u8, na.name, nb.name),
        .unresolved => std.mem.eql(u8, na.name, nb.name),
        else => true,
    };
}

fn isUnqualified(s: []const u8) bool {
    if (s.len == 0) return false;
    switch (s[0]) {
        'A'...'Z', 'a'...'z', '_' => {},
        else => return false,
    }
    for (s[1..]) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}

fn isNamespace(s: []const u8) bool {
    if (s.len == 0) return true;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| if (!isUnqualified(part)) return false;
    return true;
}

fn isDottedName(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '.') != null and isNamespace(s);
}

fn primitiveKind(s: []const u8) ?TypeKind {
    if (std.mem.eql(u8, s, "null")) return .null;
    if (std.mem.eql(u8, s, "boolean")) return .boolean;
    if (std.mem.eql(u8, s, "int")) return .int;
    if (std.mem.eql(u8, s, "long")) return .long;
    if (std.mem.eql(u8, s, "float")) return .float;
    if (std.mem.eql(u8, s, "double")) return .double;
    if (std.mem.eql(u8, s, "bytes")) return .bytes;
    if (std.mem.eql(u8, s, "string")) return .string;
    return null;
}

const Parser = struct {
    pool: *SchemaPool,
    doc: *const json.Doc,

    fn parse(self: *Parser, idx: u32, ns: []const u8, depth: usize) Error!u32 {
        if (depth > diag.max_depth) return self.pool.failf("schema nested too deeply", .{});
        switch (self.doc.node(idx).kind) {
            .string => {
                const s = self.doc.node(idx).s;
                if (primitiveKind(s)) |k| return self.pool.primitive(k);
                if (std.mem.eql(u8, s, "record") or std.mem.eql(u8, s, "enum") or std.mem.eql(u8, s, "array") or
                    std.mem.eql(u8, s, "map") or std.mem.eql(u8, s, "fixed"))
                {
                    return self.pool.failf("bare complex type '{s}'", .{s});
                }
                return self.resolveRef(s, ns);
            },
            .array => return self.parseUnion(idx, ns, depth),
            .object => return self.parseObject(idx, ns, depth),
            else => return self.pool.failf("schema must be a string, array, or object", .{}),
        }
    }

    fn resolveRef(self: *Parser, name: []const u8, enclosing: []const u8) Error!u32 {
        const q = try self.pool.qualify(name, null, enclosing);
        if (self.pool.by_name.get(q.full)) |id| return id;
        const id = try self.pool.addNode(.{
            .kind = .unresolved,
            .name = q.full,
            .short_name = q.short,
            .namespace = q.ns,
        });
        self.pool.by_name.put(q.full, id) catch return error.OutOfMemory;
        return id;
    }

    fn define(self: *Parser, kind: TypeKind, name: []const u8, explicit_ns: ?[]const u8, enclosing: []const u8) Error!u32 {
        const q = try self.pool.qualify(name, explicit_ns, enclosing);
        if (self.pool.by_name.get(q.full)) |id| {
            if (self.pool.nodes.items[id].kind != .unresolved) return self.pool.failf("duplicate name '{s}'", .{q.full});
            self.pool.nodes.items[id] = .{
                .kind = kind,
                .name = q.full,
                .short_name = q.short,
                .namespace = q.ns,
            };
            self.pool.kinds.items[id] = @intFromEnum(kind);
            return id;
        }
        const id = try self.pool.addNode(.{
            .kind = kind,
            .name = q.full,
            .short_name = q.short,
            .namespace = q.ns,
        });
        self.pool.by_name.put(q.full, id) catch return error.OutOfMemory;
        return id;
    }

    fn optString(self: *Parser, obj: u32, key: []const u8) Error!?[]const u8 {
        const v = self.doc.objectGet(obj, key) orelse return null;
        if (self.doc.node(v).kind != .string) return self.pool.failf("'{s}' must be a string", .{key});
        return try self.pool.dupe(self.doc.node(v).s);
    }

    fn reqString(self: *Parser, obj: u32, key: []const u8) Error![]const u8 {
        return (try self.optString(obj, key)) orelse self.pool.failf("missing '{s}'", .{key});
    }

    fn optNamespace(self: *Parser, obj: u32) Error!?[]const u8 {
        if (self.doc.objectGet(obj, "namespace") == null) return null;
        return try self.optString(obj, "namespace");
    }

    fn stringList(self: *Parser, obj: u32, key: []const u8) Error![]const []const u8 {
        const v = self.doc.objectGet(obj, key) orelse return &.{};
        if (self.doc.node(v).kind != .array) return self.pool.failf("'{s}' must be an array", .{key});
        const n = self.doc.arrayLen(v);
        const out = self.pool.arena.allocator().alloc([]const u8, n) catch return error.OutOfMemory;
        for (0..n) |i| {
            const el = self.doc.arrayAt(v, i);
            if (self.doc.node(el).kind != .string) return self.pool.failf("'{s}' items must be strings", .{key});
            const s = try self.pool.dupe(self.doc.node(el).s);
            if (std.mem.eql(u8, key, "symbols") and !isUnqualified(s)) return self.pool.failf("illegal symbol '{s}'", .{s});
            if (std.mem.eql(u8, key, "aliases") and !isUnqualified(s) and !isDottedName(s)) {
                return self.pool.failf("illegal alias '{s}'", .{s});
            }
            out[i] = s;
        }
        return out;
    }

    fn leftovers(self: *Parser, obj: u32, skip: []const []const u8) Error!struct { keys: []const []const u8, vals: []const []const u8 } {
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(self.pool.gpa);
        var vals: std.ArrayList([]const u8) = .empty;
        defer vals.deinit(self.pool.gpa);
        for (0..self.doc.objectLen(obj)) |i| {
            const k = self.doc.objectKey(obj, i);
            var skip_it = false;
            for (skip) |s| if (std.mem.eql(u8, s, k)) {
                skip_it = true;
                break;
            };
            if (skip_it) continue;
            const raw = self.doc.raw(self.doc.objectVal(obj, i));
            keys.append(self.pool.gpa, try self.pool.dupe(k)) catch return error.OutOfMemory;
            vals.append(self.pool.gpa, try self.pool.dupe(raw)) catch return error.OutOfMemory;
        }
        if (keys.items.len == 0) return .{ .keys = &.{}, .vals = &.{} };
        const ak = self.pool.arena.allocator().dupe([]const u8, keys.items) catch return error.OutOfMemory;
        const av = self.pool.arena.allocator().dupe([]const u8, vals.items) catch return error.OutOfMemory;
        return .{ .keys = ak, .vals = av };
    }

    fn parseObject(self: *Parser, obj: u32, ns: []const u8, depth: usize) Error!u32 {
        const t = self.doc.objectGet(obj, "type") orelse return self.pool.failf("schema object missing type", .{});
        switch (self.doc.node(t).kind) {
            .string => {
                const s = self.doc.node(t).s;
                if (primitiveKind(s)) |k| return self.parsePrimitive(obj, k);
                if (std.mem.eql(u8, s, "record")) return self.parseRecord(obj, ns, depth, false);
                if (std.mem.eql(u8, s, "enum")) return self.parseEnum(obj, ns, depth);
                if (std.mem.eql(u8, s, "array")) return self.parseArray(obj, ns, depth);
                if (std.mem.eql(u8, s, "map")) return self.parseMap(obj, ns, depth);
                if (std.mem.eql(u8, s, "fixed")) return self.parseFixed(obj, ns, depth);
                return self.resolveRef(s, ns);
            },
            .array => {
                const id = try self.parseUnion(t, ns, depth);
                const logical = try self.optString(obj, "logicalType") orelse "";
                const extra = try self.leftovers(obj, &.{ "type", "logicalType" });
                self.pool.nodes.items[id].logical_type = logical;
                self.pool.nodes.items[id].attr_keys = extra.keys;
                self.pool.nodes.items[id].attr_vals = extra.vals;
                return id;
            },
            .object => {
                const inner = try self.parse(t, ns, depth + 1);
                return self.applyOuter(inner, obj);
            },
            else => return self.pool.failf("type must be a string, array, or object", .{}),
        }
    }

    fn applyOuter(self: *Parser, id: u32, obj: u32) Error!u32 {
        if (self.doc.objectLen(obj) == 1) return id;
        var use = id;
        if (self.isSharedPrim(id)) {
            const n = self.pool.nodes.items[id];
            use = try self.pool.addNode(.{ .kind = n.kind, .name = n.name, .short_name = n.short_name });
        }
        const logical = try self.optString(obj, "logicalType") orelse "";
        const doc_s = try self.optString(obj, "doc") orelse "";
        const extra = try self.leftovers(obj, &.{ "type", "logicalType", "doc" });
        if (self.pool.nodes.items[use].logical_type.len == 0) self.pool.nodes.items[use].logical_type = logical;
        if (self.pool.nodes.items[use].doc.len == 0) self.pool.nodes.items[use].doc = doc_s;
        if (self.pool.nodes.items[use].attr_keys.len == 0) {
            self.pool.nodes.items[use].attr_keys = extra.keys;
            self.pool.nodes.items[use].attr_vals = extra.vals;
        }
        return use;
    }

    fn isSharedPrim(self: *Parser, id: u32) bool {
        const k = @intFromEnum(self.pool.nodes.items[id].kind);
        if (k > 7) return false;
        if (self.pool.prims[k]) |p| return p == id;
        return false;
    }

    fn parsePrimitive(self: *Parser, obj: u32, kind: TypeKind) Error!u32 {
        const logical = try self.optString(obj, "logicalType") orelse "";
        const extra = try self.leftovers(obj, &.{ "type", "logicalType" });
        if (logical.len == 0 and extra.keys.len == 0) return self.pool.primitive(kind);
        const name = kindName(kind);
        return self.pool.addNode(.{
            .kind = kind,
            .name = name,
            .short_name = name,
            .logical_type = logical,
            .attr_keys = extra.keys,
            .attr_vals = extra.vals,
        });
    }

    fn parseUnion(self: *Parser, arr: u32, ns: []const u8, depth: usize) Error!u32 {
        const n = self.doc.arrayLen(arr);
        if (n == 0) return self.pool.failf("empty union", .{});
        const branches = self.pool.arena.allocator().alloc(u32, n) catch return error.OutOfMemory;
        for (0..n) |i| branches[i] = try self.parse(self.doc.arrayAt(arr, i), ns, depth + 1);
        return self.pool.addNode(.{ .kind = .union_type, .branches = branches });
    }

    fn parseRecord(self: *Parser, obj: u32, enclosing: []const u8, depth: usize, is_error: bool) Error!u32 {
        const name = try self.reqString(obj, "name");
        const explicit_ns = try self.optNamespace(obj);
        const id = try self.define(.record, name, explicit_ns, enclosing);
        const rec_ns = self.pool.nodes.items[id].namespace;
        const fields_v = self.doc.objectGet(obj, "fields") orelse return self.pool.failf("record '{s}' missing fields", .{name});
        if (self.doc.node(fields_v).kind != .array) return self.pool.failf("fields must be an array", .{});
        const fields = try self.parseFields(fields_v, rec_ns, depth);
        const doc_s = try self.optString(obj, "doc") orelse "";
        const aliases = try self.stringList(obj, "aliases");
        const logical = try self.optString(obj, "logicalType") orelse "";
        const extra = try self.leftovers(obj, &.{ "type", "name", "namespace", "fields", "doc", "aliases", "logicalType" });
        self.pool.nodes.items[id].fields = fields;
        self.pool.nodes.items[id].doc = doc_s;
        self.pool.nodes.items[id].aliases = aliases;
        self.pool.nodes.items[id].logical_type = logical;
        self.pool.nodes.items[id].attr_keys = extra.keys;
        self.pool.nodes.items[id].attr_vals = extra.vals;
        self.pool.nodes.items[id].is_error = is_error;
        return id;
    }

    fn parseFields(self: *Parser, arr: u32, ns: []const u8, depth: usize) Error![]const Field {
        const n = self.doc.arrayLen(arr);
        const fields = self.pool.arena.allocator().alloc(Field, n) catch return error.OutOfMemory;
        for (0..n) |i| {
            const f = self.doc.arrayAt(arr, i);
            if (self.doc.node(f).kind != .object) return self.pool.failf("field must be an object", .{});
            const name = try self.reqString(f, "name");
            if (!isUnqualified(name)) return self.pool.failf("illegal field name '{s}'", .{name});
            for (fields[0..i]) |prev| if (std.mem.eql(u8, prev.name, name)) return self.pool.failf("duplicate field '{s}'", .{name});
            const tv = self.doc.objectGet(f, "type") orelse return self.pool.failf("field '{s}' missing type", .{name});
            const type_id = try self.parse(tv, ns, depth + 1);
            var has_default = false;
            var default_json: []const u8 = "";
            if (self.doc.objectGet(f, "default")) |d| {
                has_default = true;
                default_json = try self.pool.dupe(self.doc.raw(d));
            }
            var order: Order = .ascending;
            if (self.doc.objectGet(f, "order")) |o| {
                if (self.doc.node(o).kind != .string) return self.pool.failf("order must be a string", .{});
                const os = self.doc.node(o).s;
                if (std.mem.eql(u8, os, "ascending")) order = .ascending else if (std.mem.eql(u8, os, "descending")) order = .descending else if (std.mem.eql(u8, os, "ignore")) order = .ignore else return self.pool.failf("bad order '{s}'", .{os});
            }
            const aliases = try self.stringList(f, "aliases");
            const doc_s = try self.optString(f, "doc") orelse "";
            fields[i] = .{
                .name = name,
                .type_id = type_id,
                .has_default = has_default,
                .default_json = default_json,
                .aliases = aliases,
                .order = order,
                .doc = doc_s,
            };
        }
        return fields;
    }

    fn parseEnum(self: *Parser, obj: u32, enclosing: []const u8, depth: usize) Error!u32 {
        _ = depth;
        const name = try self.reqString(obj, "name");
        const explicit_ns = try self.optNamespace(obj);
        const id = try self.define(.enum_type, name, explicit_ns, enclosing);
        const symbols = try self.stringList(obj, "symbols");
        if (symbols.len == 0) return self.pool.failf("enum '{s}' has no symbols", .{name});
        for (symbols, 0..) |s, i| {
            if (!isUnqualified(s)) return self.pool.failf("illegal symbol '{s}'", .{s});
            for (symbols[0..i]) |p| if (std.mem.eql(u8, p, s)) return self.pool.failf("duplicate symbol '{s}'", .{s});
        }
        const enum_default = try self.optString(obj, "default") orelse "";
        const doc_s = try self.optString(obj, "doc") orelse "";
        const aliases = try self.stringList(obj, "aliases");
        const logical = try self.optString(obj, "logicalType") orelse "";
        const extra = try self.leftovers(obj, &.{ "type", "name", "namespace", "symbols", "doc", "aliases", "default", "logicalType" });
        self.pool.nodes.items[id].symbols = symbols;
        self.pool.nodes.items[id].enum_default = enum_default;
        self.pool.nodes.items[id].doc = doc_s;
        self.pool.nodes.items[id].aliases = aliases;
        self.pool.nodes.items[id].logical_type = logical;
        self.pool.nodes.items[id].attr_keys = extra.keys;
        self.pool.nodes.items[id].attr_vals = extra.vals;
        return id;
    }

    fn parseFixed(self: *Parser, obj: u32, enclosing: []const u8, depth: usize) Error!u32 {
        _ = depth;
        const name = try self.reqString(obj, "name");
        const explicit_ns = try self.optNamespace(obj);
        const id = try self.define(.fixed, name, explicit_ns, enclosing);
        const sv = self.doc.objectGet(obj, "size") orelse return self.pool.failf("fixed '{s}' missing size", .{name});
        if (self.doc.node(sv).kind != .integer or self.doc.node(sv).i < 0) return self.pool.failf("fixed size must be a non-negative integer", .{});
        if (self.doc.node(sv).i > std.math.maxInt(u32)) return self.pool.failf("fixed size is too large", .{});
        const doc_s = try self.optString(obj, "doc") orelse "";
        const aliases = try self.stringList(obj, "aliases");
        const logical = try self.optString(obj, "logicalType") orelse "";
        const extra = try self.leftovers(obj, &.{ "type", "name", "namespace", "size", "doc", "aliases", "logicalType" });
        self.pool.nodes.items[id].size = @intCast(self.doc.node(sv).i);
        self.pool.nodes.items[id].doc = doc_s;
        self.pool.nodes.items[id].aliases = aliases;
        self.pool.nodes.items[id].logical_type = logical;
        self.pool.nodes.items[id].attr_keys = extra.keys;
        self.pool.nodes.items[id].attr_vals = extra.vals;
        return id;
    }

    fn parseArray(self: *Parser, obj: u32, ns: []const u8, depth: usize) Error!u32 {
        const items = self.doc.objectGet(obj, "items") orelse return self.pool.failf("array missing items", .{});
        const item_id = try self.parse(items, ns, depth + 1);
        const logical = try self.optString(obj, "logicalType") orelse "";
        const extra = try self.leftovers(obj, &.{ "type", "items", "logicalType" });
        return self.pool.addNode(.{
            .kind = .array,
            .item_id = item_id,
            .logical_type = logical,
            .attr_keys = extra.keys,
            .attr_vals = extra.vals,
        });
    }

    fn parseMap(self: *Parser, obj: u32, ns: []const u8, depth: usize) Error!u32 {
        const values = self.doc.objectGet(obj, "values") orelse return self.pool.failf("map missing values", .{});
        const value_id = try self.parse(values, ns, depth + 1);
        const logical = try self.optString(obj, "logicalType") orelse "";
        const extra = try self.leftovers(obj, &.{ "type", "values", "logicalType" });
        return self.pool.addNode(.{
            .kind = .map,
            .value_id = value_id,
            .logical_type = logical,
            .attr_keys = extra.keys,
            .attr_vals = extra.vals,
        });
    }
};

pub fn parseAvsc(gpa: std.mem.Allocator, text: []const u8) Error!SchemaPool {
    var pool = SchemaPool.init(gpa);
    errdefer pool.deinit();
    pool.root = try parseAvscInto(&pool, text, "");
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    pool.original_json = try pool.dupe(trimmed);
    try pool.finish();
    return pool;
}

pub fn parseAvscInto(pool: *SchemaPool, text: []const u8, enclosing_ns: []const u8) Error!u32 {
    if (text.len > diag.max_schema_bytes) return pool.failf("schema exceeds {d} bytes", .{diag.max_schema_bytes});
    var doc = json.Doc.parse(pool.gpa, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return pool.failf("schema is not JSON", .{}),
    };
    defer doc.deinit();
    var parser = Parser{ .pool = pool, .doc = &doc };
    return parser.parse(doc.root, enclosing_ns, 0);
}

/// Define a record directly (IDL). `fields` must already use this pool's ids.
pub fn defineRecord(
    pool: *SchemaPool,
    name: []const u8,
    explicit_ns: ?[]const u8,
    enclosing: []const u8,
    fields: []const Field,
    is_error: bool,
) Error!u32 {
    var parser = Parser{ .pool = pool, .doc = undefined };
    const id = try parser.define(.record, name, explicit_ns, enclosing);
    pool.nodes.items[id].fields = fields;
    pool.nodes.items[id].is_error = is_error;
    return id;
}

test "parse primitives, longlist, and rejections" {
    const gpa = std.testing.allocator;
    var int_pool = try parseAvsc(gpa, "\"int\"");
    defer int_pool.deinit();
    try std.testing.expectEqual(TypeKind.int, int_pool.nodes.items[int_pool.root].kind);

    const ll =
        \\{"type":"record","name":"LongList","fields":[{"name":"value","type":"long"},{"name":"next","type":["null","LongList"]}]}
    ;
    var pool = try parseAvsc(gpa, ll);
    defer pool.deinit();
    const root = pool.nodes.items[pool.root];
    try std.testing.expectEqual(TypeKind.record, root.kind);
    try std.testing.expectEqual(@as(usize, 2), root.fields.len);
    try std.testing.expectEqual(TypeKind.union_type, pool.nodes.items[root.fields[1].type_id].kind);

    try std.testing.expectError(error.Schema, parseAvsc(gpa, "[]"));
    try std.testing.expectError(error.Schema, parseAvsc(gpa, "[\"int\",[\"string\",\"null\"]]"));
    try std.testing.expectError(error.Schema, parseAvsc(gpa, "[{\"type\":\"array\",\"items\":\"int\"},{\"type\":\"array\",\"items\":\"long\"}]"));
    try std.testing.expectError(error.Schema, parseAvsc(gpa, "{\"type\":\"record\",\"name\":\"R\",\"fields\":[{\"name\":\"a\",\"type\":[\"string\",\"null\"],\"default\":null}]}"));
    try std.testing.expectError(error.Schema, parseAvsc(gpa, "{\"type\":\"record\",\"name\":\"1bad\",\"fields\":[]}"));

    const mutual =
        \\[{"type":"record","name":"A","fields":[{"name":"b","type":["null","B"]}]},{"type":"record","name":"B","fields":[{"name":"a","type":["null","A"]}]}]
    ;
    var mp = try parseAvsc(gpa, mutual);
    defer mp.deinit();
    try std.testing.expectEqual(TypeKind.union_type, mp.nodes.items[mp.root].kind);

    const two =
        \\[{"type":"record","name":"A","fields":[]},{"type":"record","name":"B","fields":[]}]
    ;
    var tp = try parseAvsc(gpa, two);
    defer tp.deinit();
    try std.testing.expectEqual(@as(usize, 2), tp.nodes.items[tp.root].branches.len);

    const ok_default =
        \\{"type":"record","name":"R","fields":[{"name":"a","type":["null","string"],"default":null}]}
    ;
    var dp = try parseAvsc(gpa, ok_default);
    defer dp.deinit();
    try std.testing.expect(dp.nodes.items[dp.root].fields[0].has_default);
}
