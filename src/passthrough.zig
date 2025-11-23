const std = @import("std");

pub fn main() !u8 {
    var allocator_strategy = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = allocator_strategy.allocator();
    defer _ = allocator_strategy.deinit();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (argv.len < 2) {
        std.log.err("need at least one argument", .{});
        return error.InvalidArgument;
    }

    var child = std.process.Child.init(
        argv[1..],
        allocator,
    );

    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stdin_behavior = .Inherit;

    switch (try child.spawnAndWait()) {
        .Exited => |ret| {
            return ret;
        },
        else => |term| {
            std.log.err(
                "{s} failed with {} ",
                .{ argv[1], term },
            );
            return error.InstallerFailed;
        },
    }
}
