//! Avro IDL (`.avdl`) and JSON protocol (`.avpr`) parsers.

const std = @import("std");
const canon = @import("canon.zig");
const diag = @import("diag.zig");
const json = @import("json.zig");
const schema = @import("schema.zig");

pub const Error = diag.Error;

const Ann = struct {
    namespace: ?[]const u8 = null,
    aliases: []const []const u8 = &.{},
    logical: []const u8 = "",
    order: schema.Order = .ascending,
    doc: []const u8 = "",
};

const Parser = struct {
    pool: *schema.SchemaPool,
    io: std.Io,
    text: []const u8,
    pos: usize = 0,
    from_file: []const u8,
    stack: *std.ArrayList([]const u8),
    current_ns: []const u8 = "",
    pending_doc: []const u8 = "",

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
        return self.pool.failf(fmt, args);
    }

    fn skipTrivia(self: *Parser) Error!void {
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
                continue;
            }
            if (c == '/' and self.pos + 1 < self.text.len and self.text[self.pos + 1] == '/') {
                self.pos += 2;
                while (self.pos < self.text.len and self.text[self.pos] != '\n') self.pos += 1;
                continue;
            }
            if (c == '/' and self.pos + 1 < self.text.len and self.text[self.pos + 1] == '*') {
                const doc = self.pos + 2 < self.text.len and self.text[self.pos + 2] == '*';
                const start = self.pos + if (doc) @as(usize, 3) else 2;
                self.pos = start;
                const end = std.mem.indexOf(u8, self.text[self.pos..], "*/") orelse return self.fail("unterminated comment", .{});
                if (doc) {
                    const body = std.mem.trim(u8, self.text[self.pos..][0..end], " \t\r\n");
                    self.pending_doc = try self.pool.dupe(body);
                }
                self.pos += end + 2;
                continue;
            }
            return;
        }
    }

    fn peek(self: *Parser) Error!u8 {
        try self.skipTrivia();
        if (self.pos >= self.text.len) return 0;
        return self.text[self.pos];
    }

    fn eat(self: *Parser, c: u8) Error!bool {
        if (try self.peek() != c) return false;
        self.pos += 1;
        return true;
    }

    fn expectChar(self: *Parser, c: u8) Error!void {
        if (!try self.eat(c)) return self.fail("expected '{c}'", .{c});
    }

    fn ident(self: *Parser) Error![]const u8 {
        try self.skipTrivia();
        if (self.pos >= self.text.len) return self.fail("expected identifier", .{});
        const start = self.pos;
        const c = self.text[self.pos];
        if (!isIdentStart(c)) return self.fail("expected identifier", .{});
        self.pos += 1;
        while (self.pos < self.text.len and isIdentCont(self.text[self.pos])) self.pos += 1;
        return self.pool.dupe(self.text[start..self.pos]);
    }

    fn dotted(self: *Parser) Error![]const u8 {
        var name = try self.ident();
        while (try self.eat('.')) {
            const next = try self.ident();
            name = std.fmt.allocPrint(self.pool.arena.allocator(), "{s}.{s}", .{ name, next }) catch return error.OutOfMemory;
        }
        return name;
    }

    fn string(self: *Parser) Error![]const u8 {
        try self.skipTrivia();
        if (self.pos >= self.text.len or self.text[self.pos] != '"') return self.fail("expected string", .{});
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.pool.gpa);
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (c == '"') {
                self.pos += 1;
                return self.pool.dupe(out.items);
            }
            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.text.len) return self.fail("bad string escape", .{});
                const e = self.text[self.pos];
                self.pos += 1;
                switch (e) {
                    '"', '\\', '\'', '/' => out.append(self.pool.gpa, e) catch return error.OutOfMemory,
                    'n' => out.append(self.pool.gpa, '\n') catch return error.OutOfMemory,
                    'r' => out.append(self.pool.gpa, '\r') catch return error.OutOfMemory,
                    't' => out.append(self.pool.gpa, '\t') catch return error.OutOfMemory,
                    'u' => {
                        if (self.pos + 4 > self.text.len) return self.fail("bad unicode escape", .{});
                        const cp = std.fmt.parseInt(u21, self.text[self.pos..][0..4], 16) catch return self.fail("bad unicode escape", .{});
                        self.pos += 4;
                        var tmp: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &tmp) catch return self.fail("bad unicode escape", .{});
                        out.appendSlice(self.pool.gpa, tmp[0..n]) catch return error.OutOfMemory;
                    },
                    else => return self.fail("bad string escape", .{}),
                }
            } else {
                out.append(self.pool.gpa, c) catch return error.OutOfMemory;
                self.pos += 1;
            }
        }
        return self.fail("unterminated string", .{});
    }

    fn number(self: *Parser) Error![]const u8 {
        try self.skipTrivia();
        const start = self.pos;
        if (self.pos < self.text.len and self.text[self.pos] == '-') self.pos += 1;
        if (self.pos >= self.text.len or self.text[self.pos] < '0' or self.text[self.pos] > '9') return self.fail("expected number", .{});
        while (self.pos < self.text.len and self.text[self.pos] >= '0' and self.text[self.pos] <= '9') self.pos += 1;
        if (self.pos < self.text.len and self.text[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.text.len and self.text[self.pos] >= '0' and self.text[self.pos] <= '9') self.pos += 1;
        }
        if (self.pos < self.text.len and (self.text[self.pos] == 'e' or self.text[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.text.len and (self.text[self.pos] == '+' or self.text[self.pos] == '-')) self.pos += 1;
            while (self.pos < self.text.len and self.text[self.pos] >= '0' and self.text[self.pos] <= '9') self.pos += 1;
        }
        return self.pool.dupe(self.text[start..self.pos]);
    }

    fn takeDoc(self: *Parser, ann: *Ann) void {
        if (ann.doc.len == 0 and self.pending_doc.len != 0) {
            ann.doc = self.pending_doc;
            self.pending_doc = "";
        }
    }

    fn annotations(self: *Parser) Error!Ann {
        var ann = Ann{};
        self.takeDoc(&ann);
        while (try self.eat('@')) {
            const name = try self.ident();
            try self.expectChar('(');
            if (std.mem.eql(u8, name, "namespace")) {
                ann.namespace = try self.string();
                self.current_ns = ann.namespace.?;
            } else if (std.mem.eql(u8, name, "logicalType")) {
                ann.logical = try self.string();
            } else if (std.mem.eql(u8, name, "order")) {
                const s = try self.string();
                if (std.mem.eql(u8, s, "ascending")) ann.order = .ascending else if (std.mem.eql(u8, s, "descending")) ann.order = .descending else if (std.mem.eql(u8, s, "ignore")) ann.order = .ignore else return self.fail("bad order '{s}'", .{s});
            } else if (std.mem.eql(u8, name, "aliases")) {
                try self.expectChar('[');
                var list: std.ArrayList([]const u8) = .empty;
                defer list.deinit(self.pool.gpa);
                if (!try self.eat(']')) {
                    while (true) {
                        list.append(self.pool.gpa, try self.string()) catch return error.OutOfMemory;
                        if (try self.eat(']')) break;
                        try self.expectChar(',');
                    }
                }
                ann.aliases = self.pool.arena.allocator().dupe([]const u8, list.items) catch return error.OutOfMemory;
            } else return self.fail("unsupported annotation '{s}'", .{name});
            try self.expectChar(')');
            self.takeDoc(&ann);
        }
        return ann;
    }

    fn parseType(self: *Parser, ns: []const u8) Error!u32 {
        const name = try self.dotted();
        var id: u32 = undefined;
        if (std.mem.eql(u8, name, "array")) {
            try self.expectChar('<');
            const item = try self.parseType(ns);
            try self.expectChar('>');
            id = try self.pool.addNode(.{ .kind = .array, .item_id = item });
        } else if (std.mem.eql(u8, name, "map")) {
            try self.expectChar('<');
            const val = try self.parseType(ns);
            try self.expectChar('>');
            id = try self.pool.addNode(.{ .kind = .map, .value_id = val });
        } else if (std.mem.eql(u8, name, "union")) {
            try self.expectChar('{');
            var branches: std.ArrayList(u32) = .empty;
            defer branches.deinit(self.pool.gpa);
            if (!try self.eat('}')) {
                while (true) {
                    branches.append(self.pool.gpa, try self.parseType(ns)) catch return error.OutOfMemory;
                    if (try self.eat('}')) break;
                    try self.expectChar(',');
                }
            }
            const slice = self.pool.arena.allocator().dupe(u32, branches.items) catch return error.OutOfMemory;
            id = try self.pool.addNode(.{ .kind = .union_type, .branches = slice });
        } else {
            id = try self.pool.resolveName(name, ns);
        }
        while (try self.eat('?')) {
            const null_id = try self.pool.primitive(.null);
            const slice = self.pool.arena.allocator().alloc(u32, 2) catch return error.OutOfMemory;
            slice[0] = null_id;
            slice[1] = id;
            id = try self.pool.addNode(.{ .kind = .union_type, .branches = slice });
        }
        return id;
    }

    fn parseFields(self: *Parser, ns: []const u8) Error![]const schema.Field {
        try self.expectChar('{');
        var fields: std.ArrayList(schema.Field) = .empty;
        defer fields.deinit(self.pool.gpa);
        while (!try self.eat('}')) {
            const ann = try self.annotations();
            const type_id = try self.parseType(ns);
            const fname = try self.ident();
            var has_default = false;
            var default_json: []const u8 = "";
            if (try self.eat('=')) {
                has_default = true;
                default_json = try self.literalJson(type_id);
            }
            try self.expectChar(';');
            for (fields.items) |prev| if (std.mem.eql(u8, prev.name, fname)) return self.fail("duplicate field '{s}'", .{fname});
            fields.append(self.pool.gpa, .{
                .name = fname,
                .type_id = type_id,
                .has_default = has_default,
                .default_json = default_json,
                .aliases = ann.aliases,
                .order = ann.order,
                .doc = ann.doc,
            }) catch return error.OutOfMemory;
        }
        return self.pool.arena.allocator().dupe(schema.Field, fields.items) catch error.OutOfMemory;
    }

    fn literalJson(self: *Parser, type_id: u32) Error![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.pool.gpa);
        try self.writeLit(&buf, type_id);
        return self.pool.dupe(buf.items);
    }

    fn writeLit(self: *Parser, buf: *std.ArrayList(u8), type_id: u32) Error!void {
        const n = self.pool.nodes.items[type_id];
        if (n.kind == .union_type) {
            if (n.branches.len == 0) return self.fail("empty union default", .{});
            return self.writeLit(buf, n.branches[0]);
        }
        try self.skipTrivia();
        if (self.pos >= self.text.len) return self.fail("expected literal", .{});
        const c = self.text[self.pos];
        if (isIdentStart(c)) {
            const word = try self.ident();
            if (std.mem.eql(u8, word, "null")) return buf.appendSlice(self.pool.gpa, "null") catch error.OutOfMemory;
            if (std.mem.eql(u8, word, "true")) return buf.appendSlice(self.pool.gpa, "true") catch error.OutOfMemory;
            if (std.mem.eql(u8, word, "false")) return buf.appendSlice(self.pool.gpa, "false") catch error.OutOfMemory;
            try json.appendJsonString(buf, self.pool.gpa, word);
            return;
        }
        if (c == '"') {
            const s = try self.string();
            if (n.kind == .bytes or n.kind == .fixed) {
                try json.appendLatin1String(buf, self.pool.gpa, s);
            } else try json.appendJsonString(buf, self.pool.gpa, s);
            return;
        }
        if (c == '-' or (c >= '0' and c <= '9')) {
            const num = try self.number();
            return buf.appendSlice(self.pool.gpa, num) catch error.OutOfMemory;
        }
        if (c == '[') {
            self.pos += 1;
            try buf.append(self.pool.gpa, '[');
            if (n.kind != .array) return self.fail("array literal for a non-array", .{});
            if (!try self.eat(']')) {
                var first = true;
                while (true) {
                    if (!first) try buf.append(self.pool.gpa, ',');
                    first = false;
                    try self.writeLit(buf, n.item_id);
                    if (try self.eat(']')) break;
                    try self.expectChar(',');
                }
            }
            try buf.append(self.pool.gpa, ']');
            return;
        }
        if (c == '{') {
            self.pos += 1;
            try buf.append(self.pool.gpa, '{');
            if (try self.eat('}')) {
                try buf.append(self.pool.gpa, '}');
                return;
            }
            const map = n.kind == .map or (n.kind != .record and try self.looksLikeMap());
            var first = true;
            while (true) {
                if (!first) try buf.append(self.pool.gpa, ',');
                first = false;
                const key = if (try self.peek() == '"') try self.string() else try self.ident();
                try json.appendJsonString(buf, self.pool.gpa, key);
                try buf.append(self.pool.gpa, ':');
                if (map) {
                    try self.expectChar(':');
                    const value_id = if (n.kind == .map) n.value_id else type_id;
                    try self.writeLit(buf, value_id);
                } else {
                    try self.expectChar('=');
                    if (n.kind != .record) return self.fail("record literal for a non-record", .{});
                    var fid: ?u32 = null;
                    for (n.fields) |f| if (std.mem.eql(u8, f.name, key)) {
                        fid = f.type_id;
                        break;
                    };
                    const ft = fid orelse return self.fail("unknown field '{s}' in literal", .{key});
                    try self.writeLit(buf, ft);
                }
                if (try self.eat('}')) break;
                try self.expectChar(',');
            }
            try buf.append(self.pool.gpa, '}');
            return;
        }
        return self.fail("expected literal", .{});
    }

    fn looksLikeMap(self: *Parser) Error!bool {
        // Called only when kind is ambiguous. Peek past a key.
        const save = self.pos;
        const save_doc = self.pending_doc;
        if (try self.peek() == '"') _ = try self.string() else _ = try self.ident();
        const colon = try self.eat(':');
        self.pos = save;
        self.pending_doc = save_doc;
        return colon;
    }

    fn parseRecord(self: *Parser, ann: Ann, is_error: bool) Error!u32 {
        const name = try self.ident();
        const explicit = ann.namespace;
        const id = try self.pool.declare(.record, name, explicit, self.current_ns);
        const ns = self.pool.nodes.items[id].namespace;
        const fields = try self.parseFields(ns);
        self.pool.nodes.items[id].fields = fields;
        self.pool.nodes.items[id].doc = ann.doc;
        self.pool.nodes.items[id].aliases = ann.aliases;
        self.pool.nodes.items[id].logical_type = ann.logical;
        self.pool.nodes.items[id].is_error = is_error;
        self.pool.root = id;
        return id;
    }

    fn parseEnum(self: *Parser, ann: Ann) Error!u32 {
        const name = try self.ident();
        const id = try self.pool.declare(.enum_type, name, ann.namespace, self.current_ns);
        try self.expectChar('{');
        var symbols: std.ArrayList([]const u8) = .empty;
        defer symbols.deinit(self.pool.gpa);
        if (!try self.eat('}')) {
            while (true) {
                const sym = try self.ident();
                for (symbols.items) |p| if (std.mem.eql(u8, p, sym)) return self.fail("duplicate symbol '{s}'", .{sym});
                symbols.append(self.pool.gpa, sym) catch return error.OutOfMemory;
                if (try self.eat('}')) break;
                try self.expectChar(',');
            }
        }
        if (symbols.items.len == 0) return self.fail("enum has no symbols", .{});
        self.pool.nodes.items[id].symbols = self.pool.arena.allocator().dupe([]const u8, symbols.items) catch return error.OutOfMemory;
        self.pool.nodes.items[id].doc = ann.doc;
        self.pool.nodes.items[id].aliases = ann.aliases;
        self.pool.nodes.items[id].logical_type = ann.logical;
        self.pool.root = id;
        return id;
    }

    fn parseFixed(self: *Parser, ann: Ann) Error!u32 {
        const name = try self.ident();
        const id = try self.pool.declare(.fixed, name, ann.namespace, self.current_ns);
        try self.expectChar('(');
        const num = try self.number();
        const size = std.fmt.parseInt(u32, num, 10) catch return self.fail("bad fixed size", .{});
        try self.expectChar(')');
        try self.expectChar(';');
        self.pool.nodes.items[id].size = size;
        self.pool.nodes.items[id].doc = ann.doc;
        self.pool.nodes.items[id].aliases = ann.aliases;
        self.pool.nodes.items[id].logical_type = ann.logical;
        self.pool.root = id;
        return id;
    }

    fn parseImport(self: *Parser) Error!void {
        const kind = try self.ident();
        const path = try self.string();
        try self.expectChar(';');
        const resolved = try joinPath(self.pool.gpa, self.from_file, path);
        defer self.pool.gpa.free(resolved);
        for (self.stack.items) |prev| if (std.mem.eql(u8, prev, resolved)) return self.fail("import cycle '{s}'", .{path});
        const owned = try self.pool.dupe(resolved);
        self.stack.append(self.pool.gpa, owned) catch return error.OutOfMemory;
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, resolved, self.pool.gpa, .limited(diag.max_schema_bytes)) catch {
            return self.fail("cannot read import '{s}'", .{path});
        };
        defer self.pool.gpa.free(text);
        if (std.mem.eql(u8, kind, "idl")) {
            var nested = Parser{
                .pool = self.pool,
                .io = self.io,
                .text = text,
                .from_file = owned,
                .stack = self.stack,
                .current_ns = self.current_ns,
            };
            try nested.parseBody(false);
        } else if (std.mem.eql(u8, kind, "schema")) {
            _ = try schema.parseAvscInto(self.pool, text, self.current_ns);
        } else if (std.mem.eql(u8, kind, "protocol")) {
            try parseAvprInto(self.pool, text, self.current_ns);
        } else return self.fail("bad import kind '{s}'", .{kind});
        _ = self.stack.pop();
    }

    fn skipMessage(self: *Parser) Error!void {
        var paren: i32 = 0;
        var brace: i32 = 0;
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (c == '"') {
                self.pos += 1;
                while (self.pos < self.text.len and self.text[self.pos] != '"') {
                    if (self.text[self.pos] == '\\' and self.pos + 1 < self.text.len) self.pos += 2 else self.pos += 1;
                }
                if (self.pos < self.text.len) self.pos += 1;
                continue;
            }
            self.pos += 1;
            if (c == '(') paren += 1;
            if (c == ')') paren -= 1;
            if (c == '{') brace += 1;
            if (c == '}') brace -= 1;
            if (c == ';' and paren == 0 and brace == 0) return;
        }
        return self.fail("unterminated message", .{});
    }

    fn parseBody(self: *Parser, inside_protocol: bool) Error!void {
        while (true) {
            const ann = try self.annotations();
            if ((try self.peek()) == 0) {
                if (inside_protocol) return self.fail("unterminated protocol", .{});
                return;
            }
            if (inside_protocol and (try self.peek()) == '}') return;
            const kw = try self.ident();
            if (std.mem.eql(u8, kw, "protocol")) {
                if (inside_protocol) return self.fail("nested protocol", .{});
                _ = try self.ident();
                if (ann.namespace) |ns| self.current_ns = ns;
                try self.expectChar('{');
                try self.parseBody(true);
                try self.expectChar('}');
            } else if (std.mem.eql(u8, kw, "record")) {
                _ = try self.parseRecord(ann, false);
            } else if (std.mem.eql(u8, kw, "error")) {
                _ = try self.parseRecord(ann, true);
            } else if (std.mem.eql(u8, kw, "enum")) {
                _ = try self.parseEnum(ann);
            } else if (std.mem.eql(u8, kw, "fixed")) {
                _ = try self.parseFixed(ann);
            } else if (std.mem.eql(u8, kw, "import")) {
                try self.parseImport();
            } else if (std.mem.eql(u8, kw, "message")) {
                try self.skipMessage();
            } else if (std.mem.eql(u8, kw, "oneway")) {
                const next = try self.ident();
                if (!std.mem.eql(u8, next, "message")) return self.fail("expected message", .{});
                try self.skipMessage();
            } else return self.fail("unexpected '{s}'", .{kw});
        }
    }
};

fn isIdentStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}
fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn joinPath(gpa: std.mem.Allocator, from_file: []const u8, rel: []const u8) Error![]u8 {
    if (rel.len != 0 and rel[0] == '/') return gpa.dupe(u8, rel) catch error.OutOfMemory;
    const dir = std.fs.path.dirname(from_file) orelse ".";
    return std.fs.path.join(gpa, &.{ dir, rel }) catch error.OutOfMemory;
}

pub fn parseAvdl(gpa: std.mem.Allocator, io: std.Io, text: []const u8, from_file: []const u8) Error!schema.SchemaPool {
    var pool = schema.SchemaPool.init(gpa);
    errdefer pool.deinit();
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(gpa);
    var parser = Parser{
        .pool = &pool,
        .io = io,
        .text = text,
        .from_file = from_file,
        .stack = &stack,
    };
    try parser.parseBody(false);
    if (pool.nodes.items.len == 0) return pool.failf("IDL defined no types", .{});
    try pool.finish();
    const json_text = try canon.emitSchemaJson(&pool, pool.root, gpa);
    defer gpa.free(json_text);
    pool.original_json = try pool.dupe(json_text);
    return pool;
}

pub fn parseAvpr(gpa: std.mem.Allocator, text: []const u8) Error!schema.SchemaPool {
    var pool = schema.SchemaPool.init(gpa);
    errdefer pool.deinit();
    try parseAvprInto(&pool, text, "");
    try pool.finish();
    pool.original_json = try pool.dupe(std.mem.trim(u8, text, " \t\r\n"));
    return pool;
}

pub fn parseAvprInto(pool: *schema.SchemaPool, text: []const u8, enclosing: []const u8) Error!void {
    var doc = json.Doc.parse(pool.gpa, text) catch return pool.failf("protocol is not JSON", .{});
    defer doc.deinit();
    if (doc.node(doc.root).kind != .object) return pool.failf("protocol must be an object", .{});
    const proto = doc.objectGet(doc.root, "protocol") orelse return pool.failf("protocol missing protocol", .{});
    if (doc.node(proto).kind != .string) return pool.failf("protocol name must be a string", .{});
    var ns = enclosing;
    if (doc.objectGet(doc.root, "namespace")) |n| {
        if (doc.node(n).kind != .string) return pool.failf("namespace must be a string", .{});
        ns = try pool.dupe(doc.node(n).s);
    }
    const types = doc.objectGet(doc.root, "types") orelse return pool.failf("protocol missing types", .{});
    if (doc.node(types).kind != .array) return pool.failf("types must be an array", .{});
    if (doc.arrayLen(types) == 0) return pool.failf("protocol has no types", .{});
    for (0..doc.arrayLen(types)) |i| {
        const raw = doc.raw(doc.arrayAt(types, i));
        pool.root = try schema.parseAvscInto(pool, raw, ns);
    }
}

fn testIo() std.Io {
    return if (comptime @import("builtin").is_test) std.testing.io else undefined;
}

test "idl matches avsc canonical form" {
    const gpa = std.testing.allocator;
    const text = try readRepo(gpa, "testdata/avdl/demo.avdl");
    defer gpa.free(text);
    var pool = try parseAvdl(gpa, testIo(), text, "testdata/avdl/demo.avdl");
    defer pool.deinit();
    const avsc = try readRepo(gpa, "testdata/avsc/demo.avsc");
    defer gpa.free(avsc);
    var other = try schema.parseAvsc(gpa, avsc);
    defer other.deinit();
    const a = try canon.fingerprint(&pool, pool.root, gpa);
    const b = try canon.fingerprint(&other, other.root, gpa);
    try std.testing.expectEqual(a, b);
    try std.testing.expect(pool.by_name.get("demo.Color") != null);
    try std.testing.expect(pool.by_name.get("demo.MD5") != null);

    const avpr = try readRepo(gpa, "testdata/avpr/demo.avpr");
    defer gpa.free(avpr);
    var proto = try parseAvpr(gpa, avpr);
    defer proto.deinit();
    try std.testing.expect(proto.by_name.get("demo.Note") != null);

    try std.testing.expectError(error.Schema, parseAvdl(gpa, testIo(), "protocol P { record R { union { union { int, string }, null } u; } }", "mem.avdl"));
}

fn readRepo(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = if (comptime @import("builtin").is_test) std.testing.io else return error.Schema;
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(diag.max_schema_bytes)) catch error.Schema;
}
