const std = @import("std");
const avro = @import("avro");

pub const schema_json =
    \\{"name":"LongList","type":"record","fields":[{"name":"value","type":"long"},{"name":"next","type":["null","LongList"]}]}
;

pub const LongList = struct {
    value: i64,
    next: ?*LongList,
    pub fn encodedLen(self: @This()) usize {
        var n: usize = 0;
        n += avro.longLen(self.value);
        n += blk: { if (self.next) |v| break :blk avro.longLen(1) + v.*.encodedLen(); break :blk avro.longLen(0); };
        return n;
    }
    pub fn encode(self: @This(), w: *avro.Writer) avro.Error!void {
        try w.writeLong(self.value);
        if (self.next) |v| { try w.writeLong(1); try v.*.encode(w); } else try w.writeLong(0);
    }
    pub fn decode(r: *avro.Reader, gpa: std.mem.Allocator) avro.Error!@This() {
        const value: i64 = try r.readLong();
        const next: ?*LongList = blk: { const idx = try r.readLong(); if (idx == 0) break :blk null; if (idx != 1) return error.BadUnion; const p = gpa.create(LongList) catch return error.OutOfMemory; p.* = try LongList.decode(r, gpa); break :blk p; };
        errdefer if (next) |v| { v.deinit(gpa); gpa.destroy(v); };
        return .{
            .value = value,
            .next = next,
        };
    }
    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        if (self.next) |v| { v.deinit(gpa); gpa.destroy(v); }
    }
};
