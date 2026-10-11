//! Decode and schema diagnostics. `kind` values match the v1 Avro surface.

const std = @import("std");

pub const max_schema_bytes: usize = 4_194_304;
pub const max_inflate: usize = 64_194_304;
pub const max_depth: usize = 1024;
pub const max_collection: usize = 1_048_576;

pub const Kind = enum(u8) {
    eof = 1,
    bad_varint = 2,
    range = 3,
    bad_bool = 4,
    bad_utf8 = 5,
    bad_enum = 6,
    bad_union = 7,
    bad_block = 8,
    schema = 9,
    resolve = 10,
    ocf = 11,
    deflate = 12,
    json = 13,
    soe = 14,
    bad_json_number = 15,
};

pub const Error = error{
    Eof,
    BadVarint,
    Range,
    BadBool,
    BadUtf8,
    BadEnum,
    BadUnion,
    BadBlock,
    Schema,
    Resolve,
    Ocf,
    Deflate,
    Json,
    Soe,
    BadJsonNumber,
    OutOfMemory,
};

pub fn fromKind(kind: Kind) Error {
    return switch (kind) {
        .eof => error.Eof,
        .bad_varint => error.BadVarint,
        .range => error.Range,
        .bad_bool => error.BadBool,
        .bad_utf8 => error.BadUtf8,
        .bad_enum => error.BadEnum,
        .bad_union => error.BadUnion,
        .bad_block => error.BadBlock,
        .schema => error.Schema,
        .resolve => error.Resolve,
        .ocf => error.Ocf,
        .deflate => error.Deflate,
        .json => error.Json,
        .soe => error.Soe,
        .bad_json_number => error.BadJsonNumber,
    };
}

pub fn kindOf(err: Error) Kind {
    return switch (err) {
        error.Eof => .eof,
        error.BadVarint => .bad_varint,
        error.Range => .range,
        error.BadBool => .bad_bool,
        error.BadUtf8 => .bad_utf8,
        error.BadEnum => .bad_enum,
        error.BadUnion => .bad_union,
        error.BadBlock => .bad_block,
        error.Schema => .schema,
        error.Resolve => .resolve,
        error.Ocf => .ocf,
        error.Deflate => .deflate,
        error.Json => .json,
        error.Soe => .soe,
        error.BadJsonNumber => .bad_json_number,
        error.OutOfMemory => .range,
    };
}

/// Optional side message. Empty when the caller did not record one.
pub const Note = struct {
    kind: Kind = .eof,
    offset: usize = 0,
    /// 0 means the field is unknown. Otherwise a 1-based field index.
    field: usize = 0,
    message: []const u8 = "",
};

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
