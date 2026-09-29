const std = @import("std");
const Io = std.Io;
const moira = @import("moira");
const cli = moira.cli;

const usage =
    \\usage: moira [-Aclnx] [-H | -L | -P] [-g | -h | -k | -m] [-a | -s | -d depth]
    \\             [-B blocksize] [-I mask] [-t threshold]
    \\             [--share | --exclusive | --pinned | --allocated] [--du | --columns] [file ...]
    \\
    \\Flags follow du(1). The du column reports one metric:
    \\  --share      each entry's fair portion of blocks shared through clones or hard links (default)
    \\  --exclusive  space held by no other entry, freed on deletion
    \\  --pinned     the part of exclusive a snapshot holds until it expires
    \\  --allocated  what du(1) reports
    \\
    \\A terminal gets every metric as columns; pipes get du(1) lines. --du and --columns force either.
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
    const style = try style_of(io, options.layout);
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
        .request = request_for(options, style),
    };
    var walk: moira.walk.Walk = .{ .gpa = gpa, .config = &config, .report = &report };
    defer walk.deinit();

    try report.begin();
    var total: moira.Tally = .{};
    for (options.paths.items) |path| {
        if (try walk.run(path)) |tally| total.merge(tally);
    }
    if (options.grand_total) try report.total(total);
    return report.failed;
}

fn style_of(io: Io, layout: cli.Layout) Io.Cancelable!moira.report.Style {
    return switch (layout) {
        .du => .du,
        .columns => .columns,
        .automatic => if (try Io.File.stdout().isTty(io)) .columns else .du,
    };
}

fn request_for(options: *const cli.Options, style: moira.report.Style) moira.bulk.Request {
    if (options.apparent_size) return .sizes_only;
    if (style == .columns) return .private_sizes;
    return switch (options.metric) {
        .allocated => .sizes_only,
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
