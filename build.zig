const std = @import("std");
const protobuf = @import("protobuf");

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

    const exe = b.addExecutable(.{
        .name = "zsynth",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", build_options);

    const protobuf_dep = b.dependency(
        "protobuf",
        .{
            .target = target,
            .optimize = optimize,
        },
    );

    // Generate protobuf bindings before compiling the executable that imports
    // the serialized synth document types.
    const gen_proto = b.step("gen-proto", "Generate Zig files from protobuf definitions");
    const protoc_step = protobuf.RunProtocStep.create(protobuf_dep.builder, target, .{
        .destination_directory = b.path("src/"),
        .protoc = null,
        .source_files = &.{b.path("proto/zsynth.proto")},
        .include_directories = &.{b.path("proto")},
        .preserve_unknown_fields = false,
    });
    gen_proto.dependOn(protoc_step.step);

    addSdl3(b, target, exe);
    addZstbi(b, exe);
    addZpool(b, exe);
    addZaudio(b, exe);
    addImGUI(b, exe);
    addProtobuf(exe, protobuf_dep);
    exe.step.dependOn(gen_proto);
    exe.root_module.linkLibrary(mimalloc);

    const check = b.step("check", "Compile zsynth without installing it");
    check.dependOn(&exe.step);

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

fn buildMimalloc(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "mimalloc",
        .linkage = .static,
        .use_llvm = true,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
        }),
    });

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

fn addZaudio(b: *std.Build, compile_step: *std.Build.Step.Compile) void {
    const zaudio = b.dependency("zaudio", .{});
    compile_step.root_module.addImport("zaudio", zaudio.module("root"));
    compile_step.root_module.linkLibrary(zaudio.artifact("miniaudio"));
}

fn addProtobuf(
    compile_step: *std.Build.Step.Compile,
    protobuf_dep: *std.Build.Dependency,
) void {
    compile_step.root_module.addImport("protobuf", protobuf_dep.module("protobuf"));
}
