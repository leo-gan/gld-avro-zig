# gld-avro-zig

gld-avro-zig is an [Apache Avro](https://avro.apache.org/docs/1.11.1/specification/)
serializer written in [Zig](https://ziglang.org/) 0.16. The codec and the code
generator are Zig. They do not wrap libavro.

<div class="grid cards" markdown="1">

-   __Why Avro__

    ---

    What a datum is, why the schema is required, and how evolution works.

    [:octicons-arrow-right-24: Read Why Avro](why-avro.md)

-   __Instructions__

    ---

    Build with Zig 0.16, decode a record, generate Zig, and run the tests.

    [:octicons-arrow-right-24: Open Instructions](instructions.md)

-   __Examples__

    ---

    Encode a generic record, a container file, and a generated struct.

    [:octicons-arrow-right-24: See Examples](examples.md)

-   __Techniques__

    ---

    How the wire, the schema arena, and resolution are laid out.

    [:octicons-arrow-right-24: Read Techniques](techniques.md)

-   __Test data__

    ---

    Schemas, container files, and the bytes compared with Python Avro.

    [:octicons-arrow-right-24: Open Test data](test-data.md)

</div>
