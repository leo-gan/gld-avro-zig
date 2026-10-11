//! Raw DEFLATE (RFC 1951) for the Avro `deflate` codec.
//! Uses Zig's `std.compress.flate` with the raw container. Does not link libz.

const std = @import("std");
const diag = @import("diag.zig");

pub const Error = diag.Error;
pub const max_inflate = diag.max_inflate;

pub fn deflateRaw(gpa: std.mem.Allocator, src: []const u8) Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    aw.ensureUnusedCapacity(64) catch return error.OutOfMemory;
    const window = gpa.alloc(u8, std.compress.flate.max_window_len) catch return error.OutOfMemory;
    defer gpa.free(window);
    const comp = gpa.create(std.compress.flate.Compress) catch return error.OutOfMemory;
    defer gpa.destroy(comp);
    comp.* = std.compress.flate.Compress.init(&aw.writer, window, .raw, .level_1) catch return error.Deflate;
    comp.writer.writeAll(src) catch return error.Deflate;
    comp.finish() catch return error.Deflate;
    return gpa.dupe(u8, aw.written()) catch error.OutOfMemory;
}

pub fn inflateRaw(gpa: std.mem.Allocator, src: []const u8) Error![]u8 {
    if (src.len == 0) return error.Deflate;
    var input = std.Io.Reader.fixed(src);
    const window = gpa.alloc(u8, std.compress.flate.max_window_len) catch return error.OutOfMemory;
    defer gpa.free(window);
    var dec = std.compress.flate.Decompress.init(&input, .raw, window);
    const out = dec.reader.allocRemaining(gpa, .limited(max_inflate)) catch return error.Deflate;
    if (dec.err != null) {
        gpa.free(out);
        return error.Deflate;
    }
    return out;
}

test "raw deflate round trip" {
    const gpa = std.testing.allocator;
    const src = "hello hello hello hello avro deflate block";
    const comp = try deflateRaw(gpa, src);
    defer gpa.free(comp);
    const back = try inflateRaw(gpa, comp);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(src, back);
    const empty = try deflateRaw(gpa, "");
    defer gpa.free(empty);
    const back_empty = try inflateRaw(gpa, empty);
    defer gpa.free(back_empty);
    try std.testing.expectEqual(@as(usize, 0), back_empty.len);
}
