const std = @import("std");
const avro = @import("avro");

pub const schema_json =
    \\{"name":"Node","type":"record","fields":[{"name":"payload","type":["Node","string"]}]}
;

pub const Node_payload = union(enum) {
    Node: *Node,
    string: []const u8,
    pub fn encodedLen(self: @This()) usize {
        return switch (self) {
            .Node => |v| avro.longLen(0) + v.encodedLen(),
            .string => |v| avro.longLen(1) + avro.bytesLen(v.len),
        };
    }
    pub fn encode(self: @This(), w: *avro.Writer) avro.Error!void {
        switch (self) {
            .Node => |v| { try w.writeLong(0); try v.encode(w); },
            .string => |v| { try w.writeLong(1); try w.writeString(v); },
        }
    }
    pub fn decode(r: *avro.Reader, gpa: std.mem.Allocator) avro.Error!@This() {
        const i = try r.readLong();
        switch (i) {
            0 => return .{ .Node = blk: { const p = gpa.create(Node) catch return error.OutOfMemory; p.* = try Node.decode(r, gpa); break :blk p; } },
            1 => return .{ .string = try r.readString(gpa) },
            else => return error.BadUnion,
        }
    }
    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        switch (self.*) {
            .Node => |v| { v.deinit(gpa); gpa.destroy(v); },
            .string => |v| { gpa.free(v); },
        }
    }
};
pub const Node = struct {
    payload: Node_payload,
    pub fn encodedLen(self: @This()) usize {
        var n: usize = 0;
        n += self.payload.encodedLen();
        return n;
    }
    pub fn encode(self: @This(), w: *avro.Writer) avro.Error!void {
        try self.payload.encode(w);
    }
    pub fn decode(r: *avro.Reader, gpa: std.mem.Allocator) avro.Error!@This() {
        const payload: Node_payload = try Node_payload.decode(r, gpa);
        errdefer payload.deinit(gpa);
        return .{
            .payload = payload,
        };
    }
    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.payload.deinit(gpa);
    }
};
