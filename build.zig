const builtin = @import("builtin");
const std = @import("std");

pub const emsdk_ver_major = "4";
pub const emsdk_ver_minor = "0";
pub const emsdk_ver_tiny = "3";
pub const emsdk_version = emsdk_ver_major ++ "." ++ emsdk_ver_minor ++ "." ++ emsdk_ver_tiny;

pub fn build(b: *std.Build) void {
    _ = b.addModule("root", .{ .root_source_file = b.path("src/zemscripten.zig") });
}

pub fn emccPath(b: *std.Build) []const u8 {
    return std.fs.path.join(b.allocator, &.{
        b.dependency("emsdk", .{}).path("").getPath(b),
        "upstream",
        "emscripten",
        switch (builtin.target.os.tag) {
            .windows => "emcc.bat",
            else => "emcc",
        },
    }) catch unreachable;
}

pub fn emrunPath(b: *std.Build) []const u8 {
    return std.fs.path.join(b.allocator, &.{
        b.dependency("emsdk", .{}).path("").getPath(b),
        "upstream",
        "emscripten",
        switch (builtin.target.os.tag) {
            .windows => "emrun.bat",
            else => "emrun",
        },
    }) catch unreachable;
}

pub fn htmlPath(b: *std.Build) []const u8 {
    return std.fs.path.join(b.allocator, &.{
        b.dependency("emsdk", .{}).path("").getPath(b),
        "upstream",
        "emscripten",
        "src",
        "shell.html",
    }) catch unreachable;
}

pub fn activateEmsdkStep(b: *std.Build) *std.Build.Step {
    const emsdk_script_path = std.fs.path.join(b.allocator, &.{
        b.dependency("emsdk", .{}).path("").getPath(b),
        switch (builtin.target.os.tag) {
            .windows => "emsdk.bat",
            else => "emsdk",
        },
    }) catch unreachable;

    var emsdk_install = b.addSystemCommand(&.{ emsdk_script_path, "install", emsdk_version });

    switch (builtin.target.os.tag) {
        .linux, .macos => {
            emsdk_install.step.dependOn(&b.addSystemCommand(&.{ "chmod", "+x", emsdk_script_path }).step);
        },
        .windows => {
            emsdk_install.step.dependOn(&b.addSystemCommand(&.{ "takeown", "/f", emsdk_script_path }).step);
        },
        else => {},
    }

    var emsdk_activate = b.addSystemCommand(&.{ emsdk_script_path, "activate", emsdk_version });
    emsdk_activate.step.dependOn(&emsdk_install.step);

    const step = b.allocator.create(std.Build.Step) catch unreachable;
    step.* = std.Build.Step.init(.{
        .id = .custom,
        .name = "Activate EMSDK",
        .owner = b,
        .makeFn = &struct {
            fn make(_: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {}
        }.make,
    });

    switch (builtin.target.os.tag) {
        .linux, .macos => {
            const chmod_emcc = b.addSystemCommand(&.{ "chmod", "+x", emccPath(b) });
            chmod_emcc.step.dependOn(&emsdk_activate.step);
            step.dependOn(&chmod_emcc.step);

            const chmod_emrun = b.addSystemCommand(&.{ "chmod", "+x", emrunPath(b) });
            chmod_emrun.step.dependOn(&emsdk_activate.step);
            step.dependOn(&chmod_emrun.step);
        },
        .windows => {
            const takeown_emcc = b.addSystemCommand(&.{ "takeown", "/f", emccPath(b) });
            takeown_emcc.step.dependOn(&emsdk_activate.step);
            step.dependOn(&takeown_emcc.step);

            const takeown_emrun = b.addSystemCommand(&.{ "takeown", "/f", emrunPath(b) });
            takeown_emrun.step.dependOn(&emsdk_activate.step);
            step.dependOn(&takeown_emrun.step);
        },
        else => {},
    }

    return step;
}

pub const EmccFlags = std.StringHashMap(void);

pub const EmccDefaultFlagsOverrides = struct {
    optimize: std.builtin.OptimizeMode,
    fsanitize: bool,
};

pub fn emccDefaultFlags(allocator: std.mem.Allocator, options: EmccDefaultFlagsOverrides) EmccFlags {
    var args = EmccFlags.init(allocator);
    switch (options.optimize) {
        .Debug => {
            args.put("-O0", {}) catch unreachable;
            args.put("-gsource-map", {}) catch unreachable;
            if (options.fsanitize)
                args.put("-fsanitize=undefined", {}) catch unreachable;
        },
        .ReleaseSafe => {
            args.put("-O3", {}) catch unreachable;
            if (options.fsanitize) {
                args.put("-fsanitize=undefined", {}) catch unreachable;
                args.put("-fsanitize-minimal-runtime", {}) catch unreachable;
            }
        },
        .ReleaseFast => {
            args.put("-O3", {}) catch unreachable;
        },
        .ReleaseSmall => {
            args.put("-Oz", {}) catch unreachable;
        },
    }
    return args;
}

pub const EmccSettings = std.StringHashMap([]const u8);

pub const EmsdkAllocator = enum {
    none,
    dlmalloc,
    emmalloc,
    @"emmalloc-debug",
    @"emmalloc-memvalidate",
    @"emmalloc-verbose",
    mimalloc,
};

pub const EmccDefaultSettingsOverrides = struct {
    optimize: std.builtin.OptimizeMode,
    emsdk_allocator: EmsdkAllocator = .emmalloc,
    shell_file: ?[]const u8 = null,
};

pub fn emccDefaultSettings(allocator: std.mem.Allocator, options: EmccDefaultSettingsOverrides) EmccSettings {
    var settings = EmccSettings.init(allocator);
    switch (options.optimize) {
        .Debug, .ReleaseSafe => {
            settings.put("SAFE_HEAP", "1") catch unreachable;
            settings.put("STACK_OVERFLOW_CHECK", "1") catch unreachable;
            settings.put("ASSERTIONS", "1") catch unreachable;
        },
        else => {},
    }
    settings.put("USE_OFFSET_CONVERTER", "1") catch unreachable;
    settings.put("MALLOC", @tagName(options.emsdk_allocator)) catch unreachable;
    return settings;
}

pub const EmccFilePath = struct {
    src_path: []const u8,
    virtual_path: ?[]const u8 = null,
};

pub const StepOptions = struct {
    optimize: std.builtin.OptimizeMode,
    flags: EmccFlags,
    settings: EmccSettings,
    use_preload_plugins: bool = false,
    embed_paths: ?[]const EmccFilePath = null,
    preload_paths: ?[]const EmccFilePath = null,
    shell_file_path: ?std.Build.LazyPath = null,
    out_file_name: ?[]const u8 = null,
    install_dir: std.Build.InstallDir,
};

pub fn emccStep(
    b: *std.Build,
    wasm: *std.Build.Step.Compile,
    options: StepOptions,
) *std.Build.Step {
    var emcc = b.addSystemCommand(&.{emccPath(b)});

    var iterFlags = options.flags.iterator();
    while (iterFlags.next()) |kvp| {
        emcc.addArg(kvp.key_ptr.*);
    }

    var iterSettings = options.settings.iterator();
    while (iterSettings.next()) |kvp| {
        emcc.addArg(std.fmt.allocPrint(
            b.allocator,
            "-s{s}={s}",
            .{ kvp.key_ptr.*, kvp.value_ptr.* },
        ) catch unreachable);
    }

    emcc.addArtifactArg(wasm);
    {
        for (wasm.root_module.getGraph().modules) |module| {
            for (module.link_objects.items) |link_object| {
                switch (link_object) {
                    .other_step => |compile_step| {
                        switch (compile_step.kind) {
                            .lib => {
                                emcc.addArtifactArg(compile_step);
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            }
        }
    }

    emcc.addArg("-o");
    const out_file = out_file: {
        if (options.out_file_name) |out_file_name| {
            break :out_file emcc.addOutputFileArg(out_file_name);
        } else {
            break :out_file emcc.addOutputFileArg(b.fmt("{s}.html", .{wasm.name}));
        }
    };

    if (options.use_preload_plugins) {
        emcc.addArg("--use-preload-plugins");
    }

    if (options.embed_paths) |embed_paths| {
        for (embed_paths) |path| {
            const path_arg = if (path.virtual_path) |virtual_path|
                std.fmt.allocPrint(
                    b.allocator,
                    "{s}@{s}",
                    .{ path.src_path, virtual_path },
                ) catch unreachable
            else
                path.src_path;
            emcc.addArgs(&.{ "--embed-file", path_arg });
        }
    }

    if (options.preload_paths) |preload_paths| {
        for (preload_paths) |path| {
            const path_arg = if (path.virtual_path) |virtual_path|
                std.fmt.allocPrint(
                    b.allocator,
                    "{s}@{s}",
                    .{ path.src_path, virtual_path },
                ) catch unreachable
            else
                path.src_path;
            emcc.addArgs(&.{ "--preload-file", path_arg });
        }
    }

    if (options.shell_file_path) |shell_file_path| {
        emcc.addArg("--shell-file");
        emcc.addFileArg(shell_file_path);
        emcc.addFileInput(shell_file_path);
    }

    const install_step = b.addInstallDirectory(.{
        .source_dir = out_file.dirname(),
        .install_dir = options.install_dir,
        .install_subdir = "",
    });
    install_step.step.dependOn(&emcc.step);

    return &install_step.step;
}

pub fn emrunStep(
    b: *std.Build,
    html_path: []const u8,
    extra_args: []const []const u8,
) *std.Build.Step {
    var emrun = b.addSystemCommand(&.{emrunPath(b)});
    emrun.addArgs(extra_args);
    emrun.addArg(html_path);
    // emrun.addArg("--");

    return &emrun.step;
}
