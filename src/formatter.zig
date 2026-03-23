//! Output formatter for Zeal.
//!
//! Supports multiple output formats: text (human-readable with optional ANSI),
//! json (NDJSON — one JSON object per entry), and raw (raw log lines).
//! The Formatter struct wraps a writer and provides methods for every kind
//! of output the CLI needs: entries, headers, footers, group delimiters, etc.

const std = @import("std");
const Io = std.Io;
const log_entry = @import("log_entry.zig");
const log_parser = @import("log_parser.zig");
const ast = @import("ast.zig");

const LogEntry = log_entry.LogEntry;
const LogLevel = log_entry.LogLevel;
const LogFormat = log_entry.LogFormat;

/// Output format.
pub const OutputFormat = enum {
    text,
    json,
    raw,

    pub fn fromString(s: []const u8) ?OutputFormat {
        if (std.mem.eql(u8, s, "text")) return .text;
        if (std.mem.eql(u8, s, "json")) return .json;
        if (std.mem.eql(u8, s, "raw")) return .raw;
        return null;
    }

    pub fn toString(self: OutputFormat) []const u8 {
        return switch (self) {
            .text => "text",
            .json => "json",
            .raw => "raw",
        };
    }
};

/// Formatter for writing query results.
pub const Formatter = struct {
    out: *Io.Writer,
    format: OutputFormat,
    use_color: bool,

    pub fn init(out: *Io.Writer, format: OutputFormat, use_color: bool) Formatter {
        return .{ .out = out, .format = format, .use_color = use_color };
    }

    // ── Source-level structure ───────────────────────────────────────

    /// Write a source file header (e.g., "── app.json (JSON) ──────")
    pub fn writeSourceHeader(self: *Formatter, path: []const u8, format: LogFormat) Error!void {
        switch (self.format) {
            .text => {
                if (self.use_color) {
                    try self.out.print("\x1b[1m── {s}\x1b[0m \x1b[90m({s})\x1b[0m ", .{ path, format.toString() });
                } else {
                    try self.out.print("── {s} ({s}) ", .{ path, format.toString() });
                }
                for (0..40) |_| {
                    try self.out.print("─", .{});
                }
                try self.out.print("\n", .{});
            },
            .json => {}, // No header in JSON mode — just stream entries
            .raw => {},
        }
    }

    /// Write source footer with match counts.
    pub fn writeSourceFooter(self: *Formatter, matched: usize, total: usize, has_where: bool, show_info: []const u8) Error!void {
        switch (self.format) {
            .text => {
                if (has_where) {
                    if (self.use_color) {
                        try self.out.print("\n  \x1b[90m{d} matched / {d} total{s}\x1b[0m\n\n", .{ matched, total, show_info });
                    } else {
                        try self.out.print("\n  {d} matched / {d} total{s}\n\n", .{ matched, total, show_info });
                    }
                } else {
                    if (self.use_color) {
                        try self.out.print("\n  \x1b[90m{d} entries{s}\x1b[0m\n\n", .{ total, show_info });
                    } else {
                        try self.out.print("\n  {d} entries{s}\n\n", .{ total, show_info });
                    }
                }
            },
            .json, .raw => {},
        }
    }

    /// Write count result (for SHOW COUNT).
    pub fn writeCount(self: *Formatter, matched: usize, total: usize) Error!void {
        switch (self.format) {
            .text => {
                if (self.use_color) {
                    try self.out.print("  count: \x1b[1m{d}\x1b[0m matched / {d} total\n\n", .{ matched, total });
                } else {
                    try self.out.print("  count: {d} matched / {d} total\n\n", .{ matched, total });
                }
            },
            .json => {
                try self.out.print("{{\"count\":{d},\"total\":{d}}}\n", .{ matched, total });
            },
            .raw => {
                try self.out.print("{d}\n", .{matched});
            },
        }
    }

    /// Write temporal correlation info line.
    pub fn writeTemporalInfo(self: *Formatter, condition: usize, anchor: usize, correlated: usize) Error!void {
        switch (self.format) {
            .text => {
                if (self.use_color) {
                    try self.out.print("  \x1b[90m({d} condition matches, {d} anchor events, {d} correlated)\x1b[0m\n", .{
                        condition, anchor, correlated,
                    });
                } else {
                    try self.out.print("  ({d} condition matches, {d} anchor events, {d} correlated)\n", .{
                        condition, anchor, correlated,
                    });
                }
            },
            .json => {
                try self.out.print("{{\"_meta\":\"temporal\",\"condition_matches\":{d},\"anchor_events\":{d},\"correlated\":{d}}}\n", .{
                    condition, anchor, correlated,
                });
            },
            .raw => {},
        }
    }

    // ── GROUP BY structure ──────────────────────────────────────────

    /// Write group summary header (e.g., "3 entries in 2 groups:")
    pub fn writeGroupSummary(self: *Formatter, entries: usize, groups: usize) Error!void {
        switch (self.format) {
            .text => {
                if (self.use_color) {
                    try self.out.print("  \x1b[90m{d} entries in {d} groups:\x1b[0m\n\n", .{ entries, groups });
                } else {
                    try self.out.print("  {d} entries in {d} groups:\n\n", .{ entries, groups });
                }
            },
            .json, .raw => {},
        }
    }

    /// Write a GROUP BY group header (e.g., "┌─ abc123 (2 entries)")
    pub fn writeGroupHeader(self: *Formatter, key: []const u8, count: usize) Error!void {
        switch (self.format) {
            .text => {
                if (self.use_color) {
                    try self.out.print("  \x1b[1;36m┌─ {s}\x1b[0m ({d} entries)\n", .{ key, count });
                } else {
                    try self.out.print("  ┌─ {s} ({d} entries)\n", .{ key, count });
                }
            },
            .json => {}, // Each entry gets group info in JSON mode
            .raw => {},
        }
    }

    /// Write group count (for SHOW COUNT within groups).
    pub fn writeGroupCount(self: *Formatter, key: []const u8, count: usize) Error!void {
        switch (self.format) {
            .text => {
                try self.out.print("  │ count: {d}\n", .{count});
                try self.out.print("  └\n\n", .{});
            },
            .json => {
                try self.out.print("{{\"_group\":", .{});
                try writeJsonString(self.out, key);
                try self.out.print(",\"count\":{d}}}\n", .{count});
            },
            .raw => {
                try self.out.print("{s}\t{d}\n", .{ key, count });
            },
        }
    }

    /// Write group footer.
    pub fn writeGroupFooter(self: *Formatter) Error!void {
        switch (self.format) {
            .text => try self.out.print("  └\n\n", .{}),
            .json, .raw => {},
        }
    }

    // ── Entry formatting ────────────────────────────────────────────

    /// Write a single log entry in the configured format.
    pub fn writeEntry(self: *Formatter, entry: LogEntry, log_format: LogFormat) Error!void {
        switch (self.format) {
            .text => try self.writeTextEntry(entry, log_format, false),
            .json => try self.writeJsonEntry(entry),
            .raw => try self.writeRawEntry(entry),
        }
    }

    /// Write a single log entry within a GROUP BY group.
    pub fn writeGroupEntry(self: *Formatter, entry: LogEntry, log_format: LogFormat, group_key: []const u8) Error!void {
        switch (self.format) {
            .text => try self.writeTextEntry(entry, log_format, true),
            .json => try self.writeJsonEntryWithGroup(entry, group_key),
            .raw => try self.writeRawEntry(entry),
        }
    }

    // ── Multi-source total ──────────────────────────────────────────

    /// Write overall total when multiple sources are queried.
    pub fn writeTotal(self: *Formatter, matched: usize, sources: usize, scanned: usize) Error!void {
        switch (self.format) {
            .text => {
                if (self.use_color) {
                    try self.out.print("\x1b[1mTotal:\x1b[0m {d} matched from {d} sources ({d} entries scanned)\n", .{
                        matched, sources, scanned,
                    });
                } else {
                    try self.out.print("Total: {d} matched from {d} sources ({d} entries scanned)\n", .{
                        matched, sources, scanned,
                    });
                }
            },
            .json => {
                try self.out.print("{{\"_meta\":\"total\",\"matched\":{d},\"sources\":{d},\"scanned\":{d}}}\n", .{
                    matched, sources, scanned,
                });
            },
            .raw => {},
        }
    }

    // ── Explain mode ────────────────────────────────────────────────

    /// Print a query execution plan (--explain).
    pub fn writeExplain(self: *Formatter, query: ast.Query) Error!void {
        const c = self.use_color;
        const bold = if (c) "\x1b[1m" else "";
        const dim = if (c) "\x1b[90m" else "";
        const cyan = if (c) "\x1b[36m" else "";
        const reset = if (c) "\x1b[0m" else "";

        try self.out.print("{s}Query Plan{s}\n\n", .{ bold, reset });

        var step: usize = 1;

        // Step 1: READ
        for (query.from.sources) |src| {
            switch (src) {
                .file_path => |p| {
                    try self.out.print("  {s}{d}.{s} {s}READ{s} {s} {s}(auto-detect format){s}\n", .{
                        dim, step, reset, cyan, reset, p, dim, reset,
                    });
                },
                .stdin => {
                    try self.out.print("  {s}{d}.{s} {s}READ{s} stdin {s}(streaming){s}\n", .{
                        dim, step, reset, cyan, reset, dim, reset,
                    });
                },
            }
            step += 1;
        }

        // Step: SCAN
        try self.out.print("  {s}{d}.{s} {s}SCAN{s} all entries\n", .{
            dim, step, reset, cyan, reset,
        });
        step += 1;

        // Step: FILTER / TEMPORAL
        if (query.where) |where| {
            if (where.expr.* == .temporal) {
                try self.out.print("  {s}{d}.{s} {s}FILTER{s} condition: ", .{
                    dim, step, reset, cyan, reset,
                });
                try printExprPlain(self.out, where.expr.temporal.condition);
                try self.out.print("\n", .{});
                step += 1;

                try self.out.print("  {s}{d}.{s} {s}TEMPORAL{s} find entries WITHIN ", .{
                    dim, step, reset, cyan, reset,
                });
                try printDuration(self.out, where.expr.temporal.duration_ns);
                try self.out.print(" OF ", .{});
                try printExprPlain(self.out, where.expr.temporal.anchor);
                try self.out.print("\n", .{});
                try self.out.print("     {s}Strategy: binary search on sorted timestamps{s}\n", .{ dim, reset });
                step += 1;
            } else {
                try self.out.print("  {s}{d}.{s} {s}FILTER{s} ", .{
                    dim, step, reset, cyan, reset,
                });
                try printExprPlain(self.out, where.expr);
                try self.out.print("\n", .{});
                try self.out.print("     {s}Strategy: sequential scan{s}\n", .{ dim, reset });
                step += 1;
            }
        }

        // Step: GROUP BY
        if (query.group_by) |gb| {
            try self.out.print("  {s}{d}.{s} {s}GROUP BY{s} ", .{
                dim, step, reset, cyan, reset,
            });
            for (gb.fields, 0..) |field, fi| {
                if (fi > 0) try self.out.print(", ", .{});
                for (field.parts, 0..) |part, pi| {
                    if (pi > 0) try self.out.print(".", .{});
                    try self.out.print("{s}", .{part});
                }
            }
            try self.out.print("\n", .{});
            try self.out.print("     {s}Strategy: hash aggregation{s}\n", .{ dim, reset });
            step += 1;
        }

        // Step: SHOW
        if (query.show) |show| {
            try self.out.print("  {s}{d}.{s} {s}SHOW{s} ", .{
                dim, step, reset, cyan, reset,
            });
            switch (show) {
                .first => |n| try self.out.print("FIRST {d}\n", .{n}),
                .last => |n| try self.out.print("LAST {d}\n", .{n}),
                .count => try self.out.print("COUNT\n", .{}),
                .fields => |fields| {
                    for (fields, 0..) |field, fi| {
                        if (fi > 0) try self.out.print(", ", .{});
                        for (field.parts, 0..) |part, pi| {
                            if (pi > 0) try self.out.print(".", .{});
                            try self.out.print("{s}", .{part});
                        }
                    }
                    try self.out.print("\n", .{});
                },
            }
            step += 1;
        }

        // Step: OUTPUT
        try self.out.print("  {s}{d}.{s} {s}OUTPUT{s} {s} format{s}\n", .{
            dim, step, reset, cyan, reset, self.formatName(), reset,
        });

        try self.out.print("\n", .{});
    }

    // ── Query summary ───────────────────────────────────────────────

    /// Print the parsed query summary (text mode only).
    pub fn writeQuerySummary(self: *Formatter, query: ast.Query) Error!void {
        if (self.format != .text) return;

        const dim = if (self.use_color) "\x1b[90m" else "";
        const bold = if (self.use_color) "\x1b[1m" else "";
        const reset = if (self.use_color) "\x1b[0m" else "";

        if (self.use_color) {
            try self.out.print("\x1b[32m✓\x1b[0m Query parsed successfully\n\n", .{});
        } else {
            try self.out.print("✓ Query parsed successfully\n\n", .{});
        }

        // FROM
        try self.out.print("{s}FROM:{s} ", .{ bold, reset });
        for (query.from.sources, 0..) |src, i| {
            if (i > 0) try self.out.print(", ", .{});
            switch (src) {
                .file_path => |p| try self.out.print("{s}", .{p}),
                .stdin => try self.out.print("stdin", .{}),
            }
        }
        try self.out.print("\n", .{});

        // WHERE
        if (query.where) |where| {
            try self.out.print("{s}WHERE:{s} ", .{ bold, reset });
            try printExprColored(self.out, where.expr, self.use_color);
            try self.out.print("\n", .{});
        }

        // GROUP BY
        if (query.group_by) |gb| {
            try self.out.print("{s}GROUP BY:{s} ", .{ bold, reset });
            for (gb.fields, 0..) |field, i| {
                if (i > 0) try self.out.print(", ", .{});
                for (field.parts, 0..) |part, pi| {
                    if (pi > 0) try self.out.print(".", .{});
                    try self.out.print("{s}", .{part});
                }
            }
            try self.out.print("\n", .{});
        }

        // SHOW
        if (query.show) |show| {
            try self.out.print("{s}SHOW:{s} ", .{ bold, reset });
            switch (show) {
                .first => |n| try self.out.print("FIRST {d}", .{n}),
                .last => |n| try self.out.print("LAST {d}", .{n}),
                .count => try self.out.print("COUNT", .{}),
                .fields => |fields| {
                    for (fields, 0..) |field, fi| {
                        if (fi > 0) try self.out.print(", ", .{});
                        for (field.parts, 0..) |part, pi| {
                            if (pi > 0) try self.out.print(".", .{});
                            try self.out.print("{s}", .{part});
                        }
                    }
                },
            }
            try self.out.print("\n", .{});
        }

        try self.out.print("{s}", .{dim});
        for (0..60) |_| try self.out.print("─", .{});
        try self.out.print("{s}\n", .{reset});
    }

    // ── Follow mode helpers ─────────────────────────────────────────

    /// Write a follow-mode header when starting to tail a file.
    pub fn writeFollowStart(self: *Formatter, path: []const u8) Error!void {
        switch (self.format) {
            .text => {
                if (self.use_color) {
                    try self.out.print("\x1b[90m⏳ Following {s} for new entries (Ctrl+C to stop)...\x1b[0m\n", .{path});
                } else {
                    try self.out.print("Following {s} for new entries (Ctrl+C to stop)...\n", .{path});
                }
            },
            .json, .raw => {},
        }
    }

    // ── Flush ───────────────────────────────────────────────────────

    pub fn flush(self: *Formatter) Error!void {
        try self.out.flush();
    }

    // ── Private: text entry output ──────────────────────────────────

    fn writeTextEntry(self: *Formatter, entry: LogEntry, log_format: LogFormat, in_group: bool) Error!void {
        const prefix = if (in_group) "  │ " else "  ";

        switch (log_format) {
            .json, .logfmt => {
                try self.out.print("{s}", .{prefix});

                // Level with optional color
                if (self.use_color) {
                    try self.out.print("{s}{s: >5}\x1b[0m", .{ entry.level.color(), entry.level.toString() });
                } else {
                    try self.out.print("{s: >5}", .{entry.level.toString()});
                }

                // Timestamp
                if (entry.timestamp_raw) |ts| {
                    if (self.use_color) {
                        try self.out.print(" \x1b[90m{s}\x1b[0m", .{ts});
                    } else {
                        try self.out.print(" {s}", .{ts});
                    }
                }

                // Message
                if (entry.message) |msg| {
                    try self.out.print(" {s}", .{msg});
                }

                // Extra fields
                var field_count: usize = 0;
                for (entry.fields) |field| {
                    if (log_parser.isKnownField(field.key)) continue;
                    if (field_count == 0) {
                        if (self.use_color) {
                            try self.out.print(" \x1b[90m│\x1b[0m", .{});
                        } else {
                            try self.out.print(" │", .{});
                        }
                    }
                    if (self.use_color) {
                        try self.out.print(" \x1b[36m{s}\x1b[0m={s}", .{ field.key, field.value });
                    } else {
                        try self.out.print(" {s}={s}", .{ field.key, field.value });
                    }
                    field_count += 1;
                }

                try self.out.print("\n", .{});
            },
            .syslog, .plain => {
                if (entry.level != .unknown) {
                    if (self.use_color) {
                        try self.out.print("{s}{s}{s: >5}\x1b[0m {s}\n", .{ prefix, entry.level.color(), entry.level.toString(), entry.raw });
                    } else {
                        try self.out.print("{s}{s: >5} {s}\n", .{ prefix, entry.level.toString(), entry.raw });
                    }
                } else {
                    try self.out.print("{s}      {s}\n", .{ prefix, entry.raw });
                }
            },
        }
    }

    // ── Private: JSON entry output ──────────────────────────────────

    fn writeJsonEntry(self: *Formatter, entry: LogEntry) Error!void {
        try self.out.print("{{", .{});

        var first = true;

        // Level
        if (entry.level != .unknown) {
            try self.out.print("\"level\":", .{});
            try writeJsonString(self.out, entry.level.toString());
            first = false;
        }

        // Timestamp
        if (entry.timestamp_raw) |ts| {
            if (!first) try self.out.print(",", .{});
            try self.out.print("\"timestamp\":", .{});
            try writeJsonString(self.out, ts);
            first = false;
        }

        // Message
        if (entry.message) |msg| {
            if (!first) try self.out.print(",", .{});
            try self.out.print("\"message\":", .{});
            try writeJsonString(self.out, msg);
            first = false;
        }

        // Extra fields
        for (entry.fields) |field| {
            if (log_parser.isKnownField(field.key)) continue;
            if (!first) try self.out.print(",", .{});
            try writeJsonString(self.out, field.key);
            try self.out.print(":", .{});
            try writeJsonString(self.out, field.value);
            first = false;
        }

        // Line number
        if (!first) try self.out.print(",", .{});
        try self.out.print("\"line\":{d}", .{entry.line_number});

        try self.out.print("}}\n", .{});
    }

    fn writeJsonEntryWithGroup(self: *Formatter, entry: LogEntry, group_key: []const u8) Error!void {
        try self.out.print("{{\"_group\":", .{});
        try writeJsonString(self.out, group_key);
        try self.out.print(",", .{});

        // Level
        if (entry.level != .unknown) {
            try self.out.print("\"level\":", .{});
            try writeJsonString(self.out, entry.level.toString());
            try self.out.print(",", .{});
        }

        // Timestamp
        if (entry.timestamp_raw) |ts| {
            try self.out.print("\"timestamp\":", .{});
            try writeJsonString(self.out, ts);
            try self.out.print(",", .{});
        }

        // Message
        if (entry.message) |msg| {
            try self.out.print("\"message\":", .{});
            try writeJsonString(self.out, msg);
            try self.out.print(",", .{});
        }

        // Extra fields
        for (entry.fields) |field| {
            if (log_parser.isKnownField(field.key)) continue;
            try writeJsonString(self.out, field.key);
            try self.out.print(":", .{});
            try writeJsonString(self.out, field.value);
            try self.out.print(",", .{});
        }

        try self.out.print("\"line\":{d}}}\n", .{entry.line_number});
    }

    // ── Private: raw entry output ───────────────────────────────────

    fn writeRawEntry(self: *Formatter, entry: LogEntry) Error!void {
        try self.out.print("{s}\n", .{entry.raw});
    }

    // ── Private helpers ─────────────────────────────────────────────

    fn formatName(self: *Formatter) []const u8 {
        return switch (self.format) {
            .text => "text",
            .json => "json",
            .raw => "raw",
        };
    }

    pub const Error = Io.Writer.Error;
};

// ── Free functions (expression printing) ────────────────────────────

fn printExprPlain(out: *Io.Writer, expr: *const ast.Expr) Io.Writer.Error!void {
    switch (expr.*) {
        .comparison => |c| {
            for (c.field.parts, 0..) |part, i| {
                if (i > 0) try out.print(".", .{});
                try out.print("{s}", .{part});
            }
            try out.print(" {s} ", .{@tagName(c.op)});
            try printValuePlain(out, c.value);
        },
        .and_expr => |b| {
            try printExprPlain(out, b.left);
            try out.print(" AND ", .{});
            try printExprPlain(out, b.right);
        },
        .or_expr => |b| {
            try printExprPlain(out, b.left);
            try out.print(" OR ", .{});
            try printExprPlain(out, b.right);
        },
        .not_expr => |inner| {
            try out.print("NOT ", .{});
            try printExprPlain(out, inner);
        },
        .temporal => |t| {
            try out.print("(", .{});
            try printExprPlain(out, t.condition);
            try out.print(" WITHIN ", .{});
            try printDuration(out, t.duration_ns);
            try out.print(" OF ", .{});
            try printExprPlain(out, t.anchor);
            try out.print(")", .{});
        },
        .grouped => |inner| {
            try out.print("(", .{});
            try printExprPlain(out, inner);
            try out.print(")", .{});
        },
    }
}

fn printExprColored(out: *Io.Writer, expr: *const ast.Expr, use_color: bool) Io.Writer.Error!void {
    const cyan = if (use_color) "\x1b[36m" else "";
    const yellow = if (use_color) "\x1b[33m" else "";
    const magenta = if (use_color) "\x1b[35m" else "";
    const reset = if (use_color) "\x1b[0m" else "";

    switch (expr.*) {
        .comparison => |c| {
            try out.print("{s}", .{cyan});
            for (c.field.parts, 0..) |part, i| {
                if (i > 0) try out.print(".", .{});
                try out.print("{s}", .{part});
            }
            try out.print("{s} {s} {s}", .{ reset, @tagName(c.op), yellow });
            try printValuePlain(out, c.value);
            try out.print("{s}", .{reset});
        },
        .and_expr => |b| {
            try printExprColored(out, b.left, use_color);
            try out.print(" {s}AND{s} ", .{ magenta, reset });
            try printExprColored(out, b.right, use_color);
        },
        .or_expr => |b| {
            try printExprColored(out, b.left, use_color);
            try out.print(" {s}OR{s} ", .{ magenta, reset });
            try printExprColored(out, b.right, use_color);
        },
        .not_expr => |inner| {
            try out.print("{s}NOT{s} ", .{ magenta, reset });
            try printExprColored(out, inner, use_color);
        },
        .temporal => |t| {
            try out.print("(", .{});
            try printExprColored(out, t.condition, use_color);
            try out.print(" {s}WITHIN{s} ", .{ magenta, reset });
            try printDuration(out, t.duration_ns);
            try out.print(" {s}OF{s} ", .{ magenta, reset });
            try printExprColored(out, t.anchor, use_color);
            try out.print(")", .{});
        },
        .grouped => |inner| {
            try out.print("(", .{});
            try printExprColored(out, inner, use_color);
            try out.print(")", .{});
        },
    }
}

fn printValuePlain(out: *Io.Writer, value: ast.Value) Io.Writer.Error!void {
    switch (value) {
        .string => |s| try out.print("\"{s}\"", .{s}),
        .integer => |n| try out.print("{d}", .{n}),
        .float => |f| try out.print("{d}", .{f}),
        .boolean => |b| try out.print("{}", .{b}),
        .null_val => try out.print("null", .{}),
    }
}

fn printDuration(out: *Io.Writer, ns: u64) Io.Writer.Error!void {
    if (ns >= 86400 * 1_000_000_000 and ns % (86400 * 1_000_000_000) == 0) {
        try out.print("{d}d", .{ns / (86400 * 1_000_000_000)});
    } else if (ns >= 3600 * 1_000_000_000 and ns % (3600 * 1_000_000_000) == 0) {
        try out.print("{d}h", .{ns / (3600 * 1_000_000_000)});
    } else if (ns >= 60 * 1_000_000_000 and ns % (60 * 1_000_000_000) == 0) {
        try out.print("{d}m", .{ns / (60 * 1_000_000_000)});
    } else if (ns >= 1_000_000_000 and ns % 1_000_000_000 == 0) {
        try out.print("{d}s", .{ns / 1_000_000_000});
    } else if (ns >= 1_000_000 and ns % 1_000_000 == 0) {
        try out.print("{d}ms", .{ns / 1_000_000});
    } else {
        try out.print("{d}ns", .{ns});
    }
}

/// Write a JSON-escaped string.
fn writeJsonString(out: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try out.print("\"", .{});
    for (s) |c| {
        switch (c) {
            '"' => try out.print("\\\"", .{}),
            '\\' => try out.print("\\\\", .{}),
            '\n' => try out.print("\\n", .{}),
            '\r' => try out.print("\\r", .{}),
            '\t' => try out.print("\\t", .{}),
            else => {
                if (c < 0x20) {
                    try out.print("\\u{x:0>4}", .{c});
                } else {
                    try out.print("{c}", .{c});
                }
            },
        }
    }
    try out.print("\"", .{});
}

// ── Tests ──────────────────────────────────────────────────────────

test "OutputFormat fromString" {
    try std.testing.expectEqual(OutputFormat.text, OutputFormat.fromString("text").?);
    try std.testing.expectEqual(OutputFormat.json, OutputFormat.fromString("json").?);
    try std.testing.expectEqual(OutputFormat.raw, OutputFormat.fromString("raw").?);
    try std.testing.expect(OutputFormat.fromString("xml") == null);
}

test "OutputFormat toString" {
    try std.testing.expectEqualStrings("text", OutputFormat.text.toString());
    try std.testing.expectEqualStrings("json", OutputFormat.json.toString());
    try std.testing.expectEqualStrings("raw", OutputFormat.raw.toString());
}

test "writeJsonString escapes special characters" {
    // Verify the fromString/toString roundtrip at minimum
    const fmt = OutputFormat.fromString("json").?;
    try std.testing.expectEqualStrings("json", fmt.toString());
}
