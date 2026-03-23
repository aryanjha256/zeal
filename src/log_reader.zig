//! Log file reader for Zeal.
//!
//! Reads log files into memory and provides zero-copy line iteration.
//! Uses the Zig 0.16 Io-based file API.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;

/// Maximum file size we'll read (256 MB). Prevents OOM on huge files.
pub const MAX_FILE_SIZE: usize = 256 * 1024 * 1024;

/// Zero-copy line iterator over a buffer.
/// Lines are returned as slices into the original buffer (no allocations).
pub const LineIterator = struct {
    buffer: []const u8,
    pos: usize = 0,
    line_number: usize = 0,

    pub fn init(buffer: []const u8) LineIterator {
        return .{ .buffer = buffer };
    }

    /// Returns the next line (without trailing \n or \r\n), or null at EOF.
    pub fn next(self: *LineIterator) ?[]const u8 {
        while (true) {
            if (self.pos >= self.buffer.len) return null;

            const start = self.pos;
            // Find end of line
            while (self.pos < self.buffer.len and self.buffer[self.pos] != '\n') {
                self.pos += 1;
            }

            var end = self.pos;
            // Strip trailing \r (for \r\n line endings)
            if (end > start and self.buffer[end - 1] == '\r') {
                end -= 1;
            }

            // Skip the \n
            if (self.pos < self.buffer.len) {
                self.pos += 1;
            }

            self.line_number += 1;

            // Skip empty lines
            const line = self.buffer[start..end];
            if (line.len == 0) continue;

            return line;
        }
    }

    /// Current 1-based line number (of the last returned line).
    pub fn currentLineNumber(self: *const LineIterator) usize {
        return self.line_number;
    }

    /// Reset to beginning.
    pub fn reset(self: *LineIterator) void {
        self.pos = 0;
        self.line_number = 0;
    }
};

pub const ReadError = error{
    FileNotFound,
    AccessDenied,
    FileTooLarge,
    ReadFailed,
    OutOfMemory,
};

/// Read an entire file into an allocated buffer using the Zig 0.16 Io API.
/// The returned slice is owned by the allocator.
pub fn readFileAlloc(allocator: std.mem.Allocator, io: Io, path: []const u8) ReadError![]const u8 {
    const dir = Dir.cwd();
    const file = dir.openFile(io, path, .{}) catch |e| {
        return switch (e) {
            error.FileNotFound => error.FileNotFound,
            error.AccessDenied => error.AccessDenied,
            else => error.ReadFailed,
        };
    };
    defer file.close(io);

    const stat = file.stat(io) catch return error.ReadFailed;
    const size: usize = @intCast(stat.size);

    if (size > MAX_FILE_SIZE) return error.FileTooLarge;
    if (size == 0) {
        const empty = allocator.alloc(u8, 0) catch return error.OutOfMemory;
        return empty;
    }

    const content = allocator.alloc(u8, size) catch return error.OutOfMemory;

    // Use File.Reader to read the file contents
    var read_buf: [8192]u8 = undefined;
    var reader = File.Reader.init(file, io, &read_buf);
    var total_read: usize = 0;
    while (total_read < size) {
        const n = reader.interface.readSliceShort(content[total_read..]) catch return error.ReadFailed;
        if (n == 0) break; // EOF
        total_read += n;
    }
    return content[0..total_read];
}

/// Error name for user-facing messages.
pub fn readErrorMessage(err: ReadError) []const u8 {
    return switch (err) {
        error.FileNotFound => "file not found",
        error.AccessDenied => "permission denied",
        error.FileTooLarge => "file exceeds 256 MB limit",
        error.ReadFailed => "failed to read file",
        error.OutOfMemory => "out of memory",
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "LineIterator basic" {
    var iter = LineIterator.init("line one\nline two\nline three\n");
    const l1 = iter.next().?;
    try std.testing.expectEqualStrings("line one", l1);
    try std.testing.expectEqual(@as(usize, 1), iter.currentLineNumber());

    const l2 = iter.next().?;
    try std.testing.expectEqualStrings("line two", l2);

    const l3 = iter.next().?;
    try std.testing.expectEqualStrings("line three", l3);

    try std.testing.expect(iter.next() == null);
}

test "LineIterator handles CRLF" {
    var iter = LineIterator.init("first\r\nsecond\r\n");
    try std.testing.expectEqualStrings("first", iter.next().?);
    try std.testing.expectEqualStrings("second", iter.next().?);
    try std.testing.expect(iter.next() == null);
}

test "LineIterator skips empty lines" {
    var iter = LineIterator.init("first\n\n\nsecond\n");
    try std.testing.expectEqualStrings("first", iter.next().?);
    try std.testing.expectEqualStrings("second", iter.next().?);
    try std.testing.expect(iter.next() == null);
}

test "LineIterator no trailing newline" {
    var iter = LineIterator.init("only line");
    try std.testing.expectEqualStrings("only line", iter.next().?);
    try std.testing.expect(iter.next() == null);
}

test "LineIterator reset" {
    var iter = LineIterator.init("a\nb\n");
    _ = iter.next();
    _ = iter.next();
    iter.reset();
    try std.testing.expectEqualStrings("a", iter.next().?);
}
