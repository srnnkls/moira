//! Disk usage that charges each entry its fair share of blocks held through clones and hard links.

const std = @import("std");
const assert = std.debug.assert;

pub const apfs = @import("apfs.zig");
pub const bulk = @import("bulk.zig");
pub const cli = @import("cli.zig");
pub const display = @import("display.zig");
pub const report = @import("report.zig");
pub const walk = @import("walk.zig");

pub const FileSample = struct {
    allocated_bytes: u64,
    private_bytes: u64,
    clone_count: u32,
    link_count: u32,
    allocation_counted: bool = true,

    pub fn inode_share_bytes(sample: FileSample) u64 {
        assert(sample.clone_count >= 1);
        assert(sample.private_bytes <= sample.allocated_bytes);
        if (sample.clone_count == 1) return sample.allocated_bytes;
        const shared_bytes = sample.allocated_bytes - sample.private_bytes;
        return sample.private_bytes + shared_bytes / sample.clone_count;
    }

    pub fn share_bytes(sample: FileSample) u64 {
        assert(sample.link_count >= 1);
        return sample.inode_share_bytes() / sample.link_count;
    }

    pub fn exclusive_bytes(sample: FileSample) u64 {
        if (sample.link_count > 1) return 0;
        if (sample.clone_count > 1) return sample.private_bytes;
        return sample.allocated_bytes;
    }

    pub fn pinned_bytes(sample: FileSample) u64 {
        if (sample.link_count > 1 or sample.clone_count > 1) return 0;
        return sample.allocated_bytes - sample.private_bytes;
    }
};

pub const Tally = struct {
    allocated_bytes: u64 = 0,
    share_bytes: u64 = 0,
    exclusive_bytes: u64 = 0,
    pinned_bytes: u64 = 0,

    pub fn add(tally: *Tally, sample: FileSample) void {
        if (sample.allocation_counted) tally.allocated_bytes += sample.allocated_bytes;
        tally.share_bytes += sample.share_bytes();
        tally.exclusive_bytes += sample.exclusive_bytes();
        tally.pinned_bytes += sample.pinned_bytes();
        assert(tally.pinned_bytes <= tally.exclusive_bytes);
        assert(tally.exclusive_bytes <= tally.share_bytes);
    }

    pub fn merge(tally: *Tally, other: Tally) void {
        tally.allocated_bytes += other.allocated_bytes;
        tally.share_bytes += other.share_bytes;
        tally.exclusive_bytes += other.exclusive_bytes;
        tally.pinned_bytes += other.pinned_bytes;
    }
};

fn unshared(allocated_bytes: u64) FileSample {
    return .{
        .allocated_bytes = allocated_bytes,
        .private_bytes = allocated_bytes,
        .clone_count = 1,
        .link_count = 1,
    };
}

test "an unshared file is charged in full and nothing is pinned" {
    var tally: Tally = .{};
    tally.add(unshared(4096));
    try std.testing.expectEqual(Tally{
        .allocated_bytes = 4096,
        .share_bytes = 4096,
        .exclusive_bytes = 4096,
        .pinned_bytes = 0,
    }, tally);
}

test "an unshared file under a snapshot is exclusive but pinned" {
    var tally: Tally = .{};
    tally.add(.{ .allocated_bytes = 4096, .private_bytes = 0, .clone_count = 1, .link_count = 1 });
    try std.testing.expectEqual(@as(u64, 4096), tally.share_bytes);
    try std.testing.expectEqual(@as(u64, 4096), tally.exclusive_bytes);
    try std.testing.expectEqual(@as(u64, 4096), tally.pinned_bytes);
}

test "untouched clones split their blocks and none is exclusive" {
    var tally: Tally = .{};
    const clone: FileSample = .{
        .allocated_bytes = 1 << 30,
        .private_bytes = 0,
        .clone_count = 2,
        .link_count = 1,
    };
    tally.add(clone);
    try std.testing.expectEqual(@as(u64, 1 << 29), tally.share_bytes);
    try std.testing.expectEqual(@as(u64, 0), tally.exclusive_bytes);

    tally.add(clone);
    try std.testing.expectEqual(@as(u64, 1 << 30), tally.share_bytes);
    try std.testing.expectEqual(@as(u64, 2 << 30), tally.allocated_bytes);
}

test "a rewritten clone owns its private blocks and splits the rest" {
    const rewritten: FileSample = .{
        .allocated_bytes = 10_000,
        .private_bytes = 2_000,
        .clone_count = 2,
        .link_count = 1,
    };
    const original: FileSample = .{
        .allocated_bytes = 10_000,
        .private_bytes = 0,
        .clone_count = 2,
        .link_count = 1,
    };
    var tally: Tally = .{};
    tally.add(rewritten);
    tally.add(original);
    try std.testing.expectEqual(@as(u64, 6_000), rewritten.share_bytes());
    try std.testing.expectEqual(@as(u64, 2_000), rewritten.exclusive_bytes());
    try std.testing.expectEqual(@as(u64, 11_000), tally.share_bytes);
    try std.testing.expectEqual(@as(u64, 0), tally.pinned_bytes);
}

test "hard links and clones compound" {
    var tally: Tally = .{};
    const entry: FileSample = .{
        .allocated_bytes = 6000,
        .private_bytes = 0,
        .clone_count = 3,
        .link_count = 2,
    };
    for (0..6) |_| tally.add(entry);
    try std.testing.expectEqual(@as(u64, 6000), tally.share_bytes);
    try std.testing.expectEqual(@as(u64, 36000), tally.allocated_bytes);
    try std.testing.expectEqual(@as(u64, 0), tally.exclusive_bytes);
}

test "a repeated hard link keeps its share but adds no allocation" {
    var tally: Tally = .{};
    var link: FileSample = .{ .allocated_bytes = 800, .private_bytes = 800, .clone_count = 1, .link_count = 2 };
    tally.add(link);
    link.allocation_counted = false;
    tally.add(link);
    try std.testing.expectEqual(@as(u64, 800), tally.allocated_bytes);
    try std.testing.expectEqual(@as(u64, 800), tally.share_bytes);
}

test "merge sums every column" {
    var left: Tally = .{
        .allocated_bytes = 10,
        .share_bytes = 5,
        .exclusive_bytes = 2,
        .pinned_bytes = 1,
    };
    left.merge(.{ .allocated_bytes = 20, .share_bytes = 7, .exclusive_bytes = 3, .pinned_bytes = 2 });
    try std.testing.expectEqual(Tally{
        .allocated_bytes = 30,
        .share_bytes = 12,
        .exclusive_bytes = 5,
        .pinned_bytes = 3,
    }, left);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("fixture_test.zig");
}
