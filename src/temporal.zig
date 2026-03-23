//! Temporal correlation engine for Zeal.
//!
//! Implements the killer feature: `condition WITHIN duration OF anchor`
//!
//! Algorithm:
//! 1. Scan all entries to find "anchor" matches
//! 2. For each entry matching the "condition", check if any anchor
//!    event occurred within ±duration_ns (using raw timestamp strings)
//!
//! Since log timestamps are typically ISO 8601 strings, we parse them
//! into comparable nanosecond values for the window check.

const std = @import("std");
const ast = @import("ast.zig");
const log_entry = @import("log_entry.zig");
const evaluator = @import("evaluator.zig");

const LogEntry = log_entry.LogEntry;
const Expr = ast.Expr;
const TemporalExpr = ast.TemporalExpr;

/// Result of a temporal correlation check.
pub const CorrelationResult = struct {
    /// Entries matching the condition that have a correlated anchor within the window.
    matched_indices: []const usize,
    /// Total anchor events found.
    anchor_count: usize,
    /// Total condition events found (before temporal filtering).
    condition_count: usize,
};

/// Run temporal correlation on a set of entries.
///
/// Returns indices of entries that match the full temporal expression:
/// they satisfy `condition` AND have at least one entry satisfying `anchor`
/// within ±duration_ns.
pub fn correlate(
    allocator: std.mem.Allocator,
    entries: []const LogEntry,
    temporal: TemporalExpr,
) !CorrelationResult {
    // Step 1: Find all anchor timestamps
    var anchor_timestamps: std.ArrayList(i128) = .empty;
    var anchor_count: usize = 0;

    for (entries) |*entry| {
        if (evaluator.matches(entry, temporal.anchor)) {
            anchor_count += 1;
            if (entry.timestamp_raw) |ts| {
                if (parseTimestampNs(ts)) |ns| {
                    try anchor_timestamps.append(allocator, ns);
                }
            }
        }
    }

    // Sort anchor timestamps for binary search
    sortTimestamps(anchor_timestamps.items);

    // Step 2: For each entry matching condition, check temporal proximity
    var matched: std.ArrayList(usize) = .empty;
    var condition_count: usize = 0;
    const duration_ns: i128 = @intCast(temporal.duration_ns);

    for (entries, 0..) |*entry, idx| {
        if (evaluator.matches(entry, temporal.condition)) {
            condition_count += 1;

            if (entry.timestamp_raw) |ts| {
                if (parseTimestampNs(ts)) |entry_ns| {
                    if (hasAnchorWithin(anchor_timestamps.items, entry_ns, duration_ns)) {
                        try matched.append(allocator, idx);
                    }
                }
            } else {
                // No timestamp — if we can't check temporal proximity,
                // include it if there are any anchors at all (best effort)
                if (anchor_count > 0) {
                    try matched.append(allocator, idx);
                }
            }
        }
    }

    return .{
        .matched_indices = matched.items,
        .anchor_count = anchor_count,
        .condition_count = condition_count,
    };
}

/// Check if any anchor timestamp is within ±window_ns of target_ns.
/// Uses binary search since anchors are sorted.
fn hasAnchorWithin(sorted_anchors: []const i128, target_ns: i128, window_ns: i128) bool {
    if (sorted_anchors.len == 0) return false;

    const low = target_ns - window_ns;
    const high = target_ns + window_ns;

    // Binary search for the first anchor >= low
    var left: usize = 0;
    var right: usize = sorted_anchors.len;
    while (left < right) {
        const mid = left + (right - left) / 2;
        if (sorted_anchors[mid] < low) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }

    // Check if the anchor at `left` is within the window
    if (left < sorted_anchors.len and sorted_anchors[left] <= high) {
        return true;
    }

    return false;
}

// ── Timestamp parsing ───────────────────────────────────────────────

/// Parse a timestamp string into nanoseconds since epoch.
/// Supports ISO 8601 variants:
///   2024-01-15T10:30:00Z
///   2024-01-15T10:30:00.123Z
///   2024-01-15 10:30:00
///   2024-01-15T10:30:00+05:30
pub fn parseTimestampNs(s: []const u8) ?i128 {
    if (s.len < 10) return null;

    // Parse date: YYYY-MM-DD
    const year = parseInt(s[0..4]) orelse return null;
    if (s[4] != '-') return null;
    const month = parseInt(s[5..7]) orelse return null;
    if (s[7] != '-') return null;
    const day = parseInt(s[8..10]) orelse return null;

    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    var hour: i64 = 0;
    var minute: i64 = 0;
    var second: i64 = 0;
    var frac_ns: i64 = 0;
    var pos: usize = 10;

    // Parse time if present: T or space separator
    if (pos < s.len and (s[pos] == 'T' or s[pos] == ' ')) {
        pos += 1;
        if (pos + 8 > s.len) return null;

        hour = parseInt(s[pos..][0..2]) orelse return null;
        if (s[pos + 2] != ':') return null;
        minute = parseInt(s[pos + 3 ..][0..2]) orelse return null;
        if (s[pos + 5] != ':') return null;
        second = parseInt(s[pos + 6 ..][0..2]) orelse return null;
        pos += 8;

        // Fractional seconds
        if (pos < s.len and s[pos] == '.') {
            pos += 1;
            var frac_digits: usize = 0;
            var frac_val: i64 = 0;
            while (pos < s.len and std.ascii.isDigit(s[pos]) and frac_digits < 9) {
                frac_val = frac_val * 10 + @as(i64, s[pos] - '0');
                frac_digits += 1;
                pos += 1;
            }
            // Pad to 9 digits (nanoseconds)
            while (frac_digits < 9) {
                frac_val *= 10;
                frac_digits += 1;
            }
            frac_ns = frac_val;
            // Skip remaining fractional digits
            while (pos < s.len and std.ascii.isDigit(s[pos])) pos += 1;
        }
    }

    // Parse timezone offset (e.g., +05:30, -08:00, Z)
    var tz_offset_seconds: i64 = 0;
    if (pos < s.len) {
        if (s[pos] == 'Z') {
            pos += 1;
            // UTC, offset = 0
        } else if (s[pos] == '+' or s[pos] == '-') {
            const sign: i64 = if (s[pos] == '+') -1 else 1; // subtract for +, add for -
            pos += 1;
            if (pos + 2 > s.len) return null;
            const tz_hour = parseInt(s[pos..][0..2]) orelse return null;
            pos += 2;
            var tz_min: i64 = 0;
            if (pos < s.len and s[pos] == ':') {
                pos += 1;
                if (pos + 2 > s.len) return null;
                tz_min = parseInt(s[pos..][0..2]) orelse return null;
            } else if (pos + 2 <= s.len and std.ascii.isDigit(s[pos])) {
                // Handle +0530 format (no colon)
                tz_min = parseInt(s[pos..][0..2]) orelse return null;
            }
            tz_offset_seconds = sign * (tz_hour * 3600 + tz_min * 60);
        }
    }

    // Convert to epoch nanoseconds
    // Simplified: days since epoch using a basic calculation
    const days = daysSinceEpoch(year, month, day);
    const total_seconds: i128 = @as(i128, days) * 86400 + @as(i128, hour) * 3600 + @as(i128, minute) * 60 + @as(i128, second) + @as(i128, tz_offset_seconds);
    return total_seconds * 1_000_000_000 + @as(i128, frac_ns);
}

/// Calculate days from Unix epoch (1970-01-01) to given date.
fn daysSinceEpoch(year: i64, month: i64, day: i64) i64 {
    // Use a well-known algorithm
    var y = year;
    var m = month;
    if (m <= 2) {
        y -= 1;
        m += 12;
    }
    const era: i64 = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400;
    const doy: i64 = @divFloor(153 * (m - 3) + 2, 5) + day - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn parseInt(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, s, 10) catch return null;
}

fn sortTimestamps(timestamps: []i128) void {
    std.mem.sort(i128, timestamps, {}, std.sort.asc(i128));
}

// ── GROUP BY support ────────────────────────────────────────────────

/// Group entries by field values. Returns a map of group_key → entry indices.
pub fn groupBy(
    allocator: std.mem.Allocator,
    entries: []const LogEntry,
    group_fields: []const ast.FieldRef,
) !GroupResult {
    var groups = GroupResult.init();

    for (entries, 0..) |*entry, idx| {
        const key = try buildGroupKey(allocator, entry, group_fields);
        const gop = try groups.map.getOrPut(allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(allocator, idx);
    }

    return groups;
}

/// Build a group key string from an entry and field references.
fn buildGroupKey(
    allocator: std.mem.Allocator,
    entry: *const LogEntry,
    group_fields: []const ast.FieldRef,
) ![]const u8 {
    if (group_fields.len == 1) {
        // Fast path: single field group — no alloc needed, return directly
        return evaluator.resolveField(entry, group_fields[0]) orelse "(none)";
    }

    // Multi-field: concatenate with |
    var buf: std.ArrayList(u8) = .empty;
    for (group_fields, 0..) |field_ref, i| {
        if (i > 0) try buf.append(allocator, '|');
        const val = evaluator.resolveField(entry, field_ref) orelse "(none)";
        try buf.appendSlice(allocator, val);
    }
    return buf.items;
}

/// Result of GROUP BY operation.
pub const GroupResult = struct {
    map: std.StringHashMapUnmanaged(std.ArrayList(usize)),

    pub fn init() GroupResult {
        return .{
            .map = .empty,
        };
    }

    /// Iterate over groups.
    pub fn iterator(self: *const GroupResult) std.StringHashMapUnmanaged(std.ArrayList(usize)).Iterator {
        return self.map.iterator();
    }

    /// Number of groups.
    pub fn count(self: *const GroupResult) usize {
        return self.map.count();
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "parseTimestampNs basic ISO 8601" {
    const ns = parseTimestampNs("2024-01-15T10:30:00Z").?;
    // Just verify it's a reasonable value and ordering works
    const ns2 = parseTimestampNs("2024-01-15T10:30:05Z").?;
    try std.testing.expect(ns2 > ns);
    try std.testing.expectEqual(@as(i128, 5_000_000_000), ns2 - ns);
}

test "parseTimestampNs with space separator" {
    const ns1 = parseTimestampNs("2024-01-15T10:30:00Z").?;
    const ns2 = parseTimestampNs("2024-01-15 10:30:00").?;
    try std.testing.expectEqual(ns1, ns2);
}

test "parseTimestampNs with fractional seconds" {
    const ns1 = parseTimestampNs("2024-01-15T10:30:00.000Z").?;
    const ns2 = parseTimestampNs("2024-01-15T10:30:00.500Z").?;
    try std.testing.expectEqual(@as(i128, 500_000_000), ns2 - ns1);
}

test "hasAnchorWithin finds match" {
    const anchors = [_]i128{ 100, 200, 300, 400, 500 };
    try std.testing.expect(hasAnchorWithin(&anchors, 250, 60)); // 250 ±60 → [190, 310] → hits 200, 300
    try std.testing.expect(!hasAnchorWithin(&anchors, 250, 10)); // 250 ±10 → [240, 260] → misses
}

test "temporal correlation end-to-end" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const entries = [_]LogEntry{
        .{ .raw = "e1", .level = .warn, .timestamp_raw = "2024-01-15T10:30:00Z" },
        .{ .raw = "e2", .level = .err, .timestamp_raw = "2024-01-15T10:30:03Z" }, // within 5s of warn
        .{ .raw = "e3", .level = .info, .timestamp_raw = "2024-01-15T10:30:05Z" },
        .{ .raw = "e4", .level = .err, .timestamp_raw = "2024-01-15T10:31:00Z" }, // 60s after warn — outside window
    };

    // condition: level = "error", anchor: level = "warn", window: 5s
    const condition = Expr{ .comparison = .{
        .field = .{ .parts = &.{"level"} },
        .op = .eq,
        .value = .{ .string = "ERROR" },
    } };
    const anchor = Expr{ .comparison = .{
        .field = .{ .parts = &.{"level"} },
        .op = .eq,
        .value = .{ .string = "WARN" },
    } };

    const result = try correlate(alloc, &entries, .{
        .condition = &condition,
        .duration_ns = 5_000_000_000, // 5s
        .anchor = &anchor,
    });

    // Only entry[1] (error at +3s) should match — entry[3] (error at +60s) is outside window
    try std.testing.expectEqual(@as(usize, 1), result.matched_indices.len);
    try std.testing.expectEqual(@as(usize, 1), result.matched_indices[0]);
    try std.testing.expectEqual(@as(usize, 1), result.anchor_count);
    try std.testing.expectEqual(@as(usize, 2), result.condition_count);
}

test "groupBy basic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const f1 = [_]log_entry.Field{.{ .key = "request_id", .value = "abc" }};
    const f2 = [_]log_entry.Field{.{ .key = "request_id", .value = "def" }};
    const f3 = [_]log_entry.Field{.{ .key = "request_id", .value = "abc" }};

    const entries = [_]LogEntry{
        .{ .raw = "e1", .fields = &f1 },
        .{ .raw = "e2", .fields = &f2 },
        .{ .raw = "e3", .fields = &f3 },
    };

    const group_fields = [_]ast.FieldRef{
        .{ .parts = &.{"request_id"} },
    };

    const result = try groupBy(alloc, &entries, &group_fields);
    try std.testing.expectEqual(@as(usize, 2), result.count()); // "abc" and "def"
}

test "daysSinceEpoch known dates" {
    // 1970-01-01 = day 0
    try std.testing.expectEqual(@as(i64, 0), daysSinceEpoch(1970, 1, 1));
    // 2000-01-01 = day 10957
    try std.testing.expectEqual(@as(i64, 10957), daysSinceEpoch(2000, 1, 1));
    // 2024-01-15 = day 19737
    try std.testing.expectEqual(@as(i64, 19737), daysSinceEpoch(2024, 1, 15));
}

test "parseTimestampNs with positive timezone offset" {
    // 10:30:00+05:30 is 05:00:00 UTC
    const ns_offset = parseTimestampNs("2024-01-15T10:30:00+05:30").?;
    const ns_utc = parseTimestampNs("2024-01-15T05:00:00Z").?;
    try std.testing.expectEqual(ns_utc, ns_offset);
}

test "parseTimestampNs with negative timezone offset" {
    // 10:30:00-08:00 is 18:30:00 UTC
    const ns_offset = parseTimestampNs("2024-01-15T10:30:00-08:00").?;
    const ns_utc = parseTimestampNs("2024-01-15T18:30:00Z").?;
    try std.testing.expectEqual(ns_utc, ns_offset);
}

test "parseTimestampNs compact timezone offset" {
    // +0530 format (no colon)
    const ns_offset = parseTimestampNs("2024-01-15T10:30:00+0530").?;
    const ns_utc = parseTimestampNs("2024-01-15T05:00:00Z").?;
    try std.testing.expectEqual(ns_utc, ns_offset);
}
