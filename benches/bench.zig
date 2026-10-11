//! Representative encode/decode timing. Run `zig build bench -Doptimize=ReleaseFast`.

const std = @import("std");
const avro = @import("avro");

const schema_text =
    \\{"type":"record","name":"Event","namespace":"bench","fields":[
    \\{"name":"id","type":"long"},
    \\{"name":"ok","type":"boolean"},
    \\{"name":"name","type":"string"},
    \\{"name":"score","type":"double"},
    \\{"name":"tags","type":{"type":"array","items":"string"}},
    \\{"name":"labels","type":{"type":"map","values":"long"}},
    \\{"name":"inner","type":{"type":"record","name":"Inner","fields":[{"name":"x","type":"int"},{"name":"y","type":"int"}]}},
    \\{"name":"note","type":["null","string"]}
    \\]}
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var pool = try avro.parseAvsc(gpa, schema_text);
    defer pool.deinit();
    var sample = try buildSample(gpa, &pool);
    defer sample.deinit();
    const encoded = try sample.toOwnedBin();
    defer gpa.free(encoded);

    const n: usize = 2000;
    // Warmup.
    for (0..50) |_| {
        const bin = try sample.toOwnedBin();
        gpa.free(bin);
        var back = try avro.decodeBin(gpa, &pool, pool.root, encoded);
        back.deinit();
    }

    const enc_ns = try time(io, n, struct {
        fn run(ctx: *const anyopaque) !void {
            const s: *const avro.Datum = @ptrCast(@alignCast(ctx));
            const bin = try s.toOwnedBin();
            s.gpa.free(bin);
        }
    }.run, &sample);

    const dec_ns = try time(io, n, struct {
        fn run(ctx: *const anyopaque) !void {
            const c: *const Ctx = @ptrCast(@alignCast(ctx));
            var back = try avro.decodeBin(c.gpa, c.pool, c.pool.root, c.bytes);
            back.deinit();
        }
    }.run, &Ctx{ .gpa = gpa, .pool = &pool, .bytes = encoded });

    var stdout_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print("bytes {d}\nencode {d} ns/op\ndecode {d} ns/op\n", .{ encoded.len, enc_ns, dec_ns });
    try stdout.interface.flush();
}

const Ctx = struct {
    gpa: std.mem.Allocator,
    pool: *avro.SchemaPool,
    bytes: []const u8,
};

fn time(io: std.Io, n: usize, func: *const fn (*const anyopaque) anyerror!void, ctx: *const anyopaque) !u64 {
    const t0 = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..n) |_| try func(ctx);
    const t1 = std.Io.Clock.Timestamp.now(io, .awake);
    const ns: u64 = @intCast(t0.durationTo(t1).raw.nanoseconds);
    return ns / n;
}

fn buildSample(gpa: std.mem.Allocator, pool: *avro.SchemaPool) !avro.Datum {
    var d = avro.Datum.init(gpa, pool);
    errdefer d.deinit();
    const fields = pool.nodes.items[pool.root].fields;
    const tags_schema = fields[4].type_id;
    const tag_item = pool.nodes.items[tags_schema].item_id;
    var tags: [8]u32 = undefined;
    const words = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta" };
    for (words, 0..) |w, i| tags[i] = try d.putString(tag_item, w);
    const labels_schema = fields[5].type_id;
    const label_val = pool.nodes.items[labels_schema].value_id;
    const keys = [_][]const u8{ "one", "two", "three", "four" };
    var vals: [4]u32 = undefined;
    for (keys, 0..) |_, i| vals[i] = try d.putLong(label_val, @intCast(i * 10));
    const inner_schema = fields[6].type_id;
    const inner_fields = pool.nodes.items[inner_schema].fields;
    const inner = try d.putRecord(inner_schema, &.{
        try d.putInt(inner_fields[0].type_id, 4),
        try d.putInt(inner_fields[1].type_id, 5),
    });
    const note_schema = fields[7].type_id;
    const note_str = pool.nodes.items[note_schema].branches[1];
    const note = try d.putUnion(note_schema, 1, try d.putString(note_str, "hello avro"));
    d.root_schema = pool.root;
    d.root = try d.putRecord(pool.root, &.{
        try d.putLong(fields[0].type_id, 42),
        try d.putBool(fields[1].type_id, true),
        try d.putString(fields[2].type_id, "event-name"),
        try d.putDouble(fields[3].type_id, 1.5),
        try d.putArray(tags_schema, &tags),
        try d.putMap(labels_schema, &keys, &vals),
        inner,
        note,
    });
    return d;
}
