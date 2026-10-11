//! In-tree JSON tokenizer and value tree for Avro schemas and Avro JSON.

const std = @import("std");
const diag = @import("diag.zig");

pub const Error = diag.Error;

pub const Kind = enum(u8) {
    null,
    boolean,
    integer,
    float,
    string,
    array,
    object,
};

pub const Node = struct {
    kind: Kind,
    b: bool = false,
    i: i64 = 0,
    f: f64 = 0,
    /// String text, or the raw number token.
    s: []const u8 = "",
    first: u32 = 0,
    count: u32 = 0,
    raw_start: u32 = 0,
    raw_end: u32 = 0,
};

pub const Doc = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node),
    kids: std.ArrayList(u32),
    text: []const u8,
    pos: usize = 0,
    root: u32 = 0,
    err_msg: []const u8 = "",

    pub fn deinit(self: *Doc) void {
        self.nodes.deinit(self.gpa);
        self.kids.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn node(self: *const Doc, i: u32) Node {
        return self.nodes.items[i];
    }

    pub fn raw(self: *const Doc, i: u32) []const u8 {
        const n = self.nodes.items[i];
        return self.text[n.raw_start..n.raw_end];
    }

    pub fn arrayLen(self: *const Doc, i: u32) usize {
        return self.nodes.items[i].count;
    }

    pub fn arrayAt(self: *const Doc, i: u32, n: usize) u32 {
        const nd = self.nodes.items[i];
        return self.kids.items[nd.first + n];
    }

    pub fn objectLen(self: *const Doc, i: u32) usize {
        return self.nodes.items[i].count;
    }

    pub fn objectKey(self: *const Doc, i: u32, n: usize) []const u8 {
        const nd = self.nodes.items[i];
        const ki = self.kids.items[nd.first + n * 2];
        return self.nodes.items[ki].s;
    }

    pub fn objectVal(self: *const Doc, i: u32, n: usize) u32 {
        const nd = self.nodes.items[i];
        return self.kids.items[nd.first + n * 2 + 1];
    }

    pub fn objectGet(self: *const Doc, i: u32, key: []const u8) ?u32 {
        const n = self.objectLen(i);
        for (0..n) |k| {
            if (std.mem.eql(u8, self.objectKey(i, k), key)) return self.objectVal(i, k);
        }
        return null;
    }

    fn fail(self: *Doc, msg: []const u8) Error {
        self.err_msg = msg;
        return error.Json;
    }

    fn skipWs(self: *Doc) void {
        while (self.pos < self.text.len) {
            switch (self.text[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                else => return,
            }
        }
    }

    fn add(self: *Doc, n: Node) Error!u32 {
        const id: u32 = @intCast(self.nodes.items.len);
        self.nodes.append(self.gpa, n) catch return error.OutOfMemory;
        return id;
    }

    pub fn parse(gpa: std.mem.Allocator, text: []const u8) Error!Doc {
        var self = Doc{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .nodes = .empty,
            .kids = .empty,
            .text = text,
        };
        errdefer self.deinit();
        self.pos = 0;
        if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) self.pos = 3;
        self.skipWs();
        if (self.pos >= self.text.len) return self.fail("empty json");
        self.root = try self.parseValue();
        self.skipWs();
        if (self.pos != self.text.len) return self.fail("trailing json");
        return self;
    }

    fn parseValue(self: *Doc) Error!u32 {
        self.skipWs();
        if (self.pos >= self.text.len) return self.fail("truncated json");
        const start: u32 = @intCast(self.pos);
        const c = self.text[self.pos];
        if (c == 'n') return self.literal(start, "null", .{ .kind = .null });
        if (c == 't') return self.literal(start, "true", .{ .kind = .boolean, .b = true });
        if (c == 'f') return self.literal(start, "false", .{ .kind = .boolean, .b = false });
        if (c == '"') {
            const s = try self.parseString();
            const end: u32 = @intCast(self.pos);
            return self.add(.{ .kind = .string, .s = s, .raw_start = start, .raw_end = end });
        }
        if (c == '[') return self.parseArray(start);
        if (c == '{') return self.parseObject(start);
        if (c == '-' or (c >= '0' and c <= '9')) return self.parseNumber(start);
        return self.fail("bad json value");
    }

    fn literal(self: *Doc, start: u32, word: []const u8, n: Node) Error!u32 {
        if (self.pos + word.len > self.text.len or !std.mem.eql(u8, self.text[self.pos..][0..word.len], word)) {
            return self.fail("bad literal");
        }
        self.pos += word.len;
        var made = n;
        made.raw_start = start;
        made.raw_end = @intCast(self.pos);
        return self.add(made);
    }

    fn parseArray(self: *Doc, start: u32) Error!u32 {
        self.pos += 1;
        var tmp: std.ArrayList(u32) = .empty;
        defer tmp.deinit(self.gpa);
        self.skipWs();
        if (self.pos < self.text.len and self.text[self.pos] == ']') {
            self.pos += 1;
            return self.add(.{
                .kind = .array,
                .first = @intCast(self.kids.items.len),
                .count = 0,
                .raw_start = start,
                .raw_end = @intCast(self.pos),
            });
        }
        while (true) {
            const child = try self.parseValue();
            tmp.append(self.gpa, child) catch return error.OutOfMemory;
            self.skipWs();
            if (self.pos >= self.text.len) return self.fail("truncated array");
            if (self.text[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            if (self.text[self.pos] == ']') {
                self.pos += 1;
                break;
            }
            return self.fail("bad array");
        }
        const first: u32 = @intCast(self.kids.items.len);
        self.kids.appendSlice(self.gpa, tmp.items) catch return error.OutOfMemory;
        return self.add(.{
            .kind = .array,
            .first = first,
            .count = @intCast(tmp.items.len),
            .raw_start = start,
            .raw_end = @intCast(self.pos),
        });
    }

    fn parseObject(self: *Doc, start: u32) Error!u32 {
        self.pos += 1;
        var tmp: std.ArrayList(u32) = .empty;
        defer tmp.deinit(self.gpa);
        self.skipWs();
        if (self.pos < self.text.len and self.text[self.pos] == '}') {
            self.pos += 1;
            return self.add(.{
                .kind = .object,
                .first = @intCast(self.kids.items.len),
                .count = 0,
                .raw_start = start,
                .raw_end = @intCast(self.pos),
            });
        }
        while (true) {
            self.skipWs();
            if (self.pos >= self.text.len or self.text[self.pos] != '"') return self.fail("object key");
            const key_start: u32 = @intCast(self.pos);
            const key = try self.parseString();
            const key_end: u32 = @intCast(self.pos);
            const key_id = try self.add(.{
                .kind = .string,
                .s = key,
                .raw_start = key_start,
                .raw_end = key_end,
            });
            self.skipWs();
            if (self.pos >= self.text.len or self.text[self.pos] != ':') return self.fail("expected colon");
            self.pos += 1;
            const val = try self.parseValue();
            for (0..tmp.items.len / 2) |i| {
                const prev = self.nodes.items[tmp.items[i * 2]].s;
                if (std.mem.eql(u8, prev, key)) return self.fail("duplicate key");
            }
            tmp.append(self.gpa, key_id) catch return error.OutOfMemory;
            tmp.append(self.gpa, val) catch return error.OutOfMemory;
            self.skipWs();
            if (self.pos >= self.text.len) return self.fail("truncated object");
            if (self.text[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            if (self.text[self.pos] == '}') {
                self.pos += 1;
                break;
            }
            return self.fail("bad object");
        }
        const first: u32 = @intCast(self.kids.items.len);
        self.kids.appendSlice(self.gpa, tmp.items) catch return error.OutOfMemory;
        return self.add(.{
            .kind = .object,
            .first = first,
            .count = @intCast(tmp.items.len / 2),
            .raw_start = start,
            .raw_end = @intCast(self.pos),
        });
    }

    fn parseNumber(self: *Doc, start: u32) Error!u32 {
        const begin = self.pos;
        if (self.text[self.pos] == '-') self.pos += 1;
        if (self.pos >= self.text.len) return self.fail("bad number");
        if (self.text[self.pos] == '0') {
            self.pos += 1;
        } else if (self.text[self.pos] >= '1' and self.text[self.pos] <= '9') {
            while (self.pos < self.text.len and self.text[self.pos] >= '0' and self.text[self.pos] <= '9') self.pos += 1;
        } else return self.fail("bad number");
        var is_float = false;
        if (self.pos < self.text.len and self.text[self.pos] == '.') {
            is_float = true;
            self.pos += 1;
            const frac = self.pos;
            while (self.pos < self.text.len and self.text[self.pos] >= '0' and self.text[self.pos] <= '9') self.pos += 1;
            if (self.pos == frac) return self.fail("bad number");
        }
        if (self.pos < self.text.len and (self.text[self.pos] == 'e' or self.text[self.pos] == 'E')) {
            is_float = true;
            self.pos += 1;
            if (self.pos < self.text.len and (self.text[self.pos] == '+' or self.text[self.pos] == '-')) self.pos += 1;
            const exp = self.pos;
            while (self.pos < self.text.len and self.text[self.pos] >= '0' and self.text[self.pos] <= '9') self.pos += 1;
            if (self.pos == exp) return self.fail("bad number");
        }
        const tok = self.text[begin..self.pos];
        const end: u32 = @intCast(self.pos);
        if (!is_float) {
            const iv = std.fmt.parseInt(i64, tok, 10) catch return self.fail("integer out of range");
            const s = self.arena.allocator().dupe(u8, tok) catch return error.OutOfMemory;
            return self.add(.{ .kind = .integer, .i = iv, .s = s, .raw_start = start, .raw_end = end });
        }
        const fv = std.fmt.parseFloat(f64, tok) catch return self.fail("bad float");
        const s = self.arena.allocator().dupe(u8, tok) catch return error.OutOfMemory;
        return self.add(.{ .kind = .float, .f = fv, .s = s, .raw_start = start, .raw_end = end });
    }

    fn parseString(self: *Doc) Error![]const u8 {
        std.debug.assert(self.text[self.pos] == '"');
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (c == '"') {
                self.pos += 1;
                return self.arena.allocator().dupe(u8, out.items) catch error.OutOfMemory;
            }
            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.text.len) return self.fail("bad escape");
                const e = self.text[self.pos];
                self.pos += 1;
                switch (e) {
                    '"', '\\', '/' => out.append(self.gpa, e) catch return error.OutOfMemory,
                    'b' => out.append(self.gpa, 0x08) catch return error.OutOfMemory,
                    'f' => out.append(self.gpa, 0x0c) catch return error.OutOfMemory,
                    'n' => out.append(self.gpa, '\n') catch return error.OutOfMemory,
                    'r' => out.append(self.gpa, '\r') catch return error.OutOfMemory,
                    't' => out.append(self.gpa, '\t') catch return error.OutOfMemory,
                    'u' => {
                        const cp = try self.hex4();
                        if (cp >= 0xD800 and cp <= 0xDBFF) {
                            if (self.pos + 6 > self.text.len or self.text[self.pos] != '\\' or self.text[self.pos + 1] != 'u') {
                                return self.fail("lone surrogate");
                            }
                            self.pos += 2;
                            const lo = try self.hex4();
                            if (lo < 0xDC00 or lo > 0xDFFF) return self.fail("bad surrogate");
                            const u: u21 = @intCast(0x10000 + (((cp - 0xD800) << 10) | (lo - 0xDC00)));
                            try appendCp(&out, self.gpa, u);
                        } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
                            return self.fail("lone surrogate");
                        } else {
                            try appendCp(&out, self.gpa, @intCast(cp));
                        }
                    },
                    else => return self.fail("bad escape"),
                }
            } else if (c < 0x20) {
                return self.fail("raw control");
            } else {
                const len = std.unicode.utf8ByteSequenceLength(c) catch return self.fail("bad utf8");
                if (self.pos + len > self.text.len) return self.fail("bad utf8");
                const seq = self.text[self.pos..][0..len];
                _ = std.unicode.utf8Decode(seq) catch return self.fail("bad utf8");
                out.appendSlice(self.gpa, seq) catch return error.OutOfMemory;
                self.pos += len;
            }
        }
        return self.fail("unterminated string");
    }

    fn hex4(self: *Doc) Error!u21 {
        if (self.pos + 4 > self.text.len) return self.fail("bad unicode escape");
        var v: u21 = 0;
        for (0..4) |_| {
            const h = self.text[self.pos];
            self.pos += 1;
            const d: u21 = switch (h) {
                '0'...'9' => h - '0',
                'a'...'f' => h - 'a' + 10,
                'A'...'F' => h - 'A' + 10,
                else => return self.fail("bad unicode escape"),
            };
            v = (v << 4) | d;
        }
        return v;
    }
};

fn appendCp(out: *std.ArrayList(u8), gpa: std.mem.Allocator, cp: u21) Error!void {
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &tmp) catch return error.Json;
    out.appendSlice(gpa, tmp[0..n]) catch return error.OutOfMemory;
}

pub fn appendJsonString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) Error!void {
    out.append(gpa, '"') catch return error.OutOfMemory;
    for (s) |c| {
        switch (c) {
            '"' => out.appendSlice(gpa, "\\\"") catch return error.OutOfMemory,
            '\\' => out.appendSlice(gpa, "\\\\") catch return error.OutOfMemory,
            '\n' => out.appendSlice(gpa, "\\n") catch return error.OutOfMemory,
            '\r' => out.appendSlice(gpa, "\\r") catch return error.OutOfMemory,
            '\t' => out.appendSlice(gpa, "\\t") catch return error.OutOfMemory,
            else => {
                if (c < 0x20) {
                    var tmp: [6]u8 = undefined;
                    const lit = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
                    out.appendSlice(gpa, lit) catch return error.OutOfMemory;
                } else out.append(gpa, c) catch return error.OutOfMemory;
            },
        }
    }
    out.append(gpa, '"') catch return error.OutOfMemory;
}

/// Each byte becomes a Unicode code point of the same value, then a JSON string.
pub fn appendLatin1String(out: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) Error!void {
    out.append(gpa, '"') catch return error.OutOfMemory;
    for (bytes) |c| {
        if (c >= 0x20 and c <= 0x7e and c != '"' and c != '\\') {
            out.append(gpa, c) catch return error.OutOfMemory;
        } else switch (c) {
            '"' => out.appendSlice(gpa, "\\\"") catch return error.OutOfMemory,
            '\\' => out.appendSlice(gpa, "\\\\") catch return error.OutOfMemory,
            '\n' => out.appendSlice(gpa, "\\n") catch return error.OutOfMemory,
            '\r' => out.appendSlice(gpa, "\\r") catch return error.OutOfMemory,
            '\t' => out.appendSlice(gpa, "\\t") catch return error.OutOfMemory,
            else => {
                var tmp: [6]u8 = undefined;
                const lit = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
                out.appendSlice(gpa, lit) catch return error.OutOfMemory;
            },
        }
    }
    out.append(gpa, '"') catch return error.OutOfMemory;
}

pub fn latin1FromUtf8(gpa: std.mem.Allocator, s: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return error.BadUtf8;
        if (i + len > s.len) return error.BadUtf8;
        const cp = std.unicode.utf8Decode(s[i..][0..len]) catch return error.BadUtf8;
        if (cp > 255) return error.Range;
        out.append(gpa, @intCast(cp)) catch return error.OutOfMemory;
        i += len;
    }
    return out.toOwnedSlice(gpa) catch error.OutOfMemory;
}

test "parse object array string number" {
    const gpa = std.testing.allocator;
    var doc = try Doc.parse(gpa, "{\"a\":[1,true,null,\"x\\\"y\"],\"b\":-2.5}");
    defer doc.deinit();
    try std.testing.expectEqual(Kind.object, doc.node(doc.root).kind);
    const a = doc.objectGet(doc.root, "a").?;
    try std.testing.expectEqual(@as(usize, 4), doc.arrayLen(a));
    try std.testing.expectEqual(@as(i64, 1), doc.node(doc.arrayAt(a, 0)).i);
    try std.testing.expect(doc.node(doc.arrayAt(a, 1)).b);
    try std.testing.expectEqualStrings("x\"y", doc.node(doc.arrayAt(a, 3)).s);
    const b = doc.objectGet(doc.root, "b").?;
    try std.testing.expectApproxEqAbs(@as(f64, -2.5), doc.node(b).f, 0.0001);
}
