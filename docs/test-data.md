# Test data

The tests read schemas and bytes from `testdata/` and from literals in the
test programs. Nothing in this tree is named a fixture.

## Schemas

| File | What it covers |
| --- | --- |
| `testdata/avsc/demo.avsc` | Nested record, enum, fixed, array, map, and unions. |
| `testdata/avsc/longlist.avsc` | Recursive `next` field. Also the codegen sample. |
| `testdata/avdl/demo.avdl` | IDL protocol, imports, defaults, and a skipped message. |
| `testdata/avdl/extra.avdl` | `import idl`. |
| `testdata/avdl/from_schema.avsc` | `import schema`. |
| `testdata/avpr/demo.avpr` | JSON protocol. `types` are loaded. `messages` are ignored. |

`parseAvdl` of `demo.avdl` and `parseAvsc` of `demo.avsc` produce the same
CRC-64-AVRO fingerprint for `demo.Document`.

## Bytes

`testdata/golden/ocf_null.bin` and `testdata/golden/ocf_deflate.bin` are object
container files written by Python `avro` 1.12 for the same two records. The
deflate block is raw DEFLATE from `DataFileWriter`, which uses zlib with a
negative window. The test decodes both files and checks the field values. It
does not compare deflate bytes to a particular compressor.

Primitive and record goldens live next to the tests as hex. They were produced
with Python `avro.io.BinaryEncoder` for null, boolean, int, long, float,
double, bytes, string, array, map, enum, fixed, union, and a nested record.
A negative array block (`count = -2`, size 2, items 1 and 2) is decoded by
hand. Truncated strings and bad UTF-8 must fail.

`zig build test` does not need Python. Python is only the program that
originally wrote those bytes.

## Generated samples

`tests/generated/` holds Zig emitted by `gld-avrogen-zig` for `LongList`,
`demo.M`, mutual `A`/`B`, and `Node`. `tests/generated_test.zig` encodes and
decodes them. `scripts/check-generated.sh` regenerates `LongList.zig` and
fails on a diff.
