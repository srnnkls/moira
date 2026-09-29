//! Directory entries with sizes and APFS sharing attributes from getattrlistbulk(2).

const std = @import("std");
const apfs = @import("apfs.zig");

/// Which sharing attributes to request; private sizes make APFS walk each file's extents.
pub const Request = enum { sizes_only, clone_flags, private_sizes };

pub const Kind = enum { file, directory, symlink, other };

pub const Entry = struct {
    /// Borrowed from the reader's buffer; valid until the next call to `next`.
    name: [:0]const u8,
    kind: Kind,
    device: i32,
    inode: u64,
    flags: u32,
    link_count: u32,
    allocated_bytes: u64,
    apparent_bytes: u64,
    ext_flags: ?u64,
    clone_refcount: ?u32,
    private_bytes: ?u64,
    error_code: u32,
};

const attr_cmn_name: u32 = 0x00000001;
const attr_cmn_devid: u32 = 0x00000002;
const attr_cmn_objtype: u32 = 0x00000008;
const attr_cmn_flags: u32 = 0x00040000;
const attr_cmn_fileid: u32 = 0x02000000;
const attr_cmn_error: u32 = 0x20000000;
const attr_cmn_returned_attrs: u32 = 0x80000000;
const attr_dir_allocsize: u32 = 0x00000008;
const attr_dir_datalength: u32 = 0x00000020;
const attr_file_linkcount: u32 = 0x00000001;
const attr_file_allocsize: u32 = 0x00000004;
const attr_file_datalength: u32 = 0x00000200;

const vnode_regular = 1;
const vnode_directory = 2;
const vnode_symlink = 5;

extern "c" fn getattrlistbulk(
    dir_fd: std.c.fd_t,
    attr_list: *const apfs.AttrList,
    buffer: *anyopaque,
    buffer_size: usize,
    options: u64,
) c_int;

pub const buffer_bytes = 64 * 1024;

pub const ReadError = error{ReadFailed};

pub const Reader = struct {
    fd: std.c.fd_t,
    buffer: *align(8) [buffer_bytes]u8,
    request: Request,
    entries_left: u32 = 0,
    cursor: usize = 0,
    last_errno: c_int = 0,

    pub fn next(reader: *Reader) ReadError!?Entry {
        if (reader.entries_left == 0) {
            const attr_list = attr_list_for(reader.request);
            const count = getattrlistbulk(
                reader.fd,
                &attr_list,
                reader.buffer,
                buffer_bytes,
                apfs.fsopt_attr_cmn_extended,
            );
            if (count < 0) {
                reader.last_errno = std.c._errno().*;
                return error.ReadFailed;
            }
            if (count == 0) return null;
            reader.entries_left = @intCast(count);
            reader.cursor = 0;
        }
        const record = reader.buffer[reader.cursor..];
        const record_len = std.mem.readInt(u32, record[0..4], .little);
        std.debug.assert(record_len >= 4 and reader.cursor + record_len <= buffer_bytes);
        reader.cursor += record_len;
        reader.entries_left -= 1;
        return parse(record[0..record_len]);
    }
};

fn attr_list_for(request: Request) apfs.AttrList {
    return .{
        .commonattr = attr_cmn_returned_attrs | attr_cmn_name | attr_cmn_devid | attr_cmn_objtype |
            attr_cmn_flags | attr_cmn_fileid | attr_cmn_error,
        .dirattr = attr_dir_allocsize | attr_dir_datalength,
        .fileattr = attr_file_linkcount | attr_file_allocsize | attr_file_datalength,
        .forkattr = switch (request) {
            .sizes_only => 0,
            .clone_flags => apfs.attr_cmnext_ext_flags | apfs.attr_cmnext_clone_refcnt,
            .private_sizes => apfs.attr_cmnext_privatesize | apfs.attr_cmnext_ext_flags |
                apfs.attr_cmnext_clone_refcnt,
        },
    };
}

fn parse(record: []const u8) Entry {
    var cursor: Cursor = .{ .bytes = record, .offset = 4 };
    const returned = cursor.attribute_set();
    const error_code = if (returned.commonattr & attr_cmn_error != 0) cursor.int(u32) else 0;
    const name_field = cursor.offset;
    const name_offset = cursor.int(i32);
    const name_len = cursor.int(u32);
    const name_start: usize = @intCast(@as(i64, @intCast(name_field)) + name_offset);
    std.debug.assert(name_len >= 1 and name_start + name_len <= record.len);
    var entry: Entry = .{
        .name = record[name_start .. name_start + name_len - 1 :0],
        .kind = .other,
        .device = 0,
        .inode = 0,
        .flags = 0,
        .link_count = 1,
        .allocated_bytes = 0,
        .apparent_bytes = 0,
        .ext_flags = null,
        .clone_refcount = null,
        .private_bytes = null,
        .error_code = error_code,
    };
    if (returned.commonattr & attr_cmn_devid != 0) entry.device = cursor.int(i32);
    if (returned.commonattr & attr_cmn_objtype != 0) entry.kind = kind_of(cursor.int(u32));
    if (returned.commonattr & attr_cmn_flags != 0) entry.flags = cursor.int(u32);
    if (returned.commonattr & attr_cmn_fileid != 0) entry.inode = cursor.int(u64);
    if (returned.dirattr & attr_dir_allocsize != 0) entry.allocated_bytes = cursor.int(u64);
    if (returned.dirattr & attr_dir_datalength != 0) entry.apparent_bytes = cursor.int(u64);
    if (returned.fileattr & attr_file_linkcount != 0) entry.link_count = cursor.int(u32);
    if (returned.fileattr & attr_file_allocsize != 0) entry.allocated_bytes = cursor.int(u64);
    if (returned.fileattr & attr_file_datalength != 0) entry.apparent_bytes = cursor.int(u64);
    if (returned.forkattr & apfs.attr_cmnext_privatesize != 0) {
        entry.private_bytes = @intCast(@max(cursor.int(i64), 0));
    }
    if (returned.forkattr & apfs.attr_cmnext_ext_flags != 0) entry.ext_flags = cursor.int(u64);
    if (returned.forkattr & apfs.attr_cmnext_clone_refcnt != 0) {
        entry.clone_refcount = cursor.int(u32);
    }
    return entry;
}

fn kind_of(object_type: u32) Kind {
    return switch (object_type) {
        vnode_regular => .file,
        vnode_directory => .directory,
        vnode_symlink => .symlink,
        else => .other,
    };
}

const Cursor = struct {
    bytes: []const u8,
    offset: usize,

    fn int(cursor: *Cursor, comptime T: type) T {
        const size = @sizeOf(T);
        std.debug.assert(cursor.offset + size <= cursor.bytes.len);
        defer cursor.offset += size;
        return std.mem.readInt(T, cursor.bytes[cursor.offset..][0..size], .little);
    }

    fn attribute_set(cursor: *Cursor) apfs.AttributeSet {
        return .{
            .commonattr = cursor.int(u32),
            .volattr = cursor.int(u32),
            .dirattr = cursor.int(u32),
            .fileattr = cursor.int(u32),
            .forkattr = cursor.int(u32),
        };
    }
};

test "records are parsed by their returned attribute set" {
    var record = [_]u8{0} ** 80;
    var writer = std.Io.Writer.fixed(&record);
    try writer.writeInt(u32, 72, .little);
    try writer.writeInt(u32, attr_cmn_returned_attrs | attr_cmn_name | attr_cmn_devid |
        attr_cmn_objtype | attr_cmn_error, .little);
    try writer.writeInt(u32, 0, .little);
    try writer.writeInt(u32, 0, .little);
    try writer.writeInt(u32, attr_file_linkcount | attr_file_allocsize, .little);
    try writer.writeInt(u32, apfs.attr_cmnext_clone_refcnt, .little);
    try writer.writeInt(u32, 0, .little);
    try writer.writeInt(i32, 40, .little);
    try writer.writeInt(u32, 4, .little);
    try writer.writeInt(i32, 7, .little);
    try writer.writeInt(u32, vnode_regular, .little);
    try writer.writeInt(u32, 3, .little);
    try writer.writeInt(u64, 8192, .little);
    try writer.writeInt(u32, 2, .little);
    @memcpy(record[68..72], "abc\x00");

    const entry = parse(record[0..72]);
    try std.testing.expectEqualStrings("abc", entry.name);
    try std.testing.expectEqual(Kind.file, entry.kind);
    try std.testing.expectEqual(@as(i32, 7), entry.device);
    try std.testing.expectEqual(@as(u32, 3), entry.link_count);
    try std.testing.expectEqual(@as(u64, 8192), entry.allocated_bytes);
    try std.testing.expectEqual(@as(?u32, 2), entry.clone_refcount);
    try std.testing.expectEqual(@as(?u64, null), entry.ext_flags);
    try std.testing.expectEqual(@as(u64, 0), entry.inode);
}
