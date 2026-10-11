const std = @import("std");
const avro = @import("avro");

pub const schema_json =
    \\{"name":"demo.M","type":"record","fields":[{"name":"a","type":"int"},{"name":"b","type":"string"},{"name":"c","type":["null","long"]},{"name":"d","type":["int","string"]}]}
;

pub const M_d = union(enum) {
    int: i32,
    string: []const u8,
    pub fn encodedLen(self: @This()) usize {
        return switch (self) {
            .int => |v| avro.longLen(0) + avro.longLen(v),
            .string => |v| avro.longLen(1) + avro.bytesLen(v.len),
        };
    }
    pub fn encode(self: @This(), w: *avro.Writer) avro.Error!void {
        switch (self) {
            .int => |v| { try w.writeLong(0); try w.writeInt(v); },
            .string => |v| { try w.writeLong(1); try w.writeString(v); },
        }
    }
    pub fn decode(r: *avro.Reader, gpa: std.mem.Allocator) avro.Error!@This() {
        const i = try r.readLong();
        switch (i) {
            0 => return .{ .int = try r.readInt() },
            1 => return .{ .string = try r.readString(gpa) },
            else => return error.BadUnion,
        }
    }
    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        switch (self.*) {
            .int => |v| { _ = v; },
            .string => |v| { gpa.free(v); },
        }
    }
};
pub const M = struct {
    a: i32,
    b: []const u8,
    c: ?i64,
    d: M_d,
    pub fn encodedLen(self: @This()) usize {
        var n: usize = 0;
        n += avro.longLen(self.a);
        n += avro.bytesLen(self.b.len);
        n += blk: { if (self.c) |v| break :blk avro.longLen(1) + avro.longLen(v); break :blk avro.longLen(0); };
        n += self.d.encodedLen();
        return n;
    }
    pub fn encode(self: @This(), w: *avro.Writer) avro.Error!void {
        try w.writeInt(self.a);
        try w.writeString(self.b);
        if (self.c) |v| { try w.writeLong(1); try w.writeLong(v); } else try w.writeLong(0);
        try self.d.encode(w);
    }
    pub fn decode(r: *avro.Reader, gpa: std.mem.Allocator) avro.Error!@This() {
        const a: i32 = try r.readInt();
        const b: []const u8 = try r.readString(gpa);
        errdefer gpa.free(b);
        const c: ?i64 = blk: { const idx = try r.readLong(); if (idx == 0) break :blk null; if (idx != 1) return error.BadUnion; break :blk try r.readLong(); };
        const d: M_d = try M_d.decode(r, gpa);
        errdefer d.deinit(gpa);
        return .{
            .a = a,
            .b = b,
            .c = c,
            .d = d,
        };
    }
    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        gpa.free(self.b);
        self.d.deinit(gpa);
    }
};
