//! Clone and private-size attributes from the APFS extended attribute interface.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (!builtin.os.tag.isDarwin()) @compileError("moira reads APFS attributes and needs Darwin");
}

const attr_bit_map_count = 5;
const attr_cmn_returned_attrs: u32 = 0x80000000;
pub const attr_cmnext_privatesize: u32 = 0x00000008;
pub const attr_cmnext_ext_flags: u32 = 0x00000200;
pub const attr_cmnext_clone_refcnt: u32 = 0x00001000;
const ef_may_share_blocks: u64 = 0x00000001;
const ef_shares_all_blocks: u64 = 0x00000040;
const fsopt_nofollow: c_ulong = 0x00000001;
pub const fsopt_attr_cmn_extended: c_ulong = 0x00000020;

pub const AttrList = extern struct {
    bitmapcount: u16 = attr_bit_map_count,
    reserved: u16 = 0,
    commonattr: u32 = 0,
    volattr: u32 = 0,
    dirattr: u32 = 0,
    fileattr: u32 = 0,
    forkattr: u32 = 0,
};

pub const AttributeSet = extern struct {
    commonattr: u32,
    volattr: u32,
    dirattr: u32,
    fileattr: u32,
    forkattr: u32,
};

const SharingReply = extern struct {
    length: u32,
    returned: AttributeSet,
    private_size: i64,
    ext_flags: u64,
    clone_refcount: u32,
};

comptime {
    if (@offsetOf(PrivateSizeReply, "private_size") != 24) {
        @compileError("PrivateSizeReply.private_size is not where getattrlist(2) packs it");
    }
    if (@sizeOf(AttrList) != 24) @compileError("AttrList must match struct attrlist");
    const packed_offsets = .{ .private_size = 24, .ext_flags = 32, .clone_refcount = 40 };
    for (std.meta.fieldNames(@TypeOf(packed_offsets))) |name| {
        if (@offsetOf(SharingReply, name) != @field(packed_offsets, name)) {
            @compileError("SharingReply." ++ name ++ " is not where getattrlist(2) packs it");
        }
    }
}

extern "c" fn getattrlistat(
    dir_fd: std.c.fd_t,
    path: [*:0]const u8,
    attr_list: *const AttrList,
    buffer: *anyopaque,
    buffer_size: usize,
    options: c_ulong,
) c_int;

pub const Sharing = struct {
    clone_count: u32,
    private_bytes: ?u64,
};

pub const SharingError = error{AttributeUnavailable};

pub fn sharing(dir_fd: std.c.fd_t, name: [*:0]const u8, follow_symlink: bool) SharingError!Sharing {
    const wanted = attr_cmnext_privatesize | attr_cmnext_ext_flags | attr_cmnext_clone_refcnt;
    const request: AttrList = .{ .commonattr = attr_cmn_returned_attrs, .forkattr = wanted };
    var reply: SharingReply = undefined;
    const follow_option: c_ulong = if (follow_symlink) 0 else fsopt_nofollow;
    const options = follow_option | fsopt_attr_cmn_extended;
    if (getattrlistat(dir_fd, name, &request, &reply, @sizeOf(SharingReply), options) != 0) {
        return error.AttributeUnavailable;
    }
    if (reply.returned.forkattr & wanted != wanted) {
        return .{ .clone_count = 1, .private_bytes = null };
    }
    const private_bytes: u64 = @intCast(@max(reply.private_size, 0));
    return .{
        .clone_count = clone_count(reply.ext_flags, reply.clone_refcount, private_bytes),
        .private_bytes = private_bytes,
    };
}

pub fn sharing_from(ext_flags: u64, refcount: u32, private_bytes: ?u64) Sharing {
    if (ext_flags & ef_may_share_blocks == 0) {
        return .{ .clone_count = 1, .private_bytes = private_bytes };
    }
    const known_private = private_bytes orelse 0;
    return .{
        .clone_count = clone_count(ext_flags, refcount, known_private),
        .private_bytes = known_private,
    };
}

pub fn needs_private_bytes(ext_flags: u64) bool {
    return ext_flags & ef_may_share_blocks != 0 and ext_flags & ef_shares_all_blocks == 0;
}

const PrivateSizeReply = extern struct {
    length: u32,
    returned: AttributeSet,
    private_size: i64,
};

pub fn private_size(dir_fd: std.c.fd_t, name: [*:0]const u8) SharingError!u64 {
    const request: AttrList = .{
        .commonattr = attr_cmn_returned_attrs,
        .forkattr = attr_cmnext_privatesize,
    };
    var reply: PrivateSizeReply = undefined;
    const options = fsopt_nofollow | fsopt_attr_cmn_extended;
    if (getattrlistat(dir_fd, name, &request, &reply, @sizeOf(PrivateSizeReply), options) != 0) {
        return error.AttributeUnavailable;
    }
    if (reply.returned.forkattr & attr_cmnext_privatesize == 0) return error.AttributeUnavailable;
    return @intCast(@max(reply.private_size, 0));
}

fn clone_count(ext_flags: u64, refcount: u32, private_bytes: u64) u32 {
    if (ext_flags & ef_may_share_blocks == 0) return 1;
    if (ext_flags & ef_shares_all_blocks != 0) return @max(refcount, 1);
    if (refcount <= 1 and private_bytes == 0) return 1;
    return @max(refcount, 2);
}

test "only partly shared clones need their private size" {
    try std.testing.expect(!needs_private_bytes(0));
    try std.testing.expect(!needs_private_bytes(ef_may_share_blocks | ef_shares_all_blocks));
    try std.testing.expect(needs_private_bytes(ef_may_share_blocks));
    const full = sharing_from(ef_may_share_blocks | ef_shares_all_blocks, 2, null);
    try std.testing.expectEqual(Sharing{ .clone_count = 2, .private_bytes = 0 }, full);
    const never_cloned = sharing_from(0, 1, null);
    try std.testing.expectEqual(Sharing{ .clone_count = 1, .private_bytes = null }, never_cloned);
}

test "a rewritten clone shares blocks despite a refcount of 1, until its private blocks are gone" {
    const may_share = ef_may_share_blocks;
    const shares_all = ef_may_share_blocks | ef_shares_all_blocks;
    try std.testing.expectEqual(@as(u32, 1), clone_count(0, 1, 0));
    try std.testing.expectEqual(@as(u32, 1), clone_count(0, 3, 4096));
    try std.testing.expectEqual(@as(u32, 3), clone_count(shares_all, 3, 0));
    try std.testing.expectEqual(@as(u32, 2), clone_count(may_share, 1, 4096));
    try std.testing.expectEqual(@as(u32, 1), clone_count(may_share, 1, 0));
    try std.testing.expectEqual(@as(u32, 4), clone_count(may_share, 4, 0));
}
