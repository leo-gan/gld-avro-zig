//! Generic Avro values. Nodes live in lists addressed by integer ids.

const std = @import("std");
const diag = @import("diag.zig");
const schema = @import("schema.zig");
const wire = @import("wire.zig");

pub const Error = diag.Error;

pub const Kind = enum(u8) {
    null,
    boolean,
    int,
    long,
    float,
    double,
    bytes,
    string,
    enum_type,
    fixed,
    array,
    map,
    record,
    union_type,
};

pub const Node = struct {
    kind: Kind,
    b: bool = false,
    /// int/long/enum index/union index, or IEEE bits for float and double.
    i: i64 = 0,
    /// String, enum symbol, bytes, or fixed payload.
    p: []const u8 = "",
    first: u32 = 0,
    count: u32 = 0,
    schema_id: u32 = 0,
};

pub const MapEntry = struct {
    key: []const u8,
    node: u32,
};

pub const Datum = struct {
    gpa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    arena: std.heap.ArenaAllocator = undefined,
    arena_on: bool = false,
    nodes: std.ArrayList(Node),
    edges: std.ArrayList(u32),
    entries: std.ArrayList(MapEntry),
    /// Contiguous copies of bytes and strings taken from an input buffer.
    bytes_buf: []u8 = &.{},
    bytes_len: usize = 0,
    /// One allocation covering nodes, edges, entries, and bytes_buf for a decode.
    /// Lists carved from it are not freed individually unless promoted.
    /// On deinit the slab goes back to `pool.decode_scratch` when that slot is empty.
    slab: []align(8) u8 = &.{},
    nodes_owned: bool = false,
    edges_owned: bool = false,
    entries_owned: bool = false,
    root: u32 = 0,
    root_schema: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, pool: *schema.SchemaPool) Datum {
        return .{
            .gpa = gpa,
            .pool = pool,
            .nodes = .empty,
            .edges = .empty,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *Datum) void {
        if (self.slab.len == 0) {
            self.nodes.deinit(self.gpa);
            self.edges.deinit(self.gpa);
            self.entries.deinit(self.gpa);
            if (self.bytes_buf.len != 0) self.gpa.free(self.bytes_buf);
        } else {
            if (self.nodes_owned) self.nodes.deinit(self.gpa);
            if (self.edges_owned) self.edges.deinit(self.gpa);
            if (self.entries_owned) self.entries.deinit(self.gpa);
            if (self.pool.decode_scratch.len == 0) {
                self.pool.decode_scratch = self.slab;
            } else {
                self.gpa.free(self.slab);
            }
        }
        if (self.arena_on) self.arena.deinit();
    }

    fn builderAlloc(self: *Datum) std.mem.Allocator {
        if (!self.arena_on) {
            self.arena = std.heap.ArenaAllocator.init(self.gpa);
            self.arena_on = true;
        }
        return self.arena.allocator();
    }

    inline fn reserveNodes(self: *Datum, extra: usize) Error!void {
        const need = self.nodes.items.len + extra;
        if (need <= self.nodes.capacity) return;
        if (self.slab.len != 0 and !self.nodes_owned) {
            try ownList(self, Node, &self.nodes, &self.nodes_owned, need);
            return;
        }
        self.nodes.ensureTotalCapacity(self.gpa, need) catch return error.OutOfMemory;
    }

    inline fn reserveEdges(self: *Datum, extra: usize) Error!void {
        const need = self.edges.items.len + extra;
        if (need <= self.edges.capacity) return;
        if (self.slab.len != 0 and !self.edges_owned) {
            try ownList(self, u32, &self.edges, &self.edges_owned, need);
            return;
        }
        self.edges.ensureTotalCapacity(self.gpa, need) catch return error.OutOfMemory;
    }

    fn reserveEntries(self: *Datum, extra: usize) Error!void {
        const need = self.entries.items.len + extra;
        if (need <= self.entries.capacity) return;
        if (self.slab.len != 0 and !self.entries_owned) {
            try ownList(self, MapEntry, &self.entries, &self.entries_owned, need);
            return;
        }
        self.entries.ensureTotalCapacity(self.gpa, need) catch return error.OutOfMemory;
    }

    fn installSlab(self: *Datum, byte_cap: usize) Error!void {
        const node_cap: usize = @min(@max(byte_cap, 32), 16_384);
        const edge_cap = node_cap;
        const entry_cap = node_cap;
        const nbytes = slabSize(node_cap, edge_cap, entry_cap, byte_cap);
        if (self.pool.decode_scratch.len >= nbytes) {
            const slab = self.pool.decode_scratch;
            self.pool.decode_scratch = &.{};
            self.bindSlab(slab, node_cap, edge_cap, entry_cap, byte_cap);
            return;
        }
        if (self.pool.decode_scratch.len != 0) {
            self.gpa.free(self.pool.decode_scratch);
            self.pool.decode_scratch = &.{};
        }
        const slab = self.gpa.alignedAlloc(u8, .@"8", nbytes) catch return error.OutOfMemory;
        self.bindSlab(slab, node_cap, edge_cap, entry_cap, byte_cap);
    }

    fn bindSlab(self: *Datum, slab: []align(8) u8, node_cap: usize, edge_cap: usize, entry_cap: usize, byte_cap: usize) void {
        var off: usize = 0;
        const nodes_mem = carve(Node, slab, &off, node_cap);
        const edges_mem = carve(u32, slab, &off, edge_cap);
        const entries_mem = carve(MapEntry, slab, &off, entry_cap);
        const bytes_mem = carve(u8, slab, &off, byte_cap);
        self.slab = slab;
        self.nodes = .initBuffer(nodes_mem);
        self.edges = .initBuffer(edges_mem);
        self.entries = .initBuffer(entries_mem);
        self.bytes_buf = bytes_mem;
        self.bytes_len = 0;
        self.nodes_owned = false;
        self.edges_owned = false;
        self.entries_owned = false;
    }

    inline fn copyInto(self: *Datum, src: []const u8) Error![]u8 {
        if (self.bytes_len + src.len > self.bytes_buf.len) return error.OutOfMemory;
        const dest = self.bytes_buf[self.bytes_len..][0..src.len];
        @memcpy(dest, src);
        self.bytes_len += src.len;
        return dest;
    }

    pub fn dupe(self: *Datum, s: []const u8) Error![]u8 {
        return self.builderAlloc().dupe(u8, s) catch error.OutOfMemory;
    }

    pub inline fn add(self: *Datum, n: Node) Error!u32 {
        try self.reserveNodes(1);
        self.nodes.appendAssumeCapacity(n);
        return @intCast(self.nodes.items.len - 1);
    }

    pub fn kindOf(self: *const Datum, id: u32) Kind {
        return self.nodes.items[id].kind;
    }

    pub fn isNull(self: *const Datum, id: u32) bool {
        return self.nodes.items[id].kind == .null;
    }

    fn expect(self: *const Datum, id: u32, kind: Kind) Error!Node {
        const n = self.nodes.items[id];
        if (n.kind != kind) return error.Schema;
        return n;
    }

    pub fn asBool(self: *const Datum, id: u32) Error!bool {
        return (try self.expect(id, .boolean)).b;
    }
    pub fn asInt(self: *const Datum, id: u32) Error!i32 {
        const v = (try self.expect(id, .int)).i;
        if (v < std.math.minInt(i32) or v > std.math.maxInt(i32)) return error.Range;
        return @intCast(v);
    }
    pub fn asLong(self: *const Datum, id: u32) Error!i64 {
        return (try self.expect(id, .long)).i;
    }
    pub fn asFloat(self: *const Datum, id: u32) Error!f32 {
        const n = try self.expect(id, .float);
        return @bitCast(@as(u32, @truncate(@as(u64, @bitCast(n.i)))));
    }
    pub fn asDouble(self: *const Datum, id: u32) Error!f64 {
        return @bitCast((try self.expect(id, .double)).i);
    }
    pub fn asBytes(self: *const Datum, id: u32) Error![]const u8 {
        return (try self.expect(id, .bytes)).p;
    }
    pub fn asString(self: *const Datum, id: u32) Error![]const u8 {
        return (try self.expect(id, .string)).p;
    }
    pub fn asEnum(self: *const Datum, id: u32) Error![]const u8 {
        return (try self.expect(id, .enum_type)).p;
    }
    pub fn asFixed(self: *const Datum, id: u32) Error![]const u8 {
        return (try self.expect(id, .fixed)).p;
    }
    pub fn arrayLen(self: *const Datum, id: u32) Error!usize {
        return (try self.expect(id, .array)).count;
    }
    pub fn arrayAt(self: *const Datum, id: u32, i: usize) Error!u32 {
        const n = try self.expect(id, .array);
        if (i >= n.count) return error.Range;
        return self.edges.items[n.first + i];
    }
    pub fn mapLen(self: *const Datum, id: u32) Error!usize {
        return (try self.expect(id, .map)).count;
    }
    pub fn mapAt(self: *const Datum, id: u32, i: usize) Error!MapEntry {
        const n = try self.expect(id, .map);
        if (i >= n.count) return error.Range;
        return self.entries.items[n.first + i];
    }
    pub fn recordLen(self: *const Datum, id: u32) Error!usize {
        return (try self.expect(id, .record)).count;
    }
    pub fn recordAt(self: *const Datum, id: u32, i: usize) Error!u32 {
        const n = try self.expect(id, .record);
        if (i >= n.count) return error.Range;
        return self.edges.items[n.first + i];
    }
    pub fn recordField(self: *const Datum, id: u32, name: []const u8) Error!u32 {
        const n = try self.expect(id, .record);
        const fields = self.pool.nodes.items[n.schema_id].fields;
        for (fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, name)) return self.edges.items[n.first + i];
            for (f.aliases) |a| if (std.mem.eql(u8, a, name)) return self.edges.items[n.first + i];
        }
        return error.Resolve;
    }
    pub fn unionBranch(self: *const Datum, id: u32) Error!i64 {
        return (try self.expect(id, .union_type)).i;
    }
    pub fn unionChild(self: *const Datum, id: u32) Error!?u32 {
        const n = try self.expect(id, .union_type);
        if (n.count == 0) return null;
        return self.edges.items[n.first];
    }

    pub fn setRecordAt(self: *Datum, id: u32, i: usize, child: u32) Error!void {
        const n = try self.expect(id, .record);
        if (i >= n.count) return error.Range;
        self.edges.items[n.first + i] = child;
    }

    pub inline fn putNull(self: *Datum, schema_id: u32) Error!u32 {
        return self.add(.{ .kind = .null, .schema_id = schema_id });
    }
    pub inline fn putBool(self: *Datum, schema_id: u32, v: bool) Error!u32 {
        return self.add(.{ .kind = .boolean, .b = v, .schema_id = schema_id });
    }
    pub inline fn putInt(self: *Datum, schema_id: u32, v: i32) Error!u32 {
        return self.add(.{ .kind = .int, .i = v, .schema_id = schema_id });
    }
    pub inline fn putLong(self: *Datum, schema_id: u32, v: i64) Error!u32 {
        return self.add(.{ .kind = .long, .i = v, .schema_id = schema_id });
    }
    pub inline fn putFloat(self: *Datum, schema_id: u32, v: f32) Error!u32 {
        return self.add(.{ .kind = .float, .i = @as(i64, @as(u32, @bitCast(v))), .schema_id = schema_id });
    }
    pub inline fn putDouble(self: *Datum, schema_id: u32, v: f64) Error!u32 {
        return self.add(.{ .kind = .double, .i = @bitCast(v), .schema_id = schema_id });
    }
    pub fn putBytes(self: *Datum, schema_id: u32, v: []const u8) Error!u32 {
        return self.add(.{ .kind = .bytes, .p = try self.dupe(v), .schema_id = schema_id });
    }
    pub fn putString(self: *Datum, schema_id: u32, v: []const u8) Error!u32 {
        return self.add(.{ .kind = .string, .p = try self.dupe(v), .schema_id = schema_id });
    }
    pub fn putEnum(self: *Datum, schema_id: u32, symbol: []const u8) Error!u32 {
        const symbols = self.pool.nodes.items[schema_id].symbols;
        const idx = schema.symbolIndex(symbols, symbol) orelse return error.BadEnum;
        return self.add(.{
            .kind = .enum_type,
            .i = @intCast(idx),
            .p = try self.dupe(symbol),
            .schema_id = schema_id,
        });
    }
    pub fn putFixed(self: *Datum, schema_id: u32, v: []const u8) Error!u32 {
        if (v.len != self.pool.nodes.items[schema_id].size) return error.Range;
        return self.add(.{ .kind = .fixed, .p = try self.dupe(v), .schema_id = schema_id });
    }
    pub fn putRecord(self: *Datum, schema_id: u32, children: []const u32) Error!u32 {
        if (children.len != self.pool.nodes.items[schema_id].fields.len) return error.Schema;
        const first: u32 = @intCast(self.edges.items.len);
        try self.reserveEdges(children.len);
        self.edges.appendSliceAssumeCapacity(children);
        return self.add(.{
            .kind = .record,
            .first = first,
            .count = @intCast(children.len),
            .schema_id = schema_id,
        });
    }
    pub fn putArray(self: *Datum, schema_id: u32, children: []const u32) Error!u32 {
        const first: u32 = @intCast(self.edges.items.len);
        try self.reserveEdges(children.len);
        self.edges.appendSliceAssumeCapacity(children);
        return self.add(.{
            .kind = .array,
            .first = first,
            .count = @intCast(children.len),
            .schema_id = schema_id,
        });
    }
    pub fn putMap(self: *Datum, schema_id: u32, keys: []const []const u8, children: []const u32) Error!u32 {
        return self.putMapInner(schema_id, keys, children, true);
    }

    fn putMapInner(self: *Datum, schema_id: u32, keys: []const []const u8, children: []const u32, copy_keys: bool) Error!u32 {
        if (keys.len != children.len) return error.Schema;
        const first: u32 = @intCast(self.entries.items.len);
        try self.reserveEntries(keys.len);
        for (keys, children) |k, c| {
            const key = if (copy_keys) try self.dupe(k) else k;
            self.entries.appendAssumeCapacity(.{ .key = key, .node = c });
        }
        return self.add(.{
            .kind = .map,
            .first = first,
            .count = @intCast(keys.len),
            .schema_id = schema_id,
        });
    }
    pub fn putUnion(self: *Datum, schema_id: u32, branch: usize, payload: ?u32) Error!u32 {
        const branches = self.pool.nodes.items[schema_id].branches;
        if (branch >= branches.len) return error.BadUnion;
        const bkind = self.pool.nodes.items[branches[branch]].kind;
        if (bkind == .null) {
            if (payload != null) return error.BadUnion;
            return self.add(.{ .kind = .union_type, .i = @intCast(branch), .schema_id = schema_id });
        }
        const child = payload orelse return error.BadUnion;
        const first: u32 = @intCast(self.edges.items.len);
        try self.reserveEdges(1);
        self.edges.appendAssumeCapacity(child);
        return self.add(.{
            .kind = .union_type,
            .i = @intCast(branch),
            .first = first,
            .count = 1,
            .schema_id = schema_id,
        });
    }

    pub fn encodeTo(self: *const Datum, w: *wire.Writer) Error!void {
        try encodeNode(self, self.root, w);
    }

    pub fn encodedLen(self: *const Datum) usize {
        return lenNode(self, self.root);
    }

    pub fn toOwnedBin(self: *const Datum) Error![]u8 {
        // One stack pass plus one exact heap copy. A length pass plus a second
        // encode was slower on the 108-byte record.
        var stack: [512]u8 = undefined;
        var w = wire.Writer.initFixed(&stack);
        if (self.encodeTo(&w)) {
            return self.gpa.dupe(u8, w.slice()) catch error.OutOfMemory;
        } else |_| {
            var heap = try wire.Writer.initCapacity(self.gpa, @max(stack.len * 2, w.len + 64));
            errdefer heap.deinit();
            try self.encodeTo(&heap);
            return heap.toOwnedSlice();
        }
    }
};

pub fn decodeBin(gpa: std.mem.Allocator, pool: *schema.SchemaPool, root: u32, buf: []const u8) Error!Datum {
    const one = try decodeOne(gpa, pool, root, buf);
    if (one.read != buf.len) {
        var d = one.datum;
        d.deinit();
        return error.Schema;
    }
    return one.datum;
}

pub const Decoded = struct {
    datum: Datum,
    read: usize,
};

pub fn decodeOne(gpa: std.mem.Allocator, pool: *schema.SchemaPool, root: u32, buf: []const u8) Error!Decoded {
    var d = Datum.init(gpa, pool);
    errdefer d.deinit();
    try d.installSlab(buf.len);
    var r = wire.Reader.init(buf);
    d.root_schema = root;
    d.root = try decodeNode(&d, &r, root, 0);
    return .{ .datum = d, .read = r.pos };
}

fn decodeNode(d: *Datum, r: *wire.Reader, schema_id: u32, depth: usize) Error!u32 {
    if (depth > diag.max_depth) return r.fail(.range);
    const kind: schema.TypeKind = @enumFromInt(d.pool.kinds.items[schema_id]);
    switch (kind) {
        .null => return d.putNull(schema_id),
        .boolean => return d.putBool(schema_id, try r.readBool()),
        .int => return d.putInt(schema_id, try r.readInt()),
        .long => return d.putLong(schema_id, try r.readLong()),
        .float => return d.putFloat(schema_id, try r.readFloat()),
        .double => return d.putDouble(schema_id, try r.readDouble()),
        .bytes => {
            const src = try takePayload(r);
            return d.add(.{ .kind = .bytes, .p = try d.copyInto(src), .schema_id = schema_id });
        },
        .string => {
            const src = try takePayload(r);
            if (!isUtf8(src)) return r.fail(.bad_utf8);
            return d.add(.{ .kind = .string, .p = try d.copyInto(src), .schema_id = schema_id });
        },
        .fixed => {
            const size = d.pool.nodes.items[schema_id].size;
            if (size > r.remaining()) return r.fail(.eof);
            const src = r.buf[r.pos..][0..size];
            r.pos += size;
            return d.add(.{ .kind = .fixed, .p = try d.copyInto(src), .schema_id = schema_id });
        },
        .enum_type => {
            const symbols = d.pool.nodes.items[schema_id].symbols;
            const idx = try r.readInt();
            if (idx < 0 or idx >= symbols.len) return r.fail(.bad_enum);
            const ui: usize = @intCast(idx);
            return d.add(.{
                .kind = .enum_type,
                .i = idx,
                .p = symbols[ui],
                .schema_id = schema_id,
            });
        },
        .array => return decodeArray(d, r, schema_id, d.pool.nodes.items[schema_id].item_id, depth),
        .map => return decodeMap(d, r, schema_id, d.pool.nodes.items[schema_id].value_id, depth),
        .record => {
            const fields = d.pool.nodes.items[schema_id].fields;
            const first: u32 = @intCast(d.edges.items.len);
            const nfields = fields.len;
            try d.reserveEdges(nfields);
            d.edges.items.len += nfields;
            for (0..nfields) |i| {
                r.field = i + 1;
                const child = try decodeNode(d, r, fields[i].type_id, depth + 1);
                d.edges.items[first + i] = child;
            }
            r.field = 0;
            return d.add(.{
                .kind = .record,
                .first = first,
                .count = @intCast(nfields),
                .schema_id = schema_id,
            });
        },
        .union_type => {
            const branches = d.pool.nodes.items[schema_id].branches;
            const idx = try r.readLong();
            if (idx < 0 or idx >= branches.len) return r.fail(.bad_union);
            const bi: usize = @intCast(idx);
            const branch = branches[bi];
            if (d.pool.kinds.items[branch] == @intFromEnum(schema.TypeKind.null)) {
                return d.add(.{ .kind = .union_type, .i = idx, .schema_id = schema_id });
            }
            const child = try decodeNode(d, r, branch, depth + 1);
            const first: u32 = @intCast(d.edges.items.len);
            try d.reserveEdges(1);
            d.edges.appendAssumeCapacity(child);
            return d.add(.{
                .kind = .union_type,
                .i = idx,
                .first = first,
                .count = 1,
                .schema_id = schema_id,
            });
        },
        .unresolved => return error.Schema,
    }
}

inline fn isUtf8(s: []const u8) bool {
    for (s) |c| {
        if (c >= 0x80) {
            @branchHint(.unlikely);
            return std.unicode.utf8ValidateSlice(s);
        }
    }
    return true;
}

inline fn takePayload(r: *wire.Reader) Error![]const u8 {
    const n = try r.readLong();
    if (n < 0) return r.fail(.range);
    const len = std.math.cast(usize, n) orelse return r.fail(.range);
    if (len > r.remaining()) return r.fail(.eof);
    const src = r.buf[r.pos..][0..len];
    r.pos += len;
    return src;
}

const id_stack = 32;

noinline fn decodeArray(d: *Datum, r: *wire.Reader, schema_id: u32, item_id: u32, depth: usize) Error!u32 {
    var stack: [id_stack]u32 = undefined;
    var heap: std.ArrayList(u32) = .empty;
    defer heap.deinit(d.gpa);
    var n_ids: usize = 0;
    var total: usize = 0;
    while (true) {
        const blk = try r.readBlockCount();
        if (blk.count == 0) break;
        const n = std.math.cast(usize, blk.count) orelse return r.fail(.range);
        if (n > diag.max_collection or total > diag.max_collection - n) return r.fail(.bad_block);
        const start = r.pos;
        for (0..n) |_| {
            const child = try decodeNode(d, r, item_id, depth + 1);
            try pushId(d.gpa, &stack, &heap, &n_ids, child);
        }
        if (blk.size_hint >= 0 and r.pos - start > @as(usize, @intCast(blk.size_hint))) return r.fail(.bad_block);
        total += n;
    }
    const ids = if (heap.items.len == 0) stack[0..n_ids] else heap.items;
    return d.putArray(schema_id, ids);
}

noinline fn decodeMap(d: *Datum, r: *wire.Reader, schema_id: u32, value_id: u32, depth: usize) Error!u32 {
    var key_stack: [id_stack][]const u8 = undefined;
    var val_stack: [id_stack]u32 = undefined;
    var key_heap: std.ArrayList([]const u8) = .empty;
    defer key_heap.deinit(d.gpa);
    var val_heap: std.ArrayList(u32) = .empty;
    defer val_heap.deinit(d.gpa);
    var n_ids: usize = 0;
    var total: usize = 0;
    while (true) {
        const blk = try r.readBlockCount();
        if (blk.count == 0) break;
        const n = std.math.cast(usize, blk.count) orelse return r.fail(.range);
        if (n > diag.max_collection or total > diag.max_collection - n) return r.fail(.bad_block);
        const start = r.pos;
        for (0..n) |_| {
            const key_src = try takePayload(r);
            if (!isUtf8(key_src)) return r.fail(.bad_utf8);
            const key = try d.copyInto(key_src);
            const child = try decodeNode(d, r, value_id, depth + 1);
            try pushMap(d.gpa, &key_stack, &val_stack, &key_heap, &val_heap, &n_ids, key, child);
        }
        if (blk.size_hint >= 0 and r.pos - start > @as(usize, @intCast(blk.size_hint))) return r.fail(.bad_block);
        total += n;
    }
    const keys = if (key_heap.items.len == 0) key_stack[0..n_ids] else key_heap.items;
    const vals = if (val_heap.items.len == 0) val_stack[0..n_ids] else val_heap.items;
    return d.putMapInner(schema_id, keys, vals, false);
}

fn pushId(gpa: std.mem.Allocator, stack: *[id_stack]u32, heap: *std.ArrayList(u32), n_ids: *usize, child: u32) Error!void {
    if (heap.items.len != 0) {
        heap.append(gpa, child) catch return error.OutOfMemory;
        n_ids.* += 1;
        return;
    }
    if (n_ids.* < stack.len) {
        stack[n_ids.*] = child;
        n_ids.* += 1;
        return;
    }
    heap.ensureTotalCapacity(gpa, stack.len + 1) catch return error.OutOfMemory;
    heap.appendSliceAssumeCapacity(stack);
    heap.appendAssumeCapacity(child);
    n_ids.* += 1;
}

fn pushMap(
    gpa: std.mem.Allocator,
    key_stack: *[id_stack][]const u8,
    val_stack: *[id_stack]u32,
    key_heap: *std.ArrayList([]const u8),
    val_heap: *std.ArrayList(u32),
    n_ids: *usize,
    key: []const u8,
    child: u32,
) Error!void {
    if (key_heap.items.len != 0) {
        key_heap.append(gpa, key) catch return error.OutOfMemory;
        val_heap.append(gpa, child) catch return error.OutOfMemory;
        n_ids.* += 1;
        return;
    }
    if (n_ids.* < key_stack.len) {
        key_stack[n_ids.*] = key;
        val_stack[n_ids.*] = child;
        n_ids.* += 1;
        return;
    }
    key_heap.ensureTotalCapacity(gpa, key_stack.len + 1) catch return error.OutOfMemory;
    val_heap.ensureTotalCapacity(gpa, val_stack.len + 1) catch return error.OutOfMemory;
    key_heap.appendSliceAssumeCapacity(key_stack);
    val_heap.appendSliceAssumeCapacity(val_stack);
    key_heap.appendAssumeCapacity(key);
    val_heap.appendAssumeCapacity(child);
    n_ids.* += 1;
}

fn ownList(self: *Datum, comptime T: type, list: *std.ArrayList(T), owned: *bool, need: usize) Error!void {
    var cap = list.capacity * 2;
    if (cap < need) cap = need;
    if (cap < 8) cap = 8;
    const mem = self.gpa.alloc(T, cap) catch return error.OutOfMemory;
    const len = list.items.len;
    @memcpy(mem[0..len], list.items);
    list.* = .initBuffer(mem);
    list.items.len = len;
    owned.* = true;
}

fn slabSize(node_cap: usize, edge_cap: usize, entry_cap: usize, byte_cap: usize) usize {
    var off: usize = 0;
    off = std.mem.alignForward(usize, off, @alignOf(Node));
    off += node_cap * @sizeOf(Node);
    off = std.mem.alignForward(usize, off, @alignOf(u32));
    off += edge_cap * @sizeOf(u32);
    off = std.mem.alignForward(usize, off, @alignOf(MapEntry));
    off += entry_cap * @sizeOf(MapEntry);
    off += byte_cap;
    return off;
}

fn carve(comptime T: type, slab: []align(8) u8, off: *usize, n: usize) []T {
    off.* = std.mem.alignForward(usize, off.*, @alignOf(T));
    const ptr: [*]T = @ptrCast(@alignCast(slab.ptr + off.*));
    off.* += n * @sizeOf(T);
    return ptr[0..n];
}

fn encodeNode(d: *const Datum, id: u32, w: *wire.Writer) Error!void {
    const n = &d.nodes.items[id];
    switch (n.kind) {
        .null => {},
        .boolean => try w.writeBool(n.b),
        .int, .long, .enum_type, .union_type => {
            if (n.kind == .union_type) {
                try w.writeLong(n.i);
                if (n.count == 1) try encodeNode(d, d.edges.items[n.first], w);
            } else try w.writeLong(n.i);
        },
        .float => try w.writeFloat(@bitCast(@as(u32, @truncate(@as(u64, @bitCast(n.i)))))),
        .double => try w.writeDouble(@bitCast(n.i)),
        .bytes => try w.writeBytes(n.p),
        .string => try w.writeString(n.p),
        .fixed => try w.writeFixed(n.p),
        .array => {
            if (n.count > 0) {
                try w.writeLong(@intCast(n.count));
                for (0..n.count) |i| try encodeNode(d, d.edges.items[n.first + i], w);
            }
            try w.writeBlockEnd();
        },
        .map => {
            if (n.count > 0) {
                try w.writeLong(@intCast(n.count));
                for (0..n.count) |i| {
                    const e = d.entries.items[n.first + i];
                    try w.writeString(e.key);
                    try encodeNode(d, e.node, w);
                }
            }
            try w.writeBlockEnd();
        },
        .record => {
            for (0..n.count) |i| try encodeNode(d, d.edges.items[n.first + i], w);
        },
    }
}

fn lenNode(d: *const Datum, id: u32) usize {
    const n = &d.nodes.items[id];
    switch (n.kind) {
        .null => return 0,
        .boolean => return 1,
        .int, .long, .enum_type => return wire.longLen(n.i),
        .float => return 4,
        .double => return 8,
        .bytes => return wire.bytesLen(n.p.len),
        .string => return wire.bytesLen(n.p.len),
        .fixed => return n.p.len,
        .array => {
            var total: usize = wire.longLen(0);
            if (n.count > 0) {
                total += wire.longLen(@intCast(n.count));
                for (0..n.count) |i| total += lenNode(d, d.edges.items[n.first + i]);
            }
            return total;
        },
        .map => {
            var total: usize = wire.longLen(0);
            if (n.count > 0) {
                total += wire.longLen(@intCast(n.count));
                for (0..n.count) |i| {
                    const e = d.entries.items[n.first + i];
                    total += wire.bytesLen(e.key.len) + lenNode(d, e.node);
                }
            }
            return total;
        },
        .record => {
            var total: usize = 0;
            for (0..n.count) |i| total += lenNode(d, d.edges.items[n.first + i]);
            return total;
        },
        .union_type => {
            var total: usize = wire.longLen(n.i);
            if (n.count == 1) total += lenNode(d, d.edges.items[n.first]);
            return total;
        },
    }
}

pub const document_schema =
    \\{"type":"record","name":"Document","namespace":"demo","fields":[
    \\{"name":"id","type":"long"},
    \\{"name":"name","type":"string"},
    \\{"name":"flag","type":"boolean"},
    \\{"name":"count","type":"int"},
    \\{"name":"score","type":"double"},
    \\{"name":"ratio","type":"float"},
    \\{"name":"blob","type":"bytes"},
    \\{"name":"color","type":{"type":"enum","name":"Color","symbols":["RED","GREEN","BLUE"]}},
    \\{"name":"hash","type":{"type":"fixed","name":"MD5","size":4}},
    \\{"name":"tags","type":{"type":"array","items":"string"}},
    \\{"name":"labels","type":{"type":"map","values":"long"}},
    \\{"name":"inner","type":{"type":"record","name":"Inner","fields":[{"name":"x","type":"int"}]}},
    \\{"name":"maybe","type":["null","string"],"default":null},
    \\{"name":"choice","type":["int","string"]}
    \\]}
;

fn hexDecode(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    for (0..out.len) |i| out[i] = std.fmt.parseInt(u8, s[i * 2 ..][0..2], 16) catch unreachable;
    return out;
}

test "round trip every avro kind against python bytes" {
    const gpa = std.testing.allocator;
    const golden = hexDecode("540468690105000000000000f83f0000c03f0400ff02616263640402610462620002026b12000e0002027a");
    var pool = try schema.parseAvsc(gpa, document_schema);
    defer pool.deinit();
    var decoded = try decodeBin(gpa, &pool, pool.root, &golden);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(i64, 42), try decoded.asLong(try decoded.recordField(decoded.root, "id")));
    try std.testing.expectEqualStrings("hi", try decoded.asString(try decoded.recordField(decoded.root, "name")));
    try std.testing.expect(try decoded.asBool(try decoded.recordField(decoded.root, "flag")));
    try std.testing.expectEqual(@as(i32, -3), try decoded.asInt(try decoded.recordField(decoded.root, "count")));
    try std.testing.expectEqual(@as(f64, 1.5), try decoded.asDouble(try decoded.recordField(decoded.root, "score")));
    try std.testing.expectEqual(@as(f32, 1.5), try decoded.asFloat(try decoded.recordField(decoded.root, "ratio")));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0xff }, try decoded.asBytes(try decoded.recordField(decoded.root, "blob")));
    try std.testing.expectEqualStrings("GREEN", try decoded.asEnum(try decoded.recordField(decoded.root, "color")));
    try std.testing.expectEqualSlices(u8, "abcd", try decoded.asFixed(try decoded.recordField(decoded.root, "hash")));
    const tags = try decoded.recordField(decoded.root, "tags");
    try std.testing.expectEqual(@as(usize, 2), try decoded.arrayLen(tags));
    try std.testing.expectEqualStrings("bb", try decoded.asString(try decoded.arrayAt(tags, 1)));
    const labels = try decoded.recordField(decoded.root, "labels");
    try std.testing.expectEqualStrings("k", (try decoded.mapAt(labels, 0)).key);
    try std.testing.expectEqual(@as(i64, 9), try decoded.asLong((try decoded.mapAt(labels, 0)).node));
    const inner = try decoded.recordField(decoded.root, "inner");
    try std.testing.expectEqual(@as(i32, 7), try decoded.asInt(try decoded.recordField(inner, "x")));
    const maybe = try decoded.recordField(decoded.root, "maybe");
    try std.testing.expectEqual(@as(i64, 0), try decoded.unionBranch(maybe));
    try std.testing.expectEqual(@as(?u32, null), try decoded.unionChild(maybe));
    const choice = try decoded.recordField(decoded.root, "choice");
    try std.testing.expectEqual(@as(i64, 1), try decoded.unionBranch(choice));
    try std.testing.expectEqualStrings("z", try decoded.asString((try decoded.unionChild(choice)).?));
    const again = try decoded.toOwnedBin();
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, &golden, again);
    try std.testing.expectEqual(golden.len, decoded.encodedLen());
}

test "wide null record grows out of the decode slab" {
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    text.appendSlice(gpa, "{\"type\":\"record\",\"name\":\"W\",\"fields\":[") catch return error.OutOfMemory;
    for (0..40) |i| {
        if (i != 0) text.append(gpa, ',') catch return error.OutOfMemory;
        const piece = std.fmt.allocPrint(gpa, "{{\"name\":\"f{d}\",\"type\":\"null\"}}", .{i}) catch return error.OutOfMemory;
        defer gpa.free(piece);
        text.appendSlice(gpa, piece) catch return error.OutOfMemory;
    }
    text.appendSlice(gpa, "]}") catch return error.OutOfMemory;
    var pool = try schema.parseAvsc(gpa, text.items);
    defer pool.deinit();
    var d = try decodeBin(gpa, &pool, pool.root, &.{});
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 40), try d.recordLen(d.root));
    const back = try d.toOwnedBin();
    defer gpa.free(back);
    try std.testing.expectEqual(@as(usize, 0), back.len);
}

test "negative array block and truncated input" {
    const gpa = std.testing.allocator;
    var pool = try schema.parseAvsc(gpa, "{\"type\":\"array\",\"items\":\"int\"}");
    defer pool.deinit();
    const bytes = hexDecode("0304020400");
    var d = try decodeBin(gpa, &pool, pool.root, &bytes);
    defer d.deinit();
    try std.testing.expectEqual(@as(i32, 1), try d.asInt(try d.arrayAt(d.root, 0)));
    try std.testing.expectEqual(@as(i32, 2), try d.asInt(try d.arrayAt(d.root, 1)));

    var sp = try schema.parseAvsc(gpa, "\"string\"");
    defer sp.deinit();
    try std.testing.expectError(error.Eof, decodeBin(gpa, &sp, sp.root, &[_]u8{ 0x04, 'a' }));
    try std.testing.expectError(error.BadUtf8, decodeBin(gpa, &sp, sp.root, &[_]u8{ 0x02, 0xff }));
    try std.testing.expectError(error.Eof, decodeBin(gpa, &pool, pool.root, &[_]u8{0x02}));
}

test "null bool bytes fixed enum union primitives" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "\"null\"", "" },
        .{ "\"boolean\"", "01" },
        .{ "\"boolean\"", "00" },
        .{ "\"bytes\"", "0400ff" },
        .{ "\"string\"", "046869" },
        .{ "{\"type\":\"enum\",\"name\":\"C\",\"symbols\":[\"RED\",\"GREEN\"]}", "02" },
        .{ "{\"type\":\"fixed\",\"name\":\"F\",\"size\":4}", "61626364" },
        .{ "[\"null\",\"string\"]", "00" },
        .{ "[\"null\",\"string\"]", "02046162" },
        .{ "[\"string\",\"null\"]", "02" },
        .{ "[\"int\",\"string\"]", "02027a" },
    };
    for (cases) |c| {
        var pool = try schema.parseAvsc(gpa, c[0]);
        defer pool.deinit();
        var raw = std.ArrayList(u8).empty;
        defer raw.deinit(gpa);
        var i: usize = 0;
        while (i < c[1].len) : (i += 2) {
            const b = std.fmt.parseInt(u8, c[1][i..][0..2], 16) catch unreachable;
            raw.append(gpa, b) catch return error.OutOfMemory;
        }
        var d = try decodeBin(gpa, &pool, pool.root, raw.items);
        defer d.deinit();
        const back = try d.toOwnedBin();
        defer gpa.free(back);
        try std.testing.expectEqualSlices(u8, raw.items, back);
    }
}
