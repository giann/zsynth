//! Low level graphics
const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("zsdl3");

pub const ShaderTypes = struct {
    /// Used by src/shaders/SpriteGrid.vert.hlsl
    pub const Sprite = extern struct {
        position: [2]f32,
        size: [2]f32,
        uv_rect: [4]f32,
        fg: u32,
        bg: u32,
        // StructuredBuffer elements use a 48-byte stride in the compiled
        // shader; the two words below match its trailing alignment padding.
        _padding: [2]u32 = .{ 0, 0 },
    };

    /// Used by src/shaders/Grain.frag.hlsl
    pub const GrainParameters = extern struct {
        strength: f32 = 0.1,
        frame_index: u32 = 0,
        _padding: [2]u32 = .{ 0, 0 },
    };

    /// Used by src/shaders/Sharpen.frag.hlsl
    pub const SharpenParameters = extern struct {
        strength: f32 = 0.2,
        texel_size: [2]f32 = .{ 0, 0 },
        _padding: u32 = 0,
    };

    /// Used by the fullscreen bloom fragment shaders.
    pub const BloomParameters = extern struct {
        /// Brightness threshold for the extracted bloom contribution.
        threshold: f32 = 0.85,
        /// Strength of the blurred contribution in the final composite.
        intensity: f32 = 0.35,
        /// Inverse dimensions of the bloom texture.
        texel_size: [2]f32 = .{ 0, 0 },
        /// Horizontal or vertical blur direction.
        direction: [2]f32 = .{ 0, 0 },
        /// Uniform-buffer alignment padding.
        _padding: [2]u32 = .{ 0, 0 },
    };
};

pub const Shader = enum {
    @"Composite.vert",
    @"Composite.frag",
    @"SpriteGrid.vert",
    @"SpriteGrid.frag",
    @"Grain.frag",
    /// Fullscreen sharpening fragment shader.
    @"Sharpen.frag",
    /// Fullscreen bloom bright-pass fragment shader.
    @"BloomBright.frag",
    /// Fullscreen bloom blur fragment shader.
    @"BloomBlur.frag",
    /// Fullscreen bloom composite fragment shader.
    @"BloomComposite.frag",

    /// Load shader
    pub fn load(
        self: Shader,
        gpa: std.mem.Allocator,
        io: std.Io,
        device: *sdl.GPUDevice,
    ) !*sdl.GPUShader {
        // Choose appropriate shader format
        const backend_formats = sdl.getGPUShaderFormats(device);
        const shader_format: sdl.GPUShaderFormat = if (backend_formats.msl)
            .{ .msl = true }
        else if (backend_formats.spirv)
            .{ .spirv = true }
        else if (backend_formats.dxil)
            .{ .dxil = true }
        else
            @panic("Unsupported shader backend format");

        const name = @tagName(self);
        var full_name = std.Io.Writer.Allocating.init(gpa);
        try full_name.writer.print(
            "assets/shaders/{s}.{s}",
            .{
                name,
                if (shader_format.msl)
                    "msl"
                else if (shader_format.spirv)
                    "spv"
                else if (shader_format.dxil)
                    "dxil"
                else
                    @panic("Unsupported shader backend format"),
            },
        );
        defer full_name.deinit();

        // Chose shader stage based on its name
        const stage: sdl.GPUShaderStage = if (std.mem.endsWith(u8, name, ".vert"))
            .vertex
        else if (std.mem.endsWith(u8, name, ".frag"))
            .fragment
        else {
            std.debug.print("Invalid shader stage for shader `{s}`\n", .{full_name.written()});
            unreachable;
        };

        // Read shader
        const file = try std.Io.Dir.cwd().openFile(io, full_name.written(), .{});
        defer file.close(io);

        const code = try gpa.alloc(u8, (try file.stat(io)).size);
        defer gpa.free(code);
        _ = try file.readPositionalAll(io, code, 0);

        // Create shader
        const info = shader_infos.get(self);
        const shader_info = sdl.GPUShaderCreateInfo{
            .code = @ptrCast(code.ptr),
            .code_size = code.len,
            .entrypoint = if (backend_formats.msl)
                "main0"
            else
                "main",
            .format = shader_format,
            .num_samplers = info.sampler_count,
            .num_uniform_buffers = info.uniform_buffer_count,
            .num_storage_buffers = info.storage_buffer_count,
            .num_storage_textures = info.storage_texture_count,
            .stage = stage,
        };

        return try sdl.createGPUShader(device, &shader_info);
    }
};

const shader_infos = std.EnumArray(
    Shader,
    struct {
        sampler_count: u32 = 0,
        uniform_buffer_count: u32 = 0,
        storage_buffer_count: u32 = 0,
        storage_texture_count: u32 = 0,
    },
).init(
    .{
        .@"Composite.vert" = .{},
        .@"Composite.frag" = .{ .sampler_count = 1 },
        .@"SpriteGrid.vert" = .{ .storage_buffer_count = 1 },
        .@"SpriteGrid.frag" = .{ .sampler_count = 1 },
        .@"Grain.frag" = .{ .sampler_count = 1, .uniform_buffer_count = 1 },
        .@"Sharpen.frag" = .{ .sampler_count = 1, .uniform_buffer_count = 1 },
        .@"BloomBright.frag" = .{ .sampler_count = 1, .uniform_buffer_count = 1 },
        .@"BloomBlur.frag" = .{ .sampler_count = 1, .uniform_buffer_count = 1 },
        .@"BloomComposite.frag" = .{ .sampler_count = 2, .uniform_buffer_count = 1 },
    },
);

pub const GraphicsPipeline = enum {
    Composite,
    SpriteGrid,
    Grain,
    /// Fullscreen sharpening pipeline.
    Sharpen,
    /// Fullscreen bloom bright-pass pipeline.
    BloomBright,
    /// Fullscreen bloom blur pipeline.
    BloomBlur,
    /// Fullscreen bloom composite pipeline.
    BloomComposite,

    pub fn create(
        self: GraphicsPipeline,
        gpa: std.mem.Allocator,
        io: std.Io,
        device: *sdl.GPUDevice,
        target_format: sdl.GPUTextureFormat,
    ) !*sdl.GPUGraphicsPipeline {
        const vert_shader = switch (self) {
            .Composite,
            .Grain,
            .Sharpen,
            .BloomBright,
            .BloomBlur,
            .BloomComposite,
            => try Shader.@"Composite.vert".load(gpa, io, device),
            .SpriteGrid => try Shader.@"SpriteGrid.vert".load(gpa, io, device),
        };
        defer sdl.releaseGPUShader(device, vert_shader);

        const frag_shader = switch (self) {
            .Composite => try Shader.@"Composite.frag".load(gpa, io, device),
            .SpriteGrid => try Shader.@"SpriteGrid.frag".load(gpa, io, device),
            .Grain => try Shader.@"Grain.frag".load(gpa, io, device),
            .Sharpen => try Shader.@"Sharpen.frag".load(gpa, io, device),
            .BloomBright => try Shader.@"BloomBright.frag".load(gpa, io, device),
            .BloomBlur => try Shader.@"BloomBlur.frag".load(gpa, io, device),
            .BloomComposite => try Shader.@"BloomComposite.frag".load(gpa, io, device),
        };
        defer sdl.releaseGPUShader(device, frag_shader);

        // SpriteGrid uses alpha blending but no depth or stencil target.
        const color_target_descriptions = [_]sdl.GPUColorTargetDescription{
            .{
                .format = target_format,
                .blend_state = .{
                    .src_color_blendfactor = if (isOpaque(self)) .one else .src_alpha,
                    .dst_color_blendfactor = if (isOpaque(self)) .zero else .one_minus_src_alpha,
                    .color_blend_op = .add,
                    .src_alpha_blendfactor = if (isOpaque(self)) .one else .src_alpha,
                    .dst_alpha_blendfactor = if (isOpaque(self)) .zero else .one_minus_src_alpha,
                    .alpha_blend_op = .add,
                    .color_write_mask = .{
                        .red = true,
                        .green = true,
                        .blue = true,
                        .alpha = true,
                    },
                    .enable_blend = true,
                    .enable_color_write_mask = true,
                },
            },
        };

        // The target description points to stack data used only while the pipeline is created.
        const target_info = sdl.GPUGraphicsPipelineTargetInfo{
            .color_target_descriptions = &color_target_descriptions,
            .num_color_targets = 1,
            .depth_stencil_format = std.mem.zeroes(sdl.GPUTextureFormat),
            .has_depth_stencil_target = false,
        };

        const create_info: sdl.GPUGraphicsPipelineCreateInfo = switch (self) {
            .Composite => .{
                .target_info = target_info,
                // The vertex shader generates the fullscreen quad from SV_VertexID.
                .vertex_input_state = std.mem.zeroes(sdl.GPUVertexInputState),
                .primitive_type = .trianglelist,
                .vertex_shader = vert_shader,
                .fragment_shader = frag_shader,
                .rasterizer_state = std.mem.zeroes(sdl.GPURasterizerState),
                .multisample_state = std.mem.zeroes(sdl.GPUMultisampleState),
                .depth_stencil_state = std.mem.zeroes(sdl.GPUDepthStencilState),
            },
            .Grain => .{
                .target_info = target_info,
                // The vertex shader generates the fullscreen quad from SV_VertexID.
                .vertex_input_state = std.mem.zeroes(sdl.GPUVertexInputState),
                .primitive_type = .trianglelist,
                .vertex_shader = vert_shader,
                .fragment_shader = frag_shader,
                .rasterizer_state = std.mem.zeroes(sdl.GPURasterizerState),
                .multisample_state = std.mem.zeroes(sdl.GPUMultisampleState),
                .depth_stencil_state = std.mem.zeroes(sdl.GPUDepthStencilState),
            },
            .Sharpen => .{
                .target_info = target_info,
                // The vertex shader generates the fullscreen quad from SV_VertexID.
                .vertex_input_state = std.mem.zeroes(sdl.GPUVertexInputState),
                .primitive_type = .trianglelist,
                .vertex_shader = vert_shader,
                .fragment_shader = frag_shader,
                .rasterizer_state = std.mem.zeroes(sdl.GPURasterizerState),
                .multisample_state = std.mem.zeroes(sdl.GPUMultisampleState),
                .depth_stencil_state = std.mem.zeroes(sdl.GPUDepthStencilState),
            },
            .BloomBright, .BloomBlur => .{
                .target_info = target_info,
                // The vertex shader generates the fullscreen quad from SV_VertexID.
                .vertex_input_state = std.mem.zeroes(sdl.GPUVertexInputState),
                .primitive_type = .trianglelist,
                .vertex_shader = vert_shader,
                .fragment_shader = frag_shader,
                .rasterizer_state = std.mem.zeroes(sdl.GPURasterizerState),
                .multisample_state = std.mem.zeroes(sdl.GPUMultisampleState),
                .depth_stencil_state = std.mem.zeroes(sdl.GPUDepthStencilState),
            },
            .BloomComposite => .{
                .target_info = target_info,
                // The vertex shader generates the fullscreen quad from SV_VertexID.
                .vertex_input_state = std.mem.zeroes(sdl.GPUVertexInputState),
                .primitive_type = .trianglelist,
                .vertex_shader = vert_shader,
                .fragment_shader = frag_shader,
                .rasterizer_state = std.mem.zeroes(sdl.GPURasterizerState),
                .multisample_state = std.mem.zeroes(sdl.GPUMultisampleState),
                .depth_stencil_state = std.mem.zeroes(sdl.GPUDepthStencilState),
            },
            .SpriteGrid => .{
                .target_info = target_info,
                // The vertex shader generates the quad from SV_VertexID.
                .vertex_input_state = std.mem.zeroes(sdl.GPUVertexInputState),
                .primitive_type = .trianglelist,
                .vertex_shader = vert_shader,
                .fragment_shader = frag_shader,
                .rasterizer_state = std.mem.zeroes(sdl.GPURasterizerState),
                .multisample_state = std.mem.zeroes(sdl.GPUMultisampleState),
                .depth_stencil_state = std.mem.zeroes(sdl.GPUDepthStencilState),
            },
        };

        return sdl.createGPUGraphicsPipeline(device, &create_info);
    }
};

/// Returns whether a pipeline should replace rather than alpha-blend its target.
fn isOpaque(pipeline: GraphicsPipeline) bool {
    return switch (pipeline) {
        .Grain, .Sharpen, .BloomBright, .BloomBlur, .BloomComposite => true,
        .Composite, .SpriteGrid => false,
    };
}

pub const ComputePipeline = enum {
    // TODO
};

pub const Sampler = enum {
    /// Point sampling with edge clamping.
    NearestClamp,
    /// Linear sampling with edge clamping.
    LinearClamp,

    pub fn create(self: Sampler, device: *sdl.GPUDevice) !*sdl.GPUSampler {
        return sdl.createGPUSampler(device, &samplers.get(self));
    }
};

pub const samplers = std.EnumArray(Sampler, sdl.GPUSamplerCreateInfo).init(
    .{
        .NearestClamp = .{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            // Unused
            .enable_anisotropy = false,
            .enable_compare = false,
            .mip_lod_bias = 0,
            .max_anisotropy = 0,
            .compare_op = .invalid,
            .min_lod = 0,
            .max_lod = 0,
        },
        .LinearClamp = .{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .enable_anisotropy = false,
            .enable_compare = false,
            .mip_lod_bias = 0,
            .max_anisotropy = 0,
            .compare_op = .invalid,
            .min_lod = 0,
            .max_lod = 0,
        },
    },
);
