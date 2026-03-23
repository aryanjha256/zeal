//! Streaming tokenizer for the Zeal query language.
//!
//! Zero-copy: all token lexemes are slices into the original source string.
//! Call `next()` repeatedly to pull tokens one at a time.

const std = @import("std");

pub const TokenTag = enum {
    // ── Keywords ──
    kw_from,
    kw_where,
    kw_and,
    kw_or,
    kw_not,
    kw_within,
    kw_of,
    kw_group,
    kw_by,
    kw_show,
    kw_first,
    kw_last,
    kw_count,
    kw_contains,
    kw_matches,
    kw_stdin,
    kw_true,
    kw_false,
    kw_null,

    // ── Literals ──
    string_literal,
    number_literal,
    duration_literal,

    // ── Identifiers ──
    identifier,

    // ── Operators ──
    eq, // =
    neq, // !=
    gt, // >
    lt, // <
    gte, // >=
    lte, // <=

    // ── Punctuation ──
    lparen, // (
    rparen, // )
    comma, // ,
    dot, // .

    // ── Special ──
    eof,
    invalid,
};

pub const Token = struct {
    tag: TokenTag,
    lexeme: []const u8,
    pos: usize,
};

pub const Lexer = struct {
    source: []const u8,
    pos: usize,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source, .pos = 0 };
    }

    /// Pull the next token from the source.
    pub fn next(self: *Lexer) Token {
        self.skipWhitespace();

        if (self.pos >= self.source.len) {
            return .{ .tag = .eof, .lexeme = "", .pos = self.pos };
        }

        const start = self.pos;
        const c = self.source[self.pos];

        switch (c) {
            '(' => {
                self.pos += 1;
                return .{ .tag = .lparen, .lexeme = self.source[start..self.pos], .pos = start };
            },
            ')' => {
                self.pos += 1;
                return .{ .tag = .rparen, .lexeme = self.source[start..self.pos], .pos = start };
            },
            ',' => {
                self.pos += 1;
                return .{ .tag = .comma, .lexeme = self.source[start..self.pos], .pos = start };
            },
            '.' => {
                self.pos += 1;
                return .{ .tag = .dot, .lexeme = self.source[start..self.pos], .pos = start };
            },
            '=' => {
                self.pos += 1;
                return .{ .tag = .eq, .lexeme = self.source[start..self.pos], .pos = start };
            },
            '!' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '=') {
                    self.pos += 2;
                    return .{ .tag = .neq, .lexeme = self.source[start..self.pos], .pos = start };
                }
                self.pos += 1;
                return .{ .tag = .invalid, .lexeme = self.source[start..self.pos], .pos = start };
            },
            '>' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '=') {
                    self.pos += 2;
                    return .{ .tag = .gte, .lexeme = self.source[start..self.pos], .pos = start };
                }
                self.pos += 1;
                return .{ .tag = .gt, .lexeme = self.source[start..self.pos], .pos = start };
            },
            '<' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '=') {
                    self.pos += 2;
                    return .{ .tag = .lte, .lexeme = self.source[start..self.pos], .pos = start };
                }
                self.pos += 1;
                return .{ .tag = .lt, .lexeme = self.source[start..self.pos], .pos = start };
            },
            '"' => return self.readString(start),
            '/' => return self.readPath(start),
            else => {},
        }

        // Numbers (possibly followed by duration suffix)
        if (std.ascii.isDigit(c)) {
            return self.readNumberOrDuration(start);
        }

        // Identifiers and keywords
        if (std.ascii.isAlphabetic(c) or c == '_') {
            return self.readIdentifierOrKeyword(start);
        }

        self.pos += 1;
        return .{ .tag = .invalid, .lexeme = self.source[start..self.pos], .pos = start };
    }

    /// Peek at the next token without consuming it.
    pub fn peek(self: *Lexer) Token {
        const saved_pos = self.pos;
        const tok = self.next();
        self.pos = saved_pos;
        return tok;
    }

    // ── Private helpers ──────────────────────────────────────────────

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.source.len and std.ascii.isWhitespace(self.source[self.pos])) {
            self.pos += 1;
        }
    }

    fn readString(self: *Lexer, start: usize) Token {
        self.pos += 1; // skip opening "
        while (self.pos < self.source.len) {
            if (self.source[self.pos] == '\\' and self.pos + 1 < self.source.len) {
                self.pos += 2; // skip escape sequence
                continue;
            }
            if (self.source[self.pos] == '"') {
                self.pos += 1; // skip closing "
                return .{ .tag = .string_literal, .lexeme = self.source[start..self.pos], .pos = start };
            }
            self.pos += 1;
        }
        // Unterminated string
        return .{ .tag = .invalid, .lexeme = self.source[start..self.pos], .pos = start };
    }

    fn readPath(self: *Lexer, start: usize) Token {
        // Unquoted file path starting with /
        while (self.pos < self.source.len and isPathChar(self.source[self.pos])) {
            self.pos += 1;
        }
        return .{ .tag = .string_literal, .lexeme = self.source[start..self.pos], .pos = start };
    }

    fn readNumberOrDuration(self: *Lexer, start: usize) Token {
        // Consume digits
        while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
            self.pos += 1;
        }
        // Decimal part
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
                self.pos += 1;
            }
        }
        // Check for duration suffix: ms, s, m, h, d
        if (self.pos < self.source.len) {
            // "ms" (must check before single 'm')
            if (self.source[self.pos] == 'm' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == 's') {
                if (self.pos + 2 >= self.source.len or !std.ascii.isAlphanumeric(self.source[self.pos + 2])) {
                    self.pos += 2;
                    return .{ .tag = .duration_literal, .lexeme = self.source[start..self.pos], .pos = start };
                }
            }
            switch (self.source[self.pos]) {
                's', 'h', 'd' => {
                    if (self.pos + 1 >= self.source.len or !std.ascii.isAlphanumeric(self.source[self.pos + 1])) {
                        self.pos += 1;
                        return .{ .tag = .duration_literal, .lexeme = self.source[start..self.pos], .pos = start };
                    }
                },
                'm' => {
                    // 'm' for minutes — only if NOT followed by another alpha (to avoid matching identifiers)
                    if (self.pos + 1 >= self.source.len or !std.ascii.isAlphanumeric(self.source[self.pos + 1])) {
                        self.pos += 1;
                        return .{ .tag = .duration_literal, .lexeme = self.source[start..self.pos], .pos = start };
                    }
                },
                else => {},
            }
        }
        return .{ .tag = .number_literal, .lexeme = self.source[start..self.pos], .pos = start };
    }

    fn readIdentifierOrKeyword(self: *Lexer, start: usize) Token {
        while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) {
            self.pos += 1;
        }
        const lexeme = self.source[start..self.pos];
        const tag = keywordTag(lexeme) orelse .identifier;
        return .{ .tag = tag, .lexeme = lexeme, .pos = start };
    }

    fn isPathChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '/' or c == '.' or c == '-' or c == '_' or c == '~' or c == '*';
    }

    fn keywordTag(lexeme: []const u8) ?TokenTag {
        const keywords = .{
            .{ "from", TokenTag.kw_from },
            .{ "where", TokenTag.kw_where },
            .{ "and", TokenTag.kw_and },
            .{ "or", TokenTag.kw_or },
            .{ "not", TokenTag.kw_not },
            .{ "within", TokenTag.kw_within },
            .{ "of", TokenTag.kw_of },
            .{ "group", TokenTag.kw_group },
            .{ "by", TokenTag.kw_by },
            .{ "show", TokenTag.kw_show },
            .{ "first", TokenTag.kw_first },
            .{ "last", TokenTag.kw_last },
            .{ "count", TokenTag.kw_count },
            .{ "contains", TokenTag.kw_contains },
            .{ "matches", TokenTag.kw_matches },
            .{ "stdin", TokenTag.kw_stdin },
            .{ "true", TokenTag.kw_true },
            .{ "false", TokenTag.kw_false },
            .{ "null", TokenTag.kw_null },
        };
        inline for (keywords) |entry| {
            if (std.ascii.eqlIgnoreCase(lexeme, entry[0])) return entry[1];
        }
        return null;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "lex simple query keywords" {
    var lex = Lexer.init("FROM WHERE AND OR NOT");
    try std.testing.expectEqual(TokenTag.kw_from, lex.next().tag);
    try std.testing.expectEqual(TokenTag.kw_where, lex.next().tag);
    try std.testing.expectEqual(TokenTag.kw_and, lex.next().tag);
    try std.testing.expectEqual(TokenTag.kw_or, lex.next().tag);
    try std.testing.expectEqual(TokenTag.kw_not, lex.next().tag);
    try std.testing.expectEqual(TokenTag.eof, lex.next().tag);
}

test "lex case insensitive keywords" {
    var lex = Lexer.init("from Where WITHIN");
    try std.testing.expectEqual(TokenTag.kw_from, lex.next().tag);
    try std.testing.expectEqual(TokenTag.kw_where, lex.next().tag);
    try std.testing.expectEqual(TokenTag.kw_within, lex.next().tag);
}

test "lex operators" {
    var lex = Lexer.init("= != > < >= <=");
    try std.testing.expectEqual(TokenTag.eq, lex.next().tag);
    try std.testing.expectEqual(TokenTag.neq, lex.next().tag);
    try std.testing.expectEqual(TokenTag.gt, lex.next().tag);
    try std.testing.expectEqual(TokenTag.lt, lex.next().tag);
    try std.testing.expectEqual(TokenTag.gte, lex.next().tag);
    try std.testing.expectEqual(TokenTag.lte, lex.next().tag);
}

test "lex string literal" {
    var lex = Lexer.init("\"hello world\"");
    const tok = lex.next();
    try std.testing.expectEqual(TokenTag.string_literal, tok.tag);
    try std.testing.expectEqualStrings("\"hello world\"", tok.lexeme);
}

test "lex file path" {
    var lex = Lexer.init("/var/log/app.log");
    const tok = lex.next();
    try std.testing.expectEqual(TokenTag.string_literal, tok.tag);
    try std.testing.expectEqualStrings("/var/log/app.log", tok.lexeme);
}

test "lex duration literals" {
    var lex = Lexer.init("5s 10m 100ms 1h 2d");
    const s_tok = lex.next();
    try std.testing.expectEqual(TokenTag.duration_literal, s_tok.tag);
    try std.testing.expectEqualStrings("5s", s_tok.lexeme);

    const m_tok = lex.next();
    try std.testing.expectEqual(TokenTag.duration_literal, m_tok.tag);
    try std.testing.expectEqualStrings("10m", m_tok.lexeme);

    const ms_tok = lex.next();
    try std.testing.expectEqual(TokenTag.duration_literal, ms_tok.tag);
    try std.testing.expectEqualStrings("100ms", ms_tok.lexeme);

    const h_tok = lex.next();
    try std.testing.expectEqual(TokenTag.duration_literal, h_tok.tag);
    try std.testing.expectEqualStrings("1h", h_tok.lexeme);

    const d_tok = lex.next();
    try std.testing.expectEqual(TokenTag.duration_literal, d_tok.tag);
    try std.testing.expectEqualStrings("2d", d_tok.lexeme);
}

test "lex number literal" {
    var lex = Lexer.init("42 3.14");
    const int_tok = lex.next();
    try std.testing.expectEqual(TokenTag.number_literal, int_tok.tag);
    try std.testing.expectEqualStrings("42", int_tok.lexeme);

    const float_tok = lex.next();
    try std.testing.expectEqual(TokenTag.number_literal, float_tok.tag);
    try std.testing.expectEqualStrings("3.14", float_tok.lexeme);
}

test "lex full query" {
    var lex = Lexer.init(
        \\FROM /var/log/app.log WHERE level = "error" SHOW LAST 20
    );
    try std.testing.expectEqual(TokenTag.kw_from, lex.next().tag);
    try std.testing.expectEqual(TokenTag.string_literal, lex.next().tag); // path
    try std.testing.expectEqual(TokenTag.kw_where, lex.next().tag);
    try std.testing.expectEqual(TokenTag.identifier, lex.next().tag); // level
    try std.testing.expectEqual(TokenTag.eq, lex.next().tag);
    try std.testing.expectEqual(TokenTag.string_literal, lex.next().tag); // "error"
    try std.testing.expectEqual(TokenTag.kw_show, lex.next().tag);
    try std.testing.expectEqual(TokenTag.kw_last, lex.next().tag);
    try std.testing.expectEqual(TokenTag.number_literal, lex.next().tag); // 20
    try std.testing.expectEqual(TokenTag.eof, lex.next().tag);
}

test "lex identifiers with dots (handled separately)" {
    var lex = Lexer.init("request.headers.host");
    try std.testing.expectEqual(TokenTag.identifier, lex.next().tag);
    try std.testing.expectEqual(TokenTag.dot, lex.next().tag);
    try std.testing.expectEqual(TokenTag.identifier, lex.next().tag);
    try std.testing.expectEqual(TokenTag.dot, lex.next().tag);
    try std.testing.expectEqual(TokenTag.identifier, lex.next().tag);
}
