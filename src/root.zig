//! Zeal — A structured log query language + runtime.
//!
//! This is the library root. It re-exports all public modules so consumers
//! can access them via `@import("zeal")`.

pub const ast = @import("ast.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const log_entry = @import("log_entry.zig");
pub const log_reader = @import("log_reader.zig");
pub const log_parser = @import("log_parser.zig");
pub const evaluator = @import("evaluator.zig");
pub const temporal = @import("temporal.zig");
pub const cli = @import("cli.zig");
pub const formatter = @import("formatter.zig");

// Re-export key types at top level for convenience.
pub const Lexer = lexer.Lexer;
pub const Token = lexer.Token;
pub const TokenTag = lexer.TokenTag;
pub const Parser = parser.Parser;
pub const ParseError = parser.ParseError;
pub const Query = ast.Query;
pub const LogEntry = log_entry.LogEntry;
pub const LogLevel = log_entry.LogLevel;
pub const LogFormat = log_entry.LogFormat;
pub const LineIterator = log_reader.LineIterator;

test {
    // Pull in tests from all submodules.
    @import("std").testing.refAllDecls(@This());
}
