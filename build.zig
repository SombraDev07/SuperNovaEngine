const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_tracy = b.option(bool, "enable-tracy", "Enable Tracy profiling") orelse false;

    // --- Dependencies -------------------------------------------------------
    const zglfw = b.dependency("zglfw", .{ .target = target });
    const zgpu = b.dependency("zgpu", .{
        .target = target,
        .max_num_bindings_per_group = 24,
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
    const basisu = b.dependency("basisu", .{});

    const zbasis_mod = b.createModule(.{
        .root_source_file = b.path("libs/zbasis/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zgpu", .module = zgpu.module("root") },
            .{ .name = "zpool", .module = zpool.module("root") },
        },
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
            .{ .name = "zbasis", .module = zbasis_mod },
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
                .{ .name = "zstbi", .module = zstbi.module("root") },
                .{ .name = "zbasis", .module = zbasis_mod },
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
    exe.linkLibC();
    addBasisTranscoder(b, exe, basisu);

    // --- Demo texture generator (zstbi PNG write) ---------------------------
    const gen_tex = b.addExecutable(.{
        .name = "gen_demo_textures",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_demo_textures.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zstbi", .module = zstbi.module("root") },
            },
        }),
    });
    gen_tex.linkLibC();
    const run_gen_tex = b.addRunArtifact(gen_tex);
    run_gen_tex.setCwd(b.path("."));
    const gen_tex_step = b.step("gen-textures", "Generate demo PBR PNG textures");
    gen_tex_step.dependOn(&run_gen_tex.step);

    // --- Cook compressed textures (ASTC + Basis/KTX2) -----------------------
    const astc_mod = b.createModule(.{
        .root_source_file = b.path("src/render/astc.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zgpu", .module = zgpu.module("root") },
            .{ .name = "zpool", .module = zpool.module("root") },
        },
    });
    const cook_tex = b.addExecutable(.{
        .name = "cook_textures",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/cook_textures.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zstbi", .module = zstbi.module("root") },
                .{ .name = "astc", .module = astc_mod },
            },
        }),
    });
    cook_tex.linkLibC();
    addBasisEncoder(b, cook_tex, basisu);
    const run_cook_tex = b.addRunArtifact(cook_tex);
    run_cook_tex.setCwd(b.path("."));
    run_cook_tex.step.dependOn(&run_gen_tex.step);
    const cook_tex_step = b.step("cook-textures", "Cook demo PNG → ASTC + Basis/KTX2");
    cook_tex_step.dependOn(&run_cook_tex.step);

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
    mod_tests.linkLibrary(zglfw.artifact("glfw"));
    @import("zgpu").addLibraryPathsTo(mod_tests);
    mod_tests.linkLibrary(zgpu.artifact("zdawn"));
    mod_tests.linkLibrary(zaudio.artifact("miniaudio"));
    mod_tests.linkLibrary(zmesh.artifact("zmesh"));
    mod_tests.linkLibrary(znoise.artifact("FastNoiseLite"));
    mod_tests.linkLibrary(zgui.artifact("imgui"));
    mod_tests.linkLibrary(zphysics.artifact("joltc"));
    mod_tests.linkLibC();
    addBasisTranscoder(b, mod_tests, basisu);

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
}

const cxx_flags = [_][]const u8{
    "-std=c++17",
    "-fno-sanitize=undefined",
    "-DBASISD_SUPPORT_KTX2=1",
    "-DBASISD_SUPPORT_KTX2_ZSTD=1",
    "-DBASISU_NO_ITERATOR_DEBUG_LEVEL",
    "-DBASISU_SUPPORT_SSE=0",
    "-DBASISU_SUPPORT_OPENCL=0",
    "-Wno-unused-parameter",
    "-Wno-unused-variable",
    "-Wno-unused-value",
    "-Wno-deprecated-declarations",
};

const c_flags = [_][]const u8{
    "-fno-sanitize=undefined",
    "-DBASISD_SUPPORT_KTX2=1",
    "-DBASISD_SUPPORT_KTX2_ZSTD=1",
};

fn addBasisIncludes(compile: *std.Build.Step.Compile, basisu: *std.Build.Dependency, b: *std.Build) void {
    compile.addIncludePath(basisu.path("transcoder"));
    compile.addIncludePath(basisu.path("encoder"));
    compile.addIncludePath(basisu.path("zstd"));
    compile.addIncludePath(b.path("libs/zbasis"));
}

fn addBasisTranscoder(b: *std.Build, compile: *std.Build.Step.Compile, basisu: *std.Build.Dependency) void {
    addBasisIncludes(compile, basisu, b);
    compile.addCSourceFile(.{
        .file = basisu.path("transcoder/basisu_transcoder.cpp"),
        .flags = &cxx_flags,
    });
    // Full zstd (encode+decode) for CHMZ second-stage + Basis KTX2.
    compile.addCSourceFile(.{
        .file = basisu.path("zstd/zstd.c"),
        .flags = &c_flags,
    });
    compile.addCSourceFile(.{
        .file = b.path("libs/zbasis/zstd_wrap.c"),
        .flags = &c_flags,
    });
    compile.addCSourceFile(.{
        .file = b.path("libs/zbasis/zbasis.cpp"),
        .flags = &cxx_flags,
    });
    compile.linkLibCpp();
}

fn addBasisEncoder(b: *std.Build, compile: *std.Build.Step.Compile, basisu: *std.Build.Dependency) void {
    addBasisIncludes(compile, basisu, b);
    const encoder_srcs = [_][]const u8{
        "encoder/basisu_backend.cpp",
        "encoder/basisu_basis_file.cpp",
        "encoder/basisu_comp.cpp",
        "encoder/basisu_enc.cpp",
        "encoder/basisu_etc.cpp",
        "encoder/basisu_frontend.cpp",
        "encoder/basisu_gpu_texture.cpp",
        "encoder/basisu_pvrtc1_4.cpp",
        "encoder/basisu_resampler.cpp",
        "encoder/basisu_resample_filters.cpp",
        "encoder/basisu_ssim.cpp",
        "encoder/basisu_uastc_enc.cpp",
        "encoder/basisu_bc7enc.cpp",
        "encoder/jpgd.cpp",
        "encoder/basisu_kernels_sse.cpp",
        "encoder/basisu_opencl.cpp",
        "encoder/pvpngreader.cpp",
        "transcoder/basisu_transcoder.cpp",
    };
    for (encoder_srcs) |rel| {
        compile.addCSourceFile(.{
            .file = basisu.path(rel),
            .flags = &cxx_flags,
        });
    }
    // Full zstd (encoder KTX2 supercompression); transcoder-only builds use zstddeclib.c.
    compile.addCSourceFile(.{
        .file = basisu.path("zstd/zstd.c"),
        .flags = &c_flags,
    });
    compile.addCSourceFile(.{
        .file = b.path("libs/zbasis/zbasis_encode.cpp"),
        .flags = &cxx_flags,
    });
    compile.linkLibCpp();
}
