const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zsynth",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    addZaudio(b, exe);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the zsynth demo");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
}

fn addZaudio(b: *std.Build, compile_step: *std.Build.Step.Compile) void {
    const zaudio = b.dependency("zaudio", .{});
    compile_step.root_module.addImport("zaudio", zaudio.module("root"));
    compile_step.root_module.linkLibrary(zaudio.artifact("miniaudio"));
}
