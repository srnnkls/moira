//! Command-line contract: the macOS du(1) flags plus moira's metric and layout flags.

const std = @import("std");

pub const Metric = enum { share, exclusive, pinned, allocated };
pub const Symlinks = enum { never, arguments, always };
pub const Layout = enum { automatic, du, columns };
pub const Units = union(enum) { blocks: u64, human_binary, human_decimal };

pub const Options = struct {
    paths: std.ArrayList([]const u8) = .empty,
    ignore_masks: std.ArrayList([:0]const u8) = .empty,
    metric: Metric = .share,
    layout: Layout = .automatic,
    units: ?Units = null,
    symlinks: Symlinks = .never,
    max_depth: ?u32 = null,
    show_files: bool = false,
    grand_total: bool = false,
    apparent_size: bool = false,
    count_links: bool = false,
    skip_nodump: bool = false,
    one_file_system: bool = false,
    rounding_bytes: ?u64 = null,
    threshold_bytes: ?i64 = null,
    help: bool = false,

    pub fn deinit(options: *Options, gpa: std.mem.Allocator) void {
        options.paths.deinit(gpa);
        options.ignore_masks.deinit(gpa);
    }
};

pub const ParseError = error{
    UnknownOption,
    MissingValue,
    InvalidNumber,
    FilesWithDepth,
    OutOfMemory,
};

pub const Diagnostic = struct { argument: []const u8 = "" };

pub fn parse(
    gpa: std.mem.Allocator,
    arguments: []const [:0]const u8,
    diagnostic: *Diagnostic,
) ParseError!Options {
    var options: Options = .{};
    errdefer options.deinit(gpa);
    var cursor: Cursor = .{ .arguments = arguments };
    var only_paths = false;
    while (cursor.next()) |argument| {
        diagnostic.argument = argument;
        if (only_paths or argument.len < 2 or argument[0] != '-') {
            try options.paths.append(gpa, argument);
        } else if (std.mem.eql(u8, argument, "--")) {
            only_paths = true;
        } else if (std.mem.startsWith(u8, argument, "--")) {
            try apply_long(&options, gpa, &cursor, argument[2..]);
        } else {
            try apply_short_cluster(&options, gpa, &cursor, argument[1..]);
        }
    }
    if (options.show_files and options.max_depth != null) return error.FilesWithDepth;
    return options;
}

const Cursor = struct {
    arguments: []const [:0]const u8,
    index: usize = 0,

    fn next(cursor: *Cursor) ?[:0]const u8 {
        if (cursor.index == cursor.arguments.len) return null;
        defer cursor.index += 1;
        return cursor.arguments[cursor.index];
    }
};

fn apply_short_cluster(
    options: *Options,
    gpa: std.mem.Allocator,
    cursor: *Cursor,
    cluster: [:0]const u8,
) ParseError!void {
    for (cluster, 0..) |flag, index| {
        switch (flag) {
            'B', 'I', 'd', 't' => {
                const inline_value = cluster[index + 1 ..];
                const value = if (inline_value.len > 0) inline_value else cursor.next() orelse
                    return error.MissingValue;
                return apply_value(options, gpa, flag, value);
            },
            'A' => options.apparent_size = true,
            'H' => options.symlinks = .arguments,
            'L' => options.symlinks = .always,
            'P' => options.symlinks = .never,
            'a' => options.show_files = true,
            'c' => options.grand_total = true,
            'g' => options.units = .{ .blocks = 1 << 30 },
            'h' => options.units = .human_binary,
            'k' => options.units = .{ .blocks = 1 << 10 },
            'l' => options.count_links = true,
            'm' => options.units = .{ .blocks = 1 << 20 },
            'n' => options.skip_nodump = true,
            'r' => {},
            's' => options.max_depth = 0,
            'x' => options.one_file_system = true,
            else => return error.UnknownOption,
        }
    }
}

fn apply_value(
    options: *Options,
    gpa: std.mem.Allocator,
    flag: u8,
    value: [:0]const u8,
) ParseError!void {
    switch (flag) {
        'B' => {
            const bytes = try parse_size(value);
            if (bytes <= 0) return error.InvalidNumber;
            options.rounding_bytes = @intCast(bytes);
        },
        'I' => try options.ignore_masks.append(gpa, value),
        'd' => options.max_depth = std.fmt.parseInt(u32, value, 10) catch
            return error.InvalidNumber,
        't' => options.threshold_bytes = try parse_threshold(value),
        else => unreachable,
    }
}

const LongFlag = enum {
    all,
    summarize,
    @"max-depth",
    @"human-readable",
    si,
    total,
    @"one-file-system",
    @"apparent-size",
    @"count-links",
    dereference,
    @"dereference-args",
    @"no-dereference",
    threshold,
    @"block-size",
    exclude,
    help,
    share,
    exclusive,
    pinned,
    allocated,
    du,
    columns,
};

fn apply_long(
    options: *Options,
    gpa: std.mem.Allocator,
    cursor: *Cursor,
    text: [:0]const u8,
) ParseError!void {
    const equals = std.mem.indexOfScalar(u8, text, '=');
    const name = if (equals) |at| text[0..at] else text;
    const flag = std.meta.stringToEnum(LongFlag, name) orelse return error.UnknownOption;
    const short: ?u8 = switch (flag) {
        .@"max-depth" => 'd',
        .threshold => 't',
        .@"block-size" => 'B',
        .exclude => 'I',
        else => null,
    };
    if (short) |value_flag| {
        const value = if (equals) |at| text[at + 1 ..] else cursor.next() orelse
            return error.MissingValue;
        return apply_value(options, gpa, value_flag, value);
    }
    if (equals != null) return error.UnknownOption;
    switch (flag) {
        .all => options.show_files = true,
        .summarize => options.max_depth = 0,
        .@"human-readable" => options.units = .human_binary,
        .si => options.units = .human_decimal,
        .total => options.grand_total = true,
        .@"one-file-system" => options.one_file_system = true,
        .@"apparent-size" => options.apparent_size = true,
        .@"count-links" => options.count_links = true,
        .dereference => options.symlinks = .always,
        .@"dereference-args" => options.symlinks = .arguments,
        .@"no-dereference" => options.symlinks = .never,
        .help => options.help = true,
        .share => options.metric = .share,
        .exclusive => options.metric = .exclusive,
        .pinned => options.metric = .pinned,
        .allocated => options.metric = .allocated,
        .du => options.layout = .du,
        .columns => options.layout = .columns,
        .@"max-depth", .threshold, .@"block-size", .exclude => unreachable,
    }
}

pub fn parse_size(text: []const u8) error{InvalidNumber}!i64 {
    if (text.len == 0) return error.InvalidNumber;
    const suffixes = "BKMGTPE";
    const last = std.ascii.toUpper(text[text.len - 1]);
    if (std.ascii.isDigit(last)) return std.fmt.parseInt(i64, text, 10) catch error.InvalidNumber;
    const suffix_index = std.mem.indexOfScalar(u8, suffixes, last) orelse return error.InvalidNumber;
    const shift: u6 = @intCast(suffix_index * 10);
    const digits = text[0 .. text.len - 1];
    const number = std.fmt.parseInt(i64, digits, 10) catch return error.InvalidNumber;
    return std.math.shlExact(i64, number, shift) catch error.InvalidNumber;
}

fn parse_threshold(text: []const u8) error{InvalidNumber}!i64 {
    const bytes = try parse_size(text);
    if (bytes == 0) return error.InvalidNumber;
    if (bytes < 0 and !std.ascii.isDigit(text[text.len - 1])) return error.InvalidNumber;
    return bytes;
}

pub const minimum_block_bytes = 512;

pub const EnvironmentUnits = struct { units: Units, clamped: bool };

pub fn units_from_environment(blocksize: ?[]const u8) EnvironmentUnits {
    const text = blocksize orelse return .{ .units = .{ .blocks = 512 }, .clamped = false };
    const bytes = parse_size(text) catch return .{ .units = .{ .blocks = 512 }, .clamped = true };
    if (bytes < minimum_block_bytes) return .{ .units = .{ .blocks = 512 }, .clamped = true };
    return .{ .units = .{ .blocks = @intCast(bytes) }, .clamped = false };
}

fn parse_for_test(arguments: []const [:0]const u8) ParseError!Options {
    var diagnostic: Diagnostic = .{};
    return parse(std.testing.allocator, arguments, &diagnostic);
}

test "clustered short flags and inline values" {
    var options = try parse_for_test(&.{ "-shx", "-d1", "-I", "*.o", "a", "b" });
    defer options.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, 1), options.max_depth);
    try std.testing.expectEqual(Units.human_binary, options.units.?);
    try std.testing.expect(options.one_file_system);
    try std.testing.expectEqualStrings("*.o", options.ignore_masks.items[0]);
    try std.testing.expectEqual(@as(usize, 2), options.paths.items.len);
}

test "unit flags override each other in order" {
    var options = try parse_for_test(&.{ "-h", "-k", "--si", "-m" });
    defer options.deinit(std.testing.allocator);
    try std.testing.expectEqual(Units{ .blocks = 1 << 20 }, options.units.?);
}

test "long flags take values inline or as the next argument" {
    var options = try parse_for_test(&.{ "--max-depth=2", "--threshold", "1M", "--allocated", "--du" });
    defer options.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, 2), options.max_depth);
    try std.testing.expectEqual(@as(?i64, 1 << 20), options.threshold_bytes);
    try std.testing.expectEqual(Metric.allocated, options.metric);
    try std.testing.expectEqual(Layout.du, options.layout);
}

test "a double dash ends option parsing and a lone dash is a path" {
    var options = try parse_for_test(&.{ "--", "-s", "-" });
    defer options.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, null), options.max_depth);
    try std.testing.expectEqual(@as(usize, 2), options.paths.items.len);
}

test "invalid argument combinations are rejected" {
    try std.testing.expectError(error.FilesWithDepth, parse_for_test(&.{ "-a", "-s" }));
    try std.testing.expectError(error.UnknownOption, parse_for_test(&.{"-q"}));
    try std.testing.expectError(error.UnknownOption, parse_for_test(&.{"--summarize=1"}));
    try std.testing.expectError(error.MissingValue, parse_for_test(&.{"-d"}));
    try std.testing.expectError(error.InvalidNumber, parse_for_test(&.{ "-t", "1Q" }));
    try std.testing.expectError(error.InvalidNumber, parse_for_test(&.{ "-t", "0" }));
    try std.testing.expectError(error.InvalidNumber, parse_for_test(&.{ "-t", "-100K" }));
}

test "sizes accept binary suffixes and signs" {
    try std.testing.expectEqual(@as(i64, 512), try parse_size("512"));
    try std.testing.expectEqual(@as(i64, 4096), try parse_size("4k"));
    try std.testing.expectEqual(@as(i64, -(1 << 30)), try parse_size("-1G"));
    try std.testing.expectError(error.InvalidNumber, parse_size("K"));
}

test "BLOCKSIZE below 512 is clamped" {
    try std.testing.expectEqual(Units{ .blocks = 512 }, units_from_environment(null).units);
    try std.testing.expectEqual(Units{ .blocks = 1 << 20 }, units_from_environment("1M").units);
    try std.testing.expect(units_from_environment("100").clamped);
}
