# Techniques

The hot path is a schema walk. Nothing in that walk calls another Avro
library.

## Wire

`Reader` and `Writer` are cursors over byte slices. `int` and `long` use
zigzag then unsigned LEB128. A varint longer than ten bytes, or a tenth byte
that sets bits above the 64-bit remainder, is `error.BadVarint`. One-byte
values skip the loop. `float` and `double` keep their IEEE bits. `boolean`
accepts only `0` and `1`.

`encodedLen` still exists for generated code. `Datum.toOwnedBin` writes into
a 512-byte stack buffer and allocates the exact result, so a small record does
not walk the tree twice before the copy.

## Schema arena

Named types, fields, and JSON text live in a `SchemaPool`. References are
integer ids. A name that is used before it is defined becomes an unresolved
stub and is filled when the declaration is reached, which is how mutual `A`
and `B` parse in one document. `finish` rejects empty unions, nested unions,
duplicate branches, unknown names, and defaults that do not match the first
union branch.

Parsing Canonical Form emits a named type in full on the first visit and the
fullname string after that, including a recursive field. CRC-64-AVRO of the
empty input is `0xc15d213aa4d7a795`.

## Generic values

`Datum` is another arena of nodes. Record children are a contiguous range of
edge ids. Map entries are key/value pairs in order, so a round trip keeps
insertion order. Float and double bits sit in the node's integer field.

Decode of an input buffer copies strings and bytes into one slab sized to that
buffer. ASCII strings skip the full UTF-8 state machine. Node and edge lists
are reserved up front so a small payload does not grow them geometrically.

## Resolution

`decodeResolving` decodes with the writer schema, then converts into a new
datum under the reader schema. Reader aliases are applied to the writer's
fullname and unqualified name. Writer aliases are ignored. Fixed types also
compare size. Enum symbols that the reader does not know use `default` when
the reader enum has one.

## Deflate

Avro's `deflate` codec is raw DEFLATE: no zlib header and no gzip header.
`src/deflate.zig` calls `std.compress.flate` with container `.raw`. That
implementation is Zig. The library does not link libz. Inflate refuses to
grow past 64 MiB for one block.

## Codegen and recursion

Records that reach themselves, or that reach each other, are one strongly
connected component. A nullable field of a record in that component is
`?*T`, because a by-value `?T` would be infinite. A direct required field of
such a record is a codegen error. A tagged-union branch is a pointer. Arrays
stay slices; a slice is already an indirection, so the element can be the
record.
