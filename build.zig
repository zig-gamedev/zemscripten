const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("root", .{ .root_source_file = b.path("src/zemscripten.zig") });
    const passthrough = b.addExecutable(
        .{
            .name = "passthrough",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/passthrough.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseFast,
            }),
        },
    );
    b.installArtifact(passthrough);
}

pub fn emccPath(b: *std.Build, emsdk: Emsdk) std.Build.LazyPath {
    return emsdk.emsdk_dir.path(b, b.pathJoin(&.{
        "upstream",
        "emscripten",
        switch (builtin.target.os.tag) {
            .windows => "emcc.bat",
            else => "emcc",
        },
    }));
}

pub fn emrunPath(b: *std.Build, emsdk: Emsdk) std.Build.LazyPath {
    return emsdk.emsdk_dir.path(b, b.pathJoin(&.{
        b.dependency("emsdk", .{}).path("").getPath(b),
        "upstream",
        "emscripten",
        switch (builtin.target.os.tag) {
            .windows => "emrun.bat",
            else => "emrun",
        },
    }));
}

pub fn htmlPath(b: *std.Build, emsdk: Emsdk) std.Build.LazyPath {
    return emsdk.emsdk_dir.path(b, b.pathJoin(&.{
        b.dependency("emsdk", .{}).path("").getPath(b),
        "upstream",
        "emscripten",
        "src",
        "shell.html",
    }));
}

const ActivateEmsdkOptions = struct {
    emsdk: *std.Build.Dependency,
    zemscripten: *std.Build.Dependency,
    sdk_version: ?[]const u8 = null,
};

const Emsdk = struct {
    zemscripten: *std.Build.Dependency,
    step: *std.Build.Step,
    emsdk_dir: std.Build.LazyPath,
};

pub fn activateEmsdkStep(
    b: *std.Build,
    options: ActivateEmsdkOptions,
) Emsdk {
    const version = options.sdk_version orelse "4.0.19";

    const emsdk_installer = b.addExecutable(.{
        .name = "invoker",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .root_source_file = options.zemscripten.path("src/emsdk_installer.zig"),
        }),
    });

    const emsdk_script_path = options.emsdk.path("").join(b.allocator, switch (builtin.target.os.tag) {
        .windows => "emsdk.bat",
        else => "emsdk",
    }) catch unreachable;

    const activate_and_install_step = b.addRunArtifact(emsdk_installer);
    activate_and_install_step.addFileArg(emsdk_script_path);
    activate_and_install_step.addArg(version);
    return .{
        .step = &activate_and_install_step.step,
        .emsdk_dir = activate_and_install_step.addOutputDirectoryArg("emsdk"),
        .zemscripten = options.zemscripten,
    };
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
    js_library_path: ?std.Build.LazyPath = null,
    out_file_name: ?[]const u8 = null,
    install_dir: std.Build.InstallDir,
};

fn addAllLinkedArtifacts(b: *std.Build, emcc: *std.Build.Step.Run, root_module: *std.Build.Module) void {
    for (root_module.getGraph().modules) |module| {
        for (module.link_objects.items) |link_object| {
            switch (link_object) {
                .other_step => |compile_step| {
                    switch (compile_step.kind) {
                        .lib => {
                            emcc.addArtifactArg(compile_step);
                            addAllLinkedArtifacts(b, emcc, compile_step.root_module);
                        },
                        else => {},
                    }
                },
                .static_path => |static_path| {
                    emcc.addFileArg(static_path);
                },
                else => {},
            }
        }
    }
}

pub fn emccStep(
    b: *std.Build,
    emsdk: Emsdk,
    wasm: *std.Build.Step.Compile,
    options: StepOptions,
) *std.Build.Step {
    var emcc = b.addRunArtifact(emsdk.zemscripten.artifact("passthrough"));
    emcc.addFileArg(emccPath(b, emsdk));

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
        addAllLinkedArtifacts(b, emcc, wasm.root_module);
    }

    emcc.addArg("-o");
    const out_file = emcc.addOutputFileArg(
        options.out_file_name orelse b.fmt("{s}.html", .{wasm.name}),
    );

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

    if (options.js_library_path) |js_library_path| {
        emcc.addArg("--js-library");
        emcc.addFileArg(js_library_path);
        emcc.addFileInput(js_library_path);
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
    emsdk: Emsdk,
    html_path: []const u8,
    extra_args: []const []const u8,
) *std.Build.Step {
    var emrun = b.addRunArtifact(emsdk.zemscripten.artifact("passthrough"));
    emrun.addFileArg(emrunPath(b, emsdk));

    emrun.addArgs(extra_args);
    emrun.addArg(html_path);

    return &emrun.step;
}
