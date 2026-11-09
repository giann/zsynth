//! Owns the ZSynth application runtime and its top-level graphics resources.

const std = @import("std");
const pa = @import("portaudio.zig");
const sdl = @import("zsdl3");
const stbi = @import("zstbi");
const zgui = @import("zgui");
const Display = @import("Display.zig");
const PostProcessing = @import("PostProcessing.zig");
const Renderer = @import("Renderer.zig");
const StateStack = @import("StateStack.zig");
const SynthEditor = @import("SynthEditor.zig");
const DSP = @import("DSP.zig");
const pm = @import("portmidi.zig");

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
    /// Whether the transparent cursor overlay needs to be rebuilt.
    dirty: bool = false,
    /// Whether the middle mouse button is currently panning the viewport.
    middle_mouse_down: bool = false,
    /// Fractional viewport-cell movement retained between mouse events.
    viewport_pan_remainder: [2]f32 = .{ 0, 0 },
    /// Whether the left mouse button is currently held for a drag.
    left_mouse_down: bool = false,
    /// Whether the pointer moved far enough during the current left drag.
    left_mouse_moved: bool = false,
    /// World/display-cell offset from the grabbed object to the pointer.
    drag_offset: [2]i32 = .{ 0, 0 },
    /// Last world/display-cell position observed during the drag.
    drag_position: [2]i32 = .{ 0, 0 },
    /// World/display-cell position where an empty-space selection began.
    selection_anchor: [2]i32 = .{ 0, 0 },
    /// Whether the current left drag is drawing a selection marquee.
    selection_dragging: bool = false,
};

/// The I/O context shared with the renderer and asset loader.
io: std.Io,
/// Devices that passed the graph's stereo 48 kHz output-format check.
audio_devices: []pa.Device,
/// Available MIDI input devices collected after PortMidi initialization.
midi_devices: []pm.Device,
/// Device used when a new graph is created or a saved device is unavailable.
default_audio_device: pa.DeviceId,
/// GPU renderer and its window.
renderer: Renderer,
/// Character-grid display written by application states.
display: Display,
/// Transparent character-grid display used for transient UI overlays.
ui_display: Display,
/// Post-processing passes applied in order before presentation.
post_processing: []PostProcessing,
/// Stack containing the active application state contexts.
state_stack: StateStack,
/// Software cursor state, including its position and visibility.
cursor: CursorState = .{},

/// Initializes audio, SDL, the renderer, the display, and post-processing.
pub fn init(process: std.process.Init, allocator: std.mem.Allocator) !Self {
    // Initialize PortAudio and retain supported output names for UI and documents.
    try pa.init();
    errdefer pa.deinit() catch {};
    const audio_devices = try pa.enumerateOutputDevices(allocator, DSP.sample_rate);
    errdefer pa.deinitDevices(allocator, audio_devices);
    if (audio_devices.len == 0) return error.NoUsableAudioOutput;
    const default_audio_device = pa.defaultDevice(audio_devices) orelse audio_devices[0].id;

    // Retain valid MIDI input identities for the editor and synth documents.
    try pm.init();
    errdefer pm.deinit() catch {};
    const midi_devices = try pm.enumerateInputDevices(allocator);
    errdefer pm.deinitDevices(allocator, midi_devices);

    // Initialize image loading before any display assets are requested.
    stbi.init(process.io, allocator);

    // Create the SDL video subsystem and hide the native cursor.
    try sdl.init(.{ .video = true });
    try sdl.hideCursor();

    // Create the GPU renderer and its logical 640x360 window.
    var renderer = try Renderer.init(screen_width, screen_height, false, 1);

    // Attach the window to the GPU device and synchronize presentation to the display.
    try sdl.claimWindowForGPUDevice(renderer.device, renderer.window);
    if (sdl.windowSupportsGPUPresentMode(renderer.device, renderer.window, .vsync)) {
        try sdl.setGPUSwapchainParameters(
            renderer.device,
            renderer.window,
            .sdr,
            .vsync,
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

    var ui_display = Display{
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
    ui_display.resetTransparent();

    // Allocate the state stack before the first editor state is pushed.
    const state_stack = try StateStack.init(allocator);

    // Initialize the GUI backend owned by the application runtime.
    zgui.init(allocator);

    var self = Self{
        .io = process.io,
        .audio_devices = audio_devices,
        .midi_devices = midi_devices,
        .default_audio_device = default_audio_device,
        .renderer = renderer,
        .display = display,
        .ui_display = ui_display,
        .post_processing = try allocator.dupe(
            PostProcessing,
            &.{
                try PostProcessing.sharpenProcess(
                    allocator,
                    &renderer,
                    0.50,
                    screen_width,
                    screen_height,
                ),
                // try PostProcessing.bloomProcess(
                //     allocator,
                //     &renderer,
                //     0.85,
                //     0.35,
                //     screen_width,
                //     screen_height,
                // ),
                try PostProcessing.grainProcess(
                    allocator,
                    &renderer,
                    .{},
                    screen_width,
                    screen_height,
                ),
            },
        ),
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
            .context = .{
                .synth_editor = .{
                    .zsynth = self,
                    .dsp = undefined,
                    .space = .{
                        .dsp = undefined,
                        .viewport = .{
                            .x = @as(i32, @intCast(self.display.impl.graphic.width / 2)) * -1,
                            .y = @as(i32, @intCast(self.display.impl.graphic.height / 2)) * -1,
                            .width = self.display.impl.graphic.width,
                            .height = self.display.impl.graphic.height,
                        },
                    },
                    .serializer = undefined,
                },
            },
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

            // Let states inspect the raw event before typed callbacks receive it.
            const input_consumed = try self.state_stack.inputEvent(allocator, event);

            // Update the software cursor from every motion event.
            if (event.type == .mouse_motion)
                self.updateMousePosition(event.motion);

            if (!input_consumed) switch (event.type) {
                .key_down, .key_up => {
                    // Keep the fullscreen shortcut at the application level.
                    if (event.type == .key_down and
                        event.key.key == .f and
                        !event.key.repeat and
                        (@backingInt(event.key.mod) & sdl.Keymod.ctrl) != 0)
                    {
                        try self.renderer.toggleFullscreen();
                    } else {
                        try self.state_stack.keyUpDown(allocator, event.key);
                    }
                },
                .text_input => try self.state_stack.textInput(allocator, event.text),
                .mouse_motion => try self.state_stack.mouseMoved(allocator, event.motion),
                .mouse_button_down, .mouse_button_up => try self.state_stack.mouseButton(allocator, event.button),
                else => {},
            };
        }
        // Quit states cleanly when SDL reports that the window closed.
        if (should_quit) {
            try self.state_stack.quit(allocator, &self.renderer);
            break;
        }

        // Acquire the command buffer used by this frame's GPU work.
        const cmd_buffer = try sdl.acquireGPUCommandBuffer(self.renderer.device);
        // Clear transient UI content before editor states redraw their overlays.
        if (self.cursor.dirty) {
            self.ui_display.resetTransparent();
            self.cursor.dirty = false;
        }
        // Let states write their display and rendering commands.
        try self.state_stack.render(allocator, &self.renderer, frame_delta);
        // Overlay the software cursor after the state has redrawn its display.
        try self.writeCursor(allocator);
        // Composite the transparent UI overlay above the regular display.
        if (self.ui_display.impl == .graphic)
            try self.ui_display.impl.graphic.render(
                allocator,
                &self.renderer,
                frame_delta,
                true,
            );

        // Run every post-processing pass, marking the final pass for presentation.
        for (self.post_processing, 0..) |*post, index|
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
    for (self.post_processing) |*post|
        post.deinit(&self.renderer);
    allocator.free(self.post_processing);
    // Destroy the display's GPU resources while the renderer is still alive.
    if (self.display.impl == .graphic)
        self.display.impl.graphic.deinit(allocator, &self.renderer);
    if (self.ui_display.impl == .graphic)
        self.ui_display.impl.graphic.deinit(allocator, &self.renderer);
    // Release the renderer, GUI backend, and SDL services in dependency order.
    self.renderer.deinit(allocator);
    zgui.deinit();
    sdl.showCursor() catch {};
    sdl.quit();
    // Shut down image loading and audio after their users are gone.
    stbi.deinit();
    pm.deinitDevices(allocator, self.midi_devices);
    pm.deinit() catch {};
    pa.deinitDevices(allocator, self.audio_devices);
    pa.deinit() catch {};
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
    self.cursor.dirty = true;
}

/// Updates and clamps the software cursor from an SDL mouse-motion event.
fn updateMousePosition(self: *Self, event: sdl.MouseMotionEvent) void {
    const previous_position = self.cursor.position;
    const previous_relative_mode = self.cursor.relative_mode;
    const was_initialized = self.cursor.initialized;

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

    if (!was_initialized or
        previous_relative_mode != self.cursor.relative_mode or
        previous_position[0] != self.cursor.position[0] or
        previous_position[1] != self.cursor.position[1])
        self.cursor.dirty = true;
}

/// Convert a window-space position to a cell in the regular display.
pub fn displayCellAtWindowPosition(self: *Self, position: [2]f32) ?[2]u32 {
    if (self.display.impl != .graphic) return null;

    const display = &self.display.impl.graphic;
    var window_width: c_int = 0;
    var window_height: c_int = 0;
    sdl.getWindowSize(self.renderer.window, &window_width, &window_height) catch return null;
    if (window_width <= 0 or window_height <= 0) return null;

    const source_aspect = @as(f32, @floatFromInt(self.renderer.screen_width)) /
        @as(f32, @floatFromInt(self.renderer.screen_height));
    const window_aspect = @as(f32, @floatFromInt(window_width)) /
        @as(f32, @floatFromInt(window_height));
    var viewport_x: f32 = 0;
    var viewport_y: f32 = 0;
    var viewport_width: f32 = @floatFromInt(window_width);
    var viewport_height: f32 = @floatFromInt(window_height);

    if (window_aspect > source_aspect) {
        viewport_width = @as(f32, @floatFromInt(window_height)) * source_aspect;
        viewport_x = (@as(f32, @floatFromInt(window_width)) - viewport_width) / 2.0;
    } else {
        viewport_height = @as(f32, @floatFromInt(window_width)) / source_aspect;
        viewport_y = (@as(f32, @floatFromInt(window_height)) - viewport_height) / 2.0;
    }

    if (position[0] < viewport_x or
        position[1] < viewport_y or
        position[0] >= viewport_x + viewport_width or
        position[1] >= viewport_y + viewport_height)
        return null;

    const source_x = (position[0] - viewport_x) *
        @as(f32, @floatFromInt(self.renderer.screen_width)) / viewport_width;
    const source_y = (position[1] - viewport_y) *
        @as(f32, @floatFromInt(self.renderer.screen_height)) / viewport_height;
    const cell_width = display.cell_width * display.scale;
    const cell_height = display.cell_height * display.scale;
    const origin_x = display.content_origin_x * display.scale;
    const origin_y = display.content_origin_y * display.scale;
    if (cell_width == 0 or cell_height == 0 or
        source_x < @as(f32, @floatFromInt(origin_x)) or
        source_y < @as(f32, @floatFromInt(origin_y)))
        return null;

    const cell_x: u32 = @intFromFloat((source_x - @as(f32, @floatFromInt(origin_x))) /
        @as(f32, @floatFromInt(cell_width)));
    const cell_y: u32 = @intFromFloat((source_y - @as(f32, @floatFromInt(origin_y))) /
        @as(f32, @floatFromInt(cell_height)));
    if (cell_x >= display.width or cell_y >= display.height)
        return null;

    return .{ cell_x, cell_y };
}

/// Converts the window-space cursor position to a display cell and draws it.
fn writeCursor(self: *Self, allocator: std.mem.Allocator) !void {
    // Only draw the cursor when the software cursor and graphic display exist.
    if (!self.cursor.visible or self.ui_display.impl != .graphic)
        return;

    // Read the current window size before mapping pixels to logical coordinates.
    const display = &self.ui_display.impl.graphic;
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
    try self.ui_display.write(
        allocator,
        "+",
        cell_x,
        cell_y,
        .green_pea,
        .mine_shaft,
    );
}
