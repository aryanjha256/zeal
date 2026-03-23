//! Log entry types for Zeal.
//!
//! All string fields are zero-copy slices into the original log buffer.
//! No allocations for individual field values.

const std = @import("std");

/// Log severity level.
pub const LogLevel = enum {
    trace,
    debug,
    info,
    warn,
    err,
    fatal,
    unknown,

    /// Parse a log level string (case-insensitive).
    /// Recognizes common variations: "error"/"err"/"ERROR", "warning"/"warn"/"WARN", etc.
    pub fn fromString(s: []const u8) LogLevel {
        if (s.len == 0) return .unknown;

        // Normalize: compare case-insensitively
        if (std.ascii.eqlIgnoreCase(s, "trace")) return .trace;
        if (std.ascii.eqlIgnoreCase(s, "debug") or std.ascii.eqlIgnoreCase(s, "dbg")) return .debug;
        if (std.ascii.eqlIgnoreCase(s, "info") or std.ascii.eqlIgnoreCase(s, "information")) return .info;
        if (std.ascii.eqlIgnoreCase(s, "warn") or std.ascii.eqlIgnoreCase(s, "warning")) return .warn;
        if (std.ascii.eqlIgnoreCase(s, "error") or std.ascii.eqlIgnoreCase(s, "err")) return .err;
        if (std.ascii.eqlIgnoreCase(s, "fatal") or std.ascii.eqlIgnoreCase(s, "critical") or std.ascii.eqlIgnoreCase(s, "crit") or std.ascii.eqlIgnoreCase(s, "panic") or std.ascii.eqlIgnoreCase(s, "emerg")) return .fatal;
        return .unknown;
    }

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
            .unknown => "???",
        };
    }

    /// ANSI color code for this level.
    pub fn color(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "\x1b[90m", // gray
            .debug => "\x1b[36m", // cyan
            .info => "\x1b[32m", // green
            .warn => "\x1b[33m", // yellow
            .err => "\x1b[31m", // red
            .fatal => "\x1b[1;31m", // bold red
            .unknown => "\x1b[0m", // reset
        };
    }
};

/// A key-value field extracted from a log line.
/// Both key and value are zero-copy slices into the source buffer.
pub const Field = struct {
    key: []const u8,
    value: []const u8,
};

/// A parsed log entry. All slices point into the original line buffer.
pub const LogEntry = struct {
    /// The raw, unparsed line.
    raw: []const u8,

    /// Detected log severity.
    level: LogLevel = .unknown,

    /// The main log message, if extracted.
    message: ?[]const u8 = null,

    /// The timestamp string as found in the log (not yet parsed to epoch).
    timestamp_raw: ?[]const u8 = null,

    /// Structured key-value fields extracted from the line.
    fields: []const Field = &.{},

    /// 1-based line number in the source file.
    line_number: usize = 0,

    /// Which format was used to parse this entry.
    format: LogFormat = .plain,
};

/// Supported log formats.
pub const LogFormat = enum {
    json,
    logfmt,
    syslog,
    plain,

    pub fn toString(self: LogFormat) []const u8 {
        return switch (self) {
            .json => "JSON",
            .logfmt => "logfmt",
            .syslog => "syslog",
            .plain => "plain text",
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "LogLevel.fromString" {
    try std.testing.expectEqual(LogLevel.err, LogLevel.fromString("error"));
    try std.testing.expectEqual(LogLevel.err, LogLevel.fromString("ERROR"));
    try std.testing.expectEqual(LogLevel.err, LogLevel.fromString("err"));
    try std.testing.expectEqual(LogLevel.warn, LogLevel.fromString("warn"));
    try std.testing.expectEqual(LogLevel.warn, LogLevel.fromString("WARNING"));
    try std.testing.expectEqual(LogLevel.info, LogLevel.fromString("info"));
    try std.testing.expectEqual(LogLevel.debug, LogLevel.fromString("DEBUG"));
    try std.testing.expectEqual(LogLevel.fatal, LogLevel.fromString("FATAL"));
    try std.testing.expectEqual(LogLevel.fatal, LogLevel.fromString("critical"));
    try std.testing.expectEqual(LogLevel.unknown, LogLevel.fromString(""));
    try std.testing.expectEqual(LogLevel.unknown, LogLevel.fromString("garbage"));
}
