//! gld-avrogen-zig — read an .avsc or .avdl file and emit Zig types.

const std = @import("std");
const avro = @import("avro");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    defer args.deinit();
    _ = args.skip();
    var schema_path: ?[]const u8 = null;
    var idl_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--schema")) {
            schema_path = args.next() orelse return usage(io);
        } else if (std.mem.eql(u8, arg, "--idl")) {
            idl_path = args.next() orelse return usage(io);
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_dir = args.next() orelse return usage(io);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return usage(io);
        } else return usage(io);
    }
    const out = out_dir orelse return usage(io);
    if ((schema_path == null) == (idl_path == null)) return usage(io);
    if (schema_path) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(avro.diag.max_schema_bytes)) catch |err| {
            std.log.err("read {s}: {t}", .{ path, err });
            return err;
        };
        defer gpa.free(text);
        avro.codegen.generateAvsc(gpa, io, text, out) catch |err| {
            std.log.err("codegen failed: {t}", .{err});
            return err;
        };
    } else if (idl_path) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(avro.diag.max_schema_bytes)) catch |err| {
            std.log.err("read {s}: {t}", .{ path, err });
            return err;
        };
        defer gpa.free(text);
        avro.codegen.generateAvdl(gpa, io, text, path, out) catch |err| {
            std.log.err("codegen failed: {t}", .{err});
            return err;
        };
    }
}

fn usage(io: std.Io) !void {
    std.Io.File.stderr().writeStreamingAll(io,
        \\gld-avrogen-zig --schema FILE.avsc --out DIR
        \\gld-avrogen-zig --idl FILE.avdl --out DIR
        \\
    ) catch {};
    return error.InvalidArgument;
}

const InvalidArgument = error{InvalidArgument};
