//! Sizes in du(1) notation: block counts rounded up, or humanize_number(3) output.

const std = @import("std");
const Units = @import("cli.zig").Units;

pub const width_max = 24;

pub fn format(buffer: *[width_max]u8, bytes: u64, units: Units) []const u8 {
    return switch (units) {
        .blocks => |block_bytes| std.fmt.bufPrint(
            buffer,
            "{d}",
            .{std.math.divCeil(u64, bytes, block_bytes) catch unreachable},
        ) catch unreachable,
        .human_binary => humanize(buffer, bytes, 1024, "BKMGTPE"),
        .human_decimal => humanize(buffer, bytes, 1000, "BkMGTPE"),
    };
}

fn humanize(buffer: *[width_max]u8, bytes: u64, base: f64, suffixes: *const [7]u8) []const u8 {
    var scaled: f64 = @floatFromInt(bytes);
    var suffix_index: usize = 0;
    while (scaled >= 999.5 and suffix_index + 1 < suffixes.len) : (suffix_index += 1) {
        scaled /= base;
    }
    const suffix = suffixes[suffix_index];
    if (suffix_index > 0 and scaled < 9.95) {
        return std.fmt.bufPrint(buffer, "{d:.1}{c}", .{ scaled, suffix }) catch unreachable;
    }
    const whole: u64 = @intFromFloat(@round(scaled));
    return std.fmt.bufPrint(buffer, "{d:>3}{c}", .{ whole, suffix }) catch unreachable;
}

fn expect_format(expected: []const u8, bytes: u64, units: Units) !void {
    var buffer: [width_max]u8 = undefined;
    try std.testing.expectEqualStrings(expected, format(&buffer, bytes, units));
}

test "block counts round up to whole units" {
    try expect_format("0", 0, .{ .blocks = 512 });
    try expect_format("8", 4096, .{ .blocks = 512 });
    try expect_format("2", 1_503_232, .{ .blocks = 1 << 20 });
    try expect_format("13192", 13_508_608, .{ .blocks = 1024 });
}

test "human sizes match du -h samples" {
    try expect_format("  0B", 0, .human_binary);
    try expect_format("4.0K", 4096, .human_binary);
    try expect_format("1.4M", 1_503_232, .human_binary);
    try expect_format(" 11M", 12_001_280, .human_binary);
    try expect_format(" 13M", 13_508_608, .human_binary);
    try expect_format("1.0M", 1023 * 1024, .human_binary);
    try expect_format(" 16E", std.math.maxInt(u64), .human_binary);
}

test "si sizes use powers of 1000 and a lowercase kilo" {
    try expect_format("4.1k", 4096, .human_decimal);
    try expect_format(" 14M", 13_508_608, .human_decimal);
}
