//! Recursive-descent parser for the Zeal query language.
//!
//! Produces an AST (see ast.zig) from a token stream.
//! Uses arena allocation — all nodes live until the arena is destroyed.

const std = @import("std");
const ast = @import("ast.zig");
const lexer_mod = @import("lexer.zig");

const Lexer = lexer_mod.Lexer;
const Token = lexer_mod.Token;
const TokenTag = lexer_mod.TokenTag;

pub const ParseError = error{
    UnexpectedToken,
    InvalidDuration,
    ExpectedExpression,
    ExpectedFieldRef,
    ExpectedValue,
    ExpectedSource,
    OutOfMemory,
};

pub const Parser = struct {
    lexer: Lexer,
    current: Token,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        var lex = Lexer.init(source);
        const first = lex.next();
        return .{
            .lexer = lex,
            .current = first,
            .allocator = allocator,
        };
    }

    /// Parse a complete Zeal query.
    pub fn parse(self: *Parser) ParseError!ast.Query {
        const from = try self.parseFrom();

        const where: ?ast.WhereClause = if (self.current.tag == .kw_where)
            try self.parseWhere()
        else
            null;

        const group_by: ?ast.GroupByClause = if (self.current.tag == .kw_group)
            try self.parseGroupBy()
        else
            null;

        const show: ?ast.ShowClause = if (self.current.tag == .kw_show)
            try self.parseShow()
        else
            null;

        // Reject trailing tokens — catches typos like:
        //   FROM app.json WHERE level = "error" GARBAGE
        if (self.current.tag != .eof) return error.UnexpectedToken;

        return .{
            .from = from,
            .where = where,
            .group_by = group_by,
            .show = show,
        };
    }

    // ── Token helpers ────────────────────────────────────────────────

    fn advance(self: *Parser) Token {
        const prev = self.current;
        self.current = self.lexer.next();
        return prev;
    }

    fn expect(self: *Parser, tag: TokenTag) ParseError!Token {
        if (self.current.tag == tag) {
            return self.advance();
        }
        return error.UnexpectedToken;
    }

    // ── FROM clause ──────────────────────────────────────────────────

    fn parseFrom(self: *Parser) ParseError!ast.FromClause {
        _ = try self.expect(.kw_from);

        var sources: std.ArrayList(ast.Source) = .empty;
        try sources.append(self.allocator, try self.parseSource());

        while (self.current.tag == .comma) {
            _ = self.advance();
            try sources.append(self.allocator, try self.parseSource());
        }

        return .{ .sources = sources.items };
    }

    fn parseSource(self: *Parser) ParseError!ast.Source {
        if (self.current.tag == .kw_stdin) {
            _ = self.advance();
            return .stdin;
        }
        // Absolute path or quoted string: string_literal
        if (self.current.tag == .string_literal) {
            const tok = self.advance();
            return .{ .file_path = stripQuotes(tok.lexeme) };
        }
        // Relative path: identifier possibly followed by adjacent path segments
        // e.g., "testdata/app.json" lexes as identifier("testdata") + string_literal("/app.json")
        // e.g., "app.log" lexes as identifier("app") + dot(".") + identifier("log")
        if (self.current.tag == .identifier) {
            const start = self.current.pos;
            var end = start + self.current.lexeme.len;
            _ = self.advance();

            // Absorb adjacent tokens (no whitespace gap) that form the path
            while (self.current.pos == end) {
                switch (self.current.tag) {
                    .string_literal => {
                        end = self.current.pos + self.current.lexeme.len;
                        _ = self.advance();
                    },
                    .dot => {
                        end = self.current.pos + self.current.lexeme.len;
                        _ = self.advance();
                    },
                    .identifier => {
                        end = self.current.pos + self.current.lexeme.len;
                        _ = self.advance();
                    },
                    else => break,
                }
            }

            return .{ .file_path = self.lexer.source[start..end] };
        }
        return error.ExpectedSource;
    }

    // ── WHERE clause ─────────────────────────────────────────────────

    fn parseWhere(self: *Parser) ParseError!ast.WhereClause {
        _ = try self.expect(.kw_where);
        const expr = try self.parseExpr();
        return .{ .expr = expr };
    }

    fn parseExpr(self: *Parser) ParseError!*const ast.Expr {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) ParseError!*const ast.Expr {
        var left = try self.parseAnd();

        while (self.current.tag == .kw_or) {
            _ = self.advance();
            const right = try self.parseAnd();
            const node = try self.allocator.create(ast.Expr);
            node.* = .{ .or_expr = .{ .left = left, .right = right } };
            left = node;
        }

        return left;
    }

    fn parseAnd(self: *Parser) ParseError!*const ast.Expr {
        var left = try self.parseTemporalOrPrimary();

        while (self.current.tag == .kw_and) {
            _ = self.advance();
            const right = try self.parseTemporalOrPrimary();
            const node = try self.allocator.create(ast.Expr);
            node.* = .{ .and_expr = .{ .left = left, .right = right } };
            left = node;
        }

        return left;
    }

    /// Parse a primary expression, optionally followed by WITHIN duration OF primary.
    fn parseTemporalOrPrimary(self: *Parser) ParseError!*const ast.Expr {
        const left = try self.parsePrimary();

        if (self.current.tag == .kw_within) {
            _ = self.advance();
            const duration_tok = try self.expect(.duration_literal);
            const duration_ns = parseDuration(duration_tok.lexeme) orelse return error.InvalidDuration;
            _ = try self.expect(.kw_of);
            const anchor = try self.parsePrimary();

            const node = try self.allocator.create(ast.Expr);
            node.* = .{ .temporal = .{
                .condition = left,
                .duration_ns = duration_ns,
                .anchor = anchor,
            } };
            return node;
        }

        return left;
    }

    fn parsePrimary(self: *Parser) ParseError!*const ast.Expr {
        // NOT expression
        if (self.current.tag == .kw_not) {
            _ = self.advance();
            const inner = try self.parsePrimary();
            const node = try self.allocator.create(ast.Expr);
            node.* = .{ .not_expr = inner };
            return node;
        }

        // Grouped (parenthesized) expression
        if (self.current.tag == .lparen) {
            _ = self.advance();
            const inner = try self.parseExpr();
            _ = try self.expect(.rparen);
            const node = try self.allocator.create(ast.Expr);
            node.* = .{ .grouped = inner };
            return node;
        }

        // Comparison: field op value
        return self.parseComparison();
    }

    fn parseComparison(self: *Parser) ParseError!*const ast.Expr {
        const field = try self.parseFieldRef();
        const op = try self.parseOp();
        const value = try self.parseValue();

        const node = try self.allocator.create(ast.Expr);
        node.* = .{ .comparison = .{
            .field = field,
            .op = op,
            .value = value,
        } };
        return node;
    }

    fn parseFieldRef(self: *Parser) ParseError!ast.FieldRef {
        var parts: std.ArrayList([]const u8) = .empty;

        if (self.current.tag != .identifier) return error.ExpectedFieldRef;
        try parts.append(self.allocator, self.advance().lexeme);

        while (self.current.tag == .dot) {
            _ = self.advance();
            if (self.current.tag != .identifier) return error.ExpectedFieldRef;
            try parts.append(self.allocator, self.advance().lexeme);
        }

        return .{ .parts = parts.items };
    }

    fn parseOp(self: *Parser) ParseError!ast.CompOp {
        const op: ast.CompOp = switch (self.current.tag) {
            .eq => .eq,
            .neq => .neq,
            .gt => .gt,
            .lt => .lt,
            .gte => .gte,
            .lte => .lte,
            .kw_contains => .contains,
            .kw_matches => .matches,
            else => return error.UnexpectedToken,
        };
        _ = self.advance();
        return op;
    }

    fn parseValue(self: *Parser) ParseError!ast.Value {
        switch (self.current.tag) {
            .string_literal => {
                const tok = self.advance();
                return .{ .string = stripQuotes(tok.lexeme) };
            },
            .number_literal => {
                const tok = self.advance();
                if (std.fmt.parseInt(i64, tok.lexeme, 10)) |int_val| {
                    return .{ .integer = int_val };
                } else |_| {}
                if (std.fmt.parseFloat(f64, tok.lexeme)) |float_val| {
                    return .{ .float = float_val };
                } else |_| {}
                return error.UnexpectedToken;
            },
            .kw_true => {
                _ = self.advance();
                return .{ .boolean = true };
            },
            .kw_false => {
                _ = self.advance();
                return .{ .boolean = false };
            },
            .kw_null => {
                _ = self.advance();
                return .null_val;
            },
            else => return error.ExpectedValue,
        }
    }

    // ── GROUP BY clause ──────────────────────────────────────────────

    fn parseGroupBy(self: *Parser) ParseError!ast.GroupByClause {
        _ = try self.expect(.kw_group);
        _ = try self.expect(.kw_by);

        var fields: std.ArrayList(ast.FieldRef) = .empty;
        try fields.append(self.allocator, try self.parseFieldRef());

        while (self.current.tag == .comma) {
            _ = self.advance();
            try fields.append(self.allocator, try self.parseFieldRef());
        }

        return .{ .fields = fields.items };
    }

    // ── SHOW clause ──────────────────────────────────────────────────

    fn parseShow(self: *Parser) ParseError!ast.ShowClause {
        _ = try self.expect(.kw_show);

        if (self.current.tag == .kw_first) {
            _ = self.advance();
            const tok = try self.expect(.number_literal);
            const n = std.fmt.parseInt(u64, tok.lexeme, 10) catch return error.UnexpectedToken;
            return .{ .first = n };
        }

        if (self.current.tag == .kw_last) {
            _ = self.advance();
            const tok = try self.expect(.number_literal);
            const n = std.fmt.parseInt(u64, tok.lexeme, 10) catch return error.UnexpectedToken;
            return .{ .last = n };
        }

        if (self.current.tag == .kw_count) {
            _ = self.advance();
            return .count;
        }

        // Field list: SHOW field1, field2
        var fields: std.ArrayList(ast.FieldRef) = .empty;
        try fields.append(self.allocator, try self.parseFieldRef());
        while (self.current.tag == .comma) {
            _ = self.advance();
            try fields.append(self.allocator, try self.parseFieldRef());
        }
        return .{ .fields = fields.items };
    }

    // ── Utilities ────────────────────────────────────────────────────

    fn stripQuotes(s: []const u8) []const u8 {
        if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
            const inner = s[1 .. s.len - 1];
            // Fast path: no escape sequences
            if (std.mem.indexOfScalar(u8, inner, '\\') == null) {
                return inner;
            }
            // Has escapes — return as-is for now (escape sequences in
            // values are rare in log queries, and the lexer already
            // validates the string boundaries)
            return inner;
        }
        return s;
    }

    fn parseDuration(lexeme: []const u8) ?u64 {
        var num_end: usize = 0;
        while (num_end < lexeme.len and std.ascii.isDigit(lexeme[num_end])) {
            num_end += 1;
        }
        if (num_end == 0) return null;

        const num = std.fmt.parseInt(u64, lexeme[0..num_end], 10) catch return null;
        const suffix = lexeme[num_end..];

        const ns_per: u64 = if (std.mem.eql(u8, suffix, "ms"))
            1_000_000
        else if (std.mem.eql(u8, suffix, "s"))
            1_000_000_000
        else if (std.mem.eql(u8, suffix, "m"))
            60 * 1_000_000_000
        else if (std.mem.eql(u8, suffix, "h"))
            3600 * 1_000_000_000
        else if (std.mem.eql(u8, suffix, "d"))
            86400 * 1_000_000_000
        else
            return null;

        return num * ns_per;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "parse simple FROM WHERE SHOW" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var parser = Parser.init(alloc,
        \\FROM /var/log/app.log WHERE level = "error" SHOW LAST 20
    );
    const query = try parser.parse();

    // FROM
    try std.testing.expectEqual(@as(usize, 1), query.from.sources.len);
    try std.testing.expectEqualStrings("/var/log/app.log", query.from.sources[0].file_path);

    // WHERE
    try std.testing.expect(query.where != null);
    try std.testing.expectEqual(ast.CompOp.eq, query.where.?.expr.comparison.op);

    // SHOW
    try std.testing.expect(query.show != null);
    try std.testing.expectEqual(@as(u64, 20), query.show.?.last);
}

test "parse temporal correlation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var parser = Parser.init(alloc,
        \\FROM /var/log/app.log WHERE level = "error" WITHIN 5s OF level = "warn"
    );
    const query = try parser.parse();

    try std.testing.expect(query.where != null);
    const expr = query.where.?.expr;
    try std.testing.expectEqual(std.meta.activeTag(expr.*), .temporal);
    try std.testing.expectEqual(@as(u64, 5_000_000_000), expr.temporal.duration_ns);
}

test "parse multiple sources" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var parser = Parser.init(alloc,
        \\FROM /var/log/app.log, /var/log/nginx.log WHERE status >= 500
    );
    const query = try parser.parse();

    try std.testing.expectEqual(@as(usize, 2), query.from.sources.len);
    try std.testing.expectEqualStrings("/var/log/app.log", query.from.sources[0].file_path);
    try std.testing.expectEqualStrings("/var/log/nginx.log", query.from.sources[1].file_path);
}

test "parse GROUP BY" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var parser = Parser.init(alloc,
        \\FROM /var/log/app.log WHERE level = "error" GROUP BY request_id
    );
    const query = try parser.parse();

    try std.testing.expect(query.group_by != null);
    try std.testing.expectEqual(@as(usize, 1), query.group_by.?.fields.len);
    try std.testing.expectEqualStrings("request_id", query.group_by.?.fields[0].parts[0]);
}

test "parse AND / OR" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var parser = Parser.init(alloc,
        \\FROM /var/log/app.log WHERE level = "error" AND status >= 500
    );
    const query = try parser.parse();

    try std.testing.expect(query.where != null);
    try std.testing.expectEqual(std.meta.activeTag(query.where.?.expr.*), .and_expr);
}

test "parse dotted field ref" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var parser = Parser.init(alloc,
        \\FROM /var/log/app.log WHERE request.headers.host = "api.example.com"
    );
    const query = try parser.parse();

    const cmp = query.where.?.expr.comparison;
    try std.testing.expectEqual(@as(usize, 3), cmp.field.parts.len);
    try std.testing.expectEqualStrings("request", cmp.field.parts[0]);
    try std.testing.expectEqualStrings("headers", cmp.field.parts[1]);
    try std.testing.expectEqualStrings("host", cmp.field.parts[2]);
}

test "parse SHOW COUNT" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var parser = Parser.init(alloc,
        \\FROM stdin WHERE message CONTAINS "timeout" SHOW COUNT
    );
    const query = try parser.parse();

    try std.testing.expectEqual(std.meta.activeTag(query.from.sources[0]), .stdin);
    try std.testing.expect(query.show != null);
    try std.testing.expectEqual(std.meta.activeTag(query.show.?), .count);
}

test "parse duration values" {
    // Test the internal parseDuration via temporal queries
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Milliseconds
    var p1 = Parser.init(alloc,
        \\FROM /tmp/a.log WHERE a = "x" WITHIN 100ms OF b = "y"
    );
    const q1 = try p1.parse();
    try std.testing.expectEqual(@as(u64, 100_000_000), q1.where.?.expr.temporal.duration_ns);

    // Minutes
    var p2 = Parser.init(alloc,
        \\FROM /tmp/a.log WHERE a = "x" WITHIN 10m OF b = "y"
    );
    const q2 = try p2.parse();
    try std.testing.expectEqual(@as(u64, 600_000_000_000), q2.where.?.expr.temporal.duration_ns);

    // Hours
    var p3 = Parser.init(alloc,
        \\FROM /tmp/a.log WHERE a = "x" WITHIN 2h OF b = "y"
    );
    const q3 = try p3.parse();
    try std.testing.expectEqual(@as(u64, 7_200_000_000_000), q3.where.?.expr.temporal.duration_ns);
}

test "reject trailing garbage tokens" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var parser = Parser.init(alloc,
        \\FROM /tmp/a.log WHERE level = "error" GARBAGE
    );
    try std.testing.expectError(error.UnexpectedToken, parser.parse());
}

test "parse FROM-only query (no WHERE)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var parser = Parser.init(alloc,
        \\FROM /var/log/app.log
    );
    const query = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), query.from.sources.len);
    try std.testing.expect(query.where == null);
}
