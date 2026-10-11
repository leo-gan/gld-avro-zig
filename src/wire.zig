//! Avro binary primitives: zigzag varints, IEEE-754 little-endian, block counts.

const std = @import("std");
const diag = @import("diag.zig");

pub const Error = diag.Error;
pub const Kind = diag.Kind;

pub fn zigzagEncode(n: i64) u64 {
    const u: u64 = @bitCast(n);
    return (u << 1) ^ @as(u64, @bitCast(n >> 63));
}

pub fn zigzagDecode(u: u64) i64 {
    const sign: u64 = @as(u64, 0) -% (u & 1);
    return @bitCast((u >> 1) ^ sign);
}

pub fn varintLen(v: u64) usize {
    var n = v;
    var c: usize = 1;
    while (n >= 0x80) : (c += 1) n >>= 7;
    return c;
}

pub fn longLen(v: i64) usize {
    return varintLen(zigzagEncode(v));
}

pub fn bytesLen(n: usize) usize {
    return longLen(@intCast(n)) + n;
}

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,
    kind: Kind = .eof,
    field: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn remaining(self: Reader) usize {
        return self.buf.len - self.pos;
    }

    pub fn fail(self: *Reader, kind: Kind) Error {
        self.kind = kind;
        return diag.fromKind(kind);
    }

    pub fn note(self: Reader) diag.Note {
        return .{ .kind = self.kind, .offset = self.pos, .field = self.field };
    }

    pub inline fn readByte(self: *Reader) Error!u8 {
        if (self.pos >= self.buf.len) return self.fail(.eof);
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn readVarint(self: *Reader) Error!u64 {
        var n: u64 = 0;
        var shift: u8 = 0;
        while (true) {
            if (shift >= 70) return self.fail(.bad_varint);
            const b = self.readByte() catch return self.fail(.eof);
            if (shift == 63 and (b & 0x7E) != 0) return self.fail(.bad_varint);
            if (shift < 63) {
                n |= @as(u64, b & 0x7F) << @intCast(shift);
            } else {
                n |= @as(u64, b & 1) << 63;
            }
            if (b & 0x80 == 0) return n;
            shift += 7;
        }
    }

    pub inline fn readLong(self: *Reader) Error!i64 {
        // Most Avro ints, lengths, and union indexes fit in one byte.
        if (self.pos < self.buf.len) {
            const b = self.buf[self.pos];
            if (b < 0x80) {
                @branchHint(.likely);
                self.pos += 1;
                const sign: u64 = 0 -% @as(u64, b & 1);
                return @bitCast((@as(u64, b) >> 1) ^ sign);
            }
        }
        return zigzagDecode(try self.readVarint());
    }

    pub fn readInt(self: *Reader) Error!i32 {
        const v = try self.readLong();
        if (v < std.math.minInt(i32) or v > std.math.maxInt(i32)) return self.fail(.range);
        return @intCast(v);
    }

    pub fn readBool(self: *Reader) Error!bool {
        const b = self.readByte() catch return self.fail(.eof);
        if (b == 0) return false;
        if (b == 1) return true;
        return self.fail(.bad_bool);
    }

    pub fn readFloat(self: *Reader) Error!f32 {
        if (self.remaining() < 4) return self.fail(.eof);
        const bits = std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
        self.pos += 4;
        return @bitCast(bits);
    }

    pub fn readDouble(self: *Reader) Error!f64 {
        if (self.remaining() < 8) return self.fail(.eof);
        const bits = std.mem.readInt(u64, self.buf[self.pos..][0..8], .little);
        self.pos += 8;
        return @bitCast(bits);
    }

    pub fn readRaw(self: *Reader, gpa: std.mem.Allocator, n: usize) Error![]u8 {
        if (n > self.remaining()) return self.fail(.eof);
        const out = gpa.dupe(u8, self.buf[self.pos..][0..n]) catch return error.OutOfMemory;
        self.pos += n;
        return out;
    }

    pub fn readRawInto(self: *Reader, dest: []u8) Error!void {
        if (dest.len > self.remaining()) return self.fail(.eof);
        @memcpy(dest, self.buf[self.pos..][0..dest.len]);
        self.pos += dest.len;
    }

    pub fn readBytes(self: *Reader, gpa: std.mem.Allocator) Error![]u8 {
        const n = try self.readLong();
        if (n < 0) return self.fail(.range);
        const len = std.math.cast(usize, n) orelse return self.fail(.range);
        return self.readRaw(gpa, len);
    }

    pub fn readString(self: *Reader, gpa: std.mem.Allocator) Error![]u8 {
        const n = try self.readLong();
        if (n < 0) return self.fail(.range);
        const len = std.math.cast(usize, n) orelse return self.fail(.range);
        if (len > self.remaining()) return self.fail(.eof);
        const src = self.buf[self.pos..][0..len];
        if (!std.unicode.utf8ValidateSlice(src)) return self.fail(.bad_utf8);
        const out = gpa.dupe(u8, src) catch return error.OutOfMemory;
        self.pos += len;
        return out;
    }

    pub fn readFixed(self: *Reader, gpa: std.mem.Allocator, n: usize) Error![]u8 {
        return self.readRaw(gpa, n);
    }

    /// `size_hint` is -1 when the block count is non-negative.
    pub fn readBlockCount(self: *Reader) Error!struct { count: i64, size_hint: i64 } {
        const c = try self.readLong();
        if (c < 0) {
            const sz = try self.readLong();
            if (sz < 0) return self.fail(.bad_block);
            if (std.math.cast(usize, sz) == null) return self.fail(.range);
            if (@as(usize, @intCast(sz)) > self.remaining()) return self.fail(.bad_block);
            return .{ .count = -c, .size_hint = sz };
        }
        return .{ .count = c, .size_hint = -1 };
    }
};

pub const Writer = struct {
    gpa: std.mem.Allocator,
    buf: []u8,
    len: usize,
    fixed: bool = false,

    pub fn init(gpa: std.mem.Allocator) Writer {
        return .{ .gpa = gpa, .buf = &.{}, .len = 0 };
    }

    /// Encode into caller memory. `ensure` returns `error.OutOfMemory` instead of allocating.
    pub fn initFixed(buf: []u8) Writer {
        return .{ .gpa = undefined, .buf = buf, .len = 0, .fixed = true };
    }

    pub fn initCapacity(gpa: std.mem.Allocator, n: usize) Error!Writer {
        var w = Writer.init(gpa);
        try w.ensure(n);
        return w;
    }

    pub fn deinit(self: *Writer) void {
        if (!self.fixed and self.buf.len != 0) self.gpa.free(self.buf);
        self.* = undefined;
    }

    pub fn slice(self: Writer) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn toOwnedSlice(self: *Writer) Error![]u8 {
        if (self.len == 0) {
            if (self.buf.len != 0) self.gpa.free(self.buf);
            self.buf = &.{};
            return &.{};
        }
        if (self.buf.len == self.len) {
            const out = self.buf;
            self.buf = &.{};
            self.len = 0;
            return out;
        }
        if (self.gpa.remap(self.buf, self.len)) |shrunk| {
            self.buf = &.{};
            self.len = 0;
            return shrunk;
        }
        const out = self.gpa.dupe(u8, self.buf[0..self.len]) catch return error.OutOfMemory;
        self.gpa.free(self.buf);
        self.buf = &.{};
        self.len = 0;
        return out;
    }

    pub fn ensure(self: *Writer, extra: usize) Error!void {
        const need = self.len + extra;
        if (need <= self.buf.len) return;
        if (self.fixed) return error.OutOfMemory;
        var cap: usize = if (self.buf.len == 0) 64 else self.buf.len;
        while (cap < need) {
            if (cap > (1 << 30)) return error.OutOfMemory;
            cap *= 2;
        }
        const grown = self.gpa.realloc(self.buf, cap) catch return error.OutOfMemory;
        self.buf = grown;
    }

    pub inline fn writeByte(self: *Writer, b: u8) Error!void {
        if (self.len == self.buf.len) try self.ensure(1);
        self.buf[self.len] = b;
        self.len += 1;
    }

    pub inline fn writeRaw(self: *Writer, bytes: []const u8) Error!void {
        try self.ensure(bytes.len);
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn writeVarint(self: *Writer, value: u64) Error!void {
        var v = value;
        while (v >= 0x80) {
            try self.writeByte(@intCast((v & 0x7F) | 0x80));
            v >>= 7;
        }
        try self.writeByte(@intCast(v));
    }

    pub inline fn writeLong(self: *Writer, v: i64) Error!void {
        const zz = zigzagEncode(v);
        if (zz < 0x80) {
            @branchHint(.likely);
            try self.writeByte(@intCast(zz));
            return;
        }
        try self.writeVarint(zz);
    }

    pub fn writeInt(self: *Writer, v: i32) Error!void {
        try self.writeLong(v);
    }

    pub fn writeBool(self: *Writer, v: bool) Error!void {
        try self.writeByte(if (v) 1 else 0);
    }

    pub fn writeFloat(self: *Writer, v: f32) Error!void {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, @bitCast(v), .little);
        try self.writeRaw(&tmp);
    }

    pub fn writeDouble(self: *Writer, v: f64) Error!void {
        var tmp: [8]u8 = undefined;
        std.mem.writeInt(u64, &tmp, @bitCast(v), .little);
        try self.writeRaw(&tmp);
    }

    pub inline fn writeBytes(self: *Writer, v: []const u8) Error!void {
        const zz = zigzagEncode(@intCast(v.len));
        if (zz < 0x80) {
            @branchHint(.likely);
            try self.ensure(1 + v.len);
            self.buf[self.len] = @intCast(zz);
            self.len += 1;
            @memcpy(self.buf[self.len..][0..v.len], v);
            self.len += v.len;
            return;
        }
        try self.writeLong(@intCast(v.len));
        try self.writeRaw(v);
    }

    pub fn writeString(self: *Writer, v: []const u8) Error!void {
        try self.writeBytes(v);
    }

    pub fn writeFixed(self: *Writer, v: []const u8) Error!void {
        try self.writeRaw(v);
    }

    pub fn writeBlockStart(self: *Writer, count: i64) Error!void {
        try self.writeLong(count);
    }

    pub fn writeBlockEnd(self: *Writer) Error!void {
        try self.writeLong(0);
    }

    pub fn writeU64Le(self: *Writer, v: u64) Error!void {
        var tmp: [8]u8 = undefined;
        std.mem.writeInt(u64, &tmp, v, .little);
        try self.writeRaw(&tmp);
    }
};

test "zigzag matches known avro bytes" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { i64, []const u8 }{
        .{ 0, "\x00" },
        .{ 1, "\x02" },
        .{ -1, "\x01" },
        .{ 64, "\x80\x01" },
        .{ -64, "\x7f" },
        .{ std.math.maxInt(i32), "\xfe\xff\xff\xff\x0f" },
        .{ std.math.minInt(i32), "\xff\xff\xff\xff\x0f" },
        .{ std.math.maxInt(i64), "\xfe\xff\xff\xff\xff\xff\xff\xff\xff\x01" },
        .{ std.math.minInt(i64), "\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01" },
    };
    for (cases) |c| {
        var w = Writer.init(gpa);
        defer w.deinit();
        try w.writeLong(c[0]);
        try std.testing.expectEqualSlices(u8, c[1], w.slice());
        var r = Reader.init(w.slice());
        try std.testing.expectEqual(c[0], try r.readLong());
        try std.testing.expectEqual(@as(usize, 0), r.remaining());
    }
}

test "reject overlong varint and bad bool" {
    var r = Reader.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 });
    try std.testing.expectError(error.BadVarint, r.readLong());

    var r2 = Reader.init(&[_]u8{0x02});
    try std.testing.expectError(error.BadBool, r2.readBool());

    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeLong(@as(i64, std.math.maxInt(i32)) + 1);
    var r3 = Reader.init(w.slice());
    try std.testing.expectError(error.Range, r3.readInt());
    var r4 = Reader.init("\xff\xff\xff\xff\x0f");
    try std.testing.expectEqual(std.math.minInt(i32), try r4.readInt());
}

test "float and double little endian" {
    const gpa = std.testing.allocator;
    var w = Writer.init(gpa);
    defer w.deinit();
    try w.writeFloat(1.5);
    try w.writeDouble(1.5);
    try std.testing.expectEqualSlices(u8, "\x00\x00\xc0\x3f\x00\x00\x00\x00\x00\x00\xf8\x3f", w.slice());
    var r = Reader.init(w.slice());
    try std.testing.expectEqual(@as(f32, 1.5), try r.readFloat());
    try std.testing.expectEqual(@as(f64, 1.5), try r.readDouble());
}

test "truncated bytes" {
    var r = Reader.init(&[_]u8{0x04});
    try std.testing.expectError(error.Eof, r.readBytes(std.testing.allocator));
    var r2 = Reader.init(&[_]u8{0x80});
    try std.testing.expectError(error.Eof, r2.readLong());
}
