const std = @import("std");
const avro = @import("avro");
const B = @import("B.zig").B;

pub const schema_json =
    \\{"name":"A","type":"record","fields":[{"name":"b","type":["null",{"name":"B","type":"record","fields":[{"name":"a","type":["null","A"]}]}]}]}
;

pub const A = struct {
    b: ?*B,
    pub fn encodedLen(self: @This()) usize {
        var n: usize = 0;
        n += blk: { if (self.b) |v| break :blk avro.longLen(1) + v.*.encodedLen(); break :blk avro.longLen(0); };
        return n;
    }
    pub fn encode(self: @This(), w: *avro.Writer) avro.Error!void {
        if (self.b) |v| { try w.writeLong(1); try v.*.encode(w); } else try w.writeLong(0);
    }
    pub fn decode(r: *avro.Reader, gpa: std.mem.Allocator) avro.Error!@This() {
        const b: ?*B = blk: { const idx = try r.readLong(); if (idx == 0) break :blk null; if (idx != 1) return error.BadUnion; const p = gpa.create(B) catch return error.OutOfMemory; p.* = try B.decode(r, gpa); break :blk p; };
        errdefer if (b) |v| { v.deinit(gpa); gpa.destroy(v); };
        return .{
            .b = b,
        };
    }
    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        if (self.b) |v| { v.deinit(gpa); gpa.destroy(v); }
    }
};
