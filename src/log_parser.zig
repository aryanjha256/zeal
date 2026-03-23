//! Log format auto-detection and parsing for Zeal.
//!
//! Detects JSON, logfmt, and plain text log formats.
//! All parsing is zero-copy — field values are slices into the original line buffer.

const std = @import("std");
const log_entry = @import("log_entry.zig");

const LogEntry = log_entry.LogEntry;
const LogLevel = log_entry.LogLevel;
const LogFormat = log_entry.LogFormat;
const Field = log_entry.Field;

// ── Format detection ────────────────────────────────────────────────

/// Auto-detect the log format by examining a sample line.
pub fn detectFormat(line: []const u8) LogFormat {
    const trimmed = trimLeft(line);
    if (trimmed.len == 0) return .plain;

    // JSON: starts with {
    if (trimmed[0] == '{') return .json;

    // logfmt: contains key=value pattern (at least 2 key=value pairs)
    if (looksLikeLogfmt(trimmed)) return .logfmt;

    // Syslog: starts with month abbreviation or <priority>
    if (looksLikeSyslog(trimmed)) return .syslog;

    return .plain;
}

/// Parse a single log line into a LogEntry.
pub fn parseLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    format: LogFormat,
    line_number: usize,
) !LogEntry {
    return switch (format) {
        .json => try parseJsonLine(allocator, line, line_number),
        .logfmt => try parseLogfmtLine(allocator, line, line_number),
        .syslog => parsePlainLine(line, line_number, .syslog),
        .plain => parsePlainLine(line, line_number, .plain),
    };
}

// ── JSON parser ─────────────────────────────────────────────────────

/// Parse a JSON log line. Extracts top-level key-value pairs as zero-copy slices.
fn parseJsonLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_number: usize,
) !LogEntry {
    var entry = LogEntry{
        .raw = line,
        .line_number = line_number,
        .format = .json,
    };

    var fields: std.ArrayList(Field) = .empty;
    var pos: usize = 0;

    // Skip to opening {
    while (pos < line.len and line[pos] != '{') pos += 1;
    if (pos >= line.len) return entry; // not valid JSON, return raw
    pos += 1; // skip {

    while (pos < line.len) {
        skipJsonWhitespace(line, &pos);
        if (pos >= line.len or line[pos] == '}') break;
        if (line[pos] == ',') {
            pos += 1;
            continue;
        }

        // Read key
        const key = readJsonString(line, &pos) orelse break;

        // Expect :
        skipJsonWhitespace(line, &pos);
        if (pos >= line.len or line[pos] != ':') break;
        pos += 1;

        // Read value
        skipJsonWhitespace(line, &pos);
        const value = readJsonValue(line, &pos) orelse break;

        // Check for well-known fields
        if (isLevelKey(key)) {
            entry.level = LogLevel.fromString(value);
        } else if (isMessageKey(key)) {
            entry.message = value;
        } else if (isTimestampKey(key)) {
            entry.timestamp_raw = value;
        }

        try fields.append(allocator, .{ .key = key, .value = value });
    }

    entry.fields = fields.items;
    return entry;
}

/// Read a JSON string value, returning the content without quotes.
fn readJsonString(line: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= line.len or line[pos.*] != '"') return null;
    pos.* += 1; // skip opening "
    const start = pos.*;

    while (pos.* < line.len) {
        if (line[pos.*] == '\\' and pos.* + 1 < line.len) {
            pos.* += 2; // skip escape
            continue;
        }
        if (line[pos.*] == '"') {
            const result = line[start..pos.*];
            pos.* += 1; // skip closing "
            return result;
        }
        pos.* += 1;
    }
    return null; // unterminated
}

/// Read a JSON value (string, number, bool, null, or skip object/array).
/// Returns the value content as a string slice.
fn readJsonValue(line: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= line.len) return null;

    switch (line[pos.*]) {
        '"' => return readJsonString(line, pos),
        '{' => {
            // Skip nested object — find matching }
            return skipJsonNested(line, pos, '{', '}');
        },
        '[' => {
            // Skip nested array — find matching ]
            return skipJsonNested(line, pos, '[', ']');
        },
        else => {
            // Number, bool, or null — read until delimiter
            const start = pos.*;
            while (pos.* < line.len and line[pos.*] != ',' and line[pos.*] != '}' and line[pos.*] != ']' and !std.ascii.isWhitespace(line[pos.*])) {
                pos.* += 1;
            }
            if (pos.* == start) return null;
            return line[start..pos.*];
        },
    }
}

/// Skip a nested JSON object or array, returning the raw content as a slice.
fn skipJsonNested(line: []const u8, pos: *usize, open: u8, close: u8) ?[]const u8 {
    if (pos.* >= line.len or line[pos.*] != open) return null;
    const start = pos.*;
    var depth: usize = 1;
    pos.* += 1;

    while (pos.* < line.len and depth > 0) {
        if (line[pos.*] == '"') {
            // Skip strings inside nested structures
            pos.* += 1;
            while (pos.* < line.len and line[pos.*] != '"') {
                if (line[pos.*] == '\\' and pos.* + 1 < line.len) pos.* += 1;
                pos.* += 1;
            }
            if (pos.* < line.len) pos.* += 1; // skip closing "
            continue;
        }
        if (line[pos.*] == open) depth += 1;
        if (line[pos.*] == close) depth -= 1;
        pos.* += 1;
    }
    return line[start..pos.*];
}

fn skipJsonWhitespace(line: []const u8, pos: *usize) void {
    while (pos.* < line.len and std.ascii.isWhitespace(line[pos.*])) {
        pos.* += 1;
    }
}

// ── logfmt parser ───────────────────────────────────────────────────

/// Parse a logfmt line: key=value key2="quoted value" ...
fn parseLogfmtLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_number: usize,
) !LogEntry {
    var entry = LogEntry{
        .raw = line,
        .line_number = line_number,
        .format = .logfmt,
    };

    var fields: std.ArrayList(Field) = .empty;
    var pos: usize = 0;

    while (pos < line.len) {
        // Skip whitespace
        while (pos < line.len and std.ascii.isWhitespace(line[pos])) pos += 1;
        if (pos >= line.len) break;

        // Read key (until = or whitespace)
        const key_start = pos;
        while (pos < line.len and line[pos] != '=' and !std.ascii.isWhitespace(line[pos])) {
            pos += 1;
        }
        if (pos >= line.len or line[pos] != '=') {
            // Not a key=value pair, skip this token
            while (pos < line.len and !std.ascii.isWhitespace(line[pos])) pos += 1;
            continue;
        }
        const key = line[key_start..pos];
        pos += 1; // skip =

        // Read value
        var value: []const u8 = "";
        if (pos < line.len and line[pos] == '"') {
            // Quoted value
            pos += 1;
            const val_start = pos;
            while (pos < line.len and line[pos] != '"') {
                if (line[pos] == '\\' and pos + 1 < line.len) pos += 1;
                pos += 1;
            }
            value = line[val_start..pos];
            if (pos < line.len) pos += 1; // skip closing "
        } else {
            // Unquoted value
            const val_start = pos;
            while (pos < line.len and !std.ascii.isWhitespace(line[pos])) {
                pos += 1;
            }
            value = line[val_start..pos];
        }

        // Check well-known fields
        if (isLevelKey(key)) {
            entry.level = LogLevel.fromString(value);
        } else if (isMessageKey(key)) {
            entry.message = value;
        } else if (isTimestampKey(key)) {
            entry.timestamp_raw = value;
        }

        try fields.append(allocator, .{ .key = key, .value = value });
    }

    entry.fields = fields.items;
    return entry;
}

// ── Plain text parser ───────────────────────────────────────────────

/// Parse a plain text log line. Tries to extract level and timestamp from common patterns.
fn parsePlainLine(
    line: []const u8,
    line_number: usize,
    format: LogFormat,
) LogEntry {
    var entry = LogEntry{
        .raw = line,
        .line_number = line_number,
        .format = format,
        .message = line,
    };

    // Try to detect level from common patterns like:
    // [ERROR] message
    // ERROR message
    // 2024-01-15 10:30:00 ERROR message
    // timestamp [level] message
    entry.level = detectLevelInPlainText(line);
    entry.timestamp_raw = detectTimestampInPlainText(line);

    return entry;
}

/// Try to find a log level in plain text.
fn detectLevelInPlainText(line: []const u8) LogLevel {
    // Check for [LEVEL] pattern
    if (findBracketedLevel(line)) |level| return level;

    // Check for common level words in the line
    const level_words = [_]struct { word: []const u8, level: LogLevel }{
        .{ .word = "FATAL", .level = .fatal },
        .{ .word = "CRITICAL", .level = .fatal },
        .{ .word = "ERROR", .level = .err },
        .{ .word = "WARN", .level = .warn },
        .{ .word = "WARNING", .level = .warn },
        .{ .word = "INFO", .level = .info },
        .{ .word = "DEBUG", .level = .debug },
        .{ .word = "TRACE", .level = .trace },
    };
    for (&level_words) |entry| {
        if (containsWord(line, entry.word)) return entry.level;
    }
    return .unknown;
}

/// Look for [ERROR], [WARN], etc. in the line.
fn findBracketedLevel(line: []const u8) ?LogLevel {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '[') {
            const start = i + 1;
            i += 1;
            while (i < line.len and line[i] != ']') i += 1;
            if (i < line.len) {
                const content = line[start..i];
                const level = LogLevel.fromString(content);
                if (level != .unknown) return level;
            }
        }
        i += 1;
    }
    return null;
}

/// Try to detect a timestamp at the beginning of a plain text line.
/// Looks for ISO 8601-like patterns: 2024-01-15T10:30:00 or 2024-01-15 10:30:00
fn detectTimestampInPlainText(line: []const u8) ?[]const u8 {
    if (line.len < 10) return null;

    // Check for YYYY-MM-DD pattern at start
    if (line.len >= 4 and std.ascii.isDigit(line[0]) and std.ascii.isDigit(line[1]) and
        std.ascii.isDigit(line[2]) and std.ascii.isDigit(line[3]))
    {
        if (line.len >= 10 and line[4] == '-' and line[7] == '-') {
            // Found date, find end of timestamp
            var end: usize = 10;
            // Check for time part
            if (end < line.len and (line[end] == 'T' or line[end] == ' ')) {
                end += 1;
                // HH:MM:SS
                while (end < line.len and (std.ascii.isDigit(line[end]) or line[end] == ':' or line[end] == '.' or line[end] == 'Z' or line[end] == '+' or line[end] == '-')) {
                    end += 1;
                }
            }
            return line[0..end];
        }
    }

    return null;
}

// ── Helpers ─────────────────────────────────────────────────────────

/// Returns true if this key is a well-known field (level, message, timestamp).
/// Used by output formatting to avoid duplicating already-displayed info.
pub fn isKnownField(key: []const u8) bool {
    return isLevelKey(key) or isMessageKey(key) or isTimestampKey(key);
}

fn isLevelKey(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "level") or
        std.ascii.eqlIgnoreCase(key, "lvl") or
        std.ascii.eqlIgnoreCase(key, "severity") or
        std.ascii.eqlIgnoreCase(key, "log_level") or
        std.ascii.eqlIgnoreCase(key, "loglevel");
}

fn isMessageKey(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "msg") or
        std.ascii.eqlIgnoreCase(key, "message") or
        std.ascii.eqlIgnoreCase(key, "text") or
        std.ascii.eqlIgnoreCase(key, "body");
}

fn isTimestampKey(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "timestamp") or
        std.ascii.eqlIgnoreCase(key, "ts") or
        std.ascii.eqlIgnoreCase(key, "time") or
        std.ascii.eqlIgnoreCase(key, "t") or
        std.ascii.eqlIgnoreCase(key, "@timestamp") or
        std.ascii.eqlIgnoreCase(key, "datetime") or
        std.ascii.eqlIgnoreCase(key, "date");
}

fn looksLikeLogfmt(line: []const u8) bool {
    // Count key=value pairs
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < line.len) {
        // Skip whitespace
        while (pos < line.len and std.ascii.isWhitespace(line[pos])) pos += 1;
        // Look for key=
        var found_eq = false;
        while (pos < line.len and !std.ascii.isWhitespace(line[pos])) {
            if (line[pos] == '=') {
                found_eq = true;
                break;
            }
            pos += 1;
        }
        if (found_eq) {
            count += 1;
            // Skip past value
            pos += 1;
            if (pos < line.len and line[pos] == '"') {
                pos += 1;
                while (pos < line.len and line[pos] != '"') pos += 1;
                if (pos < line.len) pos += 1;
            } else {
                while (pos < line.len and !std.ascii.isWhitespace(line[pos])) pos += 1;
            }
        } else {
            while (pos < line.len and !std.ascii.isWhitespace(line[pos])) pos += 1;
        }
    }
    return count >= 2;
}

fn looksLikeSyslog(line: []const u8) bool {
    // RFC 3164: starts with month abbreviation (Jan, Feb, etc.)
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    if (line.len >= 3) {
        for (&months) |month| {
            if (std.ascii.eqlIgnoreCase(line[0..3], month)) return true;
        }
    }
    // RFC 5424: starts with <priority>
    if (line.len > 0 and line[0] == '<') {
        var i: usize = 1;
        while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        if (i < line.len and line[i] == '>') return true;
    }
    return false;
}

/// Check if a word appears as a standalone word (not part of a larger word).
fn containsWord(line: []const u8, word: []const u8) bool {
    if (line.len < word.len) return false;
    var i: usize = 0;
    while (i + word.len <= line.len) {
        if (std.ascii.eqlIgnoreCase(line[i..][0..word.len], word)) {
            // Check word boundaries
            const before_ok = (i == 0 or !std.ascii.isAlphanumeric(line[i - 1]));
            const after_ok = (i + word.len >= line.len or !std.ascii.isAlphanumeric(line[i + word.len]));
            if (before_ok and after_ok) return true;
        }
        i += 1;
    }
    return false;
}

fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    return s[i..];
}

// ── Tests ──────────────────────────────────────────────────────────

test "detectFormat JSON" {
    try std.testing.expectEqual(LogFormat.json, detectFormat(
        \\{"level":"error","message":"timeout"}
    ));
}

test "detectFormat logfmt" {
    try std.testing.expectEqual(LogFormat.logfmt, detectFormat(
        \\level=error msg="Connection timeout" duration=5000
    ));
}

test "detectFormat syslog" {
    try std.testing.expectEqual(LogFormat.syslog, detectFormat("Jan 15 10:30:00 myhost myapp[1234]: error"));
}

test "detectFormat plain" {
    try std.testing.expectEqual(LogFormat.plain, detectFormat("just a plain log line"));
}

test "parseJsonLine basic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const line =
        \\{"level":"error","message":"Connection timeout","request_id":"abc123"}
    ;
    const entry = try parseJsonLine(alloc, line, 1);
    try std.testing.expectEqual(LogLevel.err, entry.level);
    try std.testing.expectEqualStrings("Connection timeout", entry.message.?);
    try std.testing.expectEqual(@as(usize, 3), entry.fields.len);
}

test "parseJsonLine with timestamp" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const line =
        \\{"ts":"2024-01-15T10:30:00Z","level":"info","msg":"ok"}
    ;
    const entry = try parseJsonLine(alloc, line, 1);
    try std.testing.expectEqual(LogLevel.info, entry.level);
    try std.testing.expectEqualStrings("ok", entry.message.?);
    try std.testing.expectEqualStrings("2024-01-15T10:30:00Z", entry.timestamp_raw.?);
}

test "parseJsonLine with numeric value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const line =
        \\{"level":"warn","status":500,"msg":"server error"}
    ;
    const entry = try parseJsonLine(alloc, line, 1);
    try std.testing.expectEqual(LogLevel.warn, entry.level);
    try std.testing.expectEqualStrings("server error", entry.message.?);
}

test "parseLogfmtLine basic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const line = "ts=2024-01-15T10:30:00Z level=error msg=\"Connection timeout\" request_id=abc123";
    const entry = try parseLogfmtLine(alloc, line, 1);
    try std.testing.expectEqual(LogLevel.err, entry.level);
    try std.testing.expectEqualStrings("Connection timeout", entry.message.?);
    try std.testing.expectEqualStrings("2024-01-15T10:30:00Z", entry.timestamp_raw.?);
}

test "parsePlainLine with level detection" {
    const entry = parsePlainLine("2024-01-15 10:30:00 ERROR Connection timeout", 1, .plain);
    try std.testing.expectEqual(LogLevel.err, entry.level);
    try std.testing.expect(entry.timestamp_raw != null);
}

test "parsePlainLine with bracketed level" {
    const entry = parsePlainLine("[WARN] something went wrong", 1, .plain);
    try std.testing.expectEqual(LogLevel.warn, entry.level);
}

test "containsWord" {
    try std.testing.expect(containsWord("this is an ERROR here", "ERROR"));
    try std.testing.expect(!containsWord("ERRORS occurred", "ERROR")); // part of bigger word
    try std.testing.expect(containsWord("ERROR: something", "ERROR"));
    try std.testing.expect(containsWord("[ERROR] foo", "ERROR"));
}

test "looksLikeLogfmt" {
    try std.testing.expect(looksLikeLogfmt("key1=val1 key2=val2"));
    try std.testing.expect(looksLikeLogfmt("level=error msg=\"hello world\""));
    try std.testing.expect(!looksLikeLogfmt("just a plain line"));
    try std.testing.expect(!looksLikeLogfmt("only=one"));
}
