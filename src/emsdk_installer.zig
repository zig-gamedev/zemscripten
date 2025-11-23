const std = @import("std");
const builtin = @import("builtin");

fn chmod(allocator: std.mem.Allocator, path: []const u8) !void {
    const argv: []const []const u8 = switch (builtin.target.os.tag) {
        .linux, .macos => &.{ "chmod", "+x", path },
        .windows => &.{ "takeown", "/f", path },
        else => return,
    };

    var child = std.process.Child.init(
        argv,
        allocator,
    );
    if (try child.spawnAndWait() != .Exited)
        return error.FailedChmod;
}

fn do_action(
    allocator: std.mem.Allocator,
    emsdk_path: []const u8,
    action: []const u8,
    version: []const u8,
) !void {
    var child = std.process.Child.init(
        &.{
            emsdk_path,
            action,
            version,
        },
        allocator,
    );
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    return switch (try child.wait()) {
        .Exited => {},
        else => |term| {
            std.log.err(
                "running emsdk installer failed for action {s}: {}",
                .{ action, term },
            );
            return error.InstallerFailed;
        },
    };
}

pub fn main() !void {
    var allocator_strategy = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = allocator_strategy.allocator();
    defer _ = allocator_strategy.deinit();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (argv.len != 4) {
        std.log.err(
            "usage: {s} <emsdk script path> <emsdk version> <sdk install path>",
            .{argv[0]},
        );
        return error.InvalidArguments;
    }

    const emsdk_script_path_src = argv[1];
    const version = argv[2];
    const install_path = argv[3];

    const emsdk_dir_src = std.fs.path.dirname(emsdk_script_path_src) orelse unreachable;

    // Create copy of SDK installer in a dedicate output dir
    // FIXME Replace with zig implementation of cp -r
    {
        const emsdk_dir_contents_src = try std.fmt.allocPrint(allocator, "{s}/.", .{emsdk_dir_src});
        var child = std.process.Child.init(
            &.{
                "cp",
                "-r",
                emsdk_dir_contents_src,
                install_path,
            },
            allocator,
        );
        switch (try child.spawnAndWait()) {
            .Exited => {},
            else => |term| {
                std.log.err(
                    "chmod failed with {} ",
                    .{term},
                );
                return error.InstallerFailed;
            },
        }
    }

    const emsdk_script_path_dst = try std.fmt.allocPrint(
        allocator,
        "{s}/emsdk",
        .{install_path},
    );

    try chmod(allocator, emsdk_script_path_dst);
    try do_action(allocator, emsdk_script_path_dst, "install", version);
    try do_action(allocator, emsdk_script_path_dst, "activate", version);
}
