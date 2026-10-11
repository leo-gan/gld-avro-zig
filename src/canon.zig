//! Parsing Canonical Form and CRC-64-AVRO.

const std = @import("std");
const diag = @import("diag.zig");
const json = @import("json.zig");
const schema = @import("schema.zig");

pub const Error = diag.Error;

const empty_fp: u64 = 0xc15d213aa4d7a795;

fn makeTable() [256]u64 {
    @setEvalBranchQuota(20000);
    var table: [256]u64 = undefined;
    for (0..256) |i| {
        var fp: u64 = i;
        for (0..8) |_| {
            const mask: u64 = 0 -% (fp & 1);
            fp = (fp >> 1) ^ (empty_fp & mask);
        }
        table[i] = fp;
    }
    return table;
}

const fp_table = makeTable();

pub fn crc64Avro(data: []const u8) u64 {
    var result: u64 = empty_fp;
    for (data) |b| {
        const index: usize = @as(u8, @truncate(result ^ b));
        result = (result >> 8) ^ fp_table[index];
    }
    return result;
}

pub fn canonicalForm(pool: *const schema.SchemaPool, root: u32, gpa: std.mem.Allocator) Error![]u8 {
    return emit(pool, root, gpa, true);
}

pub fn emitSchemaJson(pool: *const schema.SchemaPool, root: u32, gpa: std.mem.Allocator) Error![]u8 {
    return emit(pool, root, gpa, false);
}

pub fn fingerprint(pool: *const schema.SchemaPool, root: u32, gpa: std.mem.Allocator) Error!u64 {
    const pcf = try canonicalForm(pool, root, gpa);
    defer gpa.free(pcf);
    return crc64Avro(pcf);
}

fn emit(pool: *const schema.SchemaPool, root: u32, gpa: std.mem.Allocator, canonical: bool) Error![]u8 {
    const seen = gpa.alloc(bool, pool.nodes.items.len) catch return error.OutOfMemory;
    defer gpa.free(seen);
    @memset(seen, false);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try emitNode(pool, root, gpa, canonical, seen, &out);
    return out.toOwnedSlice(gpa) catch error.OutOfMemory;
}

fn emitNode(
    pool: *const schema.SchemaPool,
    id: u32,
    gpa: std.mem.Allocator,
    canonical: bool,
    seen: []bool,
    out: *std.ArrayList(u8),
) Error!void {
    const n = pool.nodes.items[id];
    switch (n.kind) {
        .null, .boolean, .int, .long, .float, .double, .bytes, .string => {
            if (canonical or (n.logical_type.len == 0 and n.attr_keys.len == 0 and n.doc.len == 0)) {
                try appendJsonString(out, gpa, kindNameOf(n.kind));
                return;
            }
            try out.append(gpa, '{');
            try appendKey(out, gpa, "type");
            try appendJsonString(out, gpa, kindNameOf(n.kind));
            try emitCommonAttrs(n, gpa, out, false);
            try out.append(gpa, '}');
        },
        .record, .enum_type, .fixed => {
            if (seen[id]) {
                try appendJsonString(out, gpa, n.name);
                return;
            }
            seen[id] = true;
            try out.append(gpa, '{');
            if (canonical) {
                try appendKey(out, gpa, "name");
                try appendJsonString(out, gpa, n.name);
                try commaKey(out, gpa, "type");
                try appendJsonString(out, gpa, kindNameOf(n.kind));
            } else {
                try appendKey(out, gpa, "type");
                try appendJsonString(out, gpa, kindNameOf(n.kind));
                try commaKey(out, gpa, "name");
                try appendJsonString(out, gpa, n.short_name);
                if (n.namespace.len != 0) {
                    try commaKey(out, gpa, "namespace");
                    try appendJsonString(out, gpa, n.namespace);
                }
                try emitCommonAttrs(n, gpa, out, true);
            }
            switch (n.kind) {
                .record => {
                    try commaKey(out, gpa, "fields");
                    try out.append(gpa, '[');
                    for (n.fields, 0..) |f, i| {
                        if (i != 0) try out.append(gpa, ',');
                        try emitField(pool, f, gpa, canonical, seen, out);
                    }
                    try out.append(gpa, ']');
                },
                .enum_type => {
                    try commaKey(out, gpa, "symbols");
                    try out.append(gpa, '[');
                    for (n.symbols, 0..) |s, i| {
                        if (i != 0) try out.append(gpa, ',');
                        try appendJsonString(out, gpa, s);
                    }
                    try out.append(gpa, ']');
                    if (!canonical and n.enum_default.len != 0) {
                        try commaKey(out, gpa, "default");
                        try appendJsonString(out, gpa, n.enum_default);
                    }
                },
                .fixed => {
                    try commaKey(out, gpa, "size");
                    try appendU32(out, gpa, n.size);
                },
                else => unreachable,
            }
            try out.append(gpa, '}');
        },
        .array => {
            try out.append(gpa, '{');
            try appendKey(out, gpa, "type");
            try appendJsonString(out, gpa, "array");
            if (!canonical) try emitCommonAttrs(n, gpa, out, false);
            try commaKey(out, gpa, "items");
            try emitNode(pool, n.item_id, gpa, canonical, seen, out);
            try out.append(gpa, '}');
        },
        .map => {
            try out.append(gpa, '{');
            try appendKey(out, gpa, "type");
            try appendJsonString(out, gpa, "map");
            if (!canonical) try emitCommonAttrs(n, gpa, out, false);
            try commaKey(out, gpa, "values");
            try emitNode(pool, n.value_id, gpa, canonical, seen, out);
            try out.append(gpa, '}');
        },
        .union_type => {
            if (!canonical and (n.logical_type.len != 0 or n.attr_keys.len != 0)) {
                try out.append(gpa, '{');
                try appendKey(out, gpa, "type");
                try emitUnionArray(pool, n.branches, gpa, canonical, seen, out);
                try emitCommonAttrs(n, gpa, out, false);
                try out.append(gpa, '}');
            } else {
                try emitUnionArray(pool, n.branches, gpa, canonical, seen, out);
            }
        },
        .unresolved => return error.Schema,
    }
}

fn emitUnionArray(
    pool: *const schema.SchemaPool,
    branches: []const u32,
    gpa: std.mem.Allocator,
    canonical: bool,
    seen: []bool,
    out: *std.ArrayList(u8),
) Error!void {
    try out.append(gpa, '[');
    for (branches, 0..) |b, i| {
        if (i != 0) try out.append(gpa, ',');
        try emitNode(pool, b, gpa, canonical, seen, out);
    }
    try out.append(gpa, ']');
}

fn emitField(
    pool: *const schema.SchemaPool,
    f: schema.Field,
    gpa: std.mem.Allocator,
    canonical: bool,
    seen: []bool,
    out: *std.ArrayList(u8),
) Error!void {
    try out.append(gpa, '{');
    try appendKey(out, gpa, "name");
    try appendJsonString(out, gpa, f.name);
    try commaKey(out, gpa, "type");
    try emitNode(pool, f.type_id, gpa, canonical, seen, out);
    if (!canonical) {
        if (f.doc.len != 0) {
            try commaKey(out, gpa, "doc");
            try appendJsonString(out, gpa, f.doc);
        }
        if (f.aliases.len != 0) try emitAliases(out, gpa, f.aliases);
        if (f.order != .ascending) {
            try commaKey(out, gpa, "order");
            try appendJsonString(out, gpa, switch (f.order) {
                .ascending => "ascending",
                .descending => "descending",
                .ignore => "ignore",
            });
        }
        if (f.has_default) {
            try commaKey(out, gpa, "default");
            try out.appendSlice(gpa, f.default_json);
        }
    }
    try out.append(gpa, '}');
}

fn emitCommonAttrs(n: schema.SchemaNode, gpa: std.mem.Allocator, out: *std.ArrayList(u8), named_doc: bool) Error!void {
    if (named_doc and n.doc.len != 0) {
        try commaKey(out, gpa, "doc");
        try appendJsonString(out, gpa, n.doc);
    }
    if (n.aliases.len != 0) try emitAliases(out, gpa, n.aliases);
    if (n.logical_type.len != 0) {
        try commaKey(out, gpa, "logicalType");
        try appendJsonString(out, gpa, n.logical_type);
    }
    for (n.attr_keys, n.attr_vals) |k, v| {
        try commaKey(out, gpa, k);
        try out.appendSlice(gpa, v);
    }
}

fn emitAliases(out: *std.ArrayList(u8), gpa: std.mem.Allocator, aliases: []const []const u8) Error!void {
    try commaKey(out, gpa, "aliases");
    try out.append(gpa, '[');
    for (aliases, 0..) |a, i| {
        if (i != 0) try out.append(gpa, ',');
        try appendJsonString(out, gpa, a);
    }
    try out.append(gpa, ']');
}

fn kindNameOf(kind: schema.TypeKind) []const u8 {
    return schema.kindName(kind);
}

fn appendKey(out: *std.ArrayList(u8), gpa: std.mem.Allocator, key: []const u8) Error!void {
    try appendJsonString(out, gpa, key);
    try out.append(gpa, ':');
}

fn commaKey(out: *std.ArrayList(u8), gpa: std.mem.Allocator, key: []const u8) Error!void {
    try out.append(gpa, ',');
    try appendKey(out, gpa, key);
}

fn appendJsonString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) Error!void {
    try json.appendJsonString(out, gpa, s);
}

fn appendU32(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) Error!void {
    var tmp: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
    try out.appendSlice(gpa, s);
}

fn leHex(v: u64) [16]u8 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, v, .little);
    var hex: [16]u8 = undefined;
    const charset = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0xf];
    }
    return hex;
}

test "pcf and crc64 match python avro" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(empty_fp, crc64Avro(""));

    var null_pool = try schema.parseAvsc(gpa, "\"null\"");
    defer null_pool.deinit();
    const null_pcf = try canonicalForm(&null_pool, null_pool.root, gpa);
    defer gpa.free(null_pcf);
    try std.testing.expectEqualStrings("\"null\"", null_pcf);
    try std.testing.expectEqualStrings("8a8f25cce724dd63", &leHex(crc64Avro(null_pcf)));

    var int_pool = try schema.parseAvsc(gpa, "\"int\"");
    defer int_pool.deinit();
    const int_pcf = try canonicalForm(&int_pool, int_pool.root, gpa);
    defer gpa.free(int_pcf);
    try std.testing.expectEqualStrings("8f5c393f1ad57572", &leHex(crc64Avro(int_pcf)));

    const ll =
        \\{"type":"record","name":"LongList","doc":"ignored","fields":[{"name":"value","type":"long","default":0},{"name":"next","type":["null","LongList"],"default":null}]}
    ;
    var pool = try schema.parseAvsc(gpa, ll);
    defer pool.deinit();
    const pcf = try canonicalForm(&pool, pool.root, gpa);
    defer gpa.free(pcf);
    try std.testing.expectEqualStrings(
        "{\"name\":\"LongList\",\"type\":\"record\",\"fields\":[{\"name\":\"value\",\"type\":\"long\"},{\"name\":\"next\",\"type\":[\"null\",\"LongList\"]}]}",
        pcf,
    );
    try std.testing.expectEqualStrings("92ce588390071d7c", &leHex(try fingerprint(&pool, pool.root, gpa)));

    const doc_only =
        \\{"type":"record","name":"M","namespace":"demo","doc":"x","fields":[{"name":"a","type":"int","doc":"d","default":1}]}
    ;
    var a = try schema.parseAvsc(gpa, doc_only);
    defer a.deinit();
    var b = try schema.parseAvsc(gpa, "{\"type\":\"record\",\"name\":\"demo.M\",\"fields\":[{\"name\":\"a\",\"type\":\"int\"}]}");
    defer b.deinit();
    try std.testing.expectEqual(try fingerprint(&a, a.root, gpa), try fingerprint(&b, b.root, gpa));
}
