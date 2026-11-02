const std = @import("std");
const sdl = @import("zsdl3");
const G = @import("graphics.zig");
const Renderer = @import("Renderer.zig");

pub const Self = @This();

/// Persistent sampler requests used by queued post-processing commands.
const nearest_sampler_requests = [_]G.Sampler{.NearestClamp};
const linear_sampler_requests = [_]G.Sampler{.LinearClamp};

pub const Error = error{OutOfMemory};

pub const Tag = enum {
    /// Applies animated luminance grain to the frame.
    grain,
    /// Applies spatial sharpening to the frame.
    sharpen,
    /// Applies thresholded, blurred light bloom to the frame.
    bloom,
};

pub const PostProcess = union(Tag) {
    /// Animated luminance grain.
    grain: GrainProcess,
    /// Spatial frame sharpening.
    sharpen: SharpenProcess,
    /// Thresholded, blurred light bloom.
    bloom: BloomProcess,
};

pub const GrainProcess = struct {
    elapsed_ms: u64 = 0,
    interval_ms: u64 = 50,
    params: G.ShaderTypes.GrainParameters,
};

/// State and parameters for the fullscreen sharpening pass.
pub const SharpenProcess = struct {
    /// Sharpening parameters uploaded to the fragment shader.
    params: G.ShaderTypes.SharpenParameters,
};

/// State and parameters for the multi-pass fullscreen bloom effect.
pub const BloomProcess = struct {
    /// Shader parameters shared by the bloom passes.
    params: G.ShaderTypes.BloomParameters,
};

pub const Render = *const fn (
    self: *Self,
    gpa: std.mem.Allocator,
    renderer: *Renderer,
    dt: u64,
    present: bool,
) Error!void;
pub const Worker = *const fn (
    self: *Self,
    gpa: std.mem.Allocator,
    io: std.Io,
    renderer: *Renderer,
    previous: *sdl.GPUTexture,
    acquired: Renderer.Resources.Acquired,
    cmd_buffer: *sdl.GPUCommandBuffer,
) Renderer.WorkerError!void;

process: PostProcess,
render: Render,
worker: Worker,
target_texture: Renderer.TextureHandle,
target_texture_format: sdl.GPUTextureFormat,
/// Half-resolution thresholded bloom texture.
bright_texture: ?Renderer.TextureHandle = null,
/// Half-resolution ping-pong blur texture.
blur_texture: ?Renderer.TextureHandle = null,
/// Inverse dimensions used by the half-resolution blur passes.
bloom_texel_size: [2]f32 = .{ 0, 0 },
uniform_data: [1]Renderer.UniformData = undefined,

pub fn grainProcess(
    gpa: std.mem.Allocator,
    renderer: *Renderer,
    params: G.ShaderTypes.GrainParameters,
    render_width: u32,
    render_height: u32,
) !Self {
    return try .init(
        gpa,
        renderer,
        .{ .grain = .{ .params = params } },
        renderGrain,
        grainWorker,
        render_width,
        render_height,
    );
}

/// Creates a fullscreen sharpening post-process with the requested strength.
pub fn sharpenProcess(
    gpa: std.mem.Allocator,
    renderer: *Renderer,
    strength: f32,
    render_width: u32,
    render_height: u32,
) !Self {
    return try .init(
        gpa,
        renderer,
        .{
            .sharpen = .{
                .params = .{
                    .strength = strength,
                    .texel_size = .{
                        1.0 / @as(f32, @floatFromInt(render_width)),
                        1.0 / @as(f32, @floatFromInt(render_height)),
                    },
                },
            },
        },
        renderSharpen,
        sharpenWorker,
        render_width,
        render_height,
    );
}

/// Creates a half-resolution bright-pass, blur, and composite bloom effect.
pub fn bloomProcess(
    gpa: std.mem.Allocator,
    renderer: *Renderer,
    threshold: f32,
    intensity: f32,
    render_width: u32,
    render_height: u32,
) !Self {
    const format = sdl.GPUTextureFormat.r8g8b8a8_unorm;
    const target_texture = try createTexture(gpa, renderer, format, render_width, render_height);

    const bloom_width = @max(render_width / 2, 1);
    const bloom_height = @max(render_height / 2, 1);
    const bright_texture = try createTexture(gpa, renderer, format, bloom_width, bloom_height);

    const blur_texture = try createTexture(gpa, renderer, format, bloom_width, bloom_height);

    return Self{
        .process = .{
            .bloom = .{
                .params = .{
                    .threshold = threshold,
                    .intensity = intensity,
                },
            },
        },
        .render = renderBloom,
        .worker = bloomWorker,
        .target_texture = target_texture,
        .target_texture_format = format,
        .bright_texture = bright_texture,
        .blur_texture = blur_texture,
        .bloom_texel_size = .{
            1.0 / @as(f32, @floatFromInt(bloom_width)),
            1.0 / @as(f32, @floatFromInt(bloom_height)),
        },
    };
}

pub fn init(
    gpa: std.mem.Allocator,
    renderer: *Renderer,
    process: PostProcess,
    render: Render,
    worker: Worker,
    render_width: u32,
    render_height: u32,
) !Self {
    // Maybe other post-processing will require different size of format of texture, for now we just use this
    const target_texture_create_info = std.mem.zeroInit(
        sdl.GPUTextureCreateInfo,
        .{
            .type = .texturetype_2d,
            .format = .r8g8b8a8_unorm,
            .width = render_width,
            .height = render_height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .usage = .{ .color_target = true, .sampler = true },
        },
    );
    const target_texture = renderer.textures.getAvailable(target_texture_create_info) orelse
        try renderer.textures.add(
            target_texture_create_info,
            .{
                .texture = try sdl.createGPUTexture(
                    renderer.device,
                    &target_texture_create_info,
                ),
            },
            gpa,
        );

    return Self{
        .process = process,
        .render = render,
        .worker = worker,
        .target_texture = target_texture,
        .target_texture_format = target_texture_create_info.format,
    };
}

pub fn deinit(self: *Self, renderer: *Renderer) void {
    releaseTexture(renderer, self.target_texture);
    if (self.bright_texture) |texture|
        releaseTexture(renderer, texture);
    if (self.blur_texture) |texture|
        releaseTexture(renderer, texture);
}

/// Creates a reusable color target and sampler texture for a post-process.
fn createTexture(
    gpa: std.mem.Allocator,
    renderer: *Renderer,
    format: sdl.GPUTextureFormat,
    width: u32,
    height: u32,
) !Renderer.TextureHandle {
    const create_info = std.mem.zeroInit(
        sdl.GPUTextureCreateInfo,
        .{
            .type = .texturetype_2d,
            .format = format,
            .width = width,
            .height = height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .usage = .{ .color_target = true, .sampler = true },
        },
    );
    return renderer.textures.getAvailable(create_info) orelse
        try renderer.textures.add(
            create_info,
            .{
                .texture = try sdl.createGPUTexture(renderer.device, &create_info),
            },
            gpa,
        );
}

/// Releases a pooled texture and its GPU allocation.
fn releaseTexture(renderer: *Renderer, texture: Renderer.TextureHandle) void {
    sdl.releaseGPUTexture(renderer.device, texture.getColumns().texture);
    _ = texture.pool.removeIfLive(texture.handle);
}

pub fn renderGrain(
    self: *Self,
    gpa: std.mem.Allocator,
    renderer: *Renderer,
    dt: u64,
    present: bool,
) Error!void {
    self.process.grain.elapsed_ms += dt;
    if (self.process.grain.elapsed_ms >= self.process.grain.interval_ms) {
        self.process.grain.params.frame_index +%= 1;
        self.process.grain.elapsed_ms %= self.process.grain.interval_ms;
    }
    self.uniform_data[0] = .{
        .slot = 0,
        .data = std.mem.asBytes(&self.process.grain.params),
    };
    try renderer.commands.append(
        gpa,
        .init(
            self.target_texture.getColumns().texture,
            Self,
            self,
            grainWorker,
            .{
                .samplers = nearest_sampler_requests[0..],
                .uniform_data = .init(.{
                    .fragment = self.uniform_data[0..],
                }),
            },
            present,
        ),
    );
}

/// Queues the sharpening pass for the current frame.
pub fn renderSharpen(
    self: *Self,
    gpa: std.mem.Allocator,
    renderer: *Renderer,
    _: u64,
    present: bool,
) Error!void {
    self.uniform_data[0] = .{
        .slot = 0,
        .data = std.mem.asBytes(&self.process.sharpen.params),
    };
    try renderer.commands.append(
        gpa,
        .init(
            self.target_texture.getColumns().texture,
            Self,
            self,
            sharpenWorker,
            .{
                .samplers = nearest_sampler_requests[0..],
                .uniform_data = .init(.{
                    .fragment = self.uniform_data[0..],
                }),
            },
            present,
        ),
    );
}

/// Queues the multi-pass bloom effect for the current frame.
pub fn renderBloom(
    self: *Self,
    gpa: std.mem.Allocator,
    renderer: *Renderer,
    _: u64,
    present: bool,
) Error!void {
    self.uniform_data[0] = .{
        .slot = 0,
        .data = std.mem.asBytes(&self.process.bloom.params),
    };
    try renderer.commands.append(
        gpa,
        .init(
            self.target_texture.getColumns().texture,
            Self,
            self,
            bloomWorker,
            .{
                .samplers = linear_sampler_requests[0..],
                .uniform_data = .init(.{
                    .fragment = self.uniform_data[0..],
                }),
            },
            present,
        ),
    );
}

pub fn grainWorker(
    self: *Self,
    gpa: std.mem.Allocator,
    io: std.Io,
    renderer: *Renderer,
    previous: *sdl.GPUTexture,
    acquired: Renderer.Resources.Acquired,
    cmd_buffer: *sdl.GPUCommandBuffer,
) Renderer.WorkerError!void {
    const pipeline = renderer.getGraphicsPipeline(
        gpa,
        io,
        .Grain,
        self.target_texture_format,
    ) catch @panic("Could not get graphics pipeline"); // TODO: properly handle error set

    const render_pass = sdl.beginGPURenderPass(
        cmd_buffer,
        @ptrCast(
            &.{
                std.mem.zeroInit(
                    sdl.GPUColorTargetInfo,
                    .{
                        .texture = self.target_texture.getColumns().texture,
                        .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                        .load_op = .clear,
                        .store_op = .store,
                    },
                ),
            },
        ),
        1,
        null,
    );
    defer sdl.endGPURenderPass(render_pass);

    sdl.bindGPUFragmentSamplers(
        render_pass,
        0,
        @ptrCast(
            &.{
                sdl.GPUTextureSamplerBinding{
                    .texture = previous,
                    .sampler = acquired.samplers[0],
                },
            },
        ),
        1,
    );
    sdl.bindGPUGraphicsPipeline(render_pass, pipeline);

    const uniform = acquired.uniform_data.get(.fragment).?[0];
    sdl.pushGPUFragmentUniformData(
        cmd_buffer,
        uniform.slot,
        @ptrCast(uniform.data.ptr),
        @intCast(uniform.data.len),
    );

    sdl.drawGPUPrimitives(
        render_pass,
        6,
        1,
        0,
        0,
    );
}

/// Executes the fullscreen sharpening pass on the previous post-process output.
pub fn sharpenWorker(
    self: *Self,
    gpa: std.mem.Allocator,
    io: std.Io,
    renderer: *Renderer,
    previous: *sdl.GPUTexture,
    acquired: Renderer.Resources.Acquired,
    cmd_buffer: *sdl.GPUCommandBuffer,
) Renderer.WorkerError!void {
    const pipeline = renderer.getGraphicsPipeline(
        gpa,
        io,
        .Sharpen,
        self.target_texture_format,
    ) catch @panic("Could not get graphics pipeline"); // TODO: properly handle error set

    const render_pass = sdl.beginGPURenderPass(
        cmd_buffer,
        @ptrCast(
            &.{
                std.mem.zeroInit(
                    sdl.GPUColorTargetInfo,
                    .{
                        .texture = self.target_texture.getColumns().texture,
                        .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                        .load_op = .clear,
                        .store_op = .store,
                    },
                ),
            },
        ),
        1,
        null,
    );
    defer sdl.endGPURenderPass(render_pass);

    sdl.bindGPUFragmentSamplers(
        render_pass,
        0,
        @ptrCast(
            &.{
                sdl.GPUTextureSamplerBinding{
                    .texture = previous,
                    .sampler = acquired.samplers[0],
                },
            },
        ),
        1,
    );
    sdl.bindGPUGraphicsPipeline(render_pass, pipeline);

    const uniform = acquired.uniform_data.get(.fragment).?[0];
    sdl.pushGPUFragmentUniformData(
        cmd_buffer,
        uniform.slot,
        @ptrCast(uniform.data.ptr),
        @intCast(uniform.data.len),
    );

    sdl.drawGPUPrimitives(
        render_pass,
        6,
        1,
        0,
        0,
    );
}

/// Executes bright extraction, separable blur, and bloom compositing.
pub fn bloomWorker(
    self: *Self,
    gpa: std.mem.Allocator,
    io: std.Io,
    renderer: *Renderer,
    previous: *sdl.GPUTexture,
    acquired: Renderer.Resources.Acquired,
    cmd_buffer: *sdl.GPUCommandBuffer,
) Renderer.WorkerError!void {
    const bright_texture = self.bright_texture orelse
        @panic("Bloom bright texture is missing");
    const blur_texture = self.blur_texture orelse
        @panic("Bloom blur texture is missing");
    const sampler = acquired.samplers[0];
    const uniform = acquired.uniform_data.get(.fragment).?[0];

    const bright_pipeline = renderer.getGraphicsPipeline(
        gpa,
        io,
        .BloomBright,
        self.target_texture_format,
    ) catch @panic("Could not get bloom bright pipeline");
    const blur_pipeline = renderer.getGraphicsPipeline(
        gpa,
        io,
        .BloomBlur,
        self.target_texture_format,
    ) catch @panic("Could not get bloom blur pipeline");
    const composite_pipeline = renderer.getGraphicsPipeline(
        gpa,
        io,
        .BloomComposite,
        self.target_texture_format,
    ) catch @panic("Could not get bloom composite pipeline");

    self.process.bloom.params.direction = .{ 0, 0 };
    self.process.bloom.params.texel_size = self.bloom_texel_size;
    drawBloomPass(
        cmd_buffer,
        bright_texture.getColumns().texture,
        bright_pipeline,
        &.{.{ .texture = previous, .sampler = sampler }},
        uniform,
    );

    self.process.bloom.params.direction = .{ 1, 0 };
    drawBloomPass(
        cmd_buffer,
        blur_texture.getColumns().texture,
        blur_pipeline,
        &.{.{ .texture = bright_texture.getColumns().texture, .sampler = sampler }},
        uniform,
    );

    self.process.bloom.params.direction = .{ 0, 1 };
    drawBloomPass(
        cmd_buffer,
        bright_texture.getColumns().texture,
        blur_pipeline,
        &.{.{ .texture = blur_texture.getColumns().texture, .sampler = sampler }},
        uniform,
    );

    self.process.bloom.params.direction = .{ 0, 0 };
    drawBloomPass(
        cmd_buffer,
        self.target_texture.getColumns().texture,
        composite_pipeline,
        &.{
            .{ .texture = previous, .sampler = sampler },
            .{ .texture = bright_texture.getColumns().texture, .sampler = sampler },
        },
        uniform,
    );
}

/// Records one fullscreen bloom render pass with the supplied texture bindings.
fn drawBloomPass(
    cmd_buffer: *sdl.GPUCommandBuffer,
    target: *sdl.GPUTexture,
    pipeline: *sdl.GPUGraphicsPipeline,
    bindings: []const sdl.GPUTextureSamplerBinding,
    uniform: Renderer.UniformData,
) void {
    const render_pass = sdl.beginGPURenderPass(
        cmd_buffer,
        @ptrCast(
            &.{
                std.mem.zeroInit(
                    sdl.GPUColorTargetInfo,
                    .{
                        .texture = target,
                        .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                        .load_op = .clear,
                        .store_op = .store,
                    },
                ),
            },
        ),
        1,
        null,
    );
    defer sdl.endGPURenderPass(render_pass);

    sdl.bindGPUFragmentSamplers(
        render_pass,
        0,
        @ptrCast(bindings.ptr),
        @intCast(bindings.len),
    );
    sdl.bindGPUGraphicsPipeline(render_pass, pipeline);
    sdl.pushGPUFragmentUniformData(
        cmd_buffer,
        uniform.slot,
        @ptrCast(uniform.data.ptr),
        @intCast(uniform.data.len),
    );
    sdl.drawGPUPrimitives(render_pass, 6, 1, 0, 0);
}
