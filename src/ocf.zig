//! Avro Object Container Files. Codecs: null and raw DEFLATE.

const std = @import("std");
const canon = @import("canon.zig");
const deflate = @import("deflate.zig");
const diag = @import("diag.zig");
const schema = @import("schema.zig");
const value = @import("value.zig");
const wire = @import("wire.zig");
const resolve = @import("resolve.zig");

pub const Error = diag.Error;
pub const magic = [_]u8{ 'O', 'b', 'j', 0x01 };

pub const Codec = enum { @"null", deflate };

pub fn syncFromSeed(fingerprint: u64, seed: u64) [16]u8 {
    var x: u64 = fingerprint ^ seed ^ 0x9E3779B97F4A7C15;
    var out: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 8) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        std.mem.writeInt(u64, out[i..][0..8], x, .little);
    }
    return out;
}

pub const OcfWriter = struct {
    gpa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    root: u32,
    codec: Codec,
    sync_mark: [16]u8,
    objects: std.ArrayList([]u8),

    pub fn init(gpa: std.mem.Allocator, pool: *schema.SchemaPool, root: u32, codec: Codec, seed: u64) Error!OcfWriter {
        const fp = try canon.fingerprint(pool, root, gpa);
        return .{
            .gpa = gpa,
            .pool = pool,
            .root = root,
            .codec = codec,
            .sync_mark = syncFromSeed(fp, seed),
            .objects = .empty,
        };
    }

    pub fn deinit(self: *OcfWriter) void {
        for (self.objects.items) |obj| self.gpa.free(obj);
        self.objects.deinit(self.gpa);
    }

    pub fn appendDatum(self: *OcfWriter, datum: *const value.Datum) Error!void {
        const bin = try datum.toOwnedBin();
        self.objects.append(self.gpa, bin) catch {
            self.gpa.free(bin);
            return error.OutOfMemory;
        };
    }

    pub fn finish(self: *OcfWriter) Error![]u8 {
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(self.gpa);
        for (self.objects.items) |obj| raw.appendSlice(self.gpa, obj) catch return error.OutOfMemory;
        const payload = if (self.codec == .deflate)
            try deflate.deflateRaw(self.gpa, raw.items)
        else
            self.gpa.dupe(u8, raw.items) catch return error.OutOfMemory;
        defer self.gpa.free(payload);

        const schema_json = if (self.pool.original_json.len != 0)
            self.pool.original_json
        else
            try canon.emitSchemaJson(self.pool, self.root, self.gpa);
        const owned_schema = self.pool.original_json.len == 0;
        defer if (owned_schema) self.gpa.free(schema_json);

        var w = wire.Writer.init(self.gpa);
        errdefer w.deinit();
        try w.writeRaw(&magic);
        try w.writeLong(2);
        try w.writeString("avro.codec");
        try w.writeBytes(if (self.codec == .deflate) "deflate" else "null");
        try w.writeString("avro.schema");
        try w.writeBytes(schema_json);
        try w.writeBlockEnd();
        try w.writeRaw(&self.sync_mark);
        try w.writeLong(@intCast(self.objects.items.len));
        try w.writeLong(@intCast(payload.len));
        try w.writeRaw(payload);
        try w.writeRaw(&self.sync_mark);
        return w.toOwnedSlice();
    }
};

pub const OcfDocs = struct {
    gpa: std.mem.Allocator,
    pool: *schema.SchemaPool,
    items: []value.Datum,

    pub fn deinit(self: *OcfDocs) void {
        for (self.items) |*item| item.deinit();
        self.gpa.free(self.items);
        self.pool.deinit();
        self.gpa.destroy(self.pool);
    }
};

pub fn readOcf(gpa: std.mem.Allocator, bytes: []const u8, reader_schema_json: ?[]const u8) Error!OcfDocs {
    if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], &magic)) return error.Ocf;
    var r = wire.Reader.init(bytes);
    r.pos = 4;
    var schema_bytes: ?[]u8 = null;
    defer if (schema_bytes) |s| gpa.free(s);
    var codec: Codec = .@"null";
    while (true) {
        const blk = r.readBlockCount() catch return error.Ocf;
        if (blk.count == 0) break;
        const n = std.math.cast(usize, blk.count) orelse return error.Ocf;
        for (0..n) |_| {
            const key = r.readString(gpa) catch return error.Ocf;
            defer gpa.free(key);
            const val = r.readBytes(gpa) catch return error.Ocf;
            if (std.mem.eql(u8, key, "avro.schema")) {
                if (schema_bytes) |prev| gpa.free(prev);
                schema_bytes = val;
            } else if (std.mem.eql(u8, key, "avro.codec")) {
                if (std.mem.eql(u8, val, "null")) codec = .@"null" else if (std.mem.eql(u8, val, "deflate")) codec = .deflate else {
                    gpa.free(val);
                    return error.Ocf;
                }
                gpa.free(val);
            } else gpa.free(val);
        }
    }
    if (schema_bytes == null) return error.Ocf;
    if (r.remaining() < 16) return error.Ocf;
    var sync_mark: [16]u8 = undefined;
    r.readRawInto(&sync_mark) catch return error.Ocf;

    const writer_pool = gpa.create(schema.SchemaPool) catch return error.OutOfMemory;
    writer_pool.* = schema.parseAvsc(gpa, schema_bytes.?) catch |err| {
        gpa.destroy(writer_pool);
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Ocf;
    };

    var reader_pool: ?*schema.SchemaPool = null;
    if (reader_schema_json) |text| {
        const rp = gpa.create(schema.SchemaPool) catch {
            writer_pool.deinit();
            gpa.destroy(writer_pool);
            return error.OutOfMemory;
        };
        rp.* = schema.parseAvsc(gpa, text) catch |err| {
            gpa.destroy(rp);
            writer_pool.deinit();
            gpa.destroy(writer_pool);
            return if (err == error.OutOfMemory) error.OutOfMemory else error.Schema;
        };
        reader_pool = rp;
    }
    errdefer if (reader_pool) |rp| {
        rp.deinit();
        gpa.destroy(rp);
    };
    errdefer {
        writer_pool.deinit();
        gpa.destroy(writer_pool);
    }

    var items: std.ArrayList(value.Datum) = .empty;
    errdefer {
        for (items.items) |*it| it.deinit();
        items.deinit(gpa);
    }

    while (r.remaining() != 0) {
        const count = r.readLong() catch return error.Ocf;
        const size = r.readLong() catch return error.Ocf;
        if (count < 0 or size < 0) return error.Ocf;
        const ncount = std.math.cast(usize, count) orelse return error.Ocf;
        const nsize = std.math.cast(usize, size) orelse return error.Ocf;
        if (nsize > r.remaining()) return error.Ocf;
        const comp = r.buf[r.pos..][0..nsize];
        r.pos += nsize;
        var got: [16]u8 = undefined;
        r.readRawInto(&got) catch return error.Ocf;
        if (!std.mem.eql(u8, &got, &sync_mark)) return error.Ocf;
        const inflated: ?[]u8 = if (codec == .deflate) try deflate.inflateRaw(gpa, comp) else null;
        defer if (inflated) |p| gpa.free(p);
        const plain: []const u8 = inflated orelse comp;
        var off: usize = 0;
        for (0..ncount) |_| {
            if (off > plain.len) return error.Ocf;
            if (reader_pool) |rp| {
                const one = value.decodeOne(gpa, writer_pool, writer_pool.root, plain[off..]) catch return error.Ocf;
                var src = one.datum;
                defer src.deinit();
                off += one.read;
                var converted = try resolve.convertDatum(gpa, &src, rp, rp.root);
                items.append(gpa, converted) catch {
                    converted.deinit();
                    return error.OutOfMemory;
                };
            } else {
                const one = value.decodeOne(gpa, writer_pool, writer_pool.root, plain[off..]) catch return error.Ocf;
                off += one.read;
                items.append(gpa, one.datum) catch {
                    var tmp = one.datum;
                    tmp.deinit();
                    return error.OutOfMemory;
                };
            }
        }
        if (off != plain.len) return error.Ocf;
    }

    const slice = items.toOwnedSlice(gpa) catch return error.OutOfMemory;
    if (reader_pool) |rp| {
        writer_pool.deinit();
        gpa.destroy(writer_pool);
        return .{ .gpa = gpa, .pool = rp, .items = slice };
    }
    return .{ .gpa = gpa, .pool = writer_pool, .items = slice };
}

test "ocf null and deflate round trip and python files" {
    const gpa = std.testing.allocator;
    const text =
        \\{"type":"record","name":"M","fields":[{"name":"a","type":"int"},{"name":"b","type":"string"}]}
    ;
    var pool = try schema.parseAvsc(gpa, text);
    defer pool.deinit();
    for ([_]Codec{ .@"null", .deflate }) |codec| {
        var w = try OcfWriter.init(gpa, &pool, pool.root, codec, 1);
        defer w.deinit();
        var d0 = value.Datum.init(gpa, &pool);
        defer d0.deinit();
        const fields = pool.nodes.items[pool.root].fields;
        d0.root = try d0.putRecord(pool.root, &.{
            try d0.putInt(fields[0].type_id, 7),
            try d0.putString(fields[1].type_id, "hi"),
        });
        try w.appendDatum(&d0);
        var d1 = value.Datum.init(gpa, &pool);
        defer d1.deinit();
        d1.root = try d1.putRecord(pool.root, &.{
            try d1.putInt(fields[0].type_id, -1),
            try d1.putString(fields[1].type_id, ""),
        });
        try w.appendDatum(&d1);
        const file = try w.finish();
        defer gpa.free(file);
        var docs = try readOcf(gpa, file, null);
        defer docs.deinit();
        try std.testing.expectEqual(@as(usize, 2), docs.items.len);
        try std.testing.expectEqual(@as(i32, 7), try docs.items[0].asInt(try docs.items[0].recordField(docs.items[0].root, "a")));
        try std.testing.expectEqualStrings("", try docs.items[1].asString(try docs.items[1].recordField(docs.items[1].root, "b")));

        const promoted =
            \\{"type":"record","name":"M","fields":[{"name":"b","type":"string"},{"name":"a","type":"long"},{"name":"c","type":"boolean","default":false}]}
        ;
        var resolved = try readOcf(gpa, file, promoted);
        defer resolved.deinit();
        try std.testing.expectEqual(@as(i64, 7), try resolved.items[0].asLong(try resolved.items[0].recordField(resolved.items[0].root, "a")));
        try std.testing.expectEqual(false, try resolved.items[0].asBool(try resolved.items[0].recordField(resolved.items[0].root, "c")));
    }

    const py_null = try readGolden(gpa, "ocf_null.bin");
    defer gpa.free(py_null);
    const py_def = try readGolden(gpa, "ocf_deflate.bin");
    defer gpa.free(py_def);
    var a = try readOcf(gpa, py_null, null);
    defer a.deinit();
    var b = try readOcf(gpa, py_def, null);
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 2), a.items.len);
    try std.testing.expectEqual(@as(usize, 2), b.items.len);
    try std.testing.expectEqual(@as(i32, -1), try b.items[1].asInt(try b.items[1].recordField(b.items[1].root, "a")));
    try std.testing.expectError(error.Ocf, readOcf(gpa, "not avro", null));
}

fn readGolden(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = std.fmt.allocPrint(gpa, "testdata/golden/{s}", .{name}) catch return error.OutOfMemory;
    defer gpa.free(path);
    const io = if (comptime @import("builtin").is_test) std.testing.io else return error.Ocf;
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return error.Ocf;
}
