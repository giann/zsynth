//! Manages GPU resources and implements the necessary low-level graphics actions
//! needed to realize a RenderingCommand (which expresses the intent to draw
//! something on screen)
//! We may end up running this in a separate thread if it ever makes sense.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const sdl = @import("zsdl3");
const g = @import("graphics.zig");
const a = @import("assets.zig");
const p = @import("pool.zig");
const stbi = @import("zstbi");
const zgui = @import("zgui");

const Self = @This();

window: *sdl.Window,
device: *sdl.GPUDevice,
screen_width: u32,
screen_height: u32,
/// Runtime scale used by every character-grid display.
display_scale: u32,
/// Whether the window is currently in borderless fullscreen mode.
is_fullscreen: bool = false,
/// Whether SDL is currently reporting relative mouse motion for gameplay.
relative_mouse_mode: bool = false,

/// Queue of rendering commands to process in registration order.
commands: std.ArrayList(Command) = .empty,

/// All rendering command that want to render on screen will write on this texture in order
/// But any Command might have its own target texture if its work isn't supposed to be shown right away
/// Command that only do GPU compute will use neither
frame_texture: *sdl.GPUTexture,
frame_texture_initialized: bool = false,

/// Acquired resources recorded into the command buffer being built.
pending_acquired: std.ArrayList(Resources.Acquired) = .empty,

/// Submitted resource batches waiting for GPU completion.
in_flight: std.MultiArrayList(InFlight) = .empty,

/// Long-lived graphics pipelines, separated by pipeline kind and target format.
graphics_pipelines: std.AutoHashMapUnmanaged(GraphicsPipelineKey, *sdl.GPUGraphicsPipeline) = .empty,

/// Long-lived samplers
samplers: std.EnumMap(g.Sampler, *sdl.GPUSampler),

/// Long-lived asset textures
assets: std.EnumMap(a.Asset, AssetResource),

/// Reusable buffers grouped by usage and power of 2 sizes
buffers: BufferMapBucketedPool = .empty,

/// Resuable transfer buffers grouped by usage and power of 2 sizes
transfer_buffers: TransferBufferMapBucketedPool = .empty,

/// Reusable textures
textures: TextureMapPool = .empty,

pub fn init(
    screen_width: u32,
    screen_height: u32,
    fullscreen: bool,
    display_scale: u32,
) !Self {
    var self = Self{
        .screen_width = screen_width,
        .screen_height = screen_height,
        .display_scale = display_scale,
        .device = try sdl.createGPUDevice(
            .{
                .msl = builtin.target.os.tag.isDarwin(),
                .spirv = builtin.target.os.tag == .linux,
                .dxil = builtin.target.os.tag == .windows,
            },
            build_options.debug,
            null,
        ),
        .window = try sdl.createWindow(
            "ZSynth",
            @intCast(screen_width),
            @intCast(screen_height),
            .{
                .high_pixel_density = true,
                .fullscreen = fullscreen,
            },
        ),
        .samplers = .init(.{}),
        .assets = .init(.{}),
        .frame_texture = undefined,
    };

    self.frame_texture = try sdl.createGPUTexture(
        self.device,
        &std.mem.zeroInit(
            sdl.GPUTextureCreateInfo,
            .{
                .type = .texturetype_2d,
                .format = .r8g8b8a8_unorm,
                .width = screen_width,
                .height = screen_height,
                .layer_count_or_depth = 1,
                .num_levels = 1,
                // The display is rendered into this texture, then sampled by
                // the composite pass when it is copied to the swapchain.
                .usage = .{ .color_target = true, .sampler = true },
            },
        ),
    );

    return self;
}

/// Toggles the window between windowed and borderless fullscreen desktop mode.
pub fn toggleFullscreen(self: *Self) !void {
    const fullscreen = !self.is_fullscreen;

    if (fullscreen and !sdl.setWindowFullscreenMode(self.window, null))
        return sdl.makeError();

    if (!sdl.setWindowFullscreen(self.window, fullscreen))
        return sdl.makeError();

    self.is_fullscreen = fullscreen;
}

/// Enables or disables relative mouse input without repeating the SDL call.
pub fn setRelativeMouseMode(self: *Self, enabled: bool) !void {
    if (self.relative_mouse_mode == enabled)
        return;

    if (!sdl.setWindowRelativeMouseMode(self.window, enabled))
        return sdl.makeError();

    self.relative_mouse_mode = enabled;
}

pub const TextureMapPool = p.MapPool(
    sdl.GPUTextureCreateInfo,
    16,
    16,
    *sdl.GPUTexture,
    struct { texture: *sdl.GPUTexture },
);

pub const BufferMapBucketedPool = p.MapBucketedPool(
    sdl.GPUBufferUsageFlags,
    4,
    16 * 1024,
    16,
    16,
    *sdl.GPUBuffer,
    struct { buffer: *sdl.GPUBuffer },
);

pub const TransferBufferMapBucketedPool = p.MapBucketedPool(
    sdl.GPUTransferBufferUsage,
    4,
    16 * 1024,
    16,
    16,
    *sdl.GPUTransferBuffer,
    struct { buffer: *sdl.GPUTransferBuffer },
);

pub const BufferHandle = BufferMapBucketedPool.Handle;
pub const TransferBufferHandle = TransferBufferMapBucketedPool.Handle;
pub const TextureHandle = TextureMapPool.Pool.Handle;

const GraphicsPipelineKey = struct {
    format: sdl.GPUTextureFormat,
    pipeline: g.GraphicsPipeline,
};

pub const UniformData = struct {
    slot: u32,
    data: []const u8,
};

pub const AssetResource = struct {
    asset: a.Asset,
    texture: *sdl.GPUTexture,
    image: stbi.Image,

    pub fn deinit(self: AssetResource, renderer: *Self) void {
        renderer.assets.remove(self.asset);
        sdl.releaseGPUTexture(renderer.device, self.texture);
        self.image.deinit();
    }
};

fn acquireBuffers(
    renderer: *Self,
    gpa: std.mem.Allocator,
    comptime T: type,
    buffers_request: *std.EnumMap(T, u8),
    into: *std.EnumMap(T, []const BufferHandle),
    usage: sdl.GPUBufferUsageFlags,
) !void {
    var it = buffers_request.iterator();
    while (it.next()) |request| {
        var buffers = try gpa.alloc(BufferHandle, request.value.*);

        for (0..request.value.*) |i| {
            const handle = renderer.buffers.getAvailable(usage, request.key) orelse
                try renderer.buffers.add(
                    usage,
                    request.key,
                    .{
                        .buffer = try sdl.createGPUBuffer(
                            renderer.device,
                            &.{
                                .usage = usage,
                                .size = @intCast(@as(usize, @backingInt(request.key)) * 1024),
                            },
                        ),
                    },
                    gpa,
                );

            buffers[i] = handle;
        }

        into.put(request.key, buffers);
    }
}

fn acquireTransferBuffers(
    renderer: *Self,
    gpa: std.mem.Allocator,
    comptime T: type,
    buffers_request: *std.EnumMap(T, u8),
    into: *std.EnumMap(T, []const TransferBufferHandle),
    usage: sdl.GPUTransferBufferUsage,
) !void {
    var it = buffers_request.iterator();
    while (it.next()) |request| {
        var buffers = try gpa.alloc(TransferBufferHandle, request.value.*);

        for (0..request.value.*) |i| {
            const handle = renderer.transfer_buffers.getAvailable(usage, request.key) orelse
                try renderer.transfer_buffers.add(
                    usage,
                    request.key,
                    .{
                        .buffer = try sdl.createGPUTransferBuffer(
                            renderer.device,
                            &.{
                                .usage = usage,
                                .size = @intCast(@as(usize, @backingInt(request.key)) * 1024),
                            },
                        ),
                    },
                    gpa,
                );

            buffers[i] = handle;
        }

        into.put(request.key, buffers);
    }
}

pub const Resources = struct {
    samplers: []const g.Sampler = &.{},
    assets: []const a.Asset = &.{},
    vertex_buffers: std.EnumMap(BufferMapBucketedPool.Pool.Size, u8) = .{},
    index_buffers: std.EnumMap(BufferMapBucketedPool.Pool.Size, u8) = .{},
    storage_buffers: std.EnumMap(BufferMapBucketedPool.Pool.Size, u8) = .{},
    indirect_buffers: std.EnumMap(BufferMapBucketedPool.Pool.Size, u8) = .{},
    upload_transfer_buffers: std.EnumMap(TransferBufferMapBucketedPool.Pool.Size, u8) = .{},
    download_transfer_buffers: std.EnumMap(TransferBufferMapBucketedPool.Pool.Size, u8) = .{},
    uniform_data: std.EnumMap(sdl.GPUShaderStage, []const UniformData) = .{},
    textures: []const sdl.GPUTextureCreateInfo = &.{},

    pub fn acquire(self: *@This(), renderer: *Self, gpa: std.mem.Allocator) !Acquired {
        var samplers = try gpa.alloc(*sdl.GPUSampler, self.samplers.len);
        for (self.samplers, 0..) |request, i| {
            const sampler = renderer.samplers.get(request) orelse try request.create(renderer.device);

            renderer.samplers.put(request, sampler);

            samplers[i] = sampler;
        }

        var assets = try gpa.alloc(AssetResource, self.assets.len);
        for (self.assets, 0..) |request, i| {
            assets[i] = try renderer.loadImageAssetToTexture(gpa, request);
        }

        var vertex_buffers = std.EnumMap(BufferMapBucketedPool.Pool.Size, []const BufferHandle).init(.{});
        try renderer.acquireBuffers(
            gpa,
            BufferMapBucketedPool.Pool.Size,
            &self.vertex_buffers,
            &vertex_buffers,
            .{ .vertex = true },
        );

        var index_buffers = std.EnumMap(BufferMapBucketedPool.Pool.Size, []const BufferHandle).init(.{});
        try renderer.acquireBuffers(
            gpa,
            BufferMapBucketedPool.Pool.Size,
            &self.index_buffers,
            &index_buffers,
            .{ .index = true },
        );

        var storage_buffers = std.EnumMap(BufferMapBucketedPool.Pool.Size, []const BufferHandle).init(.{});
        try renderer.acquireBuffers(
            gpa,
            BufferMapBucketedPool.Pool.Size,
            &self.storage_buffers,
            &storage_buffers,
            .{ .graphics_storage_read = true },
        );

        var indirect_buffers = std.EnumMap(BufferMapBucketedPool.Pool.Size, []const BufferHandle).init(.{});
        try renderer.acquireBuffers(
            gpa,
            BufferMapBucketedPool.Pool.Size,
            &self.indirect_buffers,
            &indirect_buffers,
            .{ .indirect = true },
        );

        var upload_buffers = std.EnumMap(TransferBufferMapBucketedPool.Pool.Size, []const TransferBufferHandle).init(.{});
        try renderer.acquireTransferBuffers(
            gpa,
            TransferBufferMapBucketedPool.Pool.Size,
            &self.upload_transfer_buffers,
            &upload_buffers,
            .upload,
        );

        var download_buffers = std.EnumMap(TransferBufferMapBucketedPool.Pool.Size, []const TransferBufferHandle).init(.{});
        try renderer.acquireTransferBuffers(
            gpa,
            TransferBufferMapBucketedPool.Pool.Size,
            &self.download_transfer_buffers,
            &download_buffers,
            .download,
        );

        var textures = try gpa.alloc(TextureHandle, self.textures.len);
        for (self.textures, 0..) |request, i| {
            const handle = renderer.textures.getAvailable(request) orelse
                try renderer.textures.add(
                    request,
                    .{
                        .texture = try sdl.createGPUTexture(
                            renderer.device,
                            &request,
                        ),
                    },
                    gpa,
                );

            textures[i] = handle;
        }

        return .{
            .assets = assets,
            .download_transfer_buffers = download_buffers,
            .index_buffers = index_buffers,
            .indirect_buffers = indirect_buffers,
            .samplers = samplers,
            .storage_buffers = storage_buffers,
            .textures = textures,
            .upload_transfer_buffers = upload_buffers,
            .vertex_buffers = vertex_buffers,
            .uniform_data = self.uniform_data,
        };
    }

    /// The resources here remain acquired until the GPU fence for their command
    /// buffer signals. Pooled entries are handles so they can be returned to
    /// their owning pools without destroying the GPU resources.
    pub const Acquired = struct {
        samplers: []const *sdl.GPUSampler = &.{},
        assets: []const AssetResource = &.{},
        vertex_buffers: std.EnumMap(BufferMapBucketedPool.Pool.Size, []const BufferHandle) = .{},
        index_buffers: std.EnumMap(BufferMapBucketedPool.Pool.Size, []const BufferHandle) = .{},
        storage_buffers: std.EnumMap(BufferMapBucketedPool.Pool.Size, []const BufferHandle) = .{},
        indirect_buffers: std.EnumMap(BufferMapBucketedPool.Pool.Size, []const BufferHandle) = .{},
        upload_transfer_buffers: std.EnumMap(TransferBufferMapBucketedPool.Pool.Size, []const TransferBufferHandle) = .{},
        download_transfer_buffers: std.EnumMap(TransferBufferMapBucketedPool.Pool.Size, []const TransferBufferHandle) = .{},
        textures: []const TextureHandle = &.{},
        uniform_data: std.EnumMap(sdl.GPUShaderStage, []const UniformData) = .{},

        fn releaseBuffers(
            gpa: std.mem.Allocator,
            buffers: *std.EnumMap(BufferMapBucketedPool.Pool.Size, []const BufferHandle),
        ) void {
            var it = buffers.iterator();
            while (it.next()) |entry| {
                for (entry.value.*) |handle|
                    handle.release(gpa) catch @panic("Could not release GPU buffer handle");
                gpa.free(entry.value.*);
            }
        }

        fn releaseTransferBuffers(
            gpa: std.mem.Allocator,
            buffers: *std.EnumMap(TransferBufferMapBucketedPool.Pool.Size, []const TransferBufferHandle),
        ) void {
            var it = buffers.iterator();
            while (it.next()) |entry| {
                for (entry.value.*) |handle|
                    handle.release(gpa) catch @panic("Could not release GPU transfer buffer handle");
                gpa.free(entry.value.*);
            }
        }

        pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            gpa.free(self.samplers);
            gpa.free(self.assets);
            releaseBuffers(gpa, &self.vertex_buffers);
            releaseBuffers(gpa, &self.index_buffers);
            releaseBuffers(gpa, &self.storage_buffers);
            releaseBuffers(gpa, &self.indirect_buffers);
            releaseTransferBuffers(gpa, &self.download_transfer_buffers);
            releaseTransferBuffers(gpa, &self.upload_transfer_buffers);
            for (self.textures) |handle|
                handle.release(gpa) catch @panic("Could not release GPU texture handle");
            gpa.free(self.textures);
        }
    };
};

pub const WorkerError = sdl.Error || error{ImageInitFailed};

pub const Worker = *const fn (
    context: *anyopaque,
    gpa: std.mem.Allocator,
    io: std.Io,
    renderer: *Self,
    previous: *sdl.GPUTexture,
    acquired: Self.Resources.Acquired,
    cmd_buffer: *sdl.GPUCommandBuffer,
) WorkerError!void;

pub const Command = struct {
    target: *sdl.GPUTexture,
    worker: struct { worker: Worker, context: *anyopaque },
    resources: Resources,
    /// If true, target texture will be composited in the frame_texture of the Renderer
    present: bool,

    pub fn init(
        target: *sdl.GPUTexture,
        comptime Context: type,
        context: *Context,
        comptime callback: *const fn (
            context: *Context,
            gpa: std.mem.Allocator,
            io: std.Io,
            renderer: *Self,
            previous: *sdl.GPUTexture,
            acquired: Resources.Acquired,
            cmd_buffer: *sdl.GPUCommandBuffer,
        ) WorkerError!void,
        resources: Resources,
        present: bool,
    ) Command {
        const Wrapper = struct {
            pub fn run(
                erased: *anyopaque,
                gpa: std.mem.Allocator,
                io: std.Io,
                renderer: *Self,
                previous: *sdl.GPUTexture,
                acquired: Resources.Acquired,
                cmd_buffer: *sdl.GPUCommandBuffer,
            ) WorkerError!void {
                const typed: *Context = @ptrCast(@alignCast(erased));

                return callback(
                    typed,
                    gpa,
                    io,
                    renderer,
                    previous,
                    acquired,
                    cmd_buffer,
                );
            }
        };

        return .{
            .target = target,
            .worker = .{
                .context = context,
                .worker = Wrapper.run,
            },
            .resources = resources,
            .present = present,
        };
    }
};

const InFlight = struct {
    fence: *sdl.GPUFence,
    acquired: []Resources.Acquired = &.{},
};

fn presentToFrameBuffer(self: *Self, gpa: std.mem.Allocator, io: std.Io, cmd_buffer: *sdl.GPUCommandBuffer, texture: *sdl.GPUTexture) !void {
    const composite_pipeline = try self.getGraphicsPipeline(
        gpa,
        io,
        .Composite,
        .r8g8b8a8_unorm,
    );
    const sampler = self.samplers.get(.NearestClamp) orelse sampler: {
        const created = try g.Sampler.NearestClamp.create(self.device);
        self.samplers.put(.NearestClamp, created);
        break :sampler created;
    };

    const frame_render_pass = sdl.beginGPURenderPass(
        cmd_buffer,
        @ptrCast(
            &.{
                std.mem.zeroInit(
                    sdl.GPUColorTargetInfo,
                    .{
                        .texture = self.frame_texture,
                        .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                        .load_op = if (self.frame_texture_initialized)
                            sdl.GPULoadOp.load
                        else
                            sdl.GPULoadOp.clear,
                        .store_op = .store,
                    },
                ),
            },
        ),
        1,
        null,
    );

    sdl.bindGPUFragmentSamplers(
        frame_render_pass,
        0,
        @ptrCast(
            &.{
                sdl.GPUTextureSamplerBinding{
                    .texture = texture,
                    .sampler = sampler,
                },
            },
        ),
        1,
    );
    sdl.bindGPUGraphicsPipeline(frame_render_pass, composite_pipeline);
    sdl.drawGPUPrimitives(
        frame_render_pass,
        6,
        1,
        0,
        0,
    );
    sdl.endGPURenderPass(frame_render_pass);

    self.frame_texture_initialized = true;
}

pub fn render(self: *Self, gpa: std.mem.Allocator, io: std.Io, cmd_buffer: *sdl.GPUCommandBuffer) !void {
    self.reclaimCompleted(gpa);

    // Rendering commands execute in registration order. The current texture
    // is available to every worker; regular rendering workers may ignore it.
    var previous = self.frame_texture;
    for (self.commands.items) |*command| {
        const acquired = try command.resources.acquire(self, gpa);

        try command.worker.worker(
            command.worker.context,
            gpa,
            io,
            self,
            previous,
            acquired,
            cmd_buffer,
        );

        previous = command.target;
        if (command.present)
            try self.presentToFrameBuffer(gpa, io, cmd_buffer, command.target);
        if (command.present)
            previous = self.frame_texture;

        try self.pending_acquired.append(gpa, acquired);
    }
    self.commands.clearRetainingCapacity();

    // Draw ImGui on the logical canvas before it is letterboxed to the window.
    const gui_render_pass = sdl.beginGPURenderPass(
        cmd_buffer,
        @ptrCast(
            &.{
                std.mem.zeroInit(
                    sdl.GPUColorTargetInfo,
                    .{
                        .texture = self.frame_texture,
                        .load_op = if (self.frame_texture_initialized)
                            sdl.GPULoadOp.load
                        else
                            sdl.GPULoadOp.clear,
                        .store_op = .store,
                    },
                ),
            },
        ),
        1,
        null,
    );
    zgui.backend.renderDrawData(
        @ptrCast(cmd_buffer),
        @ptrCast(gui_render_pass),
        null,
    );
    sdl.endGPURenderPass(gui_render_pass);

    // Now draw the frame_texture to the swapchain_texture
    const pipeline = try self.getGraphicsPipeline(
        gpa,
        io,
        .Composite,
        sdl.getGPUSwapchainTextureFormat(
            self.device,
            self.window,
        ),
    );

    var swapchain_texture: ?*sdl.GPUTexture = undefined;
    var swapchain_width: u32 = undefined;
    var swapchain_height: u32 = undefined;
    try sdl.waitAndAcquireGPUSwapchainTexture(
        cmd_buffer,
        self.window,
        &swapchain_texture,
        &swapchain_width,
        &swapchain_height,
    );

    // SDL may return no drawable when the window is unavailable or when the
    // swapchain has temporarily reached its frames-in-flight limit.
    if (swapchain_texture == null)
        return;

    if (swapchain_width == 0 or swapchain_height == 0)
        return;

    const render_pass = sdl.beginGPURenderPass(
        cmd_buffer,
        @ptrCast(
            &.{
                std.mem.zeroInit(
                    sdl.GPUColorTargetInfo,
                    .{
                        .texture = swapchain_texture.?,
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

    const source_aspect = @as(f32, @floatFromInt(self.screen_width)) /
        @as(f32, @floatFromInt(self.screen_height));
    const swapchain_aspect = @as(f32, @floatFromInt(swapchain_width)) /
        @as(f32, @floatFromInt(swapchain_height));
    var viewport = sdl.GPUViewport{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(swapchain_width),
        .h = @floatFromInt(swapchain_height),
        .min_depth = 0,
        .max_depth = 1,
    };

    if (swapchain_aspect > source_aspect) {
        viewport.w = @as(f32, @floatFromInt(swapchain_height)) * source_aspect;
        viewport.x = (@as(f32, @floatFromInt(swapchain_width)) - viewport.w) / 2;
    } else {
        viewport.h = @as(f32, @floatFromInt(swapchain_width)) / source_aspect;
        viewport.y = (@as(f32, @floatFromInt(swapchain_height)) - viewport.h) / 2;
    }

    sdl.setGPUViewport(render_pass, &viewport);

    sdl.bindGPUFragmentSamplers(
        render_pass,
        0,
        @ptrCast(
            &.{
                sdl.GPUTextureSamplerBinding{
                    .texture = self.frame_texture,
                    .sampler = self.samplers.get(.NearestClamp) orelse sampler: {
                        const sampler = try g.Sampler.NearestClamp.create(self.device);
                        self.samplers.put(.NearestClamp, sampler);
                        break :sampler sampler;
                    },
                },
            },
        ),
        1,
    );
    sdl.bindGPUGraphicsPipeline(render_pass, pipeline);

    sdl.drawGPUPrimitives(
        render_pass,
        6, // Two triangles forming one fullscreen quad. The vertices are hardcoded in the Composite shader
        1,
        0,
        0,
    );

    sdl.endGPURenderPass(render_pass);
}

fn reclaimCompleted(self: *Self, gpa: std.mem.Allocator) void {
    var i: usize = 0;
    while (i < self.in_flight.len) {
        const fences = self.in_flight.items(.fence);
        if (!sdl.queryGPUFence(self.device, fences[i])) {
            i += 1;
            continue;
        }

        const fence = fences[i];
        const acquired = self.in_flight.items(.acquired)[i];
        self.in_flight.swapRemove(i);
        for (acquired) |*resource| resource.deinit(gpa);
        gpa.free(acquired);
        sdl.releaseGPUFence(self.device, fence);
    }
}

pub fn submit(self: *Self, gpa: std.mem.Allocator, cmd_buffer: *sdl.GPUCommandBuffer) !void {
    // Reserve the in-flight slot before submitting so allocation failure cannot
    // leave a submitted fence without a place to track its resources.
    try self.in_flight.ensureUnusedCapacity(gpa, 1);
    const acquired = try self.pending_acquired.toOwnedSlice(gpa);

    const fence = try sdl.submitGPUCommandBufferAndAcquireFence(cmd_buffer);

    self.in_flight.appendAssumeCapacity(
        .{
            .fence = fence,
            .acquired = acquired,
        },
    );
}

pub fn getGraphicsPipeline(
    self: *Self,
    gpa: std.mem.Allocator,
    io: std.Io,
    pipeline: g.GraphicsPipeline,
    target_format: sdl.GPUTextureFormat,
) !*sdl.GPUGraphicsPipeline {
    const key = GraphicsPipelineKey{
        .format = target_format,
        .pipeline = pipeline,
    };

    // Pipelines stay live for the renderer lifetime and are not returned to a reusable list.
    const gp = try self.graphics_pipelines.getOrPut(gpa, key);

    if (!gp.found_existing) {
        gp.value_ptr.* = try pipeline.create(gpa, io, self.device, target_format);
    }

    return gp.value_ptr.*;
}

pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    for (self.pending_acquired.items) |*acquired|
        acquired.deinit(gpa);
    self.pending_acquired.deinit(gpa);

    if (self.in_flight.len > 0) {
        sdl.waitForGPUFences(
            self.device,
            true,
            self.in_flight.items(.fence).ptr,
            @intCast(self.in_flight.len),
        ) catch
            @panic("Could not wait for GPU fences");
    }

    for (self.in_flight.items(.acquired)) |acquired| {
        for (acquired) |*resource|
            resource.deinit(gpa);
        gpa.free(acquired);
    }
    for (self.in_flight.items(.fence)) |fence|
        sdl.releaseGPUFence(self.device, fence);
    self.in_flight.deinit(gpa);

    self.commands.deinit(gpa);

    {
        var it = self.graphics_pipelines.iterator();
        while (it.next()) |gp| {
            sdl.releaseGPUGraphicsPipeline(
                self.device,
                gp.value_ptr.*,
            );
        }
        self.graphics_pipelines.deinit(gpa);
    }
    {
        var it = self.samplers.iterator();
        while (it.next()) |entry|
            sdl.releaseGPUSampler(self.device, entry.value.*);
    }
    {
        var it = self.assets.iterator();
        while (it.next()) |entry| {
            sdl.releaseGPUTexture(self.device, entry.value.*.texture);
            entry.value.*.image.deinit();
        }
    }

    {
        var it = self.buffers.map.iterator();
        while (it.next()) |entry| {
            inline for (std.enums.values(BufferMapBucketedPool.Pool.Size)) |size| {
                var bucket = entry.value_ptr.buckets.get(size);
                var it2 = bucket.pool.liveHandles();
                while (it2.next()) |buffer| {
                    sdl.releaseGPUBuffer(
                        self.device,
                        bucket.pool.getColumn(buffer, .buffer) catch @panic("Invalid buffer handle"),
                    );
                }
            }
        }
    }

    self.buffers.deinit(gpa);

    {
        var it = self.transfer_buffers.map.iterator();
        while (it.next()) |entry| {
            inline for (std.enums.values(TransferBufferMapBucketedPool.Pool.Size)) |size| {
                var bucket = entry.value_ptr.buckets.get(size);
                var it2 = bucket.pool.liveHandles();
                while (it2.next()) |buffer| {
                    sdl.releaseGPUTransferBuffer(
                        self.device,
                        bucket.pool.getColumn(buffer, .buffer) catch @panic("Invalid transfer buffer handle"),
                    );
                }
            }
        }
    }

    self.transfer_buffers.deinit(gpa);

    {
        var it = self.textures.map.iterator();
        while (it.next()) |entry| {
            var it2 = entry.value_ptr.pool.liveHandles();
            while (it2.next()) |texture| {
                sdl.releaseGPUTexture(
                    self.device,
                    entry.value_ptr.pool.getColumn(texture, .texture) catch
                        @panic("Invalid texture handle"),
                );
            }
        }
    }

    self.textures.deinit(gpa);

    sdl.releaseGPUTexture(self.device, self.frame_texture);
    sdl.releaseWindowFromGPUDevice(self.device, self.window);
    sdl.destroyWindow(self.window);
}

/// Upload image asset to the GPU
/// Better call this before the Renderer.render loop because it submits its own GPU copy pass
pub fn loadImageAssetToTexture(self: *Self, gpa: std.mem.Allocator, asset: a.Asset) !AssetResource {
    if (self.assets.get(asset)) |texture| return texture;

    std.debug.assert(a.assets_metadata.get(asset) == .image);

    const image = try asset.loadImage();

    // Target texture
    const texture = try sdl.createGPUTexture(
        self.device,
        &.{
            .type = .texturetype_2d,
            .format = .r8g8b8a8_unorm,
            .width = image.width,
            .height = image.height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .usage = .{ .sampler = true },
            .sample_count = .samplecount_1,
        },
    );
    sdl.setGPUTextureName(self.device, texture, @tagName(asset));

    // Transfer buffer
    const size = BufferMapBucketedPool.bucketSizeFor(image.data.len);
    const transfer_buffer_handle = self.transfer_buffers.getAvailable(.upload, size) orelse
        try self.transfer_buffers.add(
            .upload,
            size,
            .{
                .buffer = try sdl.createGPUTransferBuffer(
                    self.device,
                    &.{
                        .usage = .upload,
                        .size = @intCast(@as(usize, @backingInt(size)) * 1024),
                    },
                ),
            },
            gpa,
        );
    const transfer_buffer = transfer_buffer_handle.getColumns().buffer;

    // Put image data in the transfer buffer
    const texture_transfer_ptr = try sdl.mapGPUTransferBuffer(self.device, transfer_buffer, false);

    const destination: [*]u8 = @ptrCast(texture_transfer_ptr);
    const bytes: []u8 = destination[0..image.data.len];

    @memcpy(bytes, image.data);

    sdl.unmapGPUTransferBuffer(self.device, transfer_buffer);

    // Upload the transfer buffer to the GPU in a copy pass
    const upload_cmd_buffer = try sdl.acquireGPUCommandBuffer(self.device);
    const copy_pass = sdl.beginGPUCopyPass(upload_cmd_buffer);

    sdl.uploadToGPUTexture(
        copy_pass,
        &.{
            .transfer_buffer = transfer_buffer,
            .offset = 0,
            .pixels_per_row = 0,
            .rows_per_layer = 0,
        },
        &.{
            .texture = texture,
            .w = image.width,
            .h = image.height,
            .d = 1,
            .mip_level = 0,
            .layer = 0,
            .x = 0,
            .y = 0,
            .z = 0,
        },
        false,
    );

    sdl.endGPUCopyPass(copy_pass);
    const upload_fence = try sdl.submitGPUCommandBufferAndAcquireFence(upload_cmd_buffer);
    var upload_fences = [_]*sdl.GPUFence{upload_fence};
    defer sdl.releaseGPUFence(self.device, upload_fence);

    // The transfer buffer can only return to the pool after the upload has
    // completed; otherwise a later upload may overwrite it while the GPU is
    // still reading from it.
    try sdl.waitForGPUFences(
        self.device,
        true,
        upload_fences[0..].ptr,
        1,
    );
    try transfer_buffer_handle.release(gpa);

    const asset_resource = AssetResource{
        .asset = asset,
        .texture = texture,
        .image = image,
    };

    self.assets.put(asset, asset_resource);

    return asset_resource;
}
