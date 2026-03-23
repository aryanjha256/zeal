//! AST node types for the Zeal query language.
//!
//! All slices point into the original query source string (zero-copy).
//! Nodes are allocated via an arena allocator and never individually freed.

const std = @import("std");

/// A complete Zeal query.
pub const Query = struct {
    from: FromClause,
    where: ?WhereClause = null,
    group_by: ?GroupByClause = null,
    show: ?ShowClause = null,
};

/// FROM source1, source2, ...
pub const FromClause = struct {
    sources: []const Source,
};

/// A log source — either a file path or stdin.
pub const Source = union(enum) {
    file_path: []const u8,
    stdin,
};

/// WHERE expr
pub const WhereClause = struct {
    expr: *const Expr,
};

/// Expression node — the core of the WHERE clause.
pub const Expr = union(enum) {
    comparison: Comparison,
    and_expr: BinaryExpr,
    or_expr: BinaryExpr,
    not_expr: *const Expr,
    temporal: TemporalExpr,
    grouped: *const Expr,

    pub fn format(self: Expr, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try formatExpr(self, writer);
    }

    fn formatExpr(expr: Expr, writer: anytype) !void {
        switch (expr) {
            .comparison => |c| {
                try formatFieldRef(c.field, writer);
                try writer.print(" {s} ", .{@tagName(c.op)});
                try formatValue(c.value, writer);
            },
            .and_expr => |b| {
                try formatExpr(b.left.*, writer);
                try writer.writeAll(" AND ");
                try formatExpr(b.right.*, writer);
            },
            .or_expr => |b| {
                try formatExpr(b.left.*, writer);
                try writer.writeAll(" OR ");
                try formatExpr(b.right.*, writer);
            },
            .not_expr => |inner| {
                try writer.writeAll("NOT ");
                try formatExpr(inner.*, writer);
            },
            .temporal => |t| {
                try writer.writeAll("(");
                try formatExpr(t.condition.*, writer);
                try writer.writeAll(" WITHIN ");
                try formatDuration(t.duration_ns, writer);
                try writer.writeAll(" OF ");
                try formatExpr(t.anchor.*, writer);
                try writer.writeAll(")");
            },
            .grouped => |inner| {
                try writer.writeAll("(");
                try formatExpr(inner.*, writer);
                try writer.writeAll(")");
            },
        }
    }

    fn formatFieldRef(field: FieldRef, writer: anytype) !void {
        for (field.parts, 0..) |part, i| {
            if (i > 0) try writer.writeAll(".");
            try writer.writeAll(part);
        }
    }

    fn formatValue(value: Value, writer: anytype) !void {
        switch (value) {
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .integer => |n| try writer.print("{d}", .{n}),
            .float => |f| try writer.print("{d}", .{f}),
            .boolean => |b| try writer.print("{}", .{b}),
            .null_val => try writer.writeAll("null"),
        }
    }

    fn formatDuration(ns: u64, writer: anytype) !void {
        if (ns >= 86400 * 1_000_000_000 and ns % (86400 * 1_000_000_000) == 0) {
            try writer.print("{d}d", .{ns / (86400 * 1_000_000_000)});
        } else if (ns >= 3600 * 1_000_000_000 and ns % (3600 * 1_000_000_000) == 0) {
            try writer.print("{d}h", .{ns / (3600 * 1_000_000_000)});
        } else if (ns >= 60 * 1_000_000_000 and ns % (60 * 1_000_000_000) == 0) {
            try writer.print("{d}m", .{ns / (60 * 1_000_000_000)});
        } else if (ns >= 1_000_000_000 and ns % 1_000_000_000 == 0) {
            try writer.print("{d}s", .{ns / 1_000_000_000});
        } else if (ns >= 1_000_000 and ns % 1_000_000 == 0) {
            try writer.print("{d}ms", .{ns / 1_000_000});
        } else {
            try writer.print("{d}ns", .{ns});
        }
    }
};

/// Binary expression (AND / OR).
pub const BinaryExpr = struct {
    left: *const Expr,
    right: *const Expr,
};

/// field op value
pub const Comparison = struct {
    field: FieldRef,
    op: CompOp,
    value: Value,
};

/// Comparison operator.
pub const CompOp = enum {
    eq,
    neq,
    gt,
    lt,
    gte,
    lte,
    contains,
    matches,
};

/// Dotted field reference: request.headers.host → ["request", "headers", "host"]
pub const FieldRef = struct {
    parts: []const []const u8,
};

/// Literal value in a comparison.
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    null_val,
};

/// The killer feature: temporal correlation.
/// `condition WITHIN duration OF anchor`
/// Matches events satisfying `condition` that occur within `duration_ns`
/// nanoseconds of an event satisfying `anchor`.
pub const TemporalExpr = struct {
    condition: *const Expr,
    duration_ns: u64,
    anchor: *const Expr,
};

/// GROUP BY field1, field2, ...
pub const GroupByClause = struct {
    fields: []const FieldRef,
};

/// SHOW FIRST n | SHOW LAST n | SHOW COUNT | SHOW field1, field2
pub const ShowClause = union(enum) {
    first: u64,
    last: u64,
    count,
    fields: []const FieldRef,
};
