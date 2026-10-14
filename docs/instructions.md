# Instructions

These steps assume a Linux machine and Zig 0.16.0. The module name is `avro`.
The package version in `build.zig.zon` is `0.2.0`.

## Install

Zig 0.16 fetches this package by URL and content hash. The package key is `gld_avro_zig`. The module name is `avro`.

```zig
.dependencies = .{
    .gld_avro_zig = .{
        .url = "https://github.com/leo-gan/gld-avro-zig/archive/refs/tags/0.2.0.tar.gz",
        .hash = "gld_avro_zig-0.2.0-1wSpKL0YBABB8zW6GcpS_Gte5L8IhuRKluGvxAakuVIe",
    },
},
```

```zig
const avro_dep = b.dependency("gld_avro_zig", .{
    .target = target,
    .optimize = optimize,
});
const avro = avro_dep.module("avro");
```

This records the same dependency:

```bash
zig fetch --save=gld_avro_zig https://github.com/leo-gan/gld-avro-zig/archive/refs/tags/0.2.0.tar.gz
```

## Build this repository

```bash
git clone https://github.com/leo-gan/gld-avro-zig.git
cd gld-avro-zig
zig build test
zig build
```

`zig build test` compiles `src/root.zig` and `tests/generated_test.zig`.
`zig build` installs `zig-out/bin/gld-avrogen-zig`.

| Command | What it runs |
| --- | --- |
| `zig build test` | Unit tests, golden bytes, container files, and generated structs. |
| `scripts/run-tests.sh` | The same `zig build test`. |
| `zig build bench -Doptimize=ReleaseFast` | Nanoseconds per encode and decode of one `Event` record. |
| `scripts/check-generated.sh` | Regenerates `LongList.zig` and diffs it. |

A local `.env` file is gitignored. Do not commit it. This library does not
read that file.

## Decode a generic record

```zig
const std = @import("std");
const avro = @import("avro");

pub fn main(init: std.process.Init) !void {
    var pool = try avro.parseAvsc(init.gpa,
        \\{"type":"record","name":"M","fields":[{"name":"a","type":"int"}]}
    );
    defer pool.deinit();
    var datum = avro.Datum.init(init.gpa, &pool);
    defer datum.deinit();
    const a = pool.nodes.items[pool.root].fields[0].type_id;
    datum.root = try datum.putRecord(pool.root, &.{try datum.putInt(a, 7)});
    const bin = try datum.toOwnedBin();
    defer init.gpa.free(bin);
}
```

Wire a module named `avro` at `src/root.zig`:

```bash
zig run --dep avro -Mroot=examples/encode_record.zig -Mavro=src/root.zig
```

Binary `encode` returns `error.OutOfMemory` only when allocation fails. Decode
returns `avro.Error`. After a decode error, `Reader.kind`, `Reader.pos`, and
`Reader.field` are the diagnostic. `field` is 1-based inside a record and `0`
when the field is unknown.

## Generate Zig

```bash
zig build run -- --schema testdata/avsc/longlist.avsc --out tests/generated
zig build run -- --idl testdata/avdl/demo.avdl --out /tmp/avro-idl
```

Each named record, enum, and fixed becomes one `.zig` file. A nullable
recursive field is `?*T`. A two-branch union of `null` and `T` is `?T`. Any
other union is a tagged `union(enum)`. Generated functions are `encodedLen`,
`encode`, `decode`, and `deinit`. Compile generated code with `--dep avro`.

## Resolution and container files

`avro.decodeResolving` reads bytes written with one schema into another.
Promotions are `int` to `long` / `float` / `double`, `long` to `float` /
`double`, `float` to `double`, and `string` to or from `bytes`. Records match
on the unqualified name after **reader** aliases. A writer-only alias does not
match. A missing reader field uses its default or fails.

`avro.readOcf` opens an object container file. Pass a reader schema JSON
string to resolve each object. Omit it to decode with the file schema.
Codecs are `null` and `deflate`.

`avro.encodeSingle` writes `C3 01`, the little-endian CRC-64-AVRO fingerprint,
and the datum. `decodeSingle` checks that fingerprint against the reader
schema. `decodeSingleResolving` checks it against the writer schema, then
resolves.
