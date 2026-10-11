//! `gld-avrogen-zig` emitter. Generated types have `encodedLen`, `encode`, and `decode`.

const std = @import("std");
const canon = @import("canon.zig");
const diag = @import("diag.zig");
const idl = @import("idl.zig");
const schema = @import("schema.zig");

pub const Error = diag.Error;

const keywords = [_][]const u8{
    "addrspace", "align",     "allowzero", "and",        "anyframe", "anytype",  "asm",
    "async",     "await",     "break",     "callconv",   "catch",    "comptime", "const",
    "continue",  "defer",     "else",      "enum",       "errdefer", "error",    "export",
    "extern",    "fn",        "for",       "if",         "inline",   "noalias",  "noinline",
    "nosuspend", "opaque",    "or",        "orelse",     "packed",   "pub",      "resume",
    "return",    "linksection","struct",   "suspend",    "switch",   "test",     "threadlocal",
    "try",       "union",     "unreachable","unset",     "var",      "volatile", "while",
};

pub fn generateAvsc(gpa: std.mem.Allocator, io: std.Io, text: []const u8, out_dir: []const u8) Error!void {
    var pool = try schema.parseAvsc(gpa, text);
    defer pool.deinit();
    try emitPool(gpa, io, &pool, out_dir);
}

pub fn generateAvdl(gpa: std.mem.Allocator, io: std.Io, text: []const u8, from_file: []const u8, out_dir: []const u8) Error!void {
    var pool = try idl.parseAvdl(gpa, io, text, from_file);
    defer pool.deinit();
    try emitPool(gpa, io, &pool, out_dir);
}

const Rec = struct {
    ids: []u32,
    edges: []const []const u32,
    recursive: []bool,
    comp: []u32,
};

fn emitPool(gpa: std.mem.Allocator, io: std.Io, pool: *schema.SchemaPool, out_dir: []const u8) Error!void {
    var rec = try recursiveness(gpa, pool);
    defer {
        gpa.free(rec.ids);
        for (rec.edges) |e| gpa.free(e);
        gpa.free(rec.edges);
        gpa.free(rec.recursive);
        gpa.free(rec.comp);
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var count: usize = 0;
    for (pool.nodes.items, 0..) |n, i| {
        if (n.kind != .record and n.kind != .enum_type and n.kind != .fixed) continue;
        if (n.name.len == 0) continue;
        const path = try filePath(aa, out_dir, n);
        if (std.fs.path.dirname(path)) |dir| {
            std.Io.Dir.cwd().createDirPath(io, dir) catch return error.Schema;
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try emitFile(gpa, aa, pool, &rec, @intCast(i), &buf);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items }) catch return error.Schema;
        count += 1;
    }
    if (count == 0) return pool.failf("nothing to generate", .{});
}

fn filePath(aa: std.mem.Allocator, out_dir: []const u8, n: schema.SchemaNode) ![]u8 {
    const file = std.fmt.allocPrint(aa, "{s}.zig", .{n.short_name}) catch return error.OutOfMemory;
    if (n.namespace.len == 0) return std.fs.path.join(aa, &.{ out_dir, file }) catch error.OutOfMemory;
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(aa);
    parts.append(aa, out_dir) catch return error.OutOfMemory;
    var it = std.mem.splitScalar(u8, n.namespace, '.');
    while (it.next()) |p| parts.append(aa, p) catch return error.OutOfMemory;
    parts.append(aa, file) catch return error.OutOfMemory;
    return std.fs.path.join(aa, parts.items) catch error.OutOfMemory;
}

fn emitFile(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    rec: *const Rec,
    id: u32,
    buf: *std.ArrayList(u8),
) Error!void {
    const n = pool.nodes.items[id];
    try buf.appendSlice(gpa, "const std = @import(\"std\");\nconst avro = @import(\"avro\");\n");
    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();
    const visited = gpa.alloc(bool, pool.nodes.items.len) catch return error.OutOfMemory;
    defer gpa.free(visited);
    @memset(visited, false);
    try collectImports(gpa, aa, pool, id, id, visited, &seen, buf);
    const pcf = try canon.canonicalForm(pool, id, gpa);
    defer gpa.free(pcf);
    try buf.appendSlice(gpa, "\npub const schema_json =\n");
    try appendZigString(buf, gpa, pcf);
    try buf.appendSlice(gpa, ";\n\n");
    switch (n.kind) {
        .enum_type => try emitEnum(gpa, pool, id, buf),
        .fixed => try emitFixed(gpa, pool, id, buf),
        .record => try emitRecord(gpa, aa, pool, rec, id, buf),
        else => return error.Schema,
    }
}

fn collectImports(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    owner: u32,
    id: u32,
    visited: []bool,
    seen: *std.StringHashMap(void),
    buf: *std.ArrayList(u8),
) Error!void {
    if (visited[id]) return;
    visited[id] = true;
    const n = pool.nodes.items[id];
    switch (n.kind) {
        .record, .enum_type, .fixed => {
            if (id == owner) {
                if (n.kind == .record) {
                    for (n.fields) |f| try collectImports(gpa, aa, pool, owner, f.type_id, visited, seen, buf);
                }
                return;
            }
            const mangled = try mangledName(aa, n.name);
            if (seen.get(mangled) != null) return;
            seen.put(mangled, {}) catch return error.OutOfMemory;
            const imp = try importExpr(aa, pool.nodes.items[owner], n);
            try buf.appendSlice(gpa, "const ");
            try buf.appendSlice(gpa, mangled);
            try buf.appendSlice(gpa, " = ");
            try buf.appendSlice(gpa, imp);
            try buf.appendSlice(gpa, ";\n");
        },
        .array => try collectImports(gpa, aa, pool, owner, n.item_id, visited, seen, buf),
        .map => try collectImports(gpa, aa, pool, owner, n.value_id, visited, seen, buf),
        .union_type => for (n.branches) |b| try collectImports(gpa, aa, pool, owner, b, visited, seen, buf),
        else => {},
    }
}

fn importExpr(aa: std.mem.Allocator, from: schema.SchemaNode, to: schema.SchemaNode) ![]u8 {
    const file = std.fmt.allocPrint(aa, "{s}.zig", .{to.short_name}) catch return error.OutOfMemory;
    if (std.mem.eql(u8, from.namespace, to.namespace)) {
        return std.fmt.allocPrint(aa, "@import(\"{s}\").{s}", .{ file, safeType(to.short_name) }) catch error.OutOfMemory;
    }
    var ups: usize = 0;
    if (from.namespace.len != 0) {
        var it = std.mem.splitScalar(u8, from.namespace, '.');
        while (it.next()) |_| ups += 1;
    }
    var rel: std.ArrayList(u8) = .empty;
    defer rel.deinit(aa);
    for (0..ups) |_| rel.appendSlice(aa, "../") catch return error.OutOfMemory;
    if (to.namespace.len != 0) {
        var it = std.mem.splitScalar(u8, to.namespace, '.');
        while (it.next()) |p| {
            rel.appendSlice(aa, p) catch return error.OutOfMemory;
            rel.append(aa, '/') catch return error.OutOfMemory;
        }
    }
    rel.appendSlice(aa, file) catch return error.OutOfMemory;
    return std.fmt.allocPrint(aa, "@import(\"{s}\").{s}", .{ rel.items, safeType(to.short_name) }) catch error.OutOfMemory;
}

fn emitEnum(gpa: std.mem.Allocator, pool: *schema.SchemaPool, id: u32, buf: *std.ArrayList(u8)) Error!void {
    const n = pool.nodes.items[id];
    try buf.appendSlice(gpa, "pub const ");
    try buf.appendSlice(gpa, safeType(n.short_name));
    try buf.appendSlice(gpa, " = enum(i32) {\n");
    for (n.symbols, 0..) |s, i| {
        try buf.appendSlice(gpa, "    ");
        try buf.appendSlice(gpa, safeField(s));
        var tmp: [16]u8 = undefined;
        const num = std.fmt.bufPrint(&tmp, " = {d},\n", .{i}) catch unreachable;
        try buf.appendSlice(gpa, num);
    }
    try buf.appendSlice(gpa,
        \\    pub fn encodedLen(self: @This()) usize {
        \\        return avro.longLen(@intFromEnum(self));
        \\    }
        \\    pub fn encode(self: @This(), w: *avro.Writer) avro.Error!void {
        \\        try w.writeInt(@intFromEnum(self));
        \\    }
        \\    pub fn decode(r: *avro.Reader) avro.Error!@This() {
        \\        const i = try r.readInt();
        \\        return switch (i) {
        \\
    );
    for (n.symbols, 0..) |s, i| {
        var tmp: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&tmp, "            {d} => .{s},\n", .{ i, safeField(s) }) catch return error.Schema;
        try buf.appendSlice(gpa, line);
    }
    try buf.appendSlice(gpa,
        \\            else => error.BadEnum,
        \\        };
        \\    }
        \\    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        \\        _ = self;
        \\        _ = gpa;
        \\    }
        \\};
        \\
    );
}

fn emitFixed(gpa: std.mem.Allocator, pool: *schema.SchemaPool, id: u32, buf: *std.ArrayList(u8)) Error!void {
    const n = pool.nodes.items[id];
    var tmp: [512]u8 = undefined;
    const head = std.fmt.bufPrint(&tmp,
        \\pub const {s} = struct {{
        \\    bytes: [{d}]u8,
        \\    pub fn encodedLen(self: @This()) usize {{
        \\        _ = self;
        \\        return {d};
        \\    }}
        \\    pub fn encode(self: @This(), w: *avro.Writer) avro.Error!void {{
        \\        try w.writeFixed(&self.bytes);
        \\    }}
        \\    pub fn decode(r: *avro.Reader) avro.Error!@This() {{
        \\        var out: @This() = undefined;
        \\        try r.readRawInto(&out.bytes);
        \\        return out;
        \\    }}
        \\    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {{
        \\        _ = self;
        \\        _ = gpa;
        \\    }}
        \\}};
        \\
    , .{ safeType(n.short_name), n.size, n.size }) catch return error.Schema;
    try buf.appendSlice(gpa, head);
}

fn emitRecord(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    rec: *const Rec,
    id: u32,
    buf: *std.ArrayList(u8),
) Error!void {
    const n = pool.nodes.items[id];
    // Tagged unions first so the struct can name them.
    for (n.fields) |f| {
        const ft = pool.nodes.items[f.type_id];
        if (ft.kind == .union_type and !isNullable(pool, f.type_id)) {
            try emitTagged(gpa, aa, pool, rec, id, f, buf);
        }
    }
    try buf.appendSlice(gpa, "pub const ");
    try buf.appendSlice(gpa, safeType(n.short_name));
    try buf.appendSlice(gpa, " = struct {\n");
    for (n.fields) |f| {
        const ft = pool.nodes.items[f.type_id];
        const ty = if (ft.kind == .union_type and !isNullable(pool, f.type_id))
            try unionName(aa, n.short_name, f.name)
        else
            try typeExpr(aa, pool, rec, id, f.type_id, false);
        try buf.appendSlice(gpa, "    ");
        try buf.appendSlice(gpa, safeField(f.name));
        try buf.appendSlice(gpa, ": ");
        try buf.appendSlice(gpa, ty);
        try buf.appendSlice(gpa, ",\n");
    }
    try buf.appendSlice(gpa, "    pub fn encodedLen(self: @This()) usize {\n        var n: usize = 0;\n");
    for (n.fields) |f| try emitLenField(gpa, aa, pool, rec, id, f, buf);
    try buf.appendSlice(gpa, "        return n;\n    }\n");
    try buf.appendSlice(gpa, "    pub fn encode(self: @This(), w: *avro.Writer) avro.Error!void {\n");
    for (n.fields) |f| try emitEncField(gpa, aa, pool, rec, id, f, buf);
    try buf.appendSlice(gpa, "    }\n");
    try buf.appendSlice(gpa, "    pub fn decode(r: *avro.Reader, gpa: std.mem.Allocator) avro.Error!@This() {\n");
    for (n.fields) |f| try emitDecField(gpa, aa, pool, rec, id, f, buf);
    try buf.appendSlice(gpa, "        return .{\n");
    for (n.fields) |f| {
        try buf.appendSlice(gpa, "            .");
        try buf.appendSlice(gpa, safeField(f.name));
        try buf.appendSlice(gpa, " = ");
        try buf.appendSlice(gpa, safeField(f.name));
        try buf.appendSlice(gpa, ",\n");
    }
    try buf.appendSlice(gpa, "        };\n    }\n");
    try buf.appendSlice(gpa, "    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {\n");
    for (n.fields) |f| try emitDeinitField(gpa, aa, pool, rec, id, f, buf);
    try buf.appendSlice(gpa, "    }\n};\n");
}

fn emitTagged(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    rec: *const Rec,
    owner: u32,
    field: schema.Field,
    buf: *std.ArrayList(u8),
) Error!void {
    const un = pool.nodes.items[field.type_id];
    const uname = try unionName(aa, pool.nodes.items[owner].short_name, field.name);
    try buf.appendSlice(gpa, "pub const ");
    try buf.appendSlice(gpa, uname);
    try buf.appendSlice(gpa, " = union(enum) {\n");
    for (un.branches, 0..) |b, i| {
        const bn = pool.nodes.items[b];
        const tag = try branchTag(aa, bn, i);
        try buf.appendSlice(gpa, "    ");
        try buf.appendSlice(gpa, tag);
        try buf.appendSlice(gpa, ": ");
        if (bn.kind == .null) {
            try buf.appendSlice(gpa, "void");
        } else {
            const ty = try typeExpr(aa, pool, rec, owner, b, true);
            try buf.appendSlice(gpa, ty);
        }
        try buf.appendSlice(gpa, ",\n");
    }
    try buf.appendSlice(gpa, "    pub fn encodedLen(self: @This()) usize {\n        return switch (self) {\n");
    for (un.branches, 0..) |b, i| {
        const bn = pool.nodes.items[b];
        const tag = try branchTag(aa, bn, i);
        var tmp: [32]u8 = undefined;
        const idx = std.fmt.bufPrint(&tmp, "{d}", .{i}) catch unreachable;
        try buf.appendSlice(gpa, "            .");
        try buf.appendSlice(gpa, tag);
        try buf.appendSlice(gpa, " => |v| avro.longLen(");
        try buf.appendSlice(gpa, idx);
        try buf.appendSlice(gpa, ")");
        if (bn.kind != .null) {
            try buf.appendSlice(gpa, " + ");
            try emitLenValue(gpa, aa, pool, rec, owner, b, "v", buf);
        }
        try buf.appendSlice(gpa, ",\n");
    }
    try buf.appendSlice(gpa, "        };\n    }\n    pub fn encode(self: @This(), w: *avro.Writer) avro.Error!void {\n        switch (self) {\n");
    for (un.branches, 0..) |b, i| {
        const bn = pool.nodes.items[b];
        const tag = try branchTag(aa, bn, i);
        var tmp: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&tmp, "            .{s} => |v| {{ try w.writeLong({d}); ", .{ tag, i }) catch return error.Schema;
        try buf.appendSlice(gpa, line);
        if (bn.kind != .null) {
            try emitEncValue(gpa, aa, pool, rec, owner, b, "v", buf);
            try buf.appendSlice(gpa, "; },\n");
        } else try buf.appendSlice(gpa, "},\n");
    }
    try buf.appendSlice(gpa, "        }\n    }\n    pub fn decode(r: *avro.Reader, gpa: std.mem.Allocator) avro.Error!@This() {\n        const i = try r.readLong();\n        switch (i) {\n");
    for (un.branches, 0..) |b, i| {
        const bn = pool.nodes.items[b];
        const tag = try branchTag(aa, bn, i);
        var tmp: [80]u8 = undefined;
        const line = std.fmt.bufPrint(&tmp, "            {d} => return .{{ .{s} = ", .{ i, tag }) catch return error.Schema;
        try buf.appendSlice(gpa, line);
        if (bn.kind == .null) {
            try buf.appendSlice(gpa, "{}");
        } else {
            try emitDecExpr(gpa, aa, pool, rec, owner, b, buf);
        }
        try buf.appendSlice(gpa, " },\n");
    }
    try buf.appendSlice(gpa, "            else => return error.BadUnion,\n        }\n    }\n    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {\n        switch (self.*) {\n");
    for (un.branches, 0..) |b, i| {
        const bn = pool.nodes.items[b];
        const tag = try branchTag(aa, bn, i);
        try buf.appendSlice(gpa, "            .");
        try buf.appendSlice(gpa, tag);
        try buf.appendSlice(gpa, " => |v| { ");
        if (bn.kind == .null) {
            try buf.appendSlice(gpa, "_ = v;");
        } else if (bn.kind == .record and rec.recursive[b] and sameComponent(rec, owner, b)) {
            try buf.appendSlice(gpa, "v.deinit(gpa); gpa.destroy(v);");
        } else {
            try emitDeinitValue(gpa, aa, pool, rec, owner, b, "v", buf);
            if (deinitIsExpr(pool, b)) try buf.appendSlice(gpa, ";");
        }
        try buf.appendSlice(gpa, " },\n");
    }
    try buf.appendSlice(gpa, "        }\n    }\n};\n");
}

fn isNullable(pool: *schema.SchemaPool, id: u32) bool {
    const n = pool.nodes.items[id];
    if (n.kind != .union_type or n.branches.len != 2) return false;
    const a = pool.nodes.items[n.branches[0]].kind == .null;
    const b = pool.nodes.items[n.branches[1]].kind == .null;
    return a != b;
}

fn nullIndex(pool: *schema.SchemaPool, id: u32) usize {
    const n = pool.nodes.items[id];
    if (pool.nodes.items[n.branches[0]].kind == .null) return 0;
    return 1;
}

fn payloadIndex(pool: *schema.SchemaPool, id: u32) usize {
    return 1 - nullIndex(pool, id);
}

fn typeExpr(
    aa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    rec: *const Rec,
    owner: u32,
    id: u32,
    in_union: bool,
) Error![]const u8 {
    const n = pool.nodes.items[id];
    switch (n.kind) {
        .null => return "void",
        .boolean => return "bool",
        .int => return "i32",
        .long => return "i64",
        .float => return "f32",
        .double => return "f64",
        .bytes, .string => return "[]const u8",
        .enum_type, .fixed => return mangledOrSelf(aa, pool, owner, id),
        .record => {
            if (rec.recursive[id] and sameComponent(rec, owner, id)) {
                if (!in_union) return error.Schema;
                const name = try mangledOrSelf(aa, pool, owner, id);
                return std.fmt.allocPrint(aa, "*{s}", .{name}) catch error.OutOfMemory;
            }
            return mangledOrSelf(aa, pool, owner, id);
        },
        .array => {
            const inner = try typeExpr(aa, pool, rec, owner, n.item_id, false);
            return std.fmt.allocPrint(aa, "[]const {s}", .{inner}) catch error.OutOfMemory;
        },
        .map => {
            const inner = try typeExpr(aa, pool, rec, owner, n.value_id, false);
            return std.fmt.allocPrint(aa, "[]const struct {{ key: []const u8, value: {s} }}", .{inner}) catch error.OutOfMemory;
        },
        .union_type => {
            if (isNullable(pool, id)) {
                const p = n.branches[payloadIndex(pool, id)];
                const inner = try typeExpr(aa, pool, rec, owner, p, true);
                return std.fmt.allocPrint(aa, "?{s}", .{inner}) catch error.OutOfMemory;
            }
            return unionName(aa, pool.nodes.items[owner].short_name, "value");
        },
        .unresolved => return error.Schema,
    }
}

fn mangledOrSelf(aa: std.mem.Allocator, pool: *schema.SchemaPool, owner: u32, id: u32) ![]const u8 {
    if (id == owner) return safeType(pool.nodes.items[id].short_name);
    return mangledName(aa, pool.nodes.items[id].name);
}

fn sameComponent(rec: *const Rec, a: u32, b: u32) bool {
    if (a == b) return true;
    if (a >= rec.comp.len or b >= rec.comp.len) return false;
    if (!rec.recursive[a] or !rec.recursive[b]) return false;
    return rec.comp[a] == rec.comp[b];
}

fn emitLenField(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    rec: *const Rec,
    owner: u32,
    field: schema.Field,
    buf: *std.ArrayList(u8),
) Error!void {
    const access = try std.fmt.allocPrint(aa, "self.{s}", .{safeField(field.name)});
    try buf.appendSlice(gpa, "        n += ");
    try emitLenValue(gpa, aa, pool, rec, owner, field.type_id, access, buf);
    try buf.appendSlice(gpa, ";\n");
}

fn emitLenValue(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    rec: *const Rec,
    owner: u32,
    id: u32,
    access: []const u8,
    buf: *std.ArrayList(u8),
) Error!void {
    const n = pool.nodes.items[id];
    switch (n.kind) {
        .null => try buf.appendSlice(gpa, "0"),
        .boolean => try buf.appendSlice(gpa, "1"),
        .int, .long => {
            try buf.appendSlice(gpa, "avro.longLen(");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ")");
        },
        .float => try buf.appendSlice(gpa, "4"),
        .double => try buf.appendSlice(gpa, "8"),
        .bytes, .string => {
            try buf.appendSlice(gpa, "avro.bytesLen(");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ".len)");
        },
        .fixed => {
            var tmp: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n.size}) catch unreachable;
            try buf.appendSlice(gpa, s);
        },
        .enum_type, .record => {
            if (n.kind == .record and rec.recursive[id] and sameComponent(rec, owner, id)) {
                try buf.appendSlice(gpa, access);
                try buf.appendSlice(gpa, ".encodedLen()");
            } else {
                try buf.appendSlice(gpa, access);
                try buf.appendSlice(gpa, ".encodedLen()");
            }
        },
        .array => {
            try buf.appendSlice(gpa, "blk: { var t: usize = avro.longLen(0); if (");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ".len > 0) { t += avro.longLen(@intCast(");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ".len)); for (");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ") |item| t += ");
            try emitLenValue(gpa, aa, pool, rec, owner, n.item_id, "item", buf);
            try buf.appendSlice(gpa, "; } break :blk t; }");
        },
        .map => {
            try buf.appendSlice(gpa, "blk: { var t: usize = avro.longLen(0); if (");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ".len > 0) { t += avro.longLen(@intCast(");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ".len)); for (");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ") |item| t += avro.bytesLen(item.key.len) + ");
            try emitLenValue(gpa, aa, pool, rec, owner, n.value_id, "item.value", buf);
            try buf.appendSlice(gpa, "; } break :blk t; }");
        },
        .union_type => {
            if (isNullable(pool, id)) {
                const ni: i64 = @intCast(nullIndex(pool, id));
                const pi: i64 = @intCast(payloadIndex(pool, id));
                const p = n.branches[payloadIndex(pool, id)];
                try buf.appendSlice(gpa, "blk: { if (");
                try buf.appendSlice(gpa, access);
                var tmp: [80]u8 = undefined;
                const mid = std.fmt.bufPrint(&tmp, ") |v| break :blk avro.longLen({d}) + ", .{pi}) catch unreachable;
                try buf.appendSlice(gpa, mid);
                const boxed = pool.nodes.items[p].kind == .record and rec.recursive[p] and sameComponent(rec, owner, p);
                if (boxed) {
                    try emitLenValue(gpa, aa, pool, rec, owner, p, "v.*", buf);
                } else try emitLenValue(gpa, aa, pool, rec, owner, p, "v", buf);
                const tail = std.fmt.bufPrint(&tmp, "; break :blk avro.longLen({d}); }}", .{ni}) catch unreachable;
                try buf.appendSlice(gpa, tail);
            } else {
                try buf.appendSlice(gpa, access);
                try buf.appendSlice(gpa, ".encodedLen()");
            }
        },
        .unresolved => return error.Schema,
    }
}

fn emitEncField(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    rec: *const Rec,
    owner: u32,
    field: schema.Field,
    buf: *std.ArrayList(u8),
) Error!void {
    const access = try std.fmt.allocPrint(aa, "self.{s}", .{safeField(field.name)});
    try buf.appendSlice(gpa, "        ");
    try emitEncValue(gpa, aa, pool, rec, owner, field.type_id, access, buf);
    try buf.appendSlice(gpa, ";\n");
}

fn emitEncValue(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    rec: *const Rec,
    owner: u32,
    id: u32,
    access: []const u8,
    buf: *std.ArrayList(u8),
) Error!void {
    const n = pool.nodes.items[id];
    switch (n.kind) {
        .null => try buf.appendSlice(gpa, "{}"),
        .boolean => {
            try buf.appendSlice(gpa, "try w.writeBool(");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ")");
        },
        .int => {
            try buf.appendSlice(gpa, "try w.writeInt(");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ")");
        },
        .long => {
            try buf.appendSlice(gpa, "try w.writeLong(");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ")");
        },
        .float => {
            try buf.appendSlice(gpa, "try w.writeFloat(");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ")");
        },
        .double => {
            try buf.appendSlice(gpa, "try w.writeDouble(");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ")");
        },
        .bytes => {
            try buf.appendSlice(gpa, "try w.writeBytes(");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ")");
        },
        .string => {
            try buf.appendSlice(gpa, "try w.writeString(");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ")");
        },
        .fixed => {
            try buf.appendSlice(gpa, "try w.writeFixed(&");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ".bytes)");
        },
        .enum_type, .record => {
            try buf.appendSlice(gpa, "try ");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ".encode(w)");
        },
        .array => {
            try buf.appendSlice(gpa, "if (");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ".len > 0) { try w.writeLong(@intCast(");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ".len)); for (");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ") |item| { ");
            try emitEncValue(gpa, aa, pool, rec, owner, n.item_id, "item", buf);
            try buf.appendSlice(gpa, "; } } try w.writeBlockEnd()");
        },
        .map => {
            try buf.appendSlice(gpa, "if (");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ".len > 0) { try w.writeLong(@intCast(");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ".len)); for (");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ") |item| { try w.writeString(item.key); ");
            try emitEncValue(gpa, aa, pool, rec, owner, n.value_id, "item.value", buf);
            try buf.appendSlice(gpa, "; } } try w.writeBlockEnd()");
        },
        .union_type => {
            if (isNullable(pool, id)) {
                const ni: i64 = @intCast(nullIndex(pool, id));
                const pi: i64 = @intCast(payloadIndex(pool, id));
                const p = n.branches[payloadIndex(pool, id)];
                const boxed = pool.nodes.items[p].kind == .record and rec.recursive[p] and sameComponent(rec, owner, p);
                var tmp: [64]u8 = undefined;
                const head = std.fmt.bufPrint(&tmp, "if ({s}) |v| {{ try w.writeLong({d}); ", .{ access, pi }) catch return error.Schema;
                try buf.appendSlice(gpa, head);
                if (boxed) try emitEncValue(gpa, aa, pool, rec, owner, p, "v.*", buf) else try emitEncValue(gpa, aa, pool, rec, owner, p, "v", buf);
                const tail = std.fmt.bufPrint(&tmp, "; }} else try w.writeLong({d})", .{ni}) catch unreachable;
                try buf.appendSlice(gpa, tail);
            } else {
                try buf.appendSlice(gpa, "try ");
                try buf.appendSlice(gpa, access);
                try buf.appendSlice(gpa, ".encode(w)");
            }
        },
        .unresolved => return error.Schema,
    }
}

fn emitDecField(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    rec: *const Rec,
    owner: u32,
    field: schema.Field,
    buf: *std.ArrayList(u8),
) Error!void {
    const name = safeField(field.name);
    const ft = pool.nodes.items[field.type_id];
    const ty = if (ft.kind == .union_type and !isNullable(pool, field.type_id))
        try unionName(aa, pool.nodes.items[owner].short_name, field.name)
    else
        try typeExpr(aa, pool, rec, owner, field.type_id, false);
    try buf.appendSlice(gpa, "        const ");
    try buf.appendSlice(gpa, name);
    try buf.appendSlice(gpa, ": ");
    try buf.appendSlice(gpa, ty);
    try buf.appendSlice(gpa, " = ");
    if (ft.kind == .union_type and !isNullable(pool, field.type_id)) {
        try buf.appendSlice(gpa, "try ");
        try buf.appendSlice(gpa, ty);
        try buf.appendSlice(gpa, ".decode(r, gpa)");
    } else try emitDecExpr(gpa, aa, pool, rec, owner, field.type_id, buf);
    try buf.appendSlice(gpa, ";\n");
    if (needsCleanup(pool, field.type_id)) {
        try buf.appendSlice(gpa, "        errdefer ");
        try emitDeinitValue(gpa, aa, pool, rec, owner, field.type_id, name, buf);
        try finishDeinit(gpa, pool, field.type_id, true, buf);
        try buf.appendSlice(gpa, "\n");
    }
}

fn emitDecExpr(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    rec: *const Rec,
    owner: u32,
    id: u32,
    buf: *std.ArrayList(u8),
) Error!void {
    const n = pool.nodes.items[id];
    switch (n.kind) {
        .null => try buf.appendSlice(gpa, "{}"),
        .boolean => try buf.appendSlice(gpa, "try r.readBool()"),
        .int => try buf.appendSlice(gpa, "try r.readInt()"),
        .long => try buf.appendSlice(gpa, "try r.readLong()"),
        .float => try buf.appendSlice(gpa, "try r.readFloat()"),
        .double => try buf.appendSlice(gpa, "try r.readDouble()"),
        .bytes => try buf.appendSlice(gpa, "try r.readBytes(gpa)"),
        .string => try buf.appendSlice(gpa, "try r.readString(gpa)"),
        .fixed => {
            const ty = try mangledOrSelf(aa, pool, owner, id);
            try buf.appendSlice(gpa, "try ");
            try buf.appendSlice(gpa, ty);
            try buf.appendSlice(gpa, ".decode(r)");
        },
        .enum_type => {
            const ty = try mangledOrSelf(aa, pool, owner, id);
            try buf.appendSlice(gpa, "try ");
            try buf.appendSlice(gpa, ty);
            try buf.appendSlice(gpa, ".decode(r)");
        },
        .record => {
            const ty = try mangledOrSelf(aa, pool, owner, id);
            if (rec.recursive[id] and sameComponent(rec, owner, id)) {
                try buf.appendSlice(gpa, "blk: { const p = gpa.create(");
                try buf.appendSlice(gpa, ty);
                try buf.appendSlice(gpa, ") catch return error.OutOfMemory; p.* = try ");
                try buf.appendSlice(gpa, ty);
                try buf.appendSlice(gpa, ".decode(r, gpa); break :blk p; }");
            } else {
                try buf.appendSlice(gpa, "try ");
                try buf.appendSlice(gpa, ty);
                try buf.appendSlice(gpa, ".decode(r, gpa)");
            }
        },
        .array => try emitDecArray(gpa, aa, pool, rec, owner, id, buf),
        .map => try emitDecMap(gpa, aa, pool, rec, owner, id, buf),
        .union_type => {
            if (isNullable(pool, id)) {
                try emitDecOptional(gpa, aa, pool, rec, owner, id, buf);
            } else {
                const uname = try unionName(aa, pool.nodes.items[owner].short_name, "value");
                try buf.appendSlice(gpa, "try ");
                try buf.appendSlice(gpa, uname);
                try buf.appendSlice(gpa, ".decode(r, gpa)");
            }
        },
        .unresolved => return error.Schema,
    }
}

fn emitDecArray(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    rec: *const Rec,
    owner: u32,
    id: u32,
    buf: *std.ArrayList(u8),
) Error!void {
    const inner = try typeExpr(aa, pool, rec, owner, pool.nodes.items[id].item_id, false);
    try buf.appendSlice(gpa, "blk: { var list: std.ArrayList(");
    try buf.appendSlice(gpa, inner);
    try buf.appendSlice(gpa, ") = .empty; errdefer list.deinit(gpa); while (true) { const blkc = try r.readBlockCount(); if (blkc.count == 0) break; const cnt: usize = std.math.cast(usize, blkc.count) orelse return error.Range; const start = r.pos; for (0..cnt) |_| { const item = ");
    try emitDecExpr(gpa, aa, pool, rec, owner, pool.nodes.items[id].item_id, buf);
    try buf.appendSlice(gpa, "; list.append(gpa, item) catch return error.OutOfMemory; } if (blkc.size_hint >= 0 and r.pos - start > @as(usize, @intCast(blkc.size_hint))) return error.BadBlock; } break :blk try list.toOwnedSlice(gpa); }");
}

fn emitDecMap(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    rec: *const Rec,
    owner: u32,
    id: u32,
    buf: *std.ArrayList(u8),
) Error!void {
    const inner = try typeExpr(aa, pool, rec, owner, pool.nodes.items[id].value_id, false);
    try buf.appendSlice(gpa, "blk: { var list: std.ArrayList(struct { key: []const u8, value: ");
    try buf.appendSlice(gpa, inner);
    try buf.appendSlice(gpa, " }) = .empty; errdefer list.deinit(gpa); while (true) { const blkc = try r.readBlockCount(); if (blkc.count == 0) break; const cnt: usize = std.math.cast(usize, blkc.count) orelse return error.Range; const start = r.pos; for (0..cnt) |_| { const key = try r.readString(gpa); const value = ");
    try emitDecExpr(gpa, aa, pool, rec, owner, pool.nodes.items[id].value_id, buf);
    try buf.appendSlice(gpa, "; list.append(gpa, .{ .key = key, .value = value }) catch return error.OutOfMemory; } if (blkc.size_hint >= 0 and r.pos - start > @as(usize, @intCast(blkc.size_hint))) return error.BadBlock; } break :blk try list.toOwnedSlice(gpa); }");
}

fn emitDecOptional(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    rec: *const Rec,
    owner: u32,
    id: u32,
    buf: *std.ArrayList(u8),
) Error!void {
    const n = pool.nodes.items[id];
    const ni = nullIndex(pool, id);
    const pi = payloadIndex(pool, id);
    const p = n.branches[pi];
    const boxed = pool.nodes.items[p].kind == .record and rec.recursive[p] and sameComponent(rec, owner, p);
    var tmp: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&tmp, "blk: {{ const idx = try r.readLong(); if (idx == {d}) break :blk null; if (idx != {d}) return error.BadUnion; ", .{ ni, pi }) catch return error.Schema;
    try buf.appendSlice(gpa, head);
    if (boxed) {
        const ty = try mangledOrSelf(aa, pool, owner, p);
        try buf.appendSlice(gpa, "const p = gpa.create(");
        try buf.appendSlice(gpa, ty);
        try buf.appendSlice(gpa, ") catch return error.OutOfMemory; p.* = try ");
        try buf.appendSlice(gpa, ty);
        try buf.appendSlice(gpa, ".decode(r, gpa); break :blk p; }");
    } else {
        try buf.appendSlice(gpa, "break :blk ");
        try emitDecExpr(gpa, aa, pool, rec, owner, p, buf);
        try buf.appendSlice(gpa, "; }");
    }
}

fn emitDeinitField(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    rec: *const Rec,
    owner: u32,
    field: schema.Field,
    buf: *std.ArrayList(u8),
) Error!void {
    if (!needsCleanup(pool, field.type_id)) return;
    const access = try std.fmt.allocPrint(aa, "self.{s}", .{safeField(field.name)});
    try buf.appendSlice(gpa, "        ");
    try emitDeinitValue(gpa, aa, pool, rec, owner, field.type_id, access, buf);
    try finishDeinit(gpa, pool, field.type_id, false, buf);
    try buf.appendSlice(gpa, "\n");
}

fn emitDeinitValue(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    rec: *const Rec,
    owner: u32,
    id: u32,
    access: []const u8,
    buf: *std.ArrayList(u8),
) Error!void {
    const n = pool.nodes.items[id];
    switch (n.kind) {
        .null, .boolean, .int, .long, .float, .double, .enum_type, .fixed => {
            try buf.appendSlice(gpa, "_ = ");
            try buf.appendSlice(gpa, access);
        },
        .bytes, .string => {
            try buf.appendSlice(gpa, "gpa.free(");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ")");
        },
        .record => {
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ".deinit(gpa)");
        },
        .array => {
            try buf.appendSlice(gpa, "{ for (");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ") |*item| { ");
            try emitDeinitValue(gpa, aa, pool, rec, owner, n.item_id, "item.*", buf);
            if (deinitIsExpr(pool, n.item_id)) try buf.appendSlice(gpa, ";");
            try buf.appendSlice(gpa, " } gpa.free(");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, "); }");
        },
        .map => {
            try buf.appendSlice(gpa, "{ for (");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, ") |*item| { gpa.free(item.key); ");
            try emitDeinitValue(gpa, aa, pool, rec, owner, n.value_id, "item.value", buf);
            if (deinitIsExpr(pool, n.value_id)) try buf.appendSlice(gpa, ";");
            try buf.appendSlice(gpa, " } gpa.free(");
            try buf.appendSlice(gpa, access);
            try buf.appendSlice(gpa, "); }");
        },
        .union_type => {
            if (isNullable(pool, id)) {
                const p = n.branches[payloadIndex(pool, id)];
                const boxed = pool.nodes.items[p].kind == .record and rec.recursive[p] and sameComponent(rec, owner, p);
                try buf.appendSlice(gpa, "if (");
                try buf.appendSlice(gpa, access);
                try buf.appendSlice(gpa, ") |v| { ");
                if (boxed) {
                    try buf.appendSlice(gpa, "v.deinit(gpa); gpa.destroy(v);");
                } else {
                    // v is a copy for slices? optional slice: `if (opt) |v|` copies the slice. free is fine.
                    // For records by value, v is a copy and deinit on copy frees the same pointers. OK if we don't use self after.
                    try emitDeinitValue(gpa, aa, pool, rec, owner, p, "v", buf);
                    if (deinitIsExpr(pool, p)) try buf.appendSlice(gpa, ";");
                }
                try buf.appendSlice(gpa, " }");
            } else {
                try buf.appendSlice(gpa, access);
                try buf.appendSlice(gpa, ".deinit(gpa)");
            }
        },
        .unresolved => return error.Schema,
    }
}

fn needsCleanup(pool: *schema.SchemaPool, id: u32) bool {
    const n = pool.nodes.items[id];
    return switch (n.kind) {
        .null, .boolean, .int, .long, .float, .double, .enum_type, .fixed => false,
        .union_type => if (isNullable(pool, id)) needsCleanup(pool, n.branches[payloadIndex(pool, id)]) else true,
        else => true,
    };
}

fn finishDeinit(
    gpa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    id: u32,
    errdefer_site: bool,
    buf: *std.ArrayList(u8),
) Error!void {
    if (deinitIsExpr(pool, id)) {
        try buf.appendSlice(gpa, ";");
        return;
    }
    const n = pool.nodes.items[id];
    if (errdefer_site and n.kind == .union_type and isNullable(pool, id)) try buf.appendSlice(gpa, ";");
}

fn deinitIsExpr(pool: *schema.SchemaPool, id: u32) bool {
    const n = pool.nodes.items[id];
    return switch (n.kind) {
        .null, .boolean, .int, .long, .float, .double, .bytes, .string, .enum_type, .fixed, .record => true,
        .union_type => !isNullable(pool, id),
        else => false,
    };
}

fn recursiveness(gpa: std.mem.Allocator, pool: *schema.SchemaPool) Error!Rec {
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(gpa);
    for (pool.nodes.items, 0..) |n, i| if (n.kind == .record) ids.append(gpa, @intCast(i)) catch return error.OutOfMemory;
    const index_of = gpa.alloc(i32, pool.nodes.items.len) catch return error.OutOfMemory;
    defer gpa.free(index_of);
    @memset(index_of, -1);
    for (ids.items, 0..) |id, i| index_of[id] = @intCast(i);
    const edges = gpa.alloc([]u32, ids.items.len) catch return error.OutOfMemory;
    for (ids.items, 0..) |id, i| {
        var dest: std.ArrayList(u32) = .empty;
        for (pool.nodes.items[id].fields) |f| try walkRecords(pool, index_of, f.type_id, &dest);
        edges[i] = dest.toOwnedSlice(gpa) catch return error.OutOfMemory;
    }
    const recursive = gpa.alloc(bool, pool.nodes.items.len) catch return error.OutOfMemory;
    @memset(recursive, false);
    const comp = gpa.alloc(u32, pool.nodes.items.len) catch return error.OutOfMemory;
    for (comp, 0..) |*c, i| c.* = @intCast(i);
    if (ids.items.len != 0) try tarjan(gpa, ids.items, edges, recursive, comp);
    return .{
        .ids = ids.toOwnedSlice(gpa) catch return error.OutOfMemory,
        .edges = edges,
        .recursive = recursive,
        .comp = comp,
    };
}

fn walkRecords(pool: *schema.SchemaPool, index_of: []const i32, id: u32, dest: *std.ArrayList(u32)) Error!void {
    const n = pool.nodes.items[id];
    switch (n.kind) {
        .record => if (index_of[id] >= 0) dest.append(pool.gpa, @intCast(index_of[id])) catch return error.OutOfMemory,
        .array => try walkRecords(pool, index_of, n.item_id, dest),
        .map => try walkRecords(pool, index_of, n.value_id, dest),
        .union_type => for (n.branches) |b| try walkRecords(pool, index_of, b, dest),
        else => {},
    }
}

fn tarjan(gpa: std.mem.Allocator, ids: []const u32, edges: []const []const u32, recursive: []bool, comp: []u32) Error!void {
    const n = ids.len;
    var index: u32 = 0;
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    const dfi = gpa.alloc(i32, n) catch return error.OutOfMemory;
    defer gpa.free(dfi);
    @memset(dfi, -1);
    const low = gpa.alloc(u32, n) catch return error.OutOfMemory;
    defer gpa.free(low);
    const on = gpa.alloc(bool, n) catch return error.OutOfMemory;
    defer gpa.free(on);
    @memset(on, false);
    const Ctx = struct {
        ids: []const u32,
        edges: []const []const u32,
        recursive: []bool,
        comp: []u32,
        index: *u32,
        stack: *std.ArrayList(u32),
        dfi: []i32,
        low: []u32,
        on: []bool,
        gpa: std.mem.Allocator,
        fn strong(self: *@This(), v: u32) Error!void {
            self.dfi[v] = @intCast(self.index.*);
            self.low[v] = self.index.*;
            self.index.* += 1;
            self.stack.append(self.gpa, v) catch return error.OutOfMemory;
            self.on[v] = true;
            for (self.edges[v]) |w| {
                if (self.dfi[w] < 0) {
                    try self.strong(w);
                    if (self.low[w] < self.low[v]) self.low[v] = self.low[w];
                } else if (self.on[w] and @as(u32, @intCast(self.dfi[w])) < self.low[v]) {
                    self.low[v] = @intCast(self.dfi[w]);
                }
            }
            if (self.low[v] == @as(u32, @intCast(self.dfi[v]))) {
                var members: std.ArrayList(u32) = .empty;
                defer members.deinit(self.gpa);
                while (true) {
                    const w = self.stack.pop() orelse break;
                    self.on[w] = false;
                    members.append(self.gpa, w) catch return error.OutOfMemory;
                    if (w == v) break;
                }
                var self_loop = false;
                if (members.items.len == 1) {
                    for (self.edges[members.items[0]]) |e| {
                        if (e == members.items[0]) self_loop = true;
                    }
                }
                const recu = members.items.len > 1 or self_loop;
                const root = self.ids[members.items[0]];
                for (members.items) |c| {
                    self.recursive[self.ids[c]] = recu;
                    self.comp[self.ids[c]] = root;
                }
            }
        }
    };
    var ctx = Ctx{
        .ids = ids,
        .edges = edges,
        .recursive = recursive,
        .comp = comp,
        .index = &index,
        .stack = &stack,
        .dfi = dfi,
        .low = low,
        .on = on,
        .gpa = gpa,
    };
    for (0..n) |v| if (dfi[v] < 0) try ctx.strong(@intCast(v));
}

fn mangledName(aa: std.mem.Allocator, full: []const u8) ![]const u8 {
    const buf = aa.alloc(u8, full.len) catch return error.OutOfMemory;
    for (full, 0..) |c, i| buf[i] = if (c == '.') '_' else c;
    return buf;
}

fn unionName(aa: std.mem.Allocator, record: []const u8, field: []const u8) ![]const u8 {
    return std.fmt.allocPrint(aa, "{s}_{s}", .{ safeType(record), safeField(field) }) catch error.OutOfMemory;
}

fn branchTag(aa: std.mem.Allocator, n: schema.SchemaNode, index: usize) ![]const u8 {
    const base = switch (n.kind) {
        .record, .enum_type, .fixed => n.short_name,
        .null => "null",
        else => schema.kindName(n.kind),
    };
    if (isKeyword(base) or std.mem.eql(u8, base, "null")) {
        return std.fmt.allocPrint(aa, "@\"{s}\"", .{base}) catch error.OutOfMemory;
    }
    _ = index;
    return safeField(base);
}

fn safeType(name: []const u8) []const u8 {
    // Zig keywords are not wrapped in @"". An Avro name that is a Zig keyword will not compile.
    return name;
}

fn safeField(name: []const u8) []const u8 {
    return safeType(name);
}

fn isKeyword(name: []const u8) bool {
    for (keywords) |k| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

fn appendZigString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) Error!void {
    try buf.appendSlice(gpa, "    \\\\");
    try buf.appendSlice(gpa, s);
    try buf.appendSlice(gpa, "\n");
}

fn ioForTest() std.Io {
    return if (comptime @import("builtin").is_test) std.testing.io else undefined;
}

test "codegen emits encode and decode and boxes recursion" {
    const gpa = std.testing.allocator;
    const ll =
        \\{"type":"record","name":"LongList","fields":[{"name":"value","type":"long"},{"name":"next","type":["null","LongList"]}]}
    ;
    try generateAvsc(gpa, ioForTest(), ll, "temp/avro-gen-ll");
    const text = std.Io.Dir.cwd().readFileAlloc(ioForTest(), "temp/avro-gen-ll/LongList.zig", gpa, .limited(1 << 20)) catch return error.Schema;
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "fn encodedLen") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fn encode") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fn decode") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "?*LongList") != null);

    const bad =
        \\{"type":"record","name":"Bad","fields":[{"name":"self","type":"Bad"}]}
    ;
    try std.testing.expectError(error.Schema, generateAvsc(gpa, ioForTest(), bad, "temp/avro-gen-bad"));

    const flat =
        \\{"type":"record","name":"M","namespace":"demo","fields":[{"name":"a","type":"int"},{"name":"b","type":"string"},{"name":"c","type":["null","long"],"default":null},{"name":"d","type":["int","string"]}]}
    ;
    try generateAvsc(gpa, ioForTest(), flat, "temp/avro-gen-m");
    const mt = std.Io.Dir.cwd().readFileAlloc(ioForTest(), "temp/avro-gen-m/demo/M.zig", gpa, .limited(1 << 20)) catch return error.Schema;
    defer gpa.free(mt);
    try std.testing.expect(std.mem.indexOf(u8, mt, "M_d") != null);
    try std.testing.expect(std.mem.indexOf(u8, mt, "?i64") != null);
}
