const std = @import("std");
const moira = @import("root.zig");

extern "c" fn clonefileat(
    src_dir_fd: std.c.fd_t,
    src: [*:0]const u8,
    dst_dir_fd: std.c.fd_t,
    dst: [*:0]const u8,
    flags: u32,
) c_int;

const file_bytes = 1 << 20;
const rewritten_bytes = 256 << 10;

test "a partly rewritten clone pair shares exactly the blocks it still has in common" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_data: [file_bytes]u8 = undefined;
    io.random(&original_data);
    try write_synced(tmp.dir, "original", &original_data, 0);
    if (clonefileat(tmp.dir.handle, "original", tmp.dir.handle, "clone", 0) != 0) {
        return error.SkipZigTest;
    }
    var rewrite: [rewritten_bytes]u8 = undefined;
    io.random(&rewrite);
    try write_synced(tmp.dir, "clone", &rewrite, 0);

    const root_path = ".zig-cache/tmp/" ++ tmp.sub_path;
    var out = std.Io.Writer.Discarding.init(&.{});
    var diagnostics = std.Io.Writer.Discarding.init(&.{});
    var report: moira.report.Report = .{
        .out = &out.writer,
        .diagnostics = &diagnostics.writer,
        .style = .du,
        .metric = .share,
        .units = .{ .blocks = 512 },
        .max_depth = 0,
        .show_files = false,
        .threshold_bytes = null,
    };
    const config: moira.walk.Config = .{};
    var walk: moira.walk.Walk = .{
        .gpa = std.testing.allocator,
        .config = &config,
        .report = &report,
    };
    defer walk.deinit();
    const tally = (try walk.run(root_path)).?;

    try std.testing.expect(!report.failed);
    try std.testing.expectEqual(@as(u64, 2 * file_bytes), tally.allocated_bytes);
    try std.testing.expectEqual(@as(u64, file_bytes + rewritten_bytes), tally.share_bytes);
    try std.testing.expectEqual(@as(u64, 2 * rewritten_bytes), tally.exclusive_bytes);
    try std.testing.expectEqual(@as(u64, 0), tally.pinned_bytes);
}

fn write_synced(dir: std.Io.Dir, name: []const u8, data: []const u8, offset: u64) !void {
    const io = std.testing.io;
    var file = dir.openFile(io, name, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try dir.createFile(io, name, .{ .read = true }),
        else => |other| return other,
    };
    defer file.close(io);
    try file.writePositionalAll(io, data, offset);
    try file.sync(io);
}
