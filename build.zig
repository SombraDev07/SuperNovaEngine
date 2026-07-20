const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_tracy = b.option(bool, "enable-tracy", "Enable Tracy profiling") orelse false;

    // --- Dependencies -------------------------------------------------------
    const zglfw = b.dependency("zglfw", .{ .target = target });
    const zgpu = b.dependency("zgpu", .{
        .target = target,
        .max_num_bindings_per_group = 16,
    });
    const zpool = b.dependency("zpool", .{});
    const zmath = b.dependency("zmath", .{ .target = target });
    const zjobs = b.dependency("zjobs", .{});
    const zaudio = b.dependency("zaudio", .{ .target = target });
    const zmesh = b.dependency("zmesh", .{ .target = target });
    const znoise = b.dependency("znoise", .{ .target = target });
    const zstbi = b.dependency("zstbi", .{ .target = target });
    const ztracy = b.dependency("ztracy", .{
        .enable_ztracy = enable_tracy,
        .callstack = if (enable_tracy) @as(u32, 16) else @as(u32, 0),
    });
    const zphysics = b.dependency("zphysics", .{ .target = target });
    const zig_network = b.dependency("zig_network", .{});
    const zgui = b.dependency("zgui", .{
        .target = target,
        .backend = .glfw_wgpu,
    });

    // --- Engine library module ----------------------------------------------
    const engine_mod = b.addModule("TucanoEngine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zglfw", .module = zglfw.module("root") },
            .{ .name = "zgpu", .module = zgpu.module("root") },
            .{ .name = "zpool", .module = zpool.module("root") },
            .{ .name = "zmath", .module = zmath.module("root") },
            .{ .name = "zjobs", .module = zjobs.module("root") },
            .{ .name = "zaudio", .module = zaudio.module("root") },
            .{ .name = "zmesh", .module = zmesh.module("root") },
            .{ .name = "znoise", .module = znoise.module("root") },
            .{ .name = "zstbi", .module = zstbi.module("root") },
            .{ .name = "ztracy", .module = ztracy.module("root") },
            .{ .name = "zphysics", .module = zphysics.module("root") },
            .{ .name = "network", .module = zig_network.module("network") },
            .{ .name = "zgui", .module = zgui.module("root") },
        },
    });

    // --- Executable ---------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "tucano",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "TucanoEngine", .module = engine_mod },
                .{ .name = "zglfw", .module = zglfw.module("root") },
                .{ .name = "zgpu", .module = zgpu.module("root") },
                .{ .name = "zmath", .module = zmath.module("root") },
                .{ .name = "zgui", .module = zgui.module("root") },
            },
        }),
    });

    // Link native libraries
    exe.linkLibrary(zglfw.artifact("glfw"));
    @import("zgpu").addLibraryPathsTo(exe);
    exe.linkLibrary(zgpu.artifact("zdawn"));
    exe.linkLibrary(zaudio.artifact("miniaudio"));
    exe.linkLibrary(zmesh.artifact("zmesh"));
    exe.linkLibrary(znoise.artifact("FastNoiseLite"));
    exe.linkLibrary(zgui.artifact("imgui"));
    exe.linkLibrary(zphysics.artifact("joltc"));
    if (enable_tracy) {
        exe.linkLibrary(ztracy.artifact("tracy"));
    }

    // Platform SDK paths (macOS / Linux)
    if (target.result.os.tag == .macos) {
        if (b.lazyDependency("system_sdk", .{})) |system_sdk| {
            exe.addLibraryPath(system_sdk.path("macos12/usr/lib"));
            exe.addSystemFrameworkPath(system_sdk.path("macos12/System/Library/Frameworks"));
        }
    } else if (target.result.os.tag == .linux) {
        if (b.lazyDependency("system_sdk", .{})) |system_sdk| {
            exe.addLibraryPath(system_sdk.path("linux/lib/x86_64-linux-gnu"));
        }
    }

    // Install assets
    const install_assets = b.addInstallDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .bin,
        .install_subdir = "assets",
    });
    exe.step.dependOn(&install_assets.step);

    b.installArtifact(exe);

    // --- Run ----------------------------------------------------------------
    const run_step = b.step("run", "Run TucanoEngine");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // --- Tests --------------------------------------------------------------
    const mod_tests = b.addTest(.{ .root_module = engine_mod });
    // Tests that don't need GPU still need linked C libs for imports that pull natives.
    mod_tests.linkLibrary(zglfw.artifact("glfw"));
    @import("zgpu").addLibraryPathsTo(mod_tests);
    mod_tests.linkLibrary(zgpu.artifact("zdawn"));
    mod_tests.linkLibrary(zaudio.artifact("miniaudio"));
    mod_tests.linkLibrary(zmesh.artifact("zmesh"));
    mod_tests.linkLibrary(znoise.artifact("FastNoiseLite"));
    mod_tests.linkLibrary(zgui.artifact("imgui"));
    mod_tests.linkLibrary(zphysics.artifact("joltc"));

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
}
