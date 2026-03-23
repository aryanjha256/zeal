//! CLI argument parser for Zeal.
//!
//! Parses command-line arguments into a Config struct.
//! Supports flags like --format, --no-color, --follow, --explain,
//! -f/--file for file sources, and positional query arguments.

const std = @import("std");
const formatter = @import("formatter.zig");

/// Output format for displaying results (re-exported from formatter).
pub const OutputFormat = formatter.OutputFormat;

/// Color output mode.
pub const ColorMode = enum {
    auto,
    always,
    never,
};

/// Parsed CLI configuration.
pub const Config = struct {
    /// The query string (positional argument).
    query: ?[]const u8 = null,

    /// File paths provided via -f/--file flags.
    files: []const []const u8 = &.{},

    /// Output format: text (default), json, raw.
    format: OutputFormat = .text,

    /// Color mode: auto-detect TTY, force on, or force off.
    color: ColorMode = .auto,

    /// Follow mode: tail the file for new entries.
    follow: bool = false,

    /// Explain mode: show query plan without executing.
    explain: bool = false,

    /// User asked for --help.
    show_help: bool = false,

    /// User asked for --version.
    show_version: bool = false,

    /// Parse error message (set when args are invalid).
    err_msg: ?[]const u8 = null,
};

/// Parse command-line arguments into a Config.
/// `args` should include the program name at index 0.
pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) error{OutOfMemory}!Config {
    var config: Config = .{};
    var files: std.ArrayList([]const u8) = .empty;

    var i: usize = 1; // skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            config.show_help = true;
            return config;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            config.show_version = true;
            return config;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= args.len) {
                config.err_msg = "-f/--file requires a file path";
                return config;
            }
            try files.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) {
                config.err_msg = "--format requires a value (text, json, raw)";
                return config;
            }
            config.format = OutputFormat.fromString(args[i]) orelse {
                config.err_msg = "unknown format — use: text, json, raw";
                return config;
            };
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            config.color = .never;
        } else if (std.mem.eql(u8, arg, "--color")) {
            i += 1;
            if (i >= args.len) {
                config.err_msg = "--color requires a value (auto, always, never)";
                return config;
            }
            if (std.mem.eql(u8, args[i], "auto")) {
                config.color = .auto;
            } else if (std.mem.eql(u8, args[i], "always")) {
                config.color = .always;
            } else if (std.mem.eql(u8, args[i], "never")) {
                config.color = .never;
            } else {
                config.err_msg = "unknown color mode — use: auto, always, never";
                return config;
            }
        } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--follow")) {
            config.follow = true;
        } else if (std.mem.eql(u8, arg, "--explain")) {
            config.explain = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            config.err_msg = "unknown option";
            return config;
        } else {
            // Positional argument = query string
            config.query = arg;
        }
    }

    config.files = files.items;
    return config;
}

// ── Tests ──────────────────────────────────────────────────────────

test "parse help flag" {
    const config = try parseArgs(std.testing.allocator, &.{ "zeal", "--help" });
    try std.testing.expect(config.show_help);
}

test "parse version flag" {
    const config = try parseArgs(std.testing.allocator, &.{ "zeal", "--version" });
    try std.testing.expect(config.show_version);
}

test "parse basic query" {
    const config = try parseArgs(std.testing.allocator, &.{
        "zeal", "FROM /var/log/app.log WHERE level = \"error\"",
    });
    try std.testing.expect(config.query != null);
    try std.testing.expectEqual(OutputFormat.text, config.format);
    try std.testing.expectEqual(ColorMode.auto, config.color);
    try std.testing.expect(!config.follow);
    try std.testing.expect(!config.explain);
}

test "parse file flag with format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const config = try parseArgs(alloc, &.{
        "zeal", "-f", "/var/log/app.log", "--format", "json", "WHERE level = \"error\"",
    });
    try std.testing.expectEqual(@as(usize, 1), config.files.len);
    try std.testing.expectEqualStrings("/var/log/app.log", config.files[0]);
    try std.testing.expectEqual(OutputFormat.json, config.format);
    try std.testing.expect(config.query != null);
}

test "parse no-color and follow" {
    const config = try parseArgs(std.testing.allocator, &.{
        "zeal", "--no-color", "-F", "FROM /tmp/a.log",
    });
    try std.testing.expectEqual(ColorMode.never, config.color);
    try std.testing.expect(config.follow);
}

test "parse explain flag" {
    const config = try parseArgs(std.testing.allocator, &.{
        "zeal", "--explain", "FROM /tmp/a.log WHERE level = \"error\"",
    });
    try std.testing.expect(config.explain);
    try std.testing.expect(config.query != null);
}

test "missing file value" {
    const config = try parseArgs(std.testing.allocator, &.{ "zeal", "-f" });
    try std.testing.expect(config.err_msg != null);
}

test "unknown format" {
    const config = try parseArgs(std.testing.allocator, &.{ "zeal", "--format", "xml" });
    try std.testing.expect(config.err_msg != null);
}
