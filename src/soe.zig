//! Single-object encoding: C3 01, little-endian CRC-64-AVRO, then the datum.

const std = @import("std");
const canon = @import("canon.zig");
const diag = @import("diag.zig");
const resolve = @import("resolve.zig");
const schema = @import("schema.zig");
const value = @import("value.zig");
const wire = @import("wire.zig");

pub const Error = diag.Error;

pub fn fingerprintOf(buf: []const u8) Error!u64 {
    if (buf.len < 10 or buf[0] != 0xC3 or buf[1] != 0x01) return error.Soe;
    return std.mem.readInt(u64, buf[2..10], .little);
}

pub fn encodeSingle(gpa: std.mem.Allocator, pool: *const schema.SchemaPool, root: u32, datum: *const value.Datum) Error![]u8 {
    const fp = try canon.fingerprint(pool, root, gpa);
    var w = try wire.Writer.initCapacity(gpa, 10 + datum.encodedLen());
    errdefer w.deinit();
    try w.writeByte(0xC3);
    try w.writeByte(0x01);
    try w.writeU64Le(fp);
    try datum.encodeTo(&w);
    return w.toOwnedSlice();
}

pub fn decodeSingle(gpa: std.mem.Allocator, pool: *schema.SchemaPool, root: u32, buf: []const u8) Error!value.Datum {
    const fp = try fingerprintOf(buf);
    const expect = try canon.fingerprint(pool, root, gpa);
    if (fp != expect) return error.Soe;
    return value.decodeBin(gpa, pool, root, buf[10..]);
}

pub fn decodeSingleResolving(
    gpa: std.mem.Allocator,
    buf: []const u8,
    writer_pool: *schema.SchemaPool,
    writer_root: u32,
    reader_pool: *schema.SchemaPool,
    reader_root: u32,
) Error!value.Datum {
    const fp = try fingerprintOf(buf);
    const expect = try canon.fingerprint(writer_pool, writer_root, gpa);
    if (fp != expect) return error.Soe;
    return resolve.decodeResolving(gpa, buf[10..], writer_pool, writer_root, reader_pool, reader_root);
}

test "single object round trip and fingerprint check" {
    const gpa = std.testing.allocator;
    var pool = try schema.parseAvsc(gpa, "{\"type\":\"record\",\"name\":\"M\",\"fields\":[{\"name\":\"a\",\"type\":\"int\"}]}");
    defer pool.deinit();
    var d = value.Datum.init(gpa, &pool);
    defer d.deinit();
    d.root = try d.putRecord(pool.root, &.{try d.putInt(pool.nodes.items[pool.root].fields[0].type_id, 7)});
    const frame = try encodeSingle(gpa, &pool, pool.root, &d);
    defer gpa.free(frame);
    try std.testing.expectEqual(@as(u8, 0xC3), frame[0]);
    try std.testing.expectEqual(@as(u8, 0x01), frame[1]);
    var back = try decodeSingle(gpa, &pool, pool.root, frame);
    defer back.deinit();
    try std.testing.expectEqual(@as(i32, 7), try back.asInt(try back.recordAt(back.root, 0)));

    var other = try schema.parseAvsc(gpa, "\"string\"");
    defer other.deinit();
    try std.testing.expectError(error.Soe, decodeSingle(gpa, &other, other.root, frame));

    var reader = try schema.parseAvsc(gpa, "{\"type\":\"record\",\"name\":\"M\",\"fields\":[{\"name\":\"a\",\"type\":\"long\"}]}");
    defer reader.deinit();
    var promoted = try decodeSingleResolving(gpa, frame, &pool, pool.root, &reader, reader.root);
    defer promoted.deinit();
    try std.testing.expectEqual(@as(i64, 7), try promoted.asLong(try promoted.recordAt(promoted.root, 0)));
    try std.testing.expectError(error.Soe, fingerprintOf("xx"));
}
