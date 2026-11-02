const std = @import("std");
const mimalloc = @import("mimalloc.zig");
const ZSynth = @import("ZSynth.zig");

pub fn main(process: std.process.Init) !void {
    const allocator = mimalloc.mim_allocator;
    var zsynth = try ZSynth.init(process, allocator);
    defer zsynth.deinit(allocator);

    try zsynth.start(allocator);
}
