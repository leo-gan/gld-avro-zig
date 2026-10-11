# Examples

The generic API and the generated API write the same Avro binary. Use `Datum`
when the schema arrives with the file. Use a generated struct when the schema
is part of the program.

## Generic record

`examples/encode_record.zig` builds a two-field record and prints the binary
length and the Avro JSON text.

```zig
const bin = try datum.toOwnedBin();
const json = try avro.encodeJson(&datum);
```

Avro JSON for a union arm is an object, not a bare value. `["int","string"]`
holding `"z"` is `{"string":"z"}`. A `null` arm is JSON `null`.

Run it from a checkout:

```bash
zig run --dep avro -Mroot=examples/encode_record.zig -Mavro=src/root.zig
```

## Container file

```zig
var w = try avro.OcfWriter.init(gpa, &pool, pool.root, .@"null", 1);
defer w.deinit();
try w.appendDatum(&datum);
const file = try w.finish();
defer gpa.free(file);
var docs = try avro.readOcf(gpa, file, null);
defer docs.deinit();
```

The seed `1` makes the 16-byte sync marker deterministic. Pass `.deflate`
instead of `.null` to compress each block with raw DEFLATE. The reader
inflates `deflate` blocks and checks the sync marker.

To read a file with a newer schema, pass that schema's JSON as the third
argument of `readOcf`.

## Generated struct

`gld-avrogen-zig` writes `LongList` with a nullable recursive `next`:

```zig
const LongList = @import("generated/LongList.zig").LongList;
const inner = try gpa.create(LongList);
inner.* = .{ .value = 2, .next = null };
var list = LongList{ .value = 1, .next = inner };
defer list.deinit(gpa);
try list.encode(&writer);
```

`tests/generated_test.zig` round-trips `LongList`, a record with an optional
long and a tagged union, mutual `A` / `B`, and `Node`.

## Single object

```zig
const frame = try avro.encodeSingle(gpa, &pool, pool.root, &datum);
var back = try avro.decodeSingle(gpa, &pool, pool.root, frame);
```

The first ten bytes are `C3 01` and the fingerprint. A fingerprint that does
not match the schema is `error.Soe`.
