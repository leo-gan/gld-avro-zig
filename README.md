# gld-avro-zig

A from-scratch [Apache Avro](https://avro.apache.org/docs/1.11.1/specification/)
library for [Zig](https://ziglang.org/) 0.16. The import is `avro`. The code
generator is `gld-avrogen-zig`.

The runtime does not wrap, link, or vendor libavro. Object-container `deflate`
uses Zig's `std.compress.flate` raw container (RFC 1951). It does not link libz.
Python `avro` is a **test oracle** only.

This repository is a standalone library. It is not part of any other project.

Documentation: [Why Avro](https://leo-gan.github.io/gld-avro-zig/why-avro/),
[Instructions](https://leo-gan.github.io/gld-avro-zig/instructions/),
[Examples](https://leo-gan.github.io/gld-avro-zig/examples/),
[Techniques](https://leo-gan.github.io/gld-avro-zig/techniques/),
[Test data](https://leo-gan.github.io/gld-avro-zig/test-data/).

## Build

Zig 0.16.0:

```bash
git clone https://github.com/leo-gan/gld-avro-zig.git
cd gld-avro-zig
zig build test
zig build
```

`zig build` installs `gld-avrogen-zig` under `zig-out/bin`.

## What it reads and writes

| Surface | Behavior |
| --- | --- |
| Binary datum | Primitives, records, enums, arrays, maps, fixed, and unions. Zigzag varints. Variable-length array and map blocks, including negative counts. |
| Schema | `.avsc` JSON and a practical `.avdl` subset, plus JSON `.avpr` types. |
| Canonical form | Parsing Canonical Form and CRC-64-AVRO. |
| Unions | `null` plus one other type is optional. Every other union is tagged. |
| Generic values | `Datum` encode and decode, plus writer/reader resolution (promotion, reader aliases, defaults, field reorder). |
| Object container files | Magic, metadata, sync, `null` and `deflate` codecs. |
| Single-object encoding | `C3 01`, little-endian CRC-64-AVRO, then the datum. |
| Avro JSON | Official JSON encoding, including union wrappers. |
| Codegen | Zig structs with `encodedLen`, `encode`, and `decode`. |

Logical types stay on their underlying primitive. Helpers convert decimal
(within `i128`), UUID text, duration, and a civil date.

## Layout

`src/root.zig` is the public module. `src/wire.zig` is the binary codec.
`src/schema.zig` and `src/idl.zig` parse schemas. `src/value.zig` is the generic
datum. `src/resolve.zig`, `src/jcodec.zig`, `src/ocf.zig`, and `src/soe.zig`
are resolution, Avro JSON, container files, and single-object frames.
`src/deflate.zig` is raw DEFLATE. `src/codegen.zig` emits Zig.

Version `0.2.0` lives in `build.zig.zon` and `src/root.zig`.
