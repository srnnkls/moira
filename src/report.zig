//! Writes walk entries as du(1) lines or as a table of every metric.

const std = @import("std");
const Io = std.Io;
const moira = @import("root.zig");
const cli = moira.cli;
const display = moira.display;

pub const EntryKind = enum { file, directory };

pub const Entry = struct {
    path: []const u8,
    tally: moira.Tally,
    depth: u32,
    kind: EntryKind,
    repeated_link: bool = false,
};

pub const Style = enum { du, columns };

pub const Report = struct {
    out: *Io.Writer,
    diagnostics: *Io.Writer,
    style: Style,
    metric: cli.Metric,
    units: cli.Units,
    max_depth: ?u32,
    show_files: bool,
    threshold_bytes: ?i64,
    failed: bool = false,

    pub fn begin(report: *Report) Io.Writer.Error!void {
        if (report.style != .columns) return;
        try report.out.print("{s:>10} {s:>10} {s:>10} {s:>10}  path\n", .{
            "allocated", "share", "exclusive", "pinned",
        });
    }

    pub fn emit(report: *Report, entry: Entry) Io.Writer.Error!void {
        if (entry.kind == .file and entry.depth > 0 and !report.show_files) return;
        if (entry.repeated_link and report.metric == .allocated) return;
        if (report.max_depth) |depth_max| if (entry.depth > depth_max) return;
        const bytes = metric_bytes(entry.tally, report.metric);
        if (entry.kind == .directory and !report.passes_threshold(bytes)) return;
        try report.write_line(entry.tally, entry.path);
    }

    pub fn total(report: *Report, tally: moira.Tally) Io.Writer.Error!void {
        try report.write_line(tally, "total");
    }

    pub fn warn(report: *Report, path: []const u8, reason: []const u8) void {
        report.failed = true;
        report.diagnostics.print("moira: {s}: {s}\n", .{ path, reason }) catch {};
    }

    fn passes_threshold(report: *const Report, bytes: u64) bool {
        const threshold = report.threshold_bytes orelse return true;
        if (threshold >= 0) return bytes >= @as(u64, @intCast(threshold));
        return bytes <= @abs(threshold);
    }

    fn write_line(report: *Report, tally: moira.Tally, path: []const u8) Io.Writer.Error!void {
        var buffers: [4][display.width_max]u8 = undefined;
        switch (report.style) {
            .du => {
                const size = display.format(&buffers[0], metric_bytes(tally, report.metric), report.units);
                try report.out.print("{s}\t{s}\n", .{ size, path });
            },
            .columns => try report.out.print("{s:>10} {s:>10} {s:>10} {s:>10}  {s}\n", .{
                display.format(&buffers[0], tally.allocated_bytes, report.units),
                display.format(&buffers[1], tally.share_bytes, report.units),
                display.format(&buffers[2], tally.exclusive_bytes, report.units),
                display.format(&buffers[3], tally.pinned_bytes, report.units),
                path,
            }),
        }
    }
};

pub fn metric_bytes(tally: moira.Tally, metric: cli.Metric) u64 {
    return switch (metric) {
        .share => tally.share_bytes,
        .exclusive => tally.exclusive_bytes,
        .pinned => tally.pinned_bytes,
        .allocated => tally.allocated_bytes,
    };
}

fn report_for_test(out: *Io.Writer, diagnostics: *Io.Writer) Report {
    return .{
        .out = out,
        .diagnostics = diagnostics,
        .style = .du,
        .metric = .share,
        .units = .{ .blocks = 512 },
        .max_depth = null,
        .show_files = false,
        .threshold_bytes = null,
    };
}

test "du lines print the chosen metric and hide nested files unless asked" {
    var out_buffer: [256]u8 = undefined;
    var out = Io.Writer.fixed(&out_buffer);
    var diagnostics = Io.Writer.fixed(&.{});
    var report = report_for_test(&out, &diagnostics);
    const tally: moira.Tally = .{ .allocated_bytes = 8192, .share_bytes = 4096 };
    try report.emit(.{ .path = "a/f", .tally = tally, .depth = 1, .kind = .file });
    try report.emit(.{ .path = "a", .tally = tally, .depth = 0, .kind = .directory });
    report.metric = .allocated;
    try report.emit(.{ .path = "a", .tally = tally, .depth = 0, .kind = .directory });
    try std.testing.expectEqualStrings("8\ta\n16\ta\n", out.buffered());
}

test "depth and threshold filter entries" {
    var out_buffer: [256]u8 = undefined;
    var out = Io.Writer.fixed(&out_buffer);
    var diagnostics = Io.Writer.fixed(&.{});
    var report = report_for_test(&out, &diagnostics);
    report.max_depth = 1;
    report.threshold_bytes = 1000;
    const small: moira.Tally = .{ .share_bytes = 512 };
    const large: moira.Tally = .{ .share_bytes = 2048 };
    try report.emit(.{ .path = "a/b/c", .tally = large, .depth = 2, .kind = .directory });
    try report.emit(.{ .path = "a/s", .tally = small, .depth = 1, .kind = .directory });
    try report.emit(.{ .path = "a/l", .tally = large, .depth = 1, .kind = .directory });
    report.show_files = true;
    try report.emit(.{ .path = "a/f", .tally = small, .depth = 1, .kind = .file });
    report.threshold_bytes = -1000;
    try report.emit(.{ .path = "a/s", .tally = small, .depth = 1, .kind = .directory });
    try std.testing.expectEqualStrings("4\ta/l\n1\ta/f\n1\ta/s\n", out.buffered());
}

test "warnings mark the report failed" {
    var out = Io.Writer.fixed(&.{});
    var diagnostics_buffer: [64]u8 = undefined;
    var diagnostics = Io.Writer.fixed(&diagnostics_buffer);
    var report = report_for_test(&out, &diagnostics);
    report.warn("x", "Permission denied");
    try std.testing.expect(report.failed);
    try std.testing.expectEqualStrings("moira: x: Permission denied\n", diagnostics.buffered());
}
