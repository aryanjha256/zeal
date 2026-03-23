//! Query evaluator for Zeal.
//!
//! Evaluates AST expressions against parsed log entries.
//! All comparisons work on the zero-copy string fields from LogEntry.

const std = @import("std");
const ast = @import("ast.zig");
const log_entry = @import("log_entry.zig");

const LogEntry = log_entry.LogEntry;
const LogLevel = log_entry.LogLevel;
const Field = log_entry.Field;
const Expr = ast.Expr;
const Comparison = ast.Comparison;
const CompOp = ast.CompOp;
const FieldRef = ast.FieldRef;
const Value = ast.Value;

/// Evaluate a WHERE expression against a log entry.
/// Returns true if the entry matches the expression.
/// For temporal expressions, only the condition side is checked here —
/// temporal correlation is handled by the temporal engine.
pub fn matches(entry: *const LogEntry, expr: *const Expr) bool {
    return evalExpr(entry, expr);
}

fn evalExpr(entry: *const LogEntry, expr: *const Expr) bool {
    switch (expr.*) {
        .comparison => |cmp| return evalComparison(entry, cmp),
        .and_expr => |bin| return evalExpr(entry, bin.left) and evalExpr(entry, bin.right),
        .or_expr => |bin| return evalExpr(entry, bin.left) or evalExpr(entry, bin.right),
        .not_expr => |inner| return !evalExpr(entry, inner),
        .grouped => |inner| return evalExpr(entry, inner),
        .temporal => |t| {
            // For temporal expressions, the evaluator only checks the condition side.
            // The temporal engine handles the correlation logic.
            return evalExpr(entry, t.condition);
        },
    }
}

// ── Comparison evaluation ───────────────────────────────────────────

fn evalComparison(entry: *const LogEntry, cmp: Comparison) bool {
    // Resolve the field reference to a string value from the log entry
    const field_val = resolveField(entry, cmp.field) orelse {
        // Field not found — only matches if comparing against null
        return switch (cmp.op) {
            .eq => cmp.value == .null_val,
            .neq => cmp.value != .null_val,
            else => false,
        };
    };

    // Perform the comparison
    return switch (cmp.op) {
        .eq => evalEq(field_val, cmp.value),
        .neq => !evalEq(field_val, cmp.value),
        .gt => evalOrd(field_val, cmp.value, .gt),
        .lt => evalOrd(field_val, cmp.value, .lt),
        .gte => evalOrd(field_val, cmp.value, .gte),
        .lte => evalOrd(field_val, cmp.value, .lte),
        .contains => evalContains(field_val, cmp.value),
        .matches => evalContains(field_val, cmp.value), // simplified: same as contains for now
    };
}

/// Resolve a field reference to a string value from a log entry.
/// Handles well-known fields (level, message, timestamp) and key-value fields.
pub fn resolveField(entry: *const LogEntry, field_ref: FieldRef) ?[]const u8 {
    if (field_ref.parts.len == 0) return null;

    const first = field_ref.parts[0];

    // Single-part field: check well-known fields first
    if (field_ref.parts.len == 1) {
        // Well-known fields
        if (std.ascii.eqlIgnoreCase(first, "level") or
            std.ascii.eqlIgnoreCase(first, "lvl") or
            std.ascii.eqlIgnoreCase(first, "severity"))
        {
            return entry.level.toString();
        }

        if (std.ascii.eqlIgnoreCase(first, "message") or
            std.ascii.eqlIgnoreCase(first, "msg"))
        {
            return entry.message;
        }

        if (std.ascii.eqlIgnoreCase(first, "timestamp") or
            std.ascii.eqlIgnoreCase(first, "ts") or
            std.ascii.eqlIgnoreCase(first, "time"))
        {
            return entry.timestamp_raw;
        }

        if (std.ascii.eqlIgnoreCase(first, "raw") or
            std.ascii.eqlIgnoreCase(first, "line"))
        {
            return entry.raw;
        }
    }

    // Search in key-value fields — single-part: exact match
    if (field_ref.parts.len == 1) {
        for (entry.fields) |f| {
            if (std.ascii.eqlIgnoreCase(f.key, first)) {
                return f.value;
            }
        }
        return null;
    }

    // Multi-part field reference (e.g., request.headers.host)
    // For flat log formats, try joining with dots as a single key lookup
    // For JSON with nested objects, the value was stored as raw JSON — search for it
    return resolveNestedField(entry, field_ref);
}

fn resolveNestedField(entry: *const LogEntry, field_ref: FieldRef) ?[]const u8 {
    // Strategy 1: Try concatenated key (e.g., "request.headers.host")
    for (entry.fields) |f| {
        if (fieldRefMatchesKey(field_ref, f.key)) {
            return f.value;
        }
    }

    // Strategy 2: For JSON nested objects, look for the first part and
    // recursively search within the nested JSON value.
    // This is a simplified approach — we search the raw nested JSON string
    // for the target key.
    if (field_ref.parts.len >= 2) {
        for (entry.fields) |f| {
            if (std.ascii.eqlIgnoreCase(f.key, field_ref.parts[0])) {
                // If the value looks like a JSON object, search within it
                if (f.value.len > 0 and f.value[0] == '{') {
                    return searchJsonForKey(f.value, field_ref.parts[1..]);
                }
            }
        }
    }

    return null;
}

/// Check if a field reference matches a dotted key string.
fn fieldRefMatchesKey(field_ref: FieldRef, key: []const u8) bool {
    var pos: usize = 0;
    for (field_ref.parts, 0..) |part, i| {
        if (i > 0) {
            if (pos >= key.len or key[pos] != '.') return false;
            pos += 1;
        }
        if (pos + part.len > key.len) return false;
        if (!std.ascii.eqlIgnoreCase(key[pos..][0..part.len], part)) return false;
        pos += part.len;
    }
    return pos == key.len;
}

/// Simple JSON key search within a nested object string.
fn searchJsonForKey(json: []const u8, parts: []const []const u8) ?[]const u8 {
    if (parts.len == 0) return null;

    const target_key = parts[0];
    var pos: usize = 0;

    // Skip opening {
    while (pos < json.len and json[pos] != '{') pos += 1;
    if (pos >= json.len) return null;
    pos += 1;

    while (pos < json.len) {
        // Skip whitespace and commas
        while (pos < json.len and (std.ascii.isWhitespace(json[pos]) or json[pos] == ',')) pos += 1;
        if (pos >= json.len or json[pos] == '}') break;

        // Read key
        if (json[pos] != '"') break;
        pos += 1;
        const key_start = pos;
        while (pos < json.len and json[pos] != '"') pos += 1;
        if (pos >= json.len) break;
        const key = json[key_start..pos];
        pos += 1;

        // Skip :
        while (pos < json.len and (std.ascii.isWhitespace(json[pos]) or json[pos] == ':')) pos += 1;

        // Read value
        const val_start = pos;
        if (pos < json.len and json[pos] == '"') {
            // String value
            pos += 1;
            while (pos < json.len and json[pos] != '"') {
                if (json[pos] == '\\' and pos + 1 < json.len) pos += 1;
                pos += 1;
            }
            if (pos < json.len) pos += 1;

            if (std.ascii.eqlIgnoreCase(key, target_key)) {
                if (parts.len == 1) {
                    return json[val_start + 1 .. pos - 1]; // strip quotes
                }
            }
        } else if (pos < json.len and json[pos] == '{') {
            // Nested object
            var depth: usize = 1;
            pos += 1;
            while (pos < json.len and depth > 0) {
                if (json[pos] == '{') depth += 1;
                if (json[pos] == '}') depth -= 1;
                pos += 1;
            }

            if (std.ascii.eqlIgnoreCase(key, target_key) and parts.len > 1) {
                return searchJsonForKey(json[val_start..pos], parts[1..]);
            }
        } else {
            // Number, bool, null
            while (pos < json.len and json[pos] != ',' and json[pos] != '}' and !std.ascii.isWhitespace(json[pos])) {
                pos += 1;
            }
            if (std.ascii.eqlIgnoreCase(key, target_key) and parts.len == 1) {
                return json[val_start..pos];
            }
        }
    }

    return null;
}

// ── Comparison operators ────────────────────────────────────────────

fn evalEq(field_val: []const u8, target: Value) bool {
    switch (target) {
        .string => |s| return std.ascii.eqlIgnoreCase(field_val, s),
        .integer => |n| {
            const parsed = std.fmt.parseInt(i64, field_val, 10) catch return false;
            return parsed == n;
        },
        .float => |f| {
            const parsed = std.fmt.parseFloat(f64, field_val) catch return false;
            return @abs(parsed - f) < 1e-9;
        },
        .boolean => |b| {
            if (b) return std.ascii.eqlIgnoreCase(field_val, "true");
            return std.ascii.eqlIgnoreCase(field_val, "false");
        },
        .null_val => return field_val.len == 0 or std.ascii.eqlIgnoreCase(field_val, "null"),
    }
}

const OrdOp = enum { gt, lt, gte, lte };

fn evalOrd(field_val: []const u8, target: Value, op: OrdOp) bool {
    switch (target) {
        .integer => |n| {
            const parsed = std.fmt.parseInt(i64, field_val, 10) catch return false;
            return switch (op) {
                .gt => parsed > n,
                .lt => parsed < n,
                .gte => parsed >= n,
                .lte => parsed <= n,
            };
        },
        .float => |f| {
            const parsed = std.fmt.parseFloat(f64, field_val) catch return false;
            return switch (op) {
                .gt => parsed > f,
                .lt => parsed < f,
                .gte => parsed >= f,
                .lte => parsed <= f,
            };
        },
        .string => |s| {
            // Case-insensitive string ordering (consistent with evalEq)
            const order = orderIgnoreCase(field_val, s);
            return switch (op) {
                .gt => order == .gt,
                .lt => order == .lt,
                .gte => order != .lt,
                .lte => order != .gt,
            };
        },
        else => return false,
    }
}

/// Case-insensitive lexicographic ordering of two strings.
fn orderIgnoreCase(a: []const u8, b: []const u8) std.math.Order {
    const len = @min(a.len, b.len);
    for (a[0..len], b[0..len]) |ac, bc| {
        const al = std.ascii.toLower(ac);
        const bl = std.ascii.toLower(bc);
        if (al < bl) return .lt;
        if (al > bl) return .gt;
    }
    return std.math.order(a.len, b.len);
}

fn evalContains(field_val: []const u8, target: Value) bool {
    switch (target) {
        .string => |s| {
            // Case-insensitive substring search
            if (s.len == 0) return true;
            if (field_val.len < s.len) return false;
            var i: usize = 0;
            while (i + s.len <= field_val.len) : (i += 1) {
                if (std.ascii.eqlIgnoreCase(field_val[i..][0..s.len], s)) return true;
            }
            return false;
        },
        else => {
            // For non-string targets, stringify and check containment
            return false;
        },
    }
}

// ── Tests ──────────────────────────────────────────────────────────

test "matches simple comparison - level = error" {
    const entry = LogEntry{
        .raw = "test line",
        .level = .err,
        .message = "something broke",
        .fields = &.{},
    };

    // Build a comparison AST node: level = "error"
    const expr = Expr{ .comparison = .{
        .field = .{ .parts = &.{"level"} },
        .op = .eq,
        .value = .{ .string = "ERROR" },
    } };

    try std.testing.expect(matches(&entry, &expr));
}

test "matches comparison - field from fields slice" {
    const fields = [_]Field{
        .{ .key = "status", .value = "500" },
        .{ .key = "request_id", .value = "abc123" },
    };
    const entry = LogEntry{
        .raw = "test line",
        .fields = &fields,
    };

    // status >= 500
    const expr = Expr{ .comparison = .{
        .field = .{ .parts = &.{"status"} },
        .op = .gte,
        .value = .{ .integer = 500 },
    } };

    try std.testing.expect(matches(&entry, &expr));
}

test "matches AND expression" {
    const fields = [_]Field{
        .{ .key = "status", .value = "500" },
    };
    const entry = LogEntry{
        .raw = "test line",
        .level = .err,
        .fields = &fields,
    };

    const left = Expr{ .comparison = .{
        .field = .{ .parts = &.{"level"} },
        .op = .eq,
        .value = .{ .string = "ERROR" },
    } };
    const right = Expr{ .comparison = .{
        .field = .{ .parts = &.{"status"} },
        .op = .gte,
        .value = .{ .integer = 500 },
    } };
    const expr = Expr{ .and_expr = .{ .left = &left, .right = &right } };

    try std.testing.expect(matches(&entry, &expr));
}

test "matches OR expression" {
    const entry = LogEntry{
        .raw = "test line",
        .level = .warn,
    };

    const left = Expr{ .comparison = .{
        .field = .{ .parts = &.{"level"} },
        .op = .eq,
        .value = .{ .string = "ERROR" },
    } };
    const right = Expr{ .comparison = .{
        .field = .{ .parts = &.{"level"} },
        .op = .eq,
        .value = .{ .string = "WARN" },
    } };
    const expr = Expr{ .or_expr = .{ .left = &left, .right = &right } };

    try std.testing.expect(matches(&entry, &expr));
}

test "matches NOT expression" {
    const entry = LogEntry{
        .raw = "test line",
        .level = .info,
    };

    const inner = Expr{ .comparison = .{
        .field = .{ .parts = &.{"level"} },
        .op = .eq,
        .value = .{ .string = "ERROR" },
    } };
    const expr = Expr{ .not_expr = &inner };

    try std.testing.expect(matches(&entry, &expr));
}

test "matches CONTAINS" {
    const entry = LogEntry{
        .raw = "test line",
        .message = "Connection timeout after 5000ms",
    };

    const expr = Expr{ .comparison = .{
        .field = .{ .parts = &.{"message"} },
        .op = .contains,
        .value = .{ .string = "timeout" },
    } };

    try std.testing.expect(matches(&entry, &expr));
}

test "comparison against missing field" {
    const entry = LogEntry{
        .raw = "test line",
    };

    const expr = Expr{ .comparison = .{
        .field = .{ .parts = &.{"nonexistent"} },
        .op = .eq,
        .value = .{ .string = "value" },
    } };

    try std.testing.expect(!matches(&entry, &expr));
}

test "evalOrd with integers" {
    const fields = [_]Field{
        .{ .key = "status", .value = "404" },
    };
    const entry = LogEntry{
        .raw = "test",
        .fields = &fields,
    };

    // status > 200
    const gt_expr = Expr{ .comparison = .{
        .field = .{ .parts = &.{"status"} },
        .op = .gt,
        .value = .{ .integer = 200 },
    } };
    try std.testing.expect(matches(&entry, &gt_expr));

    // status < 500
    const lt_expr = Expr{ .comparison = .{
        .field = .{ .parts = &.{"status"} },
        .op = .lt,
        .value = .{ .integer = 500 },
    } };
    try std.testing.expect(matches(&entry, &lt_expr));

    // status >= 404
    const gte_expr = Expr{ .comparison = .{
        .field = .{ .parts = &.{"status"} },
        .op = .gte,
        .value = .{ .integer = 404 },
    } };
    try std.testing.expect(matches(&entry, &gte_expr));
}

test "float equality uses epsilon" {
    const fields = [_]Field{
        .{ .key = "latency", .value = "3.14" },
    };
    const entry = LogEntry{
        .raw = "test",
        .fields = &fields,
    };

    const expr = Expr{ .comparison = .{
        .field = .{ .parts = &.{"latency"} },
        .op = .eq,
        .value = .{ .float = 3.14 },
    } };
    try std.testing.expect(matches(&entry, &expr));
}

test "string ordering is case-insensitive" {
    const fields = [_]Field{
        .{ .key = "host", .value = "API-SERVER" },
    };
    const entry = LogEntry{
        .raw = "test",
        .fields = &fields,
    };

    // "API-SERVER" > "api" should work case-insensitively
    const expr = Expr{ .comparison = .{
        .field = .{ .parts = &.{"host"} },
        .op = .gt,
        .value = .{ .string = "api" },
    } };
    // "api-server" > "api" → true
    try std.testing.expect(matches(&entry, &expr));
}

test "nested field resolution in JSON" {
    const fields = [_]Field{
        .{ .key = "request", .value = "{\"method\":\"GET\",\"path\":\"/api\"}" },
    };
    const entry = LogEntry{
        .raw = "test",
        .fields = &fields,
    };

    const expr = Expr{ .comparison = .{
        .field = .{ .parts = &.{ "request", "method" } },
        .op = .eq,
        .value = .{ .string = "GET" },
    } };
    try std.testing.expect(matches(&entry, &expr));
}
