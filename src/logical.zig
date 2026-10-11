//! Logical-type helpers. Values still travel as the underlying primitive.
//! A logical type on the wrong underlying type is left to the caller; these
//! helpers return `error.Schema` in that case.

const std = @import("std");
const diag = @import("diag.zig");
const schema = @import("schema.zig");

pub const Error = diag.Error;

pub const Duration = struct { months: u32, days: u32, millis: u32 };

pub fn decimalI128(bytes: []const u8) Error!i128 {
    if (bytes.len == 0 or bytes.len > 16) return error.Range;
    var raw: [16]u8 = undefined;
    const pad: u8 = if (bytes[0] & 0x80 != 0) 0xff else 0;
    @memset(raw[0 .. 16 - bytes.len], pad);
    @memcpy(raw[16 - bytes.len ..], bytes);
    return std.mem.readInt(i128, &raw, .big);
}

pub fn decimalBytes(gpa: std.mem.Allocator, unscaled: i128) Error![]u8 {
    var raw: [16]u8 = undefined;
    std.mem.writeInt(i128, &raw, unscaled, .big);
    var start: usize = 0;
    while (start + 1 < raw.len) {
        if (raw[start] == 0xff and (raw[start + 1] & 0x80) != 0) {
            start += 1;
            continue;
        }
        if (raw[start] == 0x00 and (raw[start + 1] & 0x80) == 0) {
            start += 1;
            continue;
        }
        break;
    }
    return gpa.dupe(u8, raw[start..]) catch error.OutOfMemory;
}

pub fn validateUuid(s: []const u8) Error!void {
    if (s.len != 36) return error.Schema;
    for (s, 0..) |c, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (dash) {
            if (c != '-') return error.Schema;
            continue;
        }
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!hex) return error.Schema;
    }
}

pub fn decodeDuration(bytes: []const u8) Error!Duration {
    if (bytes.len != 12) return error.Range;
    return .{
        .months = std.mem.readInt(u32, bytes[0..4], .little),
        .days = std.mem.readInt(u32, bytes[4..8], .little),
        .millis = std.mem.readInt(u32, bytes[8..12], .little),
    };
}

pub fn encodeDuration(d: Duration) [12]u8 {
    var out: [12]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], d.months, .little);
    std.mem.writeInt(u32, out[4..8], d.days, .little);
    std.mem.writeInt(u32, out[8..12], d.millis, .little);
    return out;
}

pub fn dateDays(year: i32, month: u8, day: u8) i32 {
    // Civil date to days since 1970-01-01 (Howard Hinnant).
    const y: i32 = if (month <= 2) year - 1 else year;
    const era = if (y >= 0) @divFloor(y, 400) else @divFloor(y - 399, 400);
    const yoe: u32 = @intCast(y - era * 400);
    const mp: u32 = if (month > 2) month - 3 else month + 9;
    const doy: u32 = (153 * mp + 2) / 5 + day - 1;
    const doe: u32 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return @as(i32, @intCast(era * 146097 + @as(i32, @intCast(doe)))) - 719468;
}

pub fn logicalOk(pool: *const schema.SchemaPool, id: u32) bool {
    const n = pool.nodes.items[id];
    if (n.logical_type.len == 0) return true;
    if (std.mem.eql(u8, n.logical_type, "decimal")) {
        if (n.kind != .bytes and n.kind != .fixed) return false;
        return pool.attr(id, "precision") != null;
    }
    if (std.mem.eql(u8, n.logical_type, "uuid")) return n.kind == .string;
    if (std.mem.eql(u8, n.logical_type, "date") or std.mem.eql(u8, n.logical_type, "time-millis")) return n.kind == .int;
    if (std.mem.eql(u8, n.logical_type, "time-micros") or
        std.mem.eql(u8, n.logical_type, "timestamp-millis") or
        std.mem.eql(u8, n.logical_type, "timestamp-micros") or
        std.mem.eql(u8, n.logical_type, "local-timestamp-millis") or
        std.mem.eql(u8, n.logical_type, "local-timestamp-micros")) return n.kind == .long;
    if (std.mem.eql(u8, n.logical_type, "duration")) return n.kind == .fixed and n.size == 12;
    return true;
}

test "decimal uuid duration and date" {
    const gpa = std.testing.allocator;
    const raw = try decimalBytes(gpa, -12345);
    defer gpa.free(raw);
    try std.testing.expectEqual(@as(i128, -12345), try decimalI128(raw));
    const pos = try decimalBytes(gpa, 42);
    defer gpa.free(pos);
    try std.testing.expectEqual(@as(i128, 42), try decimalI128(pos));
    try validateUuid("00112233-4455-6677-8899-aabbccddeeff");
    try std.testing.expectError(error.Schema, validateUuid("nope"));
    const dur = Duration{ .months = 1, .days = 2, .millis = 3 };
    const enc = encodeDuration(dur);
    try std.testing.expectEqual(dur, try decodeDuration(&enc));
    try std.testing.expectEqual(@as(i32, 0), dateDays(1970, 1, 1));
    try std.testing.expectEqual(@as(i32, 1), dateDays(1970, 1, 2));

    var pool = try schema.parseAvsc(gpa, "{\"type\":\"fixed\",\"name\":\"D\",\"size\":12,\"logicalType\":\"duration\"}");
    defer pool.deinit();
    try std.testing.expect(logicalOk(&pool, pool.root));
    var bad = try schema.parseAvsc(gpa, "{\"type\":\"int\",\"logicalType\":\"uuid\"}");
    defer bad.deinit();
    try std.testing.expect(!logicalOk(&bad, bad.root));
}
