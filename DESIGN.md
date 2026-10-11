# Apache Avro for Zig (`gld-avro-zig`)

| Field | Value |
| --- | --- |
| **Document title** | Apache Avro serializer for Zig |
| **Author** | Leonid Ganeline |
| **Date** | 2026-10-11 |
| **Status** | Implemented (0.2.0) |
| **Module** | `avro` |
| **CLI** | `gld-avrogen-zig` |
| **License** | MIT, Copyright (c) 2026 Leonid Ganeline |
| **Language** | Zig 0.16.0 |
| **Spec target** | [Apache Avro 1.11.1](https://avro.apache.org/docs/1.11.1/specification/) |

## Goals

1. Encode and decode Avro binary for every primitive and for record, enum, array, map, fixed, and union.
2. Zigzag varints for `int` and `long`, including lengths. Reject overlong varints.
3. Variable-length array and map blocks, including a negative count plus a byte size.
4. Parse `.avsc` and a practical `.avdl` subset, including `import idl`, `import schema`, and `import protocol` (JSON `.avpr`, types only).
5. Parsing Canonical Form and CRC-64-AVRO. Empty input fingerprints to `0xc15d213aa4d7a795`.
6. A two-branch union of `null` and `T` is optional. Every other union is tagged. The branch index is the schema index, not "null is always zero".
7. Generic `Datum` values and writer/reader resolution: numeric promotion, `string`/`bytes`, reader aliases, defaults, field reorder, enum defaults. Writer-only aliases do not match. Fixed matches unqualified name and size.
8. Object container files with codecs `null` and `deflate`.
9. Single-object encoding: `C3 01`, little-endian CRC-64-AVRO, datum.
10. Official Avro JSON encoding, including union wrappers. Named branches encode with the short name and decode with the short name or the fullname.
11. `gld-avrogen-zig` emits Zig types with `encodedLen`, `encode`, and `decode`.
12. No libavro and no libz.

## Non-goals

- Avro RPC, handshake, or generated message stubs. An IDL `message` is skipped so the data types around it still parse.
- Snappy, bzip2, xz, zstandard, or the Confluent schema-registry framing.
- A full arbitrary-precision decimal type. Decimal helpers cover two's-complement values that fit in `i128`.
- Reflection over arbitrary Zig structs that were not generated from a schema.

## Layout

```text
src/root.zig       public module avro
src/wire.zig       binary reader and writer
src/json.zig       JSON values for schemas and Avro JSON
src/schema.zig     .avsc model, names, defaults
src/idl.zig        .avdl and .avpr
src/canon.zig      Parsing Canonical Form and CRC-64-AVRO
src/value.zig      generic Datum
src/resolve.zig    writer/reader conversion
src/jcodec.zig     Avro JSON
src/ocf.zig        object container files
src/soe.zig        single-object frames
src/deflate.zig    raw DEFLATE
src/logical.zig    decimal, uuid, duration, date helpers
src/codegen.zig    Zig emitter
src/main.zig       gld-avrogen-zig
```

Version `0.2.0` is `build.zig.zon` `.version` and `avro.version` in `src/root.zig`.

## Wire

Encode appends to a buffer. It returns `error.OutOfMemory` when the buffer cannot grow. It does not validate schema-level constraints. Decode returns `avro.Error` and records `Reader.kind`, `Reader.pos`, and `Reader.field`.

`int` is range-checked to 32 bits after zigzag. A length that is negative or larger than the remaining input is an error. Boolean bytes other than 0 and 1 are `error.BadBool`. Strings must be UTF-8.

Array and map blocks end with a zero count. A negative count is followed by a non-negative size. The size must fit in the remaining input. Decoding still walks each item. The writer emits one positive block and a zero terminator.

## Schema

`SchemaPool` stores nodes in a list. Strings live in an arena. A forward reference allocates an unresolved node so recursive and mutually recursive records resolve. `finish` checks unions and defaults.

Defaults are raw JSON text. A union default is checked against branch 0 only. `["string","null"]` with default `null` is rejected. `["null","string"]` with default `null` is accepted.

IDL field defaults are converted to Avro JSON at parse time (`null`, booleans, numbers, strings, arrays, maps with `:`, records with `=`). `T?` is `["null", T]`. `error` is a record with `is_error` set. The binary layout is the same as a record.

Parsing Canonical Form drops doc, aliases, defaults, and logical types, uses fullnames, and emits a named schema object once. Later references, including recursion, are the fullname string.

## Runtime

`Datum` nodes point at schema ids. Records store children in schema order. Maps store pairs in insertion order. Float and double values keep IEEE bits in the integer slot so a binary round trip does not quiet a NaN. JSON encode rejects NaN and infinity.

Resolution decodes with the writer schema and converts. Match rules:

| Writer | Reader | Result |
| --- | --- | --- |
| `int` | `long`, `float`, `double` | promote |
| `long` | `float`, `double` | promote |
| `float` | `double` | promote |
| `string` | `bytes` | copy UTF-8 bytes |
| `bytes` | `string` | copy if UTF-8 |
| record | record | unqualified name, after reader aliases |
| enum | enum | same name rule; unknown symbol uses reader default |
| fixed | fixed | same name rule and equal size |
| union | union or a bare type | first compatible branch |

A reader field that the writer does not have requires a default. Extra writer fields are skipped.

Object container files use the metadata map `avro.schema` and optional `avro.codec`. A missing codec means `null`. Each block is a count, a size, the payload, and the sync marker. `readOcf` can resolve into a caller schema.

Single-object decode with one schema checks the fingerprint against that schema. The resolving entry point checks the fingerprint against the writer schema.

## Codegen

Output path is `out/<namespace dirs>/<Name>.zig`. Generated code imports the `avro` module. Recursive records use `?*T` for a nullable cycle and `*T` for a tagged-union branch. A required field whose type is in the same recursive component is rejected. `encode` and `decode` use the explicit error set `avro.Error` so two files can call each other.

## Deflate

`deflateRaw` and `inflateRaw` use `std.compress.flate.Compress` and `Decompress` with container `.raw`. There is no zlib wrapper and no link to libz. The writer uses the library's level-1 options. Goldens are cross-inflated with Python's container files, not byte-compared to zlib's compressor output.

## Tests

`zig build test` covers zigzag goldens, a nested record whose bytes match Python Avro, negative blocks, truncated input, canonical form, resolution (including a writer alias that must not match), Avro JSON, container files, single-object frames, IDL, logical helpers, and generated structs. Python is not invoked by the test run.

## Security

Lengths are checked against the remaining buffer before allocation. Schema text above 4_194_304 bytes is rejected. One deflate block may not inflate past 64_194_304 bytes. One array or map block may not exceed 1_048_576 items. Nested values stop at depth 1024.
