//! Zeal CLI — structured log query language.
//!
//! Usage:  zeal [options] '<query>'
//!         zeal -f <file> [options] '<query>'

const std = @import("std");
const Io = std.Io;
const zeal = @import("zeal");

const version = "0.1.0";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_fw.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const err_out = &stderr_fw.interface;

    // ── Parse CLI arguments ─────────────────────────────────────────

    const config = try zeal.cli.parseArgs(arena, args);

    if (config.show_help) {
        try printUsage(out);
        try out.flush();
        return;
    }

    if (config.show_version) {
        try out.print("zeal {s}\n", .{version});
        try out.flush();
        return;
    }

    if (config.err_msg) |msg| {
        try err_out.print("error: {s}\n", .{msg});
        try err_out.print("Try 'zeal --help' for usage.\n", .{});
        try err_out.flush();
        std.process.exit(1);
    }

    if (config.query == null and config.files.len == 0) {
        try printUsage(out);
        try out.flush();
        return;
    }

    // ── Determine color mode ────────────────────────────────────────
    // When outputting JSON or raw, default to no color.

    const use_color = switch (config.color) {
        .auto => blk: {
            if (config.format != .text) break :blk false;
            const is_tty = Io.File.isTty(.stdout(), io) catch false;
            break :blk is_tty;
        },
        .always => true,
        .never => false,
    };

    // ── Create formatter ────────────────────────────────────────────

    var fmtr = zeal.formatter.Formatter.init(out, config.format, use_color);

    // ── Parse query ─────────────────────────────────────────────────
    // If no query provided but files given via -f, use a minimal query.

    const query_str: []const u8 = config.query orelse blk: {
        // Build a synthetic FROM query from -f files
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(arena, "FROM ");
        for (config.files, 0..) |f, i| {
            if (i > 0) try buf.appendSlice(arena, ", ");
            try buf.appendSlice(arena, f);
        }
        break :blk buf.items;
    };

    var parser = zeal.Parser.init(arena, query_str);
    const parsed_query = parser.parse() catch |e| {
        const msg = switch (e) {
            error.UnexpectedToken => "unexpected token",
            error.InvalidDuration => "invalid duration (use: 5s, 100ms, 2m, 1h, 1d)",
            error.ExpectedExpression => "expected an expression",
            error.ExpectedFieldRef => "expected a field name (e.g., level, request.id)",
            error.ExpectedValue => "expected a value (string, number, true, false, null)",
            error.ExpectedSource => "expected a source (file path or stdin)",
            error.OutOfMemory => "out of memory",
        };

        if (use_color) {
            try err_out.print("\x1b[1;31merror:\x1b[0m {s}\n", .{msg});
            try err_out.print("  \x1b[90m│\x1b[0m {s}\n", .{query_str});
            try err_out.print("  \x1b[90m│\x1b[0m ", .{});
        } else {
            try err_out.print("error: {s}\n", .{msg});
            try err_out.print("  │ {s}\n", .{query_str});
            try err_out.print("  │ ", .{});
        }
        for (0..parser.current.pos) |_| {
            try err_out.print(" ", .{});
        }
        if (use_color) {
            try err_out.print("\x1b[1;31m^\x1b[0m\n", .{});
        } else {
            try err_out.print("^\n", .{});
        }
        // Show what was found vs expected
        if (parser.current.lexeme.len > 0 and parser.current.tag != .eof) {
            if (use_color) {
                try err_out.print("  \x1b[90m│\x1b[0m found: \x1b[33m{s}\x1b[0m ({s})\n", .{ parser.current.lexeme, @tagName(parser.current.tag) });
            } else {
                try err_out.print("  │ found: {s} ({s})\n", .{ parser.current.lexeme, @tagName(parser.current.tag) });
            }
        } else if (parser.current.tag == .eof) {
            if (use_color) {
                try err_out.print("  \x1b[90m│\x1b[0m found: \x1b[33mend of query\x1b[0m\n", .{});
            } else {
                try err_out.print("  │ found: end of query\n", .{});
            }
        }
        try err_out.flush();
        std.process.exit(1);
    };

    // Merge -f files into the query's FROM sources
    var query = parsed_query;
    if (config.files.len > 0) {
        var sources: std.ArrayList(zeal.ast.Source) = .empty;
        for (query.from.sources) |s| {
            try sources.append(arena, s);
        }
        for (config.files) |f| {
            // Avoid duplicates
            var dup = false;
            for (sources.items) |existing| {
                switch (existing) {
                    .file_path => |p| {
                        if (std.mem.eql(u8, p, f)) {
                            dup = true;
                            break;
                        }
                    },
                    .stdin => {},
                }
            }
            if (!dup) try sources.append(arena, .{ .file_path = f });
        }
        query.from.sources = sources.items;
    }

    // ── Explain mode ────────────────────────────────────────────────

    if (config.explain) {
        try fmtr.writeExplain(query);
        try fmtr.flush();
        return;
    }

    // ── Print query summary (text mode only) ────────────────────────

    try fmtr.writeQuerySummary(query);

    // ── Execute query ───────────────────────────────────────────────

    var total_entries: usize = 0;
    var total_matched: usize = 0;

    for (query.from.sources) |src| {
        switch (src) {
            .file_path => |path| {
                const matched = try executeSource(
                    arena,
                    io,
                    path,
                    query,
                    &fmtr,
                    err_out,
                );
                total_entries += matched.total;
                total_matched += matched.matched;
            },
            .stdin => {
                try err_out.print("error: stdin reading not yet supported (use file paths)\n", .{});
                try err_out.flush();
            },
        }
    }

    // Multi-source total
    if (query.from.sources.len > 1) {
        try fmtr.writeTotal(total_matched, query.from.sources.len, total_entries);
    }

    try fmtr.flush();

    // ── Follow mode ─────────────────────────────────────────────────

    if (config.follow and query.from.sources.len == 1) {
        switch (query.from.sources[0]) {
            .file_path => |path| {
                try followFile(arena, io, path, query, &fmtr, err_out, total_entries);
            },
            .stdin => {},
        }
    }
}

// ── Source execution ─────────────────────────────────────────────────

const SourceResult = struct {
    matched: usize,
    total: usize,
};

fn executeSource(
    arena: std.mem.Allocator,
    io: Io,
    path: []const u8,
    query: zeal.Query,
    fmtr: *zeal.formatter.Formatter,
    err_out: *Io.Writer,
) !SourceResult {
    const content = zeal.log_reader.readFileAlloc(arena, io, path) catch |e| {
        try err_out.print("error: {s}: {s}\n", .{
            zeal.log_reader.readErrorMessage(e),
            path,
        });
        try err_out.flush();
        return .{ .matched = 0, .total = 0 };
    };

    // Detect format
    var detect_iter = zeal.LineIterator.init(content);
    const first_line = detect_iter.next() orelse {
        try fmtr.out.print("  (empty file: {s})\n", .{path});
        return .{ .matched = 0, .total = 0 };
    };
    const log_format = zeal.log_parser.detectFormat(first_line);

    try fmtr.writeSourceHeader(path, log_format);

    // Parse all lines
    var all_entries: std.ArrayList(zeal.LogEntry) = .empty;
    var line_iter = zeal.LineIterator.init(content);
    while (line_iter.next()) |line| {
        const entry = zeal.log_parser.parseLine(
            arena,
            line,
            log_format,
            line_iter.currentLineNumber(),
        ) catch {
            try all_entries.append(arena, .{
                .raw = line,
                .line_number = line_iter.currentLineNumber(),
                .message = line,
            });
            continue;
        };
        try all_entries.append(arena, entry);
    }

    // Apply WHERE filter
    var filtered: std.ArrayList(zeal.LogEntry) = .empty;

    if (query.where) |where| {
        if (where.expr.* == .temporal) {
            const result = try zeal.temporal.correlate(
                arena,
                all_entries.items,
                where.expr.temporal,
            );
            for (result.matched_indices) |idx| {
                try filtered.append(arena, all_entries.items[idx]);
            }
            try fmtr.writeTemporalInfo(result.condition_count, result.anchor_count, result.matched_indices.len);
        } else {
            for (all_entries.items) |*entry| {
                if (zeal.evaluator.matches(entry, where.expr)) {
                    try filtered.append(arena, entry.*);
                }
            }
        }
    } else {
        for (all_entries.items) |entry| {
            try filtered.append(arena, entry);
        }
    }

    var matched_count: usize = 0;

    // GROUP BY
    if (query.group_by) |gb| {
        const groups = try zeal.temporal.groupBy(
            arena,
            filtered.items,
            gb.fields,
        );

        try fmtr.writeGroupSummary(filtered.items.len, groups.count());

        var group_iter = groups.iterator();
        while (group_iter.next()) |kv| {
            const group_key = kv.key_ptr.*;
            const indices = kv.value_ptr.items;

            try fmtr.writeGroupHeader(group_key, indices.len);

            // Apply SHOW limits within each group
            var group_entries = indices;
            if (query.show) |show| {
                switch (show) {
                    .first => |n| {
                        if (n < group_entries.len) group_entries = group_entries[0..n];
                    },
                    .last => |n| {
                        if (n < group_entries.len) group_entries = group_entries[group_entries.len - n ..];
                    },
                    .count => {
                        try fmtr.writeGroupCount(group_key, indices.len);
                        matched_count += indices.len;
                        continue;
                    },
                    .fields => {},
                }
            }

            for (group_entries) |idx| {
                try fmtr.writeGroupEntry(filtered.items[idx], log_format, group_key);
            }
            try fmtr.writeGroupFooter();
            matched_count += indices.len;
        }
    } else {
        // No GROUP BY — apply SHOW limits and display
        var display_entries = filtered.items;
        var show_info: []const u8 = "";
        if (query.show) |show| {
            switch (show) {
                .first => |n| {
                    if (n < display_entries.len) {
                        display_entries = display_entries[0..n];
                        show_info = " (showing first)";
                    }
                },
                .last => |n| {
                    if (n < display_entries.len) {
                        display_entries = display_entries[display_entries.len - n ..];
                        show_info = " (showing last)";
                    }
                },
                .count => {
                    try fmtr.writeCount(filtered.items.len, all_entries.items.len);
                    return .{ .matched = filtered.items.len, .total = all_entries.items.len };
                },
                .fields => {},
            }
        }

        for (display_entries) |entry| {
            try fmtr.writeEntry(entry, log_format);
        }

        matched_count = display_entries.len;
        try fmtr.writeSourceFooter(filtered.items.len, all_entries.items.len, query.where != null, show_info);
    }

    try fmtr.flush();
    return .{ .matched = matched_count, .total = all_entries.items.len };
}

// ── Follow mode ─────────────────────────────────────────────────────

fn followFile(
    _: std.mem.Allocator,
    io: Io,
    path: []const u8,
    query: zeal.Query,
    fmtr: *zeal.formatter.Formatter,
    _: *Io.Writer,
    initial_entries: usize,
) !void {
    try fmtr.writeFollowStart(path);
    try fmtr.flush();

    var last_size: u64 = blk: {
        const dir = Io.Dir.cwd();
        const file = dir.openFile(io, path, .{}) catch return;
        defer file.close(io);
        const stat = file.stat(io) catch return;
        break :blk stat.size;
    };

    var line_number: usize = initial_entries;

    while (true) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake) catch {}; // 200ms

        // Check file size
        const dir = Io.Dir.cwd();
        const file = dir.openFile(io, path, .{}) catch continue;

        const stat = file.stat(io) catch {
            file.close(io);
            continue;
        };

        if (stat.size <= last_size) {
            if (stat.size < last_size) {
                // File was truncated (log rotation) — reset
                last_size = 0;
            } else {
                file.close(io);
                continue;
            }
        }

        // Read only the new content (from last_size to current size)
        const new_size: usize = @intCast(stat.size - last_size);
        var follow_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

        const fa = follow_arena.allocator();

        const new_content = fa.alloc(u8, new_size) catch {
            follow_arena.deinit();
            file.close(io);
            continue;
        };

        // Skip past already-processed bytes
        var read_buf: [8192]u8 = undefined;
        var reader = Io.File.Reader.init(file, io, &read_buf);
        const off: usize = @intCast(last_size);
        var skipped: usize = 0;
        while (skipped < off) {
            const skip_len = @min(off - skipped, read_buf.len);
            const n = reader.interface.readSliceShort(read_buf[0..skip_len]) catch break;
            if (n == 0) break;
            skipped += n;
        }

        // Read new bytes
        var total_read: usize = 0;
        while (total_read < new_size) {
            const n = reader.interface.readSliceShort(new_content[total_read..]) catch break;
            if (n == 0) break;
            total_read += n;
        }

        file.close(io);
        last_size = stat.size;

        if (total_read == 0) {
            follow_arena.deinit();
            continue;
        }
        const content = new_content[0..total_read];

        // Detect format from first line of new content
        var detect_iter = zeal.LineIterator.init(content);
        const first_new = detect_iter.next() orelse {
            follow_arena.deinit();
            continue;
        };
        const log_format = zeal.log_parser.detectFormat(first_new);

        // Parse and filter new entries
        var iter = zeal.LineIterator.init(content);
        while (iter.next()) |line| {
            line_number += 1;
            const entry = zeal.log_parser.parseLine(fa, line, log_format, line_number) catch continue;

            // Apply WHERE filter
            if (query.where) |where| {
                if (where.expr.* == .temporal) {
                    // Temporal correlation not supported in follow mode — just match condition
                    if (!zeal.evaluator.matches(&entry, where.expr.temporal.condition)) continue;
                } else {
                    if (!zeal.evaluator.matches(&entry, where.expr)) continue;
                }
            }

            try fmtr.writeEntry(entry, log_format);
        }

        try fmtr.flush();
        follow_arena.deinit();
    }
}

// ── Usage ───────────────────────────────────────────────────────────

fn printUsage(out: *Io.Writer) Io.Writer.Error!void {
    try out.print(
        \\zeal — query your logs like a database
        \\
        \\Usage:
        \\  zeal '<query>'
        \\  zeal -f <file> [options] '<query>'
        \\
        \\Options:
        \\  -h, --help            Show this help
        \\  -V, --version         Show version
        \\  -f, --file <path>     Log file (alternative to FROM clause)
        \\  --format <fmt>        Output: text (default), json, raw
        \\  --no-color            Disable color output
        \\  --color <mode>        auto (default), always, never
        \\  -F, --follow          Tail file for new entries (like tail -f)
        \\  --explain             Show query plan without executing
        \\
        \\Query syntax:
        \\  FROM <source>, ...     Log source (file path)
        \\  WHERE <expr>           Filter expression
        \\  WITHIN <dur> OF <expr> Temporal correlation
        \\  GROUP BY <field>, ...  Group results by field
        \\  SHOW LAST|FIRST <n>    Limit output
        \\  SHOW COUNT             Count matches
        \\
        \\Operators: = != > < >= <= CONTAINS
        \\Durations: ms, s, m, h, d
        \\
        \\Examples:
        \\  zeal 'FROM app.json WHERE level = "error"'
        \\  zeal 'FROM app.json WHERE level = "error" WITHIN 5s OF level = "warn"'
        \\  zeal 'FROM app.json WHERE status >= 500 GROUP BY path SHOW COUNT'
        \\  zeal -f app.json --format json 'WHERE level = "error"'
        \\  zeal -f app.log --follow 'WHERE level = "error"'
        \\
        \\Docs: https://github.com/aryanjha256/zeal
        \\
    , .{});
}
