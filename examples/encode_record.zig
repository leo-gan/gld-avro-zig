//! Encode one generic record and print its length.
//!
//! From the repo root:
//! zig build run -- --help
//! zig run --dep avro -Mroot=examples/encode_record.zig -Mavro=src/root.zig

const std = @import("std");
const avro = @import("avro");

const schema_text =
    \\{"type":"record","name":"M","fields":[{"name":"a","type":"int"},{"name":"b","type":"string"}]}
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var pool = try avro.parseAvsc(gpa, schema_text);
    defer pool.deinit();
    var datum = avro.Datum.init(gpa, &pool);
    defer datum.deinit();
    const fields = pool.nodes.items[pool.root].fields;
    datum.root = try datum.putRecord(pool.root, &.{
        try datum.putInt(fields[0].type_id, 7),
        try datum.putString(fields[1].type_id, "hi"),
    });
    const bin = try datum.toOwnedBin();
    defer gpa.free(bin);
    const json = try avro.encodeJson(&datum);
    defer gpa.free(json);
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "binary {d} bytes, json {s}\n", .{ bin.len, json }) catch return;
    std.Io.File.stdout().writeStreamingAll(init.io, line) catch {};
}
