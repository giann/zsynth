const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const debug = b.option(
        bool,
        "debug",
        "Enable renderer debug features regardless of build OptimizeMode",
    ) orelse (optimize == .debug);
    const build_options = b.addOptions();
    build_options.addOption(bool, "debug", debug);

    const mimalloc = buildMimalloc(b, target, optimize);
    const portmidi = buildPortMidi(b, target, optimize);
    const portaudio = buildPortAudio(b, target, optimize);
    const bui = buildBUI(b, target, optimize);

    const exe = b.addExecutable(.{
        .name = "zsynth",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", build_options);

    addSdl3(b, target, exe);
    addZstbi(b, exe);
    addZpool(b, exe);
    addZaudio(b, exe);
    addImGUI(b, exe);
    exe.root_module.linkLibrary(mimalloc);
    exe.root_module.linkLibrary(bui);

    exe.root_module.linkLibrary(portmidi);
    exe.root_module.linkLibrary(portaudio);

    const check = b.step("check", "Compile zsynth without installing it");
    check.dependOn(&exe.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/Serializer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zsynth unit tests");
    test_step.dependOn(&run_tests.step);

    b.installArtifact(exe);
    installAssets(b);

    const run_step = b.step("run", "Run the zsynth demo");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
}

fn installAssets(b: *std.Build) void {
    const assets = [_][]const u8{
        "assets/fonts/giann-shaded.png",
        "assets/shaders/BloomBlur.frag.dxil",
        "assets/shaders/BloomBlur.frag.msl",
        "assets/shaders/BloomBlur.frag.spv",
        "assets/shaders/BloomBright.frag.dxil",
        "assets/shaders/BloomBright.frag.msl",
        "assets/shaders/BloomBright.frag.spv",
        "assets/shaders/BloomComposite.frag.dxil",
        "assets/shaders/BloomComposite.frag.msl",
        "assets/shaders/BloomComposite.frag.spv",
        "assets/shaders/Composite.frag.dxil",
        "assets/shaders/Composite.frag.msl",
        "assets/shaders/Composite.frag.spv",
        "assets/shaders/Composite.vert.dxil",
        "assets/shaders/Composite.vert.msl",
        "assets/shaders/Composite.vert.spv",
        "assets/shaders/Grain.frag.dxil",
        "assets/shaders/Grain.frag.msl",
        "assets/shaders/Grain.frag.spv",
        "assets/shaders/Sharpen.frag.dxil",
        "assets/shaders/Sharpen.frag.msl",
        "assets/shaders/Sharpen.frag.spv",
        "assets/shaders/SpriteGrid.frag.dxil",
        "assets/shaders/SpriteGrid.frag.msl",
        "assets/shaders/SpriteGrid.frag.spv",
        "assets/shaders/SpriteGrid.vert.dxil",
        "assets/shaders/SpriteGrid.vert.msl",
        "assets/shaders/SpriteGrid.vert.spv",
    };

    for (assets) |asset| {
        b.getInstallStep().dependOn(
            &b.addInstallFileWithDir(
                b.path(asset),
                .bin,
                asset,
            ).step,
        );
    }
}

fn addImGUI(b: *std.Build, compile_step: *std.Build.Step.Compile) void {
    const zgui = b.dependency(
        "zgui",
        .{
            .shared = false,
            .backend = .sdl3_gpu,
            .with_implot = true,
        },
    );
    compile_step.root_module.addImport("zgui", zgui.module("root"));
    compile_step.root_module.linkLibrary(zgui.artifact("imgui"));
}

fn addZpool(b: *std.Build, compile_step: *std.Build.Step.Compile) void {
    const zpool = b.dependency("zpool", .{});
    compile_step.root_module.addImport("zpool", zpool.module("root"));
}

fn addZstbi(b: *std.Build, compile_step: *std.Build.Step.Compile) void {
    const zstbi = b.dependency("zstbi", .{});
    compile_step.root_module.addImport("zstbi", zstbi.module("root"));
}

/// Adds zaudio's bindings and miniaudio implementation for decoder APIs.
fn addZaudio(b: *std.Build, compile_step: *std.Build.Step.Compile) void {
    const zaudio = b.dependency("zaudio", .{});
    compile_step.root_module.addImport("zaudio", zaudio.module("root"));
    compile_step.root_module.linkLibrary(zaudio.artifact("miniaudio"));
}

fn addSdl3(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    compile_step: *std.Build.Step.Compile,
) void {
    compile_step.root_module.link_libc = true;

    const zsdl = b.dependency("zsdl", .{});
    compile_step.root_module.addImport("zsdl3", zsdl.module("zsdl3"));

    switch (target.result.os.tag) {
        .windows, .linux => {
            compile_step.root_module.linkSystemLibrary("SDL3", .{});
        },
        .macos => {
            compile_step.root_module.linkFramework("SDL3", .{});
            compile_step.root_module.addRPathSpecial("@executable_path");
        },
        else => {},
    }

    switch (target.result.os.tag) {
        .windows => if (target.result.cpu.arch.isX86()) {
            if (zsdl.builder.lazyDependency("sdl3_prebuilt_x86_64_windows_gnu", .{})) |sdl3| {
                compile_step.root_module.addLibraryPath(sdl3.path("bin"));
                b.getInstallStep().dependOn(&b.addInstallFileWithDir(
                    sdl3.path("bin/SDL3.dll"),
                    .bin,
                    "SDL3.dll",
                ).step);
            }
        },
        .linux => if (target.result.cpu.arch.isX86()) {
            if (zsdl.builder.lazyDependency("sdl3_prebuilt_x86_64_linux_gnu", .{})) |sdl3| {
                compile_step.root_module.addLibraryPath(sdl3.path("lib"));
                b.getInstallStep().dependOn(&b.addInstallFileWithDir(
                    sdl3.path("lib/libSDL3.so"),
                    .bin,
                    "libSDL3.so",
                ).step);
                b.getInstallStep().dependOn(&b.addInstallFileWithDir(
                    sdl3.path("lib/libSDL3.so"),
                    .bin,
                    "libSDL3.so.0",
                ).step);
            }
        },
        .macos => if (zsdl.builder.lazyDependency("sdl3_prebuilt_macos", .{})) |sdl3| {
            compile_step.root_module.addFrameworkPath(sdl3.path("Frameworks"));
            b.getInstallStep().dependOn(&b.addInstallDirectory(.{
                .source_dir = sdl3.path("Frameworks/SDL3.framework"),
                .install_dir = .bin,
                .install_subdir = "SDL3.framework",
            }).step);
        },
        else => {},
    }
}

fn buildMimalloc(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Step.Compile {
    const lib = b.addLibrary(
        .{
            .name = "mimalloc",
            .linkage = .static,
            .use_llvm = true,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .pic = true,
            }),
        },
    );

    lib.root_module.addIncludePath(b.path("vendors/mimalloc/include"));
    lib.root_module.addCSourceFiles(.{
        .files = &.{
            "vendors/mimalloc/src/alloc.c",
            "vendors/mimalloc/src/alloc-aligned.c",
            "vendors/mimalloc/src/alloc-posix.c",
            "vendors/mimalloc/src/arena.c",
            "vendors/mimalloc/src/arena-meta.c",
            "vendors/mimalloc/src/bitmap.c",
            "vendors/mimalloc/src/heap.c",
            "vendors/mimalloc/src/init.c",
            "vendors/mimalloc/src/libc.c",
            "vendors/mimalloc/src/options.c",
            "vendors/mimalloc/src/os.c",
            "vendors/mimalloc/src/page.c",
            "vendors/mimalloc/src/page-map.c",
            "vendors/mimalloc/src/random.c",
            "vendors/mimalloc/src/stats.c",
            "vendors/mimalloc/src/prim/prim.c",
        },
        .flags = if (optimize != .debug)
            &.{
                "-DNDEBUG=1",
                "-DMI_SECURE=0",
                "-DMI_STAT=0",
                "-DMI_SHOW_ERRORS=1",
                "-fno-sanitize=undefined",
                "-Wno-date-time",
                "-DMI_SKIP_COLLECT_ON_EXIT=1",
            }
        else
            &.{
                "-fno-sanitize=undefined",
                "-Wno-date-time",
                "-DMI_SKIP_COLLECT_ON_EXIT=1",
            },
    });

    return lib;
}

fn buildPortMidi(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Step.Compile {
    const lib = b.addLibrary(
        .{
            .name = "portmidi",
            .linkage = .static,
            .use_llvm = true,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .pic = true,
            }),
        },
    );

    lib.root_module.addIncludePath(b.path("vendors/portmidi/pm_common"));
    lib.root_module.addIncludePath(b.path("vendors/portmidi/porttime"));
    const common_sources = [_][]const u8{
        "vendors/portmidi/pm_common/portmidi.c",
        "vendors/portmidi/pm_common/pmutil.c",
        "vendors/portmidi/porttime/porttime.c",
    };
    lib.root_module.addCSourceFiles(.{ .files = &common_sources });

    switch (target.result.os.tag) {
        .linux => {
            lib.root_module.addIncludePath(b.path("vendors/portmidi/pm_linux"));
            lib.root_module.addCSourceFiles(.{
                .files = &.{
                    "vendors/portmidi/porttime/ptlinux.c",
                    "vendors/portmidi/pm_linux/pmlinux.c",
                    "vendors/portmidi/pm_linux/pmlinuxalsa.c",
                },
                .flags = &.{ "-DPMALSA", "-pthread" },
            });
            lib.root_module.linkSystemLibrary("asound", .{});
            lib.root_module.linkSystemLibrary("pthread", .{});
        },
        .macos => {
            lib.root_module.addIncludePath(b.path("vendors/portmidi/pm_mac"));
            lib.root_module.addCSourceFiles(.{ .files = &.{
                "vendors/portmidi/porttime/ptmacosx_cf.c",
                "vendors/portmidi/porttime/ptmacosx_mach.c",
                "vendors/portmidi/pm_mac/pmmac.c",
                "vendors/portmidi/pm_mac/pmmacosxcm.c",
            } });
            lib.root_module.linkFramework("CoreAudio", .{});
            lib.root_module.linkFramework("CoreFoundation", .{});
            lib.root_module.linkFramework("CoreMidi", .{});
            lib.root_module.linkFramework("CoreServices", .{});
        },
        .windows => {
            lib.root_module.addIncludePath(b.path("vendors/portmidi/pm_win"));
            lib.root_module.addCSourceFiles(.{ .files = &.{
                "vendors/portmidi/porttime/ptwinmm.c",
                "vendors/portmidi/pm_win/pmwin.c",
                "vendors/portmidi/pm_win/pmwinmm.c",
            } });
            lib.root_module.linkSystemLibrary("winmm", .{});
        },
        else => @panic("PortMidi is not configured for this target OS"),
    }

    return lib;
}

/// Builds the Steinberg ASIO SDK host helpers for a Windows target.
fn buildASIO(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "asio",
        .linkage = .static,
        .use_llvm = true,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
            .pic = true,
        }),
    });

    lib.root_module.addIncludePath(b.path("vendors/asio/common"));
    lib.root_module.addIncludePath(b.path("vendors/asio/host"));
    lib.root_module.addIncludePath(b.path("vendors/asio/host/pc"));

    // PortAudio's ASIO finder applies this SDK fix before compiling asiolist.cpp.
    const asio_list_path = b.root.joinString(b.allocator, "vendors/asio/host/pc/asiolist.cpp") catch
        @panic("failed to resolve the ASIO SDK driver list source path");
    const asio_list_source = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        asio_list_path,
        b.allocator,
        .limited(1024 * 1024),
    ) catch @panic("failed to read the ASIO SDK driver list source");
    std.debug.assert(std.mem.indexOf(u8, asio_list_source, "delete lpdrv") != null);
    const patched_asio_list_source = std.mem.replaceOwned(
        u8,
        b.allocator,
        asio_list_source,
        "delete lpdrv",
        "delete[] lpdrv",
    ) catch @panic("failed to patch the ASIO SDK driver list source");
    const generated_files = b.addWriteFiles();
    const patched_asio_list = generated_files.add("patched_asiolist.cpp", patched_asio_list_source);

    lib.root_module.addCSourceFiles(.{ .files = &.{
        "vendors/asio/common/asio.cpp",
        "vendors/asio/host/asiodrivers.cpp",
    } });
    lib.root_module.addCSourceFile(.{ .file = patched_asio_list });
    lib.root_module.linkSystemLibrary("ole32", .{});
    lib.root_module.linkSystemLibrary("uuid", .{});

    return lib;
}

/// Builds PortAudio with the native host API used on the target platform.
fn buildPortAudio(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "portaudio",
        .linkage = .static,
        .use_llvm = true,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = target.result.os.tag == .windows,
            .pic = true,
        }),
    });

    lib.root_module.addIncludePath(b.path("vendors/portaudio/include"));
    lib.root_module.addIncludePath(b.path("vendors/portaudio/src/common"));

    const common_sources = [_][]const u8{
        "vendors/portaudio/src/common/pa_allocation.c",
        "vendors/portaudio/src/common/pa_converters.c",
        "vendors/portaudio/src/common/pa_cpuload.c",
        "vendors/portaudio/src/common/pa_debugprint.c",
        "vendors/portaudio/src/common/pa_dither.c",
        "vendors/portaudio/src/common/pa_front.c",
        "vendors/portaudio/src/common/pa_process.c",
        "vendors/portaudio/src/common/pa_ringbuffer.c",
        "vendors/portaudio/src/common/pa_stream.c",
        "vendors/portaudio/src/common/pa_trace.c",
    };
    lib.root_module.addCSourceFiles(.{ .files = &common_sources });

    switch (target.result.os.tag) {
        .linux => {
            lib.root_module.addIncludePath(b.path("vendors/portaudio/src/os/unix"));
            lib.root_module.addCSourceFiles(.{
                .files = &.{
                    "vendors/portaudio/src/os/unix/pa_unix_hostapis.c",
                    "vendors/portaudio/src/os/unix/pa_unix_util.c",
                    "vendors/portaudio/src/os/unix/pa_pthread_util.c",
                    "vendors/portaudio/src/hostapi/alsa/pa_linux_alsa.c",
                },
                .flags = &.{ "-DPA_USE_ALSA=1", "-pthread" },
            });
            lib.root_module.linkSystemLibrary("asound", .{});
            lib.root_module.linkSystemLibrary("pthread", .{});
            lib.root_module.linkSystemLibrary("m", .{});
        },
        .macos => {
            lib.root_module.addIncludePath(b.path("vendors/portaudio/src/os/unix"));
            lib.root_module.addIncludePath(b.path("vendors/portaudio/src/hostapi/coreaudio"));
            lib.root_module.addCSourceFiles(.{
                .files = &.{
                    "vendors/portaudio/src/os/unix/pa_unix_hostapis.c",
                    "vendors/portaudio/src/os/unix/pa_unix_util.c",
                    "vendors/portaudio/src/os/unix/pa_pthread_util.c",
                    "vendors/portaudio/src/hostapi/coreaudio/pa_mac_core.c",
                    "vendors/portaudio/src/hostapi/coreaudio/pa_mac_core_blocking.c",
                    "vendors/portaudio/src/hostapi/coreaudio/pa_mac_core_utilities.c",
                },
                .flags = &.{ "-DPA_USE_COREAUDIO=1", "-pthread" },
            });
            lib.root_module.linkSystemLibrary("pthread", .{});
            lib.root_module.linkSystemLibrary("m", .{});
            lib.root_module.linkFramework("CoreAudio", .{});
            lib.root_module.linkFramework("AudioToolbox", .{});
            lib.root_module.linkFramework("AudioUnit", .{});
            lib.root_module.linkFramework("CoreFoundation", .{});
            lib.root_module.linkFramework("CoreServices", .{});
        },
        .windows => {
            const asio = buildASIO(b, target, optimize);
            lib.root_module.addIncludePath(b.path("vendors/portaudio/src/os/win"));
            lib.root_module.addIncludePath(b.path("vendors/portaudio/src/hostapi/asio"));
            lib.root_module.addIncludePath(b.path("vendors/asio/common"));
            lib.root_module.addIncludePath(b.path("vendors/asio/host"));
            lib.root_module.addIncludePath(b.path("vendors/asio/host/pc"));
            lib.root_module.addCSourceFiles(.{
                .files = &.{
                    "vendors/portaudio/src/os/win/pa_win_coinitialize.c",
                    "vendors/portaudio/src/os/win/pa_win_hostapis.c",
                    "vendors/portaudio/src/os/win/pa_win_util.c",
                    "vendors/portaudio/src/os/win/pa_win_version.c",
                    "vendors/portaudio/src/os/win/pa_win_waveformat.c",
                    "vendors/portaudio/src/hostapi/wasapi/pa_win_wasapi.c",
                },
                .flags = &.{
                    "-DPA_USE_ASIO=1",
                    "-DPA_USE_WASAPI=1",
                    "-D_WIN32_WINNT=0x0600",
                    "-DWINVER=0x0600",
                },
            });
            lib.root_module.addCSourceFiles(.{
                .files = &.{
                    "vendors/portaudio/src/hostapi/asio/pa_asio.cpp",
                    "vendors/portaudio/src/hostapi/asio/iasiothiscallresolver.cpp",
                },
                .flags = &.{"-DPA_USE_ASIO=1"},
            });
            lib.root_module.linkLibrary(asio);
            lib.root_module.linkSystemLibrary("winmm", .{});
            lib.root_module.linkSystemLibrary("ole32", .{});
            lib.root_module.linkSystemLibrary("uuid", .{});
        },
        else => @panic("PortAudio is not configured for this target OS"),
    }

    return lib;
}

/// Builds BUI's base C/C++ runtime and links its platform window backend.
fn buildBUI(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "bui",
        .linkage = .static,
        .use_llvm = true,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
            .pic = true,
        }),
    });

    const core_c_sources = [_][]const u8{
        "vendors/BUI/core/intern/listbase.c",
        "vendors/BUI/core/intern/BLI_dynstr.c",
        "vendors/BUI/core/intern/BLI_memarena.c",
        "vendors/BUI/core/intern/BLI_mempool.c",
        "vendors/BUI/core/intern/BLI_ghash.c",
        "vendors/BUI/core/intern/BLI_ghash_utils.c",
        "vendors/BUI/core/intern/BLI_linklist.c",
        "vendors/BUI/core/intern/rct.c",
        "vendors/BUI/core/intern/math_base.c",
        "vendors/BUI/core/intern/math_vector.c",
        "vendors/BUI/core/intern/math_matrix_c.c",
        "vendors/BUI/core/intern/math_rotation_c.c",
        "vendors/BUI/core/intern/math_color.c",
        "vendors/BUI/core/intern/math_geom.c",
        "vendors/BUI/core/intern/matrix_invert.c",
        "vendors/BUI/core/intern/string.c",
        "vendors/BUI/core/intern/string_utf8.c",
        "vendors/BUI/core/intern/string_cursor_utf8.c",
        "vendors/BUI/core/intern/endian_switch.c",
        "vendors/BUI/core/intern/array_utils_c.c",
        "vendors/BUI/core/intern/sort_utils.c",
        "vendors/BUI/core/intern/hash_mm3.c",
        "vendors/BUI/core/intern/hash_mm2.c",
        "vendors/BUI/core/intern/svd_m3.c",
        "vendors/BUI/core/intern/fnmatch.c",
        "vendors/BUI/core/intern/gsqueue.c",
        "vendors/BUI/core/intern/stack.c",
        "vendors/BUI/core/intern/BLI_assert.c",
        "vendors/BUI/core/intern/guardedalloc.c",
        "vendors/BUI/core/intern/bui_threads.c",
        "vendors/BUI/core/intern/bui_system_stubs.c",
        "vendors/BUI/core/intern/wcwidth/wcwidth.c",
    };
    const core_cxx_sources = [_][]const u8{
        "vendors/BUI/core/intern/expr_pylike_eval.cc",
        "vendors/BUI/core/intern/string_search.cc",
        "vendors/BUI/core/intern/bui_blender_c.cc",
    };
    lib.root_module.addIncludePath(b.path("vendors/BUI/core/include"));
    lib.root_module.addIncludePath(b.path("vendors/BUI/types/dna/include"));
    lib.root_module.addIncludePath(b.path("vendors/BUI/core"));
    lib.root_module.addIncludePath(b.path("vendors/BUI/core/intern"));
    lib.root_module.addIncludePath(b.path("vendors/BUI/core/intern/atomic"));
    lib.root_module.addIncludePath(b.path("vendors/BUI/core/intern/wcwidth"));
    lib.root_module.addCSourceFiles(.{
        .files = &core_c_sources,
        .flags = &.{
            "-funsigned-char",
            "-includevendors/BUI/core/intern/bui_c_compat.h",
        },
    });
    lib.root_module.addCSourceFiles(.{
        .files = &core_cxx_sources,
        .flags = &.{ "-funsigned-char", "-std=c++20" },
    });

    const gpu_sources = [_][]const u8{
        "vendors/BUI/gpu/intern/gpu_null.c",
        "vendors/BUI/gpu/intern/gpu_raster.c",
        "vendors/BUI/gpu/intern/gpu_d3d11.c",
        "vendors/BUI/gpu/extern/freetype/src/base/ftsystem.c",
        "vendors/BUI/gpu/extern/freetype/src/base/ftinit.c",
        "vendors/BUI/gpu/extern/freetype/src/base/ftdebug.c",
        "vendors/BUI/gpu/extern/freetype/src/base/ftbase.c",
        "vendors/BUI/gpu/extern/freetype/src/base/ftmm.c",
        "vendors/BUI/gpu/extern/freetype/src/base/ftbitmap.c",
        "vendors/BUI/gpu/extern/freetype/src/base/ftbbox.c",
        "vendors/BUI/gpu/extern/freetype/src/truetype/truetype.c",
        "vendors/BUI/gpu/extern/freetype/src/sfnt/sfnt.c",
        "vendors/BUI/gpu/extern/freetype/src/autofit/autofit.c",
        "vendors/BUI/gpu/extern/freetype/src/smooth/smooth.c",
        "vendors/BUI/gpu/extern/freetype/src/psnames/psnames.c",
        "vendors/BUI/gpu/extern/freetype/src/cff/cff.c",
        "vendors/BUI/gpu/extern/freetype/src/psaux/psaux.c",
        "vendors/BUI/gpu/extern/freetype/src/pshinter/pshinter.c",
    };
    lib.root_module.addIncludePath(b.path("vendors/BUI/gpu/include"));
    lib.root_module.addIncludePath(b.path("vendors/BUI/gpu/extern/freetype/bui"));
    lib.root_module.addIncludePath(b.path("vendors/BUI/gpu/extern/freetype/include"));
    lib.root_module.addCSourceFiles(.{
        .files = &gpu_sources,
        .flags = &.{
            "-DBUI_GPU",
            "-DBUI_TEXT_FREETYPE",
            "-DBUI_TEXT_FT",
            "-DBUI_SLUG_DEFAULT=1",
            "-DFT2_BUILD_LIBRARY",
            "-DFT_CONFIG_OPTIONS_H=<bui_ftoption.h>",
            "-DFT_CONFIG_MODULES_H=<bui_ftmodule.h>",
        },
    });

    lib.root_module.addIncludePath(b.path("vendors/BUI/compat/include"));
    lib.root_module.addCSourceFile(.{
        .file = b.path("vendors/BUI/compat/intern/bui_stubs.cc"),
        .flags = &.{"-std=c++20"},
    });

    const kit_c_sources = [_][]const u8{
        "vendors/BUI/kit/intern/kit_core.c",
        "vendors/BUI/kit/intern/kit_draw.c",
        "vendors/BUI/kit/intern/kit_theme_presets.c",
        "vendors/BUI/kit/intern/kit_theme.c",
        "vendors/BUI/kit/intern/kit_json.c",
        "vendors/BUI/kit/intern/kit_icons_data.c",
        "vendors/BUI/kit/intern/kit_widgets.c",
        "vendors/BUI/kit/intern/kit_views.c",
        "vendors/BUI/kit/intern/kit_menus.c",
        "vendors/BUI/kit/intern/kit_color.c",
        "vendors/BUI/kit/intern/kit_frame.c",
        "vendors/BUI/kit/intern/kit_textarea.c",
        "vendors/BUI/kit/intern/kit_ime.c",
        "vendors/BUI/kit/intern/kit_ime_win32.c",
        "vendors/BUI/kit/intern/kit_window_win32.c",
        "vendors/BUI/kit/intern/kit_window_x11.c",
        "vendors/BUI/kit/intern/kit_window_null.c",
        "vendors/BUI/kit/intern/kit_icons_svg.c",
        "vendors/BUI/kit/intern/kit_regions.c",
        "vendors/BUI/kit/intern/kit_nodes.c",
        "vendors/BUI/kit/intern/kit_custom.c",
        "vendors/BUI/kit/intern/kit_filebrowser.c",
        "vendors/BUI/kit/intern/kit_filebrowser_paths.c",
        "vendors/BUI/kit/intern/kit_filebrowser_posix.c",
        "vendors/BUI/kit/intern/kit_filebrowser_win32.c",
        "vendors/BUI/kit/intern/kit_filelist.c",
        "vendors/BUI/kit/intern/kit_filelist_view.c",
        "vendors/BUI/kit/intern/kit_fileops.c",
        "vendors/BUI/kit/intern/kit_fsmenu.c",
        "vendors/BUI/kit/intern/image/imbuf.c",
        "vendors/BUI/kit/intern/image/filetype.c",
        "vendors/BUI/kit/intern/image/anim.c",
        "vendors/BUI/kit/intern/image/play.c",
        "vendors/BUI/kit/intern/image/format_hdr.c",
        "vendors/BUI/kit/intern/image/format_pnm.c",
        "vendors/BUI/kit/intern/image/format_svg.c",
        "vendors/BUI/kit/intern/image/format_wuffs.c",
        "vendors/BUI/kit/intern/image/format_jpeg.c",
        "vendors/BUI/kit/intern/image/format_webp.c",
        "vendors/BUI/kit/intern/image/cache.c",
        "vendors/BUI/kit/intern/image/loader.c",
        "vendors/BUI/kit/intern/image/draw.c",
        "vendors/BUI/kit/intern/image/video.c",
        "vendors/BUI/kit/intern/image/movie.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/jaricom.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/jcomapi.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/jdapimin.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/jdarith.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/jdatasrc.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/jdhuff.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/jdinput.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/jdlhuff.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/jdmarker.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/jdmaster.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/jdphuff.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/jerror.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/jmemmgr.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/wrapper/jdapistd-8.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/wrapper/jdcoefct-8.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/wrapper/jdcolor-8.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/wrapper/jddctmgr-8.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/wrapper/jddiffct-8.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/wrapper/jdlossls-8.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/wrapper/jdmainct-8.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/wrapper/jdmerge-8.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/wrapper/jdpostct-8.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/wrapper/jdsample-8.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/wrapper/jidctflt-8.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/wrapper/jidctfst-8.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/wrapper/jidctint-8.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/wrapper/jidctred-8.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/src/wrapper/jutils-8.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/bui/jmem_bui.c",
        "vendors/BUI/kit/extern/libjpeg-turbo/bui/jdecode_8bit_only.c",
        "vendors/BUI/kit/extern/libwebp/src/dec/alpha_dec.c",
        "vendors/BUI/kit/extern/libwebp/src/dec/buffer_dec.c",
        "vendors/BUI/kit/extern/libwebp/src/dec/frame_dec.c",
        "vendors/BUI/kit/extern/libwebp/src/dec/idec_dec.c",
        "vendors/BUI/kit/extern/libwebp/src/dec/io_dec.c",
        "vendors/BUI/kit/extern/libwebp/src/dec/quant_dec.c",
        "vendors/BUI/kit/extern/libwebp/src/dec/tree_dec.c",
        "vendors/BUI/kit/extern/libwebp/src/dec/vp8_dec.c",
        "vendors/BUI/kit/extern/libwebp/src/dec/vp8l_dec.c",
        "vendors/BUI/kit/extern/libwebp/src/dec/webp_dec.c",
        "vendors/BUI/kit/extern/libwebp/src/demux/anim_decode.c",
        "vendors/BUI/kit/extern/libwebp/src/demux/demux.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/alpha_processing.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/alpha_processing_mips_dsp_r2.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/alpha_processing_neon.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/alpha_processing_sse2.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/alpha_processing_sse41.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/cpu.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/dec.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/dec_clip_tables.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/dec_mips32.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/dec_mips_dsp_r2.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/dec_msa.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/dec_neon.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/dec_sse2.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/dec_sse41.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/filters.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/filters_mips_dsp_r2.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/filters_msa.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/filters_neon.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/filters_sse2.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/lossless.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/lossless_avx2.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/lossless_mips_dsp_r2.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/lossless_msa.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/lossless_neon.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/lossless_sse2.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/lossless_sse41.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/rescaler.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/rescaler_mips32.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/rescaler_mips_dsp_r2.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/rescaler_msa.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/rescaler_neon.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/rescaler_sse2.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/upsampling.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/upsampling_mips_dsp_r2.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/upsampling_msa.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/upsampling_neon.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/upsampling_sse2.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/upsampling_sse41.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/yuv.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/yuv_mips32.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/yuv_mips_dsp_r2.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/yuv_neon.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/yuv_sse2.c",
        "vendors/BUI/kit/extern/libwebp/src/dsp/yuv_sse41.c",
        "vendors/BUI/kit/extern/libwebp/src/utils/bit_reader_utils.c",
        "vendors/BUI/kit/extern/libwebp/src/utils/color_cache_utils.c",
        "vendors/BUI/kit/extern/libwebp/src/utils/filters_utils.c",
        "vendors/BUI/kit/extern/libwebp/src/utils/huffman_utils.c",
        "vendors/BUI/kit/extern/libwebp/src/utils/palette.c",
        "vendors/BUI/kit/extern/libwebp/src/utils/quant_levels_dec_utils.c",
        "vendors/BUI/kit/extern/libwebp/src/utils/random_utils.c",
        "vendors/BUI/kit/extern/libwebp/src/utils/rescaler_utils.c",
        "vendors/BUI/kit/extern/libwebp/src/utils/thread_utils.c",
        "vendors/BUI/kit/extern/libwebp/src/utils/utils.c",
        "vendors/BUI/kit/extern/nanosvg/blender_nanosvg.c",
        "vendors/BUI/kit/extern/nanosvg/blender_raster.c",
    };
    const kit_cxx_sources = [_][]const u8{
        "vendors/BUI/kit/intern/blender/interface_string_search.cc",
        "vendors/BUI/kit/intern/blender/interface_utils.cc",
        "vendors/BUI/kit/intern/blender/interface_undo.cc",
    };
    lib.root_module.addIncludePath(b.path("vendors/BUI/kit/include"));
    lib.root_module.addIncludePath(b.path("vendors/BUI/kit/intern"));
    lib.root_module.addIncludePath(b.path("vendors/BUI/kit/extern/nanosvg"));
    lib.root_module.addIncludePath(b.path("vendors/BUI/kit/extern/wuffs"));
    lib.root_module.addIncludePath(b.path("vendors/BUI/kit/extern/libjpeg-turbo/bui"));
    lib.root_module.addIncludePath(b.path("vendors/BUI/kit/extern/libjpeg-turbo/src"));
    lib.root_module.addIncludePath(b.path("vendors/BUI/kit/extern/libwebp"));
    lib.root_module.addCSourceFiles(.{
        .files = &kit_c_sources,
        .flags = &.{
            "-DBUI_FILEBROWSER",
            "-DBUI_IMAGE_PNG",
            "-DBUI_IMAGE_GIF",
            "-DBUI_IMAGE_BMP",
            "-DBUI_IMAGE_TGA",
            "-DBUI_IMAGE_QOI",
            "-DBUI_IMAGE_JPEG",
            "-DBUI_IMAGE_WEBP",
            "-DBUI_IMAGE_HDR",
            "-DBUI_IMAGE_PNM",
            "-DBUI_IMAGE_SVG",
            "-DBUI_TEXT_FREETYPE",
            "-DBUI_VIDEO",
            "-DWEBP_USE_THREAD",
        },
    });
    lib.root_module.addCSourceFiles(.{
        .files = &kit_cxx_sources,
        .flags = &.{"-std=c++20"},
    });

    lib.root_module.addCSourceFile(.{
        .file = b.path("vendors/BUI/api/bui_c_api.c"),
    });
    lib.root_module.addIncludePath(b.path("vendors/BUI/api"));

    switch (target.result.os.tag) {
        .linux => {
            lib.root_module.addCSourceFile(.{
                .file = b.path("vendors/BUI/gpu/intern/gpu_gl.c"),
                .flags = &.{ "-DBUI_GPU", "-DBUI_GPU_GL" },
            });
            lib.root_module.addCSourceFile(.{
                .file = b.path("vendors/BUI/kit/intern/image/movie_gst.c"),
                .flags = &.{"-DBUI_VIDEO_GST"},
            });
            lib.root_module.linkSystemLibrary("dl", .{});
            lib.root_module.linkSystemLibrary("m", .{});
            lib.root_module.linkSystemLibrary("pthread", .{});
        },
        .macos => {
            lib.root_module.addCSourceFile(.{
                .file = b.path("vendors/BUI/kit/intern/image/movie_avf.m"),
                .flags = &.{ "-DBUI_VIDEO_AVF", "-fno-objc-arc" },
            });
            lib.root_module.addCSourceFile(.{
                .file = b.path("vendors/BUI/kit/intern/kit_window_cocoa.m"),
                .flags = &.{ "-DBUI_WINDOW_COCOA", "-fno-objc-arc" },
            });
            lib.root_module.linkFramework("Cocoa", .{});
            lib.root_module.linkFramework("CoreGraphics", .{});
            lib.root_module.linkFramework("AVFoundation", .{ .weak = true });
            lib.root_module.linkFramework("CoreMedia", .{ .weak = true });
            lib.root_module.linkFramework("CoreVideo", .{ .weak = true });
            lib.root_module.linkSystemLibrary("objc", .{});
        },
        .windows => {
            lib.root_module.addCSourceFile(.{
                .file = b.path("vendors/BUI/kit/intern/image/movie_mf.c"),
                .flags = &.{"-DBUI_VIDEO_MF"},
            });
            lib.root_module.linkSystemLibrary("user32", .{});
            lib.root_module.linkSystemLibrary("gdi32", .{});
            lib.root_module.linkSystemLibrary("imm32", .{});
        },
        else => {},
    }

    return lib;
}
