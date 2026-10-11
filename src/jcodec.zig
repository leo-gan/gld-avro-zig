//! Official Avro JSON encoding. Union defaults are the first branch, not a wrapper.

const std = @import("std");
const diag = @import("diag.zig");
const json = @import("json.zig");
const schema = @import("schema.zig");
const value = @import("value.zig");

pub const Error = diag.Error;

const Mode = enum { default, value };

pub fn encodeJson(d: *const value.Datum) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(d.gpa);
    try writeJson(d, d.root, &out);
    return out.toOwnedSlice(d.gpa) catch error.OutOfMemory;
}

pub fn decodeJson(gpa: std.mem.Allocator, pool: *schema.SchemaPool, root: u32, text: []const u8) Error!value.Datum {
    var d = value.Datum.init(gpa, pool);
    errdefer d.deinit();
    d.root_schema = root;
    d.root = try decodeDefaultInto(&d, root, text, .value);
    return d;
}

fn decodeDefaultInto(dst: *value.Datum, schema_id: u32, text: []const u8, mode: Mode) Error!u32 {
    var doc = json.Doc.parse(dst.gpa, text) catch return error.Json;
    defer doc.deinit();
    return readJson(dst, &doc, doc.root, schema_id, mode);
}

pub fn readDefault(dst: *value.Datum, schema_id: u32, text: []const u8) Error!u32 {
    return decodeDefaultInto(dst, schema_id, text, .default);
}

fn writeJson(d: *const value.Datum, id: u32, out: *std.ArrayList(u8)) Error!void {
    const n = d.nodes.items[id];
    const gpa = d.gpa;
    switch (n.kind) {
        .null => try out.appendSlice(gpa, "null"),
        .boolean => try out.appendSlice(gpa, if (n.b) "true" else "false"),
        .int, .long => try appendI64(out, gpa, n.i),
        .float => {
            const f: f32 = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(n.i)))));
            try appendF64(out, gpa, f);
        },
        .double => try appendF64(out, gpa, @bitCast(n.i)),
        .string, .enum_type => try json.appendJsonString(out, gpa, n.p),
        .bytes => try json.appendLatin1String(out, gpa, n.p),
        .fixed => try json.appendLatin1String(out, gpa, n.p),
        .array => {
            try out.append(gpa, '[');
            for (0..n.count) |i| {
                if (i != 0) try out.append(gpa, ',');
                try writeJson(d, d.edges.items[n.first + i], out);
            }
            try out.append(gpa, ']');
        },
        .map => {
            try out.append(gpa, '{');
            for (0..n.count) |i| {
                if (i != 0) try out.append(gpa, ',');
                const e = d.entries.items[n.first + i];
                try json.appendJsonString(out, gpa, e.key);
                try out.append(gpa, ':');
                try writeJson(d, e.node, out);
            }
            try out.append(gpa, '}');
        },
        .record => {
            const fields = d.pool.nodes.items[n.schema_id].fields;
            try out.append(gpa, '{');
            for (0..n.count) |i| {
                if (i != 0) try out.append(gpa, ',');
                try json.appendJsonString(out, gpa, fields[i].name);
                try out.append(gpa, ':');
                try writeJson(d, d.edges.items[n.first + i], out);
            }
            try out.append(gpa, '}');
        },
        .union_type => {
            const branches = d.pool.nodes.items[n.schema_id].branches;
            const bi: usize = @intCast(n.i);
            const bsch = d.pool.nodes.items[branches[bi]];
            if (bsch.kind == .null) {
                try out.appendSlice(gpa, "null");
                return;
            }
            try out.append(gpa, '{');
            try json.appendJsonString(out, gpa, branchKey(bsch));
            try out.append(gpa, ':');
            try writeJson(d, d.edges.items[n.first], out);
            try out.append(gpa, '}');
        },
    }
}

fn branchKey(n: schema.SchemaNode) []const u8 {
    return switch (n.kind) {
        .record, .enum_type, .fixed => if (n.short_name.len != 0) n.short_name else schema.unqualified(n.name),
        else => schema.kindName(n.kind),
    };
}

fn appendI64(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: i64) Error!void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
    out.appendSlice(gpa, s) catch return error.OutOfMemory;
}

fn appendF64(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: f64) Error!void {
    if (std.math.isNan(v) or std.math.isInf(v)) return error.BadJsonNumber;
    var tmp: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
    out.appendSlice(gpa, s) catch return error.OutOfMemory;
}

fn readJson(dst: *value.Datum, doc: *const json.Doc, jid: u32, schema_id: u32, mode: Mode) Error!u32 {
    const sch = dst.pool.nodes.items[schema_id];
    const j = doc.node(jid);
    switch (sch.kind) {
        .null => {
            if (j.kind != .null) return error.Json;
            return dst.putNull(schema_id);
        },
        .boolean => {
            if (j.kind != .boolean) return error.Json;
            return dst.putBool(schema_id, j.b);
        },
        .int => {
            if (j.kind != .integer) return error.Json;
            if (j.i < std.math.minInt(i32) or j.i > std.math.maxInt(i32)) return error.Range;
            return dst.putInt(schema_id, @intCast(j.i));
        },
        .long => {
            if (j.kind != .integer) return error.Json;
            return dst.putLong(schema_id, j.i);
        },
        .float => return dst.putFloat(schema_id, try jsonFloat(j, f32)),
        .double => return dst.putDouble(schema_id, try jsonFloat(j, f64)),
        .string => {
            if (j.kind != .string) return error.Json;
            return dst.putString(schema_id, j.s);
        },
        .bytes => {
            if (j.kind != .string) return error.Json;
            const latin = try json.latin1FromUtf8(dst.gpa, j.s);
            defer dst.gpa.free(latin);
            return dst.putBytes(schema_id, latin);
        },
        .fixed => {
            if (j.kind != .string) return error.Json;
            const latin = try json.latin1FromUtf8(dst.gpa, j.s);
            defer dst.gpa.free(latin);
            if (latin.len != sch.size) return error.Range;
            return dst.putFixed(schema_id, latin);
        },
        .enum_type => {
            if (j.kind != .string) return error.Json;
            return try dst.putEnum(schema_id, j.s);
        },
        .array => {
            if (j.kind != .array) return error.Json;
            var kids: std.ArrayList(u32) = .empty;
            defer kids.deinit(dst.gpa);
            for (0..doc.arrayLen(jid)) |i| {
                kids.append(dst.gpa, try readJson(dst, doc, doc.arrayAt(jid, i), sch.item_id, mode)) catch return error.OutOfMemory;
            }
            return dst.putArray(schema_id, kids.items);
        },
        .map => {
            if (j.kind != .object) return error.Json;
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(dst.gpa);
            var vals: std.ArrayList(u32) = .empty;
            defer vals.deinit(dst.gpa);
            for (0..doc.objectLen(jid)) |i| {
                keys.append(dst.gpa, doc.objectKey(jid, i)) catch return error.OutOfMemory;
                vals.append(dst.gpa, try readJson(dst, doc, doc.objectVal(jid, i), sch.value_id, mode)) catch return error.OutOfMemory;
            }
            return dst.putMap(schema_id, keys.items, vals.items);
        },
        .record => {
            if (j.kind != .object) return error.Json;
            var seen = dst.gpa.alloc(bool, sch.fields.len) catch return error.OutOfMemory;
            defer dst.gpa.free(seen);
            @memset(seen, false);
            var kids = dst.gpa.alloc(u32, sch.fields.len) catch return error.OutOfMemory;
            defer dst.gpa.free(kids);
            for (0..doc.objectLen(jid)) |i| {
                const key = doc.objectKey(jid, i);
                var found = false;
                for (sch.fields, 0..) |f, fi| {
                    if (std.mem.eql(u8, f.name, key)) {
                        if (seen[fi]) return error.Json;
                        seen[fi] = true;
                        kids[fi] = try readJson(dst, doc, doc.objectVal(jid, i), f.type_id, mode);
                        found = true;
                        break;
                    }
                }
                if (!found) return error.Json;
            }
            for (sch.fields, 0..) |f, fi| {
                if (seen[fi]) continue;
                if (!f.has_default) return error.Json;
                kids[fi] = try readDefault(dst, f.type_id, f.default_json);
            }
            return dst.putRecord(schema_id, kids);
        },
        .union_type => {
            if (mode == .default) return readJson(dst, doc, jid, sch.branches[0], .default);
            if (j.kind == .null) {
                for (sch.branches, 0..) |b, i| {
                    if (dst.pool.nodes.items[b].kind == .null) return dst.putUnion(schema_id, i, null);
                }
                return error.BadUnion;
            }
            if (j.kind != .object or doc.objectLen(jid) != 1) return error.BadUnion;
            const key = doc.objectKey(jid, 0);
            for (sch.branches, 0..) |b, i| {
                const bn = dst.pool.nodes.items[b];
                if (std.mem.eql(u8, branchKey(bn), key) or std.mem.eql(u8, bn.name, key)) {
                    if (bn.kind == .null) return error.BadUnion;
                    const child = try readJson(dst, doc, doc.objectVal(jid, 0), b, .value);
                    return dst.putUnion(schema_id, i, child);
                }
            }
            return error.BadUnion;
        },
        .unresolved => return error.Schema,
    }
}

fn jsonFloat(j: json.Node, comptime T: type) Error!T {
    switch (j.kind) {
        .integer => return @floatFromInt(j.i),
        .float => {
            if (std.math.isNan(j.f) or std.math.isInf(j.f)) return error.BadJsonNumber;
            if (T == f64) return j.f;
            return @floatCast(j.f);
        },
        else => return error.Json,
    }
}

test "avro json unions, bytes, and records" {
    const gpa = std.testing.allocator;
    var pool = try schema.parseAvsc(gpa, document_schema);
    defer pool.deinit();
    const golden = hexDecode("540468690105000000000000f83f0000c03f0400ff02616263640402610462620002026b12000e0002027a");
    var bin = try value.decodeBin(gpa, &pool, pool.root, &golden);
    defer bin.deinit();
    const text = try encodeJson(&bin);
    defer gpa.free(text);
    var back = try decodeJson(gpa, &pool, pool.root, text);
    defer back.deinit();
    const again = try back.toOwnedBin();
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, &golden, again);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"choice\":{\"string\":\"z\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"maybe\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\u00ff") != null);

    var up2 = try schema.parseAvsc(gpa,
        \\["null",{"type":"record","name":"demo.Inner","fields":[{"name":"x","type":"int"}]}]
    );
    defer up2.deinit();
    var wrapped = try decodeJson(gpa, &up2, up2.root, "{\"Inner\":{\"x\":7}}");
    defer wrapped.deinit();
    try std.testing.expectEqual(@as(i64, 1), try wrapped.unionBranch(wrapped.root));
    var full = try decodeJson(gpa, &up2, up2.root, "{\"demo.Inner\":{\"x\":4}}");
    defer full.deinit();
    const child = (try full.unionChild(full.root)).?;
    try std.testing.expectEqual(@as(i32, 4), try full.asInt(try full.recordField(child, "x")));

    var fp = try schema.parseAvsc(gpa, "\"float\"");
    defer fp.deinit();
    var nan_d = value.Datum.init(gpa, &fp);
    defer nan_d.deinit();
    nan_d.root = try nan_d.putFloat(fp.root, std.math.nan(f32));
    try std.testing.expectError(error.BadJsonNumber, encodeJson(&nan_d));
}

const document_schema = @import("value.zig").document_schema;

fn hexDecode(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    for (0..out.len) |i| out[i] = std.fmt.parseInt(u8, s[i * 2 ..][0..2], 16) catch unreachable;
    return out;
}
