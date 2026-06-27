const builtin = @import("builtin");
const std = @import("std");

pub const emsdk_ver_major = "4";
pub const emsdk_ver_minor = "0";
pub const emsdk_ver_tiny = "19";
pub const emsdk_version = emsdk_ver_major ++ "." ++ emsdk_ver_minor ++ "." ++ emsdk_ver_tiny;

pub fn build(b: *std.Build) void {
    _ = b.addModule("root", .{ .root_source_file = b.path("src/zemscripten.zig") });
}

pub fn emccPath(b: *std.Build) std.Build.LazyPath {
    return b.dependency("emsdk", .{}).path("upstream/emscripten/emcc.py");
}

pub fn emrunPath(b: *std.Build) std.Build.LazyPath {
    return switch (builtin.target.os.tag) {
        .windows => b.dependency("emsdk", .{}).path("upstream/emscripten/emrun.bat"),
        else => b.dependency("emsdk", .{}).path("upstream/emscripten/emrun"),
    };
}

pub fn htmlPath(b: *std.Build) std.Build.LazyPath {
    return b.dependency("emsdk", .{}).path("upstream/emscripten/src/shell.html");
}

/// Returns a step that install/update and otherwise prepare emscripten.
///
/// The returned step typically must be called / depended on before compiling and/or running code.
pub fn activateEmsdkStep(b: *std.Build) *std.Build.Step {
    const user_step = b.step("Activate EMSDK", "Install/Update and otherwise prepare emscripten sdk");

    const path_emsdk_script = switch (builtin.target.os.tag) {
        .windows => b.dependency("emsdk", .{}).path("emsdk.bat"),
        else => b.dependency("emsdk", .{}).path("emsdk"),
    };

    var emsdk_update_cmd = b.addRunFile(path_emsdk_script);
    emsdk_update_cmd.addArg("update");

    switch (builtin.target.os.tag) {
        .linux, .macos => {
            const make_emsdk_executable = b.addSystemCommand(&.{ "chmod", "+x" });
            make_emsdk_executable.addFileArg(path_emsdk_script);
            emsdk_update_cmd.step.dependOn(&make_emsdk_executable.step);
        },
        .windows => {
            const make_emsdk_executable = b.addSystemCommand(&.{ "takeown", "/f" });
            make_emsdk_executable.addFileArg(path_emsdk_script);
            emsdk_update_cmd.step.dependOn(&make_emsdk_executable.step);
        },
        else => {},
    }

    var emsdk_install_cmd = b.addRunFile(path_emsdk_script);
    emsdk_install_cmd.addArg("install");
    emsdk_install_cmd.addArg(emsdk_version);
    emsdk_install_cmd.step.dependOn(&emsdk_update_cmd.step);

    var emsdk_activate_cmd = b.addRunFile(path_emsdk_script);
    emsdk_activate_cmd.addArg("activate");
    emsdk_activate_cmd.addArg(emsdk_version);
    emsdk_activate_cmd.step.dependOn(&emsdk_install_cmd.step);
    user_step.dependOn(&emsdk_activate_cmd.step);

    switch (builtin.target.os.tag) {
        .linux, .macos => {
            const make_emcc_executable = b.addSystemCommand(&.{ "chmod", "a+x" });
            make_emcc_executable.addFileArg(emccPath(b));
            make_emcc_executable.step.dependOn(&emsdk_install_cmd.step);
            user_step.dependOn(&make_emcc_executable.step);

            const make_emrun_executable = b.addSystemCommand(&.{ "chmod", "a+x" });
            make_emrun_executable.addFileArg(emrunPath(b));
            make_emrun_executable.step.dependOn(&emsdk_install_cmd.step);
            user_step.dependOn(&make_emrun_executable.step);
        },
        .windows => {
            const make_emcc_executable = b.addSystemCommand(&.{ "takeown", "/f" });
            make_emcc_executable.addFileArg(emccPath(b));
            make_emcc_executable.step.dependOn(&emsdk_install_cmd.step);
            user_step.dependOn(&make_emcc_executable.step);

            const make_emrun_executable = b.addSystemCommand(&.{ "takeown", "/f" });
            make_emrun_executable.addFileArg(emrunPath(b));
            make_emrun_executable.step.dependOn(&emsdk_install_cmd.step);
            user_step.dependOn(&make_emrun_executable.step);
        },
        else => {},
    }

    return user_step;
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

pub const ResourceFile = struct {
    src_path: std.Build.LazyPath,
    virtual_path: ?[]const u8 = null,

    pub fn get(self: ResourceFile, b: *std.Build) []const u8 {
        return if (self.virtual_path) |virtual_path|
            b.fmt(
                "{s}@{s}",
                .{ self.src_path.path(b, ""), virtual_path },
            )
        else
            self.src_path.path(b, "");
    }
};

pub const StepOptions = struct {
    optimize: std.builtin.OptimizeMode,
    flags: EmccFlags,
    settings: EmccSettings,
    use_preload_plugins: bool = false,
    embed_paths: ?[]const ResourceFile = null,
    preload_paths: ?[]const ResourceFile = null,
    shell_file_path: ?std.Build.LazyPath = null,
    js_library_path: ?std.Build.LazyPath = null,
    out_file_name: []const u8,
    install_dir: std.Build.InstallDir,
};

pub fn emccStep(
    b: *std.Build,
    src_paths: []const std.Build.LazyPath,
    compile_steps: []const *std.Build.Step.Compile,
    options: StepOptions,
) *std.Build.Step {
    var emcc = b.addRunFile(emccPath(b));

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

    for (src_paths) |src_path| {
        emcc.addFileArg(src_path);
    }

    for (compile_steps) |compile_step| {
        emcc.addArtifactArg(compile_step);
        for (compile_step.root_module.getGraph().modules) |module| {
            for (module.link_objects.items) |link_object| {
                switch (link_object) {
                    .other_step => |linked_compile_step| {
                        switch (linked_compile_step.kind) {
                            .lib => {
                                emcc.addArtifactArg(linked_compile_step);
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
    const out_file = emcc.addOutputFileArg(options.out_file_name);

    if (options.use_preload_plugins) {
        emcc.addArg("--use-preload-plugins");
    }

    if (options.embed_paths) |embed_paths| {
        for (embed_paths) |path| {
            emcc.addArg("--embed-file");
            emcc.addFileArg(path.src_path);
        }
    }

    if (options.preload_paths) |preload_paths| {
        for (preload_paths) |path| {
            emcc.addArg("--preload-file");
            emcc.addFileArg(path.src_path);
        }
    }

    if (options.shell_file_path) |shell_file_path| {
        emcc.addArg("--shell-file");
        emcc.addFileArg(shell_file_path);
    }

    if (options.js_library_path) |js_library_path| {
        emcc.addArg("--js-library");
        emcc.addFileArg(js_library_path);
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
    html_path: std.Build.LazyPath,
    extra_args: []const []const u8,
) *std.Build.Step {
    var emrun = b.addRunFile(emrunPath(b));
    emrun.addArgs(extra_args);
    emrun.addFileArg(html_path);
    // emrun.addArg("--");

    return &emrun.step;
}
