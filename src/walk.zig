//! Post-order traversal in du(1) order: children are reported before their directory.

const std = @import("std");
const moira = @import("root.zig");
const apfs = moira.apfs;
const bulk = moira.bulk;
const cli = moira.cli;
const Report = moira.report.Report;

pub const Config = struct {
    symlinks: cli.Symlinks = .never,
    one_file_system: bool = false,
    apparent_size: bool = false,
    count_links: bool = false,
    skip_nodump: bool = false,
    rounding_bytes: ?u64 = null,
    ignore_masks: []const [:0]const u8 = &.{},
    request: bulk.Request = .private_sizes,
};

pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error;

const uf_nodump: u32 = 0x00000001;

extern "c" fn fnmatch(pattern: [*:0]const u8, string: [*:0]const u8, flags: c_int) c_int;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;

const Inode = struct { device: i32, inode: u64 };

const Frame = struct {
    reader: bulk.Reader,
    tally: moira.Tally,
    path_len: usize,
};

const Buffer = *align(8) [bulk.buffer_bytes]u8;

pub const Walk = struct {
    gpa: std.mem.Allocator,
    config: *const Config,
    report: *Report,
    seen_links: std.AutoHashMapUnmanaged(Inode, void) = .empty,
    seen_directories: std.AutoHashMapUnmanaged(Inode, void) = .empty,
    path: std.ArrayList(u8) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    buffers: std.ArrayList(Buffer) = .empty,

    pub fn deinit(walk: *Walk) void {
        for (walk.frames.items) |frame| _ = std.c.close(frame.reader.fd);
        for (walk.buffers.items) |buffer| walk.gpa.destroy(buffer);
        walk.seen_links.deinit(walk.gpa);
        walk.seen_directories.deinit(walk.gpa);
        walk.path.deinit(walk.gpa);
        walk.frames.deinit(walk.gpa);
        walk.buffers.deinit(walk.gpa);
    }

    pub fn run(walk: *Walk, argument: []const u8) Error!?moira.Tally {
        const name = try walk.gpa.dupeZ(u8, argument);
        defer walk.gpa.free(name);
        const follow = walk.config.symlinks != .never;
        var stat: std.c.Stat = undefined;
        if (!stat_at(std.c.AT.FDCWD, name, follow, &stat)) {
            walk.report.warn(argument, errno_message());
            return null;
        }
        walk.path.clearRetainingCapacity();
        try walk.path.appendSlice(walk.gpa, argument);
        if (!std.c.S.ISDIR(stat.mode)) {
            const sample = try walk.sample_from_stat(std.c.AT.FDCWD, name, stat, follow) orelse
                return null;
            var tally: moira.Tally = .{};
            tally.add(sample);
            try walk.report.emit(.{ .path = argument, .tally = tally, .depth = 0, .kind = .file });
            return tally;
        }
        const fd = open_directory(std.c.AT.FDCWD, name, follow) orelse {
            walk.report.warn(argument, errno_message());
            return null;
        };
        try walk.push(fd, walk.unshared_tally(block_bytes(stat), @intCast(stat.size)));
        return try walk.drain(stat.dev);
    }

    fn drain(walk: *Walk, root_device: i32) Error!moira.Tally {
        while (true) {
            const top = &walk.frames.items[walk.frames.items.len - 1];
            const found = top.reader.next() catch found: {
                walk.report.warn(walk.path.items[0..top.path_len], message_of(top.reader.last_errno));
                break :found null;
            };
            if (found) |entry| {
                try walk.visit(entry, root_device);
                continue;
            }
            const frame = walk.frames.pop().?;
            _ = std.c.close(frame.reader.fd);
            const depth = walk.frames.items.len;
            try walk.report.emit(.{
                .path = walk.path.items[0..frame.path_len],
                .tally = frame.tally,
                .depth = @intCast(depth),
                .kind = .directory,
            });
            if (depth == 0) return frame.tally;
            walk.frames.items[depth - 1].tally.merge(frame.tally);
        }
    }

    fn push(walk: *Walk, fd: std.c.fd_t, tally: moira.Tally) Error!void {
        errdefer _ = std.c.close(fd);
        const depth = walk.frames.items.len;
        if (depth == walk.buffers.items.len) {
            const buffer = try walk.gpa.create([bulk.buffer_bytes]u8);
            errdefer walk.gpa.destroy(buffer);
            try walk.buffers.append(walk.gpa, @alignCast(buffer));
        }
        try walk.frames.append(walk.gpa, .{
            .reader = .{ .fd = fd, .buffer = walk.buffers.items[depth], .request = walk.config.request },
            .tally = tally,
            .path_len = walk.path.items.len,
        });
    }

    fn visit(walk: *Walk, entry: bulk.Entry, root_device: i32) Error!void {
        const parent = walk.frames.items[walk.frames.items.len - 1];
        walk.path.shrinkRetainingCapacity(parent.path_len);
        try walk.path.append(walk.gpa, '/');
        try walk.path.appendSlice(walk.gpa, entry.name);
        if (entry.error_code != 0) {
            return walk.report.warn(walk.path.items, message_of(@intCast(entry.error_code)));
        }
        if (walk.ignored(entry.name)) return;
        if (walk.config.skip_nodump and entry.flags & uf_nodump != 0) return;
        if (walk.config.one_file_system and entry.device != root_device) return;

        const depth: u32 = @intCast(walk.frames.items.len);
        switch (entry.kind) {
            .directory => {
                const tally = walk.unshared_tally(entry.allocated_bytes, entry.apparent_bytes);
                const inode: Inode = .{ .device = entry.device, .inode = entry.inode };
                try walk.enter(parent.reader.fd, entry.name, tally, inode, false);
            },
            .symlink => if (walk.config.symlinks == .always) {
                try walk.visit_followed(parent.reader.fd, entry.name, depth, root_device);
            } else {
                try walk.add_file(try walk.sample_from_entry(parent.reader.fd, entry), depth);
            },
            .file, .other => {
                try walk.add_file(try walk.sample_from_entry(parent.reader.fd, entry), depth);
            },
        }
    }

    fn visit_followed(
        walk: *Walk,
        dir_fd: std.c.fd_t,
        name: [:0]const u8,
        depth: u32,
        root_device: i32,
    ) Error!void {
        var stat: std.c.Stat = undefined;
        if (!stat_at(dir_fd, name, true, &stat)) {
            return walk.report.warn(walk.path.items, errno_message());
        }
        if (walk.config.one_file_system and stat.dev != root_device) return;
        if (std.c.S.ISDIR(stat.mode)) {
            const tally = walk.unshared_tally(block_bytes(stat), @intCast(stat.size));
            return walk.enter(dir_fd, name, tally, inode_of(stat), true);
        }
        try walk.add_file(try walk.sample_from_stat(dir_fd, name, stat, true), depth);
    }

    fn enter(
        walk: *Walk,
        dir_fd: std.c.fd_t,
        name: [:0]const u8,
        tally: moira.Tally,
        inode: Inode,
        follow: bool,
    ) Error!void {
        if (walk.config.symlinks == .always) {
            const seen = try walk.seen_directories.getOrPut(walk.gpa, inode);
            if (seen.found_existing) return;
        }
        const fd = open_directory(dir_fd, name, follow) orelse {
            return walk.report.warn(walk.path.items, errno_message());
        };
        try walk.push(fd, tally);
    }

    fn add_file(walk: *Walk, sample: ?moira.FileSample, depth: u32) Error!void {
        const file = sample orelse return;
        walk.frames.items[walk.frames.items.len - 1].tally.add(file);
        var tally: moira.Tally = .{};
        tally.add(file);
        try walk.report.emit(.{
            .path = walk.path.items,
            .tally = tally,
            .depth = depth,
            .kind = .file,
            .repeated_link = !file.allocation_counted,
        });
    }

    fn ignored(walk: *const Walk, basename: [:0]const u8) bool {
        for (walk.config.ignore_masks) |mask| {
            if (fnmatch(mask, basename, 0) == 0) return true;
        }
        return false;
    }

    fn sample_from_entry(
        walk: *Walk,
        dir_fd: std.c.fd_t,
        entry: bulk.Entry,
    ) Error!?moira.FileSample {
        const inode: Inode = .{ .device = entry.device, .inode = entry.inode };
        var sample = try walk.unshared_sample(
            entry.allocated_bytes,
            entry.apparent_bytes,
            entry.link_count,
            inode,
        );
        if (walk.config.apparent_size or entry.kind != .file) return sample;
        const ext_flags = entry.ext_flags orelse return sample;
        var private_bytes = entry.private_bytes;
        if (private_bytes == null and apfs.needs_private_bytes(ext_flags)) {
            private_bytes = apfs.private_size(dir_fd, entry.name) catch {
                walk.report.warn(walk.path.items, "cannot read APFS sharing attributes");
                return null;
            };
        }
        const sharing = apfs.sharing_from(ext_flags, entry.clone_refcount orelse 1, private_bytes);
        walk.apply_sharing(&sample, sharing, entry.allocated_bytes);
        return sample;
    }

    fn sample_from_stat(
        walk: *Walk,
        dir_fd: std.c.fd_t,
        name: [*:0]const u8,
        stat: std.c.Stat,
        follow: bool,
    ) Error!?moira.FileSample {
        var sample = try walk.unshared_sample(
            block_bytes(stat),
            @intCast(stat.size),
            @intCast(stat.nlink),
            inode_of(stat),
        );
        if (walk.config.apparent_size or walk.config.request == .sizes_only) return sample;
        if (!std.c.S.ISREG(stat.mode)) return sample;
        const sharing = apfs.sharing(dir_fd, name, follow) catch {
            walk.report.warn(walk.path.items, "cannot read APFS sharing attributes");
            return null;
        };
        walk.apply_sharing(&sample, sharing, block_bytes(stat));
        return sample;
    }

    fn apply_sharing(
        walk: *const Walk,
        sample: *moira.FileSample,
        sharing: apfs.Sharing,
        raw_bytes: u64,
    ) void {
        const private_raw = @min(sharing.private_bytes orelse raw_bytes, raw_bytes);
        sample.private_bytes = walk.rounded(private_raw);
        sample.clone_count = sharing.clone_count;
    }

    fn unshared_sample(
        walk: *Walk,
        allocated_bytes: u64,
        apparent_bytes: u64,
        link_count: u32,
        inode: Inode,
    ) Error!moira.FileSample {
        const bytes = walk.charged_bytes(allocated_bytes, apparent_bytes);
        const links = @max(link_count, 1);
        return .{
            .allocated_bytes = bytes,
            .private_bytes = bytes,
            .clone_count = 1,
            .link_count = links,
            .allocation_counted = try walk.first_sighting(inode, links),
        };
    }

    fn first_sighting(walk: *Walk, inode: Inode, link_count: u32) Error!bool {
        if (walk.config.count_links or link_count <= 1) return true;
        const seen = try walk.seen_links.getOrPut(walk.gpa, inode);
        return !seen.found_existing;
    }

    fn unshared_tally(walk: *const Walk, allocated_bytes: u64, apparent_bytes: u64) moira.Tally {
        const bytes = walk.charged_bytes(allocated_bytes, apparent_bytes);
        var tally: moira.Tally = .{};
        tally.add(.{ .allocated_bytes = bytes, .private_bytes = bytes, .clone_count = 1, .link_count = 1 });
        return tally;
    }

    fn charged_bytes(walk: *const Walk, allocated_bytes: u64, apparent_bytes: u64) u64 {
        if (!walk.config.apparent_size) return walk.rounded(allocated_bytes);
        return round_up(apparent_bytes, walk.config.rounding_bytes orelse 512);
    }

    fn rounded(walk: *const Walk, bytes: u64) u64 {
        return round_up(bytes, walk.config.rounding_bytes orelse return bytes);
    }
};

fn round_up(bytes: u64, unit: u64) u64 {
    return (std.math.divCeil(u64, bytes, unit) catch unreachable) * unit;
}

fn block_bytes(stat: std.c.Stat) u64 {
    return @as(u64, @intCast(stat.blocks)) * 512;
}

fn inode_of(stat: std.c.Stat) Inode {
    return .{ .device = stat.dev, .inode = stat.ino };
}

fn stat_at(dir_fd: std.c.fd_t, name: [*:0]const u8, follow: bool, stat: *std.c.Stat) bool {
    const flags: u32 = if (follow) 0 else std.c.AT.SYMLINK_NOFOLLOW;
    return std.c.fstatat(dir_fd, name, stat, flags) == 0;
}

fn open_directory(dir_fd: std.c.fd_t, name: [*:0]const u8, follow: bool) ?std.c.fd_t {
    const fd = std.c.openat(dir_fd, name, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .NOFOLLOW = !follow,
        .CLOEXEC = true,
    });
    return if (fd < 0) null else fd;
}

fn errno_message() []const u8 {
    return message_of(std.c._errno().*);
}

fn message_of(errno: c_int) []const u8 {
    return std.mem.span(strerror(errno));
}
