//! Owns the ZSynth application runtime and its top-level graphics resources.

const std = @import("std");
const audio = @import("zaudio");
const sdl = @import("zsdl3");
const stbi = @import("zstbi");
const zgui = @import("zgui");
const Display = @import("Display.zig");
const PostProcessing = @import("PostProcessing.zig");
const Renderer = @import("Renderer.zig");
const StateStack = @import("StateStack.zig");
const SynthEditor = @import("SynthEditor.zig");

const Self = @This();

/// Logical width of the renderer and display in pixels.
pub const screen_width = 640;
/// Logical height of the renderer and display in pixels.
pub const screen_height = 360;

/// All state used to draw and update the software mouse cursor.
pub const CursorState = struct {
    /// Current mouse position in window pixels.
    position: [2]f32 = .{ 0, 0 },
    /// Whether `position` has been initialized from an SDL event or window size.
    initialized: bool = false,
    /// Relative-mode setting used when `position` was last updated.
    relative_mode: bool = false,
    /// Whether the software cursor should be written to the display.
    visible: bool = false,
};

/// The I/O context shared with the renderer and asset loader.
io: std.Io,
/// The process-wide audio engine used by the active editor state.
audio_engine: *audio.Engine,
/// GPU renderer and its window.
renderer: Renderer,
/// Character-grid display written by application states.
display: Display,
/// Post-processing passes applied in order before presentation.
post_processing: [3]PostProcessing,
/// Stack containing the active application state contexts.
state_stack: StateStack,
/// Software cursor state, including its position and visibility.
cursor: CursorState = .{},

/// Initializes audio, SDL, the renderer, the display, and post-processing.
pub fn init(process: std.process.Init, allocator: std.mem.Allocator) !Self {
    // Start the audio library before creating the engine that depends on it.
    audio.init(allocator);

    // Configure a stereo, 48 kHz engine for the synth DSP graph.
    var audio_engine_config = audio.Engine.Config.init();
    audio_engine_config.channels = 2;
    audio_engine_config.sample_rate = 48_000;
    const audio_engine = try audio.Engine.create(audio_engine_config);

    // Initialize image loading before any display assets are requested.
    stbi.init(process.io, allocator);

    // Create the SDL video subsystem and hide the native cursor.
    try sdl.init(.{ .video = true });
    try sdl.hideCursor();

    // Create the GPU renderer and its logical 640x360 window.
    var renderer = try Renderer.init(screen_width, screen_height, false, 1);

    // Attach the window to the GPU device and prefer immediate presentation.
    try sdl.claimWindowForGPUDevice(renderer.device, renderer.window);
    if (sdl.windowSupportsGPUPresentMode(renderer.device, renderer.window, .immediate)) {
        try sdl.setGPUSwapchainParameters(
            renderer.device,
            renderer.window,
            .sdr,
            .immediate,
        );
    }

    // Allocate the character-grid display and load its glyph sheet.
    const display = Display{
        .impl = .{
            .graphic = try Display.GraphicDisplay.init(
                allocator,
                &renderer,
                .{
                    .sheet_asset = .giann_shaded,
                    .render_width = screen_width,
                    .render_height = screen_height,
                },
            ),
        },
    };

    // Build the ordered sharpen, bloom, and grain post-processing chain.
    var post_processing: [3]PostProcessing = undefined;

    post_processing[0] = try PostProcessing.sharpenProcess(
        allocator,
        &renderer,
        0.50,
        screen_width,
        screen_height,
    );
    post_processing[1] = try PostProcessing.bloomProcess(
        allocator,
        &renderer,
        0.85,
        0.35,
        screen_width,
        screen_height,
    );
    post_processing[2] = try PostProcessing.grainProcess(
        allocator,
        &renderer,
        .{},
        screen_width,
        screen_height,
    );

    // Allocate the state stack before the first editor state is pushed.
    const state_stack = try StateStack.init(allocator);

    // Initialize the GUI backend owned by the application runtime.
    zgui.init(allocator);

    var self = Self{
        .io = process.io,
        .audio_engine = audio_engine,
        .renderer = renderer,
        .display = display,
        .post_processing = post_processing,
        .state_stack = state_stack,
    };
    // Seed the cursor at the center until the first motion event arrives.
    self.initializeCursorPosition();
    return self;
}

/// Pushes the synth editor and runs the application loop until it exits.
pub fn start(self: *Self, allocator: std.mem.Allocator) !void {
    // Make the editor the sole initial state in the stack.
    _ = try self.state_stack.push(
        allocator,
        .{
            .context = .{ .synth_editor = .{ .zsynth = self } },
            .vtable = &SynthEditor.vtable,
        },
    );

    // Continue processing frames while the state stack has an active state.
    try self.loop(allocator);
}

/// Runs one frame at a time until the active state stack becomes empty.
fn loop(self: *Self, allocator: std.mem.Allocator) !void {
    // Use SDL ticks so every state receives elapsed milliseconds.
    var previous_ticks = sdl.getTicks();

    while (self.state_stack.current() != null) {
        // Measure this frame and advance all active states.
        const ticks = sdl.getTicks();
        const frame_delta = ticks - previous_ticks;
        previous_ticks = ticks;

        try self.state_stack.update(allocator, frame_delta);

        // Poll all pending SDL events before rendering the frame.
        var event: sdl.Event = undefined;
        var should_quit = false;
        while (sdl.pollEvent(&event)) {
            // Defer state-stack teardown until the event batch is complete.
            if (event.type == .quit) {
                should_quit = true;
                break;
            }

            // Update the software cursor from every motion event.
            if (event.type == .mouse_motion)
                self.updateMousePosition(event.motion);

            // Keep the fullscreen shortcut at the application level.
            if (event.type == .key_down and
                event.key.key == .f and
                !event.key.repeat and
                (@backingInt(event.key.mod) & sdl.Keymod.ctrl) != 0)
            {
                try self.renderer.toggleFullscreen();
            }

            // Give enabled states the opportunity to consume the event.
            _ = try self.state_stack.inputEvent(allocator, event);
        }
        // Quit states cleanly when SDL reports that the window closed.
        if (should_quit) {
            try self.state_stack.quit(allocator, &self.renderer);
            break;
        }

        // Acquire the command buffer used by this frame's GPU work.
        const cmd_buffer = try sdl.acquireGPUCommandBuffer(self.renderer.device);
        // Let states write their display and rendering commands.
        try self.state_stack.render(allocator, &self.renderer, frame_delta);
        // Overlay the software cursor after the state has redrawn its display.
        try self.writeCursor(allocator);

        // Run every post-processing pass, marking the final pass for presentation.
        for (&self.post_processing, 0..) |*post, index|
            try post.render(
                post,
                allocator,
                &self.renderer,
                frame_delta,
                index + 1 == self.post_processing.len,
            );

        // Submit the composed frame and yield briefly to avoid a busy loop.
        try self.renderer.render(allocator, self.io, cmd_buffer);
        try self.renderer.submit(allocator, cmd_buffer);
        sdl.delay(1);
    }
}

/// Releases states, post-processing resources, graphics resources, and services.
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    // Give the active state a chance to release its DSP graph.
    self.state_stack.quit(allocator, &self.renderer) catch @panic("Could not quit state stack");
    // Destroy post-processing resources before the renderer they reference.
    for (&self.post_processing) |*post|
        post.deinit(&self.renderer);
    // Destroy the display's GPU resources while the renderer is still alive.
    if (self.display.impl == .graphic)
        self.display.impl.graphic.deinit(allocator, &self.renderer);
    // Release the renderer, GUI backend, and SDL services in dependency order.
    self.renderer.deinit(allocator);
    zgui.deinit();
    sdl.showCursor() catch {};
    sdl.quit();
    // Shut down image loading and audio after their users are gone.
    stbi.deinit();
    self.audio_engine.destroy();
    audio.deinit();
}

/// Initializes the software cursor at the center of the current window.
fn initializeCursorPosition(self: *Self) void {
    // Read the current window size so the initial position is valid.
    var window_width: c_int = 0;
    var window_height: c_int = 0;
    sdl.getWindowSize(self.renderer.window, &window_width, &window_height) catch return;
    // Place the cursor at the window center until motion data is available.
    self.cursor.position = .{
        @as(f32, @floatFromInt(window_width)) / 2.0,
        @as(f32, @floatFromInt(window_height)) / 2.0,
    };
    // Record the mode used to interpret subsequent motion events.
    self.cursor.initialized = true;
    self.cursor.relative_mode = self.renderer.relative_mouse_mode;
    self.cursor.visible = true;
}

/// Updates and clamps the software cursor from an SDL mouse-motion event.
fn updateMousePosition(self: *Self, event: sdl.MouseMotionEvent) void {
    // Detect relative-mode changes before choosing absolute or relative motion.
    const relative_mode = self.renderer.relative_mouse_mode;
    if (!self.cursor.initialized or self.cursor.relative_mode != relative_mode) {
        // Re-seed from the event when the coordinate interpretation changes.
        self.cursor.position = .{ event.x, event.y };
        self.cursor.initialized = true;
        self.cursor.relative_mode = relative_mode;
    } else if (relative_mode) {
        // Relative events report deltas, so accumulate them in window space.
        self.cursor.position[0] += event.xrel;
        self.cursor.position[1] += event.yrel;
    } else {
        // Absolute events already contain the complete window-space position.
        self.cursor.position = .{ event.x, event.y };
    }

    // Read the window bounds used to constrain the cursor.
    var window_width: c_int = 0;
    var window_height: c_int = 0;
    sdl.getWindowSize(self.renderer.window, &window_width, &window_height) catch return;
    // Keep accumulated relative motion inside the drawable window.
    if (window_width > 0)
        self.cursor.position[0] = std.math.clamp(
            self.cursor.position[0],
            0,
            @as(f32, @floatFromInt(window_width - 1)),
        );
    if (window_height > 0)
        self.cursor.position[1] = std.math.clamp(
            self.cursor.position[1],
            0,
            @as(f32, @floatFromInt(window_height - 1)),
        );
}

/// Converts the window-space cursor position to a display cell and draws it.
fn writeCursor(self: *Self, allocator: std.mem.Allocator) !void {
    // Only draw the cursor when the software cursor and graphic display exist.
    if (!self.cursor.visible or self.display.impl != .graphic)
        return;

    // Read the current window size before mapping pixels to logical coordinates.
    const display = &self.display.impl.graphic;
    var window_width: c_int = 0;
    var window_height: c_int = 0;
    try sdl.getWindowSize(self.renderer.window, &window_width, &window_height);
    if (window_width <= 0 or window_height <= 0) return;

    // Compute the aspect-preserving viewport inside the SDL window.
    const source_aspect = @as(f32, @floatFromInt(self.renderer.screen_width)) /
        @as(f32, @floatFromInt(self.renderer.screen_height));
    const window_aspect = @as(f32, @floatFromInt(window_width)) /
        @as(f32, @floatFromInt(window_height));
    var viewport_x: f32 = 0;
    var viewport_y: f32 = 0;
    var viewport_width: f32 = @floatFromInt(window_width);
    var viewport_height: f32 = @floatFromInt(window_height);

    if (window_aspect > source_aspect) {
        // Wider windows add horizontal letterboxing.
        viewport_width = @as(f32, @floatFromInt(window_height)) * source_aspect;
        viewport_x = (@as(f32, @floatFromInt(window_width)) - viewport_width) / 2.0;
    } else {
        // Taller windows add vertical pillarboxing.
        viewport_height = @as(f32, @floatFromInt(window_width)) / source_aspect;
        viewport_y = (@as(f32, @floatFromInt(window_height)) - viewport_height) / 2.0;
    }

    // Ignore cursor positions in letterbox and pillarbox margins.
    if (self.cursor.position[0] < viewport_x or
        self.cursor.position[1] < viewport_y or
        self.cursor.position[0] >= viewport_x + viewport_width or
        self.cursor.position[1] >= viewport_y + viewport_height)
        return;

    // Convert window pixels into the renderer's logical screen coordinates.
    const source_x = (self.cursor.position[0] - viewport_x) *
        @as(f32, @floatFromInt(self.renderer.screen_width)) / viewport_width;
    const source_y = (self.cursor.position[1] - viewport_y) *
        @as(f32, @floatFromInt(self.renderer.screen_height)) / viewport_height;
    // Convert logical pixels into the display's scaled cell-grid coordinates.
    const cell_width = display.cell_width * display.scale;
    const cell_height = display.cell_height * display.scale;
    const origin_x = display.content_origin_x * display.scale;
    const origin_y = display.content_origin_y * display.scale;
    if (cell_width == 0 or cell_height == 0 or
        source_x < @as(f32, @floatFromInt(origin_x)) or
        source_y < @as(f32, @floatFromInt(origin_y)))
        return;

    // Find the cell under the cursor and reject coordinates outside the grid.
    const cell_x: u32 = @intFromFloat((source_x - @as(f32, @floatFromInt(origin_x))) /
        @as(f32, @floatFromInt(cell_width)));
    const cell_y: u32 = @intFromFloat((source_y - @as(f32, @floatFromInt(origin_y))) /
        @as(f32, @floatFromInt(cell_height)));
    if (cell_x >= display.width or cell_y >= display.height)
        return;

    // Write the cursor glyph after the state's display content is complete.
    try self.display.write(allocator, "+", cell_x, cell_y, .mine_shaft, .green_pea);
}
