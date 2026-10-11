const std = @import("std");
const avro = @import("avro");
const LongList = @import("generated/LongList.zig").LongList;
const M = @import("generated/demo/M.zig").M;
const MChoice = @import("generated/demo/M.zig").M_d;
const A = @import("generated/A.zig").A;
const B = @import("generated/B.zig").B;
const Node = @import("generated/Node.zig").Node;
const NodePayload = @import("generated/Node.zig").Node_payload;

test "generated long list round trip" {
    const gpa = std.testing.allocator;
    const inner = try gpa.create(LongList);
    inner.* = .{ .value = 2, .next = null };
    var value = LongList{ .value = 1, .next = inner };
    defer value.deinit(gpa);
    var w = avro.Writer.init(gpa);
    defer w.deinit();
    try value.encode(&w);
    try std.testing.expectEqual(value.encodedLen(), w.slice().len);
    var r = avro.Reader.init(w.slice());
    var back = try LongList.decode(&r, gpa);
    defer back.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 1), back.value);
    try std.testing.expectEqual(@as(i64, 2), back.next.?.value);
    try std.testing.expect(back.next.?.next == null);
}

test "generated record optional union and mutual records" {
    const gpa = std.testing.allocator;
    const msg = M{
        .a = -3,
        .b = "hi",
        .c = null,
        .d = .{ .string = "z" },
    };
    var w = avro.Writer.init(gpa);
    defer w.deinit();
    try msg.encode(&w);
    var r = avro.Reader.init(w.slice());
    var back = try M.decode(&r, gpa);
    defer back.deinit(gpa);
    try std.testing.expectEqual(@as(i32, -3), back.a);
    try std.testing.expectEqualStrings("hi", back.b);
    try std.testing.expect(back.c == null);
    try std.testing.expectEqualStrings("z", back.d.string);

    const b_node = try gpa.create(B);
    b_node.* = .{ .a = null };
    var a = A{ .b = b_node };
    defer a.deinit(gpa);
    var w2 = avro.Writer.init(gpa);
    defer w2.deinit();
    try a.encode(&w2);
    var r2 = avro.Reader.init(w2.slice());
    var ab = try A.decode(&r2, gpa);
    defer ab.deinit(gpa);
    try std.testing.expect(ab.b.?.a == null);

    const node = Node{ .payload = .{ .string = "leaf" } };
    var w3 = avro.Writer.init(gpa);
    defer w3.deinit();
    try node.encode(&w3);
    var r3 = avro.Reader.init(w3.slice());
    var nb = try Node.decode(&r3, gpa);
    defer nb.deinit(gpa);
    try std.testing.expectEqualStrings("leaf", nb.payload.string);
    _ = MChoice;
    _ = NodePayload;
}
