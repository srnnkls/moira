const std = @import("std");
const Io = std.Io;
const moira = @import("moira");
const build_options = @import("build_options");
const cli = moira.cli;

const usage =
    \\usage: moira [-Aclnx] [-H | -L | -P] [-g | -h | -k | -m] [-a | -s | -d depth]
    \\             [-B blocksize] [-I mask] [-t threshold] [-S | -E | -p] [-C] [--version] [file ...]
    \\
    \\Without -S, -E, -p or -C, moira prints what du(1) prints.
    \\  -S, --share      each entry's fair portion of blocks shared through clones or hard links
    \\  -E, --exclusive  space held by no other entry, freed on deletion
    \\  -p, --pinned     the part of exclusive a snapshot holds until it expires
    \\  -C, --columns    every metric side by side
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var out_buffer: [16 * 1024]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &out_buffer);
    var diagnostics_buffer: [1024]u8 = undefined;
    var diagnostics = Io.File.stderr().writerStreaming(io, &diagnostics_buffer);
    defer diagnostics.flush() catch {};

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var diagnostic: cli.Diagnostic = .{};
    var options = cli.parse(init.gpa, arguments[1..], &diagnostic) catch |err| {
        try diagnostics.interface.print("moira: {s}: {s}\n{s}", .{
            parse_failure(err), diagnostic.argument, usage,
        });
        return 1;
    };
    defer options.deinit(init.gpa);
    if (options.version) {
        try out.interface.print("moira {s}\n", .{build_options.version});
        try out.flush();
        return 0;
    }
    if (options.help) {
        try out.interface.writeAll(usage);
        try out.flush();
        return 0;
    }
    if (options.paths.items.len == 0) try options.paths.append(init.gpa, ".");

    const failed = try run(io, init.gpa, &options, init.environ_map, &out.interface, &diagnostics.interface);
    out.flush() catch |err| return if (out.err) |cause| cause else err;
    return if (failed) 1 else 0;
}

fn run(
    io: Io,
    gpa: std.mem.Allocator,
    options: *const cli.Options,
    environment: *const std.process.Environ.Map,
    out: *Io.Writer,
    diagnostics: *Io.Writer,
) !bool {
    const units = options.units orelse units: {
        const resolved = cli.units_from_environment(environment.get("BLOCKSIZE"));
        if (resolved.clamped) try diagnostics.writeAll("moira: minimum blocksize is 512\n");
        break :units resolved.units;
    };
    const style: moira.report.Style = switch (options.layout) {
        .du => .du,
        .columns => .columns,
    };
    const sharing_hint = style == .du and options.metric == .allocated and
        !options.apparent_size and try Io.File.stderr().isTty(io);
    var report: moira.report.Report = .{
        .out = out,
        .diagnostics = diagnostics,
        .style = style,
        .metric = options.metric,
        .units = units,
        .max_depth = options.max_depth,
        .show_files = options.show_files,
        .threshold_bytes = options.threshold_bytes,
    };
    const config: moira.walk.Config = .{
        .symlinks = options.symlinks,
        .one_file_system = options.one_file_system,
        .apparent_size = options.apparent_size,
        .count_links = options.count_links,
        .skip_nodump = options.skip_nodump,
        .rounding_bytes = rounding_bytes(options),
        .ignore_masks = options.ignore_masks.items,
        .request = request_for(options, style, sharing_hint),
    };
    var walk: moira.walk.Walk = .{ .gpa = gpa, .config = &config, .report = &report };
    defer walk.deinit();

    try report.begin();
    var total: moira.Tally = .{};
    for (options.paths.items) |path| {
        if (try walk.run(path)) |tally| total.merge(tally);
    }
    if (options.grand_total) try report.total(total);
    if (sharing_hint) try write_sharing_hint(diagnostics, total);
    return report.failed;
}

const sharing_hint_bytes_min = 1 << 20;

fn write_sharing_hint(diagnostics: *Io.Writer, total: moira.Tally) Io.Writer.Error!void {
    if (total.allocated_bytes < total.share_bytes + sharing_hint_bytes_min) return;
    var shared: [moira.display.width_max]u8 = undefined;
    var allocated: [moira.display.width_max]u8 = undefined;
    try diagnostics.print(
        "moira: {s} of {s} is shared through clones or hard links; -S shows each entry's share, -C every metric\n",
        .{
            std.mem.trimStart(u8, moira.display.format(&shared, total.allocated_bytes - total.share_bytes, .human_binary), " "),
            std.mem.trimStart(u8, moira.display.format(&allocated, total.allocated_bytes, .human_binary), " "),
        },
    );
}

fn request_for(
    options: *const cli.Options,
    style: moira.report.Style,
    sharing_hint: bool,
) moira.bulk.Request {
    if (options.apparent_size) return .sizes_only;
    if (style == .columns) return .private_sizes;
    return switch (options.metric) {
        .allocated => if (sharing_hint) .clone_flags else .sizes_only,
        .share, .exclusive => .clone_flags,
        .pinned => .private_sizes,
    };
}

fn rounding_bytes(options: *const cli.Options) ?u64 {
    const requested = options.rounding_bytes orelse return null;
    if (options.apparent_size) return requested;
    return std.mem.alignForward(u64, requested, cli.minimum_block_bytes);
}

fn parse_failure(err: cli.ParseError) []const u8 {
    return switch (err) {
        error.UnknownOption => "unknown option",
        error.MissingValue => "option requires a value",
        error.InvalidNumber => "invalid number",
        error.FilesWithDepth => "-a cannot be combined with -s or -d",
        error.OutOfMemory => "out of memory",
    };
}
