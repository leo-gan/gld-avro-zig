//! Writer/reader schema resolution. Match named types by unqualified name
//! after applying reader aliases. Writer-only aliases are not a match key.

const std = @import("std");
const diag = @import("diag.zig");
const jcodec = @import("jcodec.zig");
const schema = @import("schema.zig");
const value = @import("value.zig");

pub const Error = diag.Error;

pub fn decodeResolving(
    gpa: std.mem.Allocator,
    buf: []const u8,
    writer_pool: *schema.SchemaPool,
    writer_root: u32,
    reader_pool: *schema.SchemaPool,
    reader_root: u32,
) Error!value.Datum {
    var src = try value.decodeBin(gpa, writer_pool, writer_root, buf);
    defer src.deinit();
    return convertDatum(gpa, &src, reader_pool, reader_root);
}

pub fn convertDatum(
    gpa: std.mem.Allocator,
    src: *const value.Datum,
    reader_pool: *schema.SchemaPool,
    reader_root: u32,
) Error!value.Datum {
    var dst = value.Datum.init(gpa, reader_pool);
    errdefer dst.deinit();
    dst.root_schema = reader_root;
    dst.root = try convert(&dst, src, src.root, src.root_schema, reader_root);
    return dst;
}

pub fn resolves(wp: *const schema.SchemaPool, w: u32, rp: *const schema.SchemaPool, r: u32) bool {
    const wn = wp.nodes.items[w];
    const rn = rp.nodes.items[r];
    if (wn.kind == .union_type or rn.kind == .union_type) return false;
    if (wn.kind == rn.kind) {
        return switch (wn.kind) {
            .array => resolves(wp, wn.item_id, rp, rn.item_id),
            .map => resolves(wp, wn.value_id, rp, rn.value_id),
            .record, .enum_type => namedMatch(wn, rn),
            .fixed => namedMatch(wn, rn) and wn.size == rn.size,
            else => true,
        };
    }
    return switch (wn.kind) {
        .int => rn.kind == .long or rn.kind == .float or rn.kind == .double,
        .long => rn.kind == .float or rn.kind == .double,
        .float => rn.kind == .double,
        .string => rn.kind == .bytes,
        .bytes => rn.kind == .string,
        else => false,
    };
}

fn namedMatch(w: schema.SchemaNode, r: schema.SchemaNode) bool {
    const w_short = if (w.short_name.len != 0) w.short_name else schema.unqualified(w.name);
    for (r.aliases) |al| {
        if (std.mem.eql(u8, al, w.name) or std.mem.eql(u8, al, w_short)) return true;
    }
    return std.mem.eql(u8, schema.unqualified(w.name), schema.unqualified(r.name));
}

fn findBranch(wp: *const schema.SchemaPool, w: u32, rp: *const schema.SchemaPool, union_id: u32) ?usize {
    const branches = rp.nodes.items[union_id].branches;
    for (branches, 0..) |b, i| if (resolves(wp, w, rp, b)) return i;
    return null;
}

fn convert(dst: *value.Datum, src: *const value.Datum, src_node: u32, w_id: u32, r_id: u32) Error!u32 {
    const wn = src.pool.nodes.items[w_id];
    const rn = dst.pool.nodes.items[r_id];
    if (wn.kind == .union_type) {
        const bi: usize = @intCast(try src.unionBranch(src_node));
        if (bi >= wn.branches.len) return error.BadUnion;
        const branch = wn.branches[bi];
        if (rn.kind == .union_type) {
            const ri = findBranch(src.pool, branch, dst.pool, r_id) orelse return error.Resolve;
            if (src.pool.nodes.items[branch].kind == .null) return dst.putUnion(r_id, ri, null);
            const payload = (try src.unionChild(src_node)) orelse return error.BadUnion;
            const child = try convert(dst, src, payload, branch, dst.pool.nodes.items[r_id].branches[ri]);
            return dst.putUnion(r_id, ri, child);
        }
        if (src.pool.nodes.items[branch].kind == .null) {
            if (rn.kind != .null) return error.Resolve;
            return dst.putNull(r_id);
        }
        const payload = (try src.unionChild(src_node)) orelse return error.BadUnion;
        return convert(dst, src, payload, branch, r_id);
    }
    if (rn.kind == .union_type) {
        const ri = findBranch(src.pool, w_id, dst.pool, r_id) orelse return error.Resolve;
        const branch = rn.branches[ri];
        if (dst.pool.nodes.items[branch].kind == .null) return dst.putUnion(r_id, ri, null);
        const child = try convert(dst, src, src_node, w_id, branch);
        return dst.putUnion(r_id, ri, child);
    }
    if (wn.kind == .record and rn.kind == .record) {
        if (!namedMatch(wn, rn)) return error.Resolve;
        var kids = dst.gpa.alloc(u32, rn.fields.len) catch return error.OutOfMemory;
        defer dst.gpa.free(kids);
        for (rn.fields, 0..) |rf, i| {
            if (findField(wn.fields, rf)) |wi| {
                const child = try src.recordAt(src_node, wi);
                kids[i] = try convert(dst, src, child, wn.fields[wi].type_id, rf.type_id);
            } else if (rf.has_default) {
                kids[i] = try jcodec.readDefault(dst, rf.type_id, rf.default_json);
            } else return error.Resolve;
        }
        return dst.putRecord(r_id, kids);
    }
    if (wn.kind == .enum_type and rn.kind == .enum_type) {
        if (!namedMatch(wn, rn)) return error.Resolve;
        const sym = try src.asEnum(src_node);
        if (schema.symbolIndex(rn.symbols, sym) != null) return dst.putEnum(r_id, sym);
        if (rn.enum_default.len != 0) return dst.putEnum(r_id, rn.enum_default);
        return error.Resolve;
    }
    if (wn.kind == .array and rn.kind == .array) {
        if (!resolves(src.pool, wn.item_id, dst.pool, rn.item_id) and !promotes(src.pool, wn.item_id, dst.pool, rn.item_id)) {
            // Item schemas may still resolve field-by-field (records). Try anyway.
        }
        const n = try src.arrayLen(src_node);
        var kids = dst.gpa.alloc(u32, n) catch return error.OutOfMemory;
        defer dst.gpa.free(kids);
        for (0..n) |i| {
            kids[i] = try convert(dst, src, try src.arrayAt(src_node, i), wn.item_id, rn.item_id);
        }
        return dst.putArray(r_id, kids);
    }
    if (wn.kind == .map and rn.kind == .map) {
        const n = try src.mapLen(src_node);
        var keys = dst.gpa.alloc([]const u8, n) catch return error.OutOfMemory;
        defer dst.gpa.free(keys);
        var vals = dst.gpa.alloc(u32, n) catch return error.OutOfMemory;
        defer dst.gpa.free(vals);
        for (0..n) |i| {
            const e = try src.mapAt(src_node, i);
            keys[i] = e.key;
            vals[i] = try convert(dst, src, e.node, wn.value_id, rn.value_id);
        }
        return dst.putMap(r_id, keys, vals);
    }
    if (wn.kind == .fixed and rn.kind == .fixed) {
        if (!namedMatch(wn, rn) or wn.size != rn.size) return error.Resolve;
        return dst.putFixed(r_id, try src.asFixed(src_node));
    }
    if (wn.kind == rn.kind) return copySame(dst, src, src_node, r_id);
    return promote(dst, src, src_node, w_id, r_id);
}

fn promotes(wp: *const schema.SchemaPool, w: u32, rp: *const schema.SchemaPool, r: u32) bool {
    return resolves(wp, w, rp, r);
}

fn findField(fields: []const schema.Field, reader: schema.Field) ?usize {
    for (fields, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, reader.name)) return i;
        for (reader.aliases) |a| if (std.mem.eql(u8, a, f.name)) return i;
    }
    return null;
}

fn copySame(dst: *value.Datum, src: *const value.Datum, src_node: u32, r_id: u32) Error!u32 {
    return switch (src.kindOf(src_node)) {
        .null => dst.putNull(r_id),
        .boolean => dst.putBool(r_id, try src.asBool(src_node)),
        .int => dst.putInt(r_id, try src.asInt(src_node)),
        .long => dst.putLong(r_id, try src.asLong(src_node)),
        .float => dst.putFloat(r_id, try src.asFloat(src_node)),
        .double => dst.putDouble(r_id, try src.asDouble(src_node)),
        .bytes => dst.putBytes(r_id, try src.asBytes(src_node)),
        .string => dst.putString(r_id, try src.asString(src_node)),
        .fixed => dst.putFixed(r_id, try src.asFixed(src_node)),
        else => error.Resolve,
    };
}

fn promote(dst: *value.Datum, src: *const value.Datum, src_node: u32, w_id: u32, r_id: u32) Error!u32 {
    const wk = src.pool.nodes.items[w_id].kind;
    const rk = dst.pool.nodes.items[r_id].kind;
    if (wk == .int and rk == .long) return dst.putLong(r_id, try src.asInt(src_node));
    if (wk == .int and rk == .float) return dst.putFloat(r_id, @floatFromInt(try src.asInt(src_node)));
    if (wk == .int and rk == .double) return dst.putDouble(r_id, @floatFromInt(try src.asInt(src_node)));
    if (wk == .long and rk == .float) return dst.putFloat(r_id, @floatFromInt(try src.asLong(src_node)));
    if (wk == .long and rk == .double) return dst.putDouble(r_id, @floatFromInt(try src.asLong(src_node)));
    if (wk == .float and rk == .double) return dst.putDouble(r_id, try src.asFloat(src_node));
    if (wk == .string and rk == .bytes) return dst.putBytes(r_id, try src.asString(src_node));
    if (wk == .bytes and rk == .string) {
        const b = try src.asBytes(src_node);
        if (!std.unicode.utf8ValidateSlice(b)) return error.BadUtf8;
        return dst.putString(r_id, b);
    }
    return error.Resolve;
}

test "promotion aliases defaults and enums" {
    const gpa = std.testing.allocator;

    var wi = try schema.parseAvsc(gpa, "\"int\"");
    defer wi.deinit();
    var d = value.Datum.init(gpa, &wi);
    defer d.deinit();
    d.root_schema = wi.root;
    d.root = try d.putInt(wi.root, 7);
    const raw = try d.toOwnedBin();
    defer gpa.free(raw);
    var rl = try schema.parseAvsc(gpa, "\"long\"");
    defer rl.deinit();
    var got = try decodeResolving(gpa, raw, &wi, wi.root, &rl, rl.root);
    defer got.deinit();
    try std.testing.expectEqual(@as(i64, 7), try got.asLong(got.root));

    const wfoo =
        \\{"type":"record","name":"Foo","namespace":"com.a","fields":[{"name":"a","type":"int"},{"name":"skip","type":"string"},{"name":"b","type":"string"}]}
    ;
    const rfoo =
        \\{"type":"record","name":"Foo","namespace":"com.b","fields":[{"name":"b","type":"string"},{"name":"a","type":"long"},{"name":"c","type":"int","default":3}]}
    ;
    var wp = try schema.parseAvsc(gpa, wfoo);
    defer wp.deinit();
    var src = value.Datum.init(gpa, &wp);
    defer src.deinit();
    const f = wp.nodes.items[wp.root].fields;
    src.root = try src.putRecord(wp.root, &.{
        try src.putInt(f[0].type_id, 7),
        try src.putString(f[1].type_id, "nope"),
        try src.putString(f[2].type_id, "x"),
    });
    const rec_bin = try src.toOwnedBin();
    defer gpa.free(rec_bin);
    var rp = try schema.parseAvsc(gpa, rfoo);
    defer rp.deinit();
    var out = try decodeResolving(gpa, rec_bin, &wp, wp.root, &rp, rp.root);
    defer out.deinit();
    try std.testing.expectEqualStrings("x", try out.asString(try out.recordField(out.root, "b")));
    try std.testing.expectEqual(@as(i64, 7), try out.asLong(try out.recordField(out.root, "a")));
    try std.testing.expectEqual(@as(i32, 3), try out.asInt(try out.recordField(out.root, "c")));

    var ralias = try schema.parseAvsc(gpa, "{\"type\":\"record\",\"name\":\"Bar\",\"aliases\":[\"Foo\"],\"fields\":[{\"name\":\"a\",\"type\":\"int\"}]}");
    defer ralias.deinit();
    var wsimple = try schema.parseAvsc(gpa, "{\"type\":\"record\",\"name\":\"Foo\",\"fields\":[{\"name\":\"a\",\"type\":\"int\"}]}");
    defer wsimple.deinit();
    var one = value.Datum.init(gpa, &wsimple);
    defer one.deinit();
    one.root = try one.putRecord(wsimple.root, &.{try one.putInt(wsimple.nodes.items[wsimple.root].fields[0].type_id, 1)});
    const one_bin = try one.toOwnedBin();
    defer gpa.free(one_bin);
    var matched = try decodeResolving(gpa, one_bin, &wsimple, wsimple.root, &ralias, ralias.root);
    defer matched.deinit();
    try std.testing.expectEqual(@as(i32, 1), try matched.asInt(try matched.recordAt(matched.root, 0)));

    var walias = try schema.parseAvsc(gpa, "{\"type\":\"record\",\"name\":\"Foo\",\"aliases\":[\"Bar\"],\"fields\":[{\"name\":\"a\",\"type\":\"int\"}]}");
    defer walias.deinit();
    var rbar = try schema.parseAvsc(gpa, "{\"type\":\"record\",\"name\":\"Bar\",\"fields\":[{\"name\":\"a\",\"type\":\"int\"}]}");
    defer rbar.deinit();
    try std.testing.expectError(error.Resolve, decodeResolving(gpa, one_bin, &walias, walias.root, &rbar, rbar.root));

    var wf = try schema.parseAvsc(gpa, "{\"type\":\"fixed\",\"name\":\"com.a.F\",\"size\":4}");
    defer wf.deinit();
    var ff = value.Datum.init(gpa, &wf);
    defer ff.deinit();
    ff.root = try ff.putFixed(wf.root, "abcd");
    const fbin = try ff.toOwnedBin();
    defer gpa.free(fbin);
    var rf = try schema.parseAvsc(gpa, "{\"type\":\"fixed\",\"name\":\"F\",\"size\":4}");
    defer rf.deinit();
    var fgot = try decodeResolving(gpa, fbin, &wf, wf.root, &rf, rf.root);
    defer fgot.deinit();
    try std.testing.expectEqualSlices(u8, "abcd", try fgot.asFixed(fgot.root));
    var bad_size = try schema.parseAvsc(gpa, "{\"type\":\"fixed\",\"name\":\"F\",\"size\":2}");
    defer bad_size.deinit();
    try std.testing.expectError(error.Resolve, decodeResolving(gpa, fbin, &wf, wf.root, &bad_size, bad_size.root));
    var bad_name = try schema.parseAvsc(gpa, "{\"type\":\"fixed\",\"name\":\"G\",\"size\":4}");
    defer bad_name.deinit();
    try std.testing.expectError(error.Resolve, decodeResolving(gpa, fbin, &wf, wf.root, &bad_name, bad_name.root));

    var we = try schema.parseAvsc(gpa, "{\"type\":\"enum\",\"name\":\"Color\",\"symbols\":[\"RED\",\"GREEN\"]}");
    defer we.deinit();
    var ed = value.Datum.init(gpa, &we);
    defer ed.deinit();
    ed.root = try ed.putEnum(we.root, "GREEN");
    const ebin = try ed.toOwnedBin();
    defer gpa.free(ebin);
    var re = try schema.parseAvsc(gpa, "{\"type\":\"enum\",\"name\":\"Color\",\"symbols\":[\"RED\"],\"default\":\"RED\"}");
    defer re.deinit();
    var egot = try decodeResolving(gpa, ebin, &we, we.root, &re, re.root);
    defer egot.deinit();
    try std.testing.expectEqualStrings("RED", try egot.asEnum(egot.root));

    var ws = try schema.parseAvsc(gpa, "\"string\"");
    defer ws.deinit();
    var sd = value.Datum.init(gpa, &ws);
    defer sd.deinit();
    sd.root = try sd.putString(ws.root, "ab");
    const sbin = try sd.toOwnedBin();
    defer gpa.free(sbin);
    var rb = try schema.parseAvsc(gpa, "\"bytes\"");
    defer rb.deinit();
    var bgot = try decodeResolving(gpa, sbin, &ws, ws.root, &rb, rb.root);
    defer bgot.deinit();
    try std.testing.expectEqualSlices(u8, "ab", try bgot.asBytes(bgot.root));

    var wu = try schema.parseAvsc(gpa, "[\"null\",\"int\"]");
    defer wu.deinit();
    var ud = value.Datum.init(gpa, &wu);
    defer ud.deinit();
    const int_branch = wu.nodes.items[wu.root].branches[1];
    ud.root = try ud.putUnion(wu.root, 1, try ud.putInt(int_branch, 5));
    const ubin = try ud.toOwnedBin();
    defer gpa.free(ubin);
    var ru = try schema.parseAvsc(gpa, "[\"string\",\"long\"]");
    defer ru.deinit();
    var ugot = try decodeResolving(gpa, ubin, &wu, wu.root, &ru, ru.root);
    defer ugot.deinit();
    try std.testing.expectEqual(@as(i64, 1), try ugot.unionBranch(ugot.root));
    try std.testing.expectEqual(@as(i64, 5), try ugot.asLong((try ugot.unionChild(ugot.root)).?));
}
