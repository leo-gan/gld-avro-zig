# Why Avro

Apache Avro is a schema-first binary format. The bytes do not carry field
names or type tags. The reader already has the schema, so each value is only
the data, in schema order. That is the opposite of a self-describing format
such as JSON.

A writer and a reader may use different schemas. Avro's resolution rules say
when an `int` may be read as a `long`, when a removed field needs a default,
and when two records are the same type even if their namespaces differ.

---

## What goes on the wire

| Avro type | Encoding |
| --- | --- |
| `null` | no bytes |
| `boolean` | `0x00` or `0x01` |
| `int`, `long` | zigzag varint |
| `float`, `double` | IEEE-754 little-endian |
| `bytes`, `string` | zigzag length, then payload |
| `fixed` | exactly N bytes |
| `enum` | zigzag index |
| `record` | fields concatenated in schema order |
| `array`, `map` | blocks of counts, then a zero count |
| `union` | branch index, then the value |

Arrays and maps may use a negative block count. The absolute value is the
item count, and the next long is a byte size. This library accepts that form
and still decodes item by item.

---

## Schemas travel with the data

An object container file starts with `Obj` plus `0x01`, a metadata map, and a
16-byte sync marker. The metadata key `avro.schema` is the writer's schema
JSON. `avro.codec` is `null` or `deflate`. `deflate` here is raw DEFLATE, not
zlib and not gzip.

A single object is shorter. Two marker bytes, `C3 01`, then the 8-byte
CRC-64-AVRO fingerprint of the schema's Parsing Canonical Form, little-endian,
then the datum.

Avro also has a JSON encoding. It is not "print the struct as JSON". Unions
are either `null` or a one-key object whose key is the branch name. Bytes are
a string of Unicode code points in `0..255`.

---

## Why a Zig library

A Zig program that links libavro measures that C library and crosses the FFI
boundary on every buffer. This repository is the codec. Generic `Datum` values
serve container files whose schema arrives at runtime. `gld-avrogen-zig` emits
structs when the schema is known early. Both paths share one wire encoder.
