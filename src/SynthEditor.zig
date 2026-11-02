//! The synth editor state and its demonstration DSP graph.
const std = @import("std");
const sdl = @import("zsdl3");
const DSP = @import("DSP.zig");
const StateStack = @import("StateStack.zig");
const ZSynth = @import("ZSynth.zig");
const Renderer = @import("Renderer.zig");
const Space = @import("Space.zig");

const Self = @This();

/// Runtime owning the display, renderer, and audio engine used by this state.
zsynth: *ZSynth,
/// DSP graph constructed when the editor enters the state stack.
dsp: DSP,
space: Space,

/// State-stack callbacks used by the synth editor context.
pub const vtable = StateStack.State.VTable{
    .enter = enter,
    .leave = leave,
    .quit = quit,
    .render = render,
    .keyUpDown = keyUpDown,
    .mouseMoved = mouseMoved,
    .mouseButton = mouseButton,
};

/// Initializes the editor DSP graph and writes its initial display text.
fn enter(
    state_stack: *StateStack,
    gpa: std.mem.Allocator,
    state: StateStack.State.Index,
) anyerror!void {
    // Resolve this state index to the concrete editor context.
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;
    // Initialize the DSP against the runtime-owned audio engine.
    try self.dsp.init(self.zsynth.audio_engine, gpa);
    self.space.dsp = &self.dsp;
    try addVisualNode(self, gpa, DSP.Node.Index.noop, .{ .x = 0, .y = 0 });
    // Build and start the simple demonstration graph.
    try simpleDSP(self, gpa);
    // Show the editor status after audio is running.
    try self.write(gpa);
}

/// Releases editor resources when the state is temporarily popped.
fn leave(
    state_stack: *StateStack,
    gpa: std.mem.Allocator,
    _: *Renderer,
    state: StateStack.State.Index,
) anyerror!void {
    // Resolve the concrete editor context before releasing its DSP graph.
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;
    self.deinit(gpa);
}

/// Releases editor resources when the application is shutting down.
fn quit(
    state_stack: *StateStack,
    gpa: std.mem.Allocator,
    _: *Renderer,
    state: StateStack.State.Index,
) anyerror!void {
    // Resolve the concrete editor context before releasing its DSP graph.
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;
    self.deinit(gpa);
}

/// Stops and deinitializes the DSP graph exactly once.
fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    self.dsp.deinit(gpa);
    self.space.deinit(gpa);
}

/// Redraws the editor's status text in the runtime-owned display.
fn write(self: *Self, gpa: std.mem.Allocator) !void {
    self.zsynth.display.reset();
    try self.space.write(gpa, &self.zsynth.display);
}

/// Moves the viewport and redraws the complete visible space.
fn moveViewport(self: *Self, gpa: std.mem.Allocator, dx: i32, dy: i32) !void {
    if (dx == 0 and dy == 0) return;
    self.space.moveViewport(dx, dy);
    try self.write(gpa);
}

/// Handles arrow keys used to move the editor viewport.
fn keyUpDown(
    state_stack: *StateStack,
    gpa: std.mem.Allocator,
    state: StateStack.State.Index,
    event: sdl.KeyboardEvent,
) anyerror!bool {
    if (!event.down) return false;

    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;
    const modifiers = std.mem.bytesToValue(u16, std.mem.asBytes(&event.mod));
    const delta: i32 = if ((modifiers & sdl.Keymod.shift) != 0) 5 else 1;

    switch (event.key) {
        .d => if ((modifiers & sdl.Keymod.ctrl) != 0) {
            if (self.zsynth.display.impl == .graphic) {
                var stdout_buffer: [4096]u8 = undefined;
                var stdout = std.Io.File.stdout().writer(self.zsynth.io, &stdout_buffer);
                try self.zsynth.display.impl.graphic.dump(&stdout.interface);
                stdout.flush() catch return error.WriteFailed;
            }
        } else return false,
        .up => try self.moveViewport(gpa, 0, -delta),
        .down => try self.moveViewport(gpa, 0, delta),
        .left => try self.moveViewport(gpa, -delta, 0),
        .right => try self.moveViewport(gpa, delta, 0),
        .space => try self.dsp.toggle(),
        .escape => {
            self.space.selected_node = null;
            try self.write(gpa);
        },
        else => return false,
    }

    return true;
}

/// Starts and stops viewport panning with the middle mouse button.
fn mouseButton(
    state_stack: *StateStack,
    gpa: std.mem.Allocator,
    state: StateStack.State.Index,
    event: sdl.MouseButtonEvent,
) anyerror!bool {
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;

    if (event.button == 1) {
        self.zsynth.cursor.left_mouse_down = event.down;
        self.zsynth.cursor.left_mouse_moved = false;

        if (event.down) {
            const cell = self.zsynth.displayCellAtWindowPosition(.{ event.x, event.y });
            self.space.selected_node = if (cell) |display_cell|
                self.space.nodeAtDisplayCell(display_cell[0], display_cell[1])
            else
                null;

            if (cell) |display_cell| if (self.space.selected_node) |node| {
                if (!node.isNoop()) {
                    const world = self.space.worldPositionAtDisplayCell(display_cell[0], display_cell[1]);
                    const position = self.space.nodePosition(node);
                    self.zsynth.cursor.drag_offset = .{
                        world.x - position.x,
                        world.y - position.y,
                    };
                    self.zsynth.cursor.drag_position = .{ world.x, world.y };
                }
            };
            try self.write(gpa);
        } else if (self.zsynth.cursor.left_mouse_moved) {
            try self.space.computePaths(gpa);
            self.zsynth.cursor.left_mouse_moved = false;
            try self.write(gpa);
        } else {
            self.zsynth.cursor.left_mouse_moved = false;
        }
        return true;
    }

    if (event.button != 2) return false;

    self.zsynth.cursor.middle_mouse_down = event.down;
    self.zsynth.cursor.viewport_pan_remainder = .{ 0, 0 };
    return true;
}

/// Converts middle-button mouse motion into whole-cell viewport movement.
fn mouseMoved(
    state_stack: *StateStack,
    gpa: std.mem.Allocator,
    state: StateStack.State.Index,
    event: sdl.MouseMotionEvent,
) anyerror!bool {
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;

    if (self.zsynth.cursor.left_mouse_down) {
        if (event.state.left == 0) {
            self.zsynth.cursor.left_mouse_down = false;
            if (self.zsynth.cursor.left_mouse_moved) {
                try self.space.computePaths(gpa);
                self.zsynth.cursor.left_mouse_moved = false;
                try self.write(gpa);
            }
            return true;
        }

        const cell = self.zsynth.displayCellAtWindowPosition(.{ event.x, event.y }) orelse return true;
        const world = self.space.worldPositionAtDisplayCell(cell[0], cell[1]);
        const cursor_position = &self.zsynth.cursor;
        if (cursor_position.drag_position[0] == world.x and
            cursor_position.drag_position[1] == world.y)
            return true;
        cursor_position.drag_position = .{ world.x, world.y };

        if (self.space.selected_node) |node| {
            if (!node.isNoop()) {
                const position = Space.Position{
                    .x = world.x - cursor_position.drag_offset[0],
                    .y = world.y - cursor_position.drag_offset[1],
                };
                if (try self.space.moveNode(gpa, node, position)) {
                    cursor_position.left_mouse_moved = true;
                    try self.space.recomputePathsForNode(gpa, node);
                    try self.write(gpa);
                }
            }
        }
        return true;
    }

    if (!self.zsynth.cursor.middle_mouse_down) return false;

    if (event.state.middle == 0) {
        self.zsynth.cursor.middle_mouse_down = false;
        self.zsynth.cursor.viewport_pan_remainder = .{ 0, 0 };
        return false;
    }

    if (self.zsynth.display.impl != .graphic) return true;

    const display = &self.zsynth.display.impl.graphic;
    const source_aspect = @as(f32, @floatFromInt(self.zsynth.renderer.screen_width)) /
        @as(f32, @floatFromInt(self.zsynth.renderer.screen_height));
    var window_width: c_int = 0;
    var window_height: c_int = 0;
    sdl.getWindowSize(self.zsynth.renderer.window, &window_width, &window_height) catch return true;
    if (window_width <= 0 or window_height <= 0) return true;

    var viewport_width: f32 = @floatFromInt(window_width);
    var viewport_height: f32 = @floatFromInt(window_height);
    const window_aspect = @as(f32, @floatFromInt(window_width)) /
        @as(f32, @floatFromInt(window_height));
    if (source_aspect > window_aspect) {
        viewport_width = @as(f32, @floatFromInt(window_height)) * source_aspect;
    } else {
        viewport_height = @as(f32, @floatFromInt(window_width)) / source_aspect;
    }

    const source_delta_x = event.xrel *
        @as(f32, @floatFromInt(self.zsynth.renderer.screen_width)) / viewport_width;
    const source_delta_y = event.yrel *
        @as(f32, @floatFromInt(self.zsynth.renderer.screen_height)) / viewport_height;
    const cell_width = @as(f32, @floatFromInt(display.cell_width * display.scale));
    const cell_height = @as(f32, @floatFromInt(display.cell_height * display.scale));
    if (cell_width == 0 or cell_height == 0) return true;

    self.zsynth.cursor.viewport_pan_remainder[0] += source_delta_x / cell_width;
    self.zsynth.cursor.viewport_pan_remainder[1] += source_delta_y / cell_height;
    const cell_delta_x: i32 = @intFromFloat(self.zsynth.cursor.viewport_pan_remainder[0]);
    const cell_delta_y: i32 = @intFromFloat(self.zsynth.cursor.viewport_pan_remainder[1]);
    self.zsynth.cursor.viewport_pan_remainder[0] -= @floatFromInt(cell_delta_x);
    self.zsynth.cursor.viewport_pan_remainder[1] -= @floatFromInt(cell_delta_y);

    try self.moveViewport(gpa, -cell_delta_x, -cell_delta_y);
    return true;
}

/// Rebuilds the text display and enqueues the graphic display renderer.
fn render(
    state_stack: *StateStack,
    gpa: std.mem.Allocator,
    state: StateStack.State.Index,
    renderer: *Renderer,
    dt: u64,
) anyerror!void {
    // Resolve the concrete editor context for this frame.
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;
    // Redraw text before the runtime overlays the software cursor.
    try self.write(gpa);
    // Submit the graphic display only when that display backend is active.
    if (self.zsynth.display.impl == .graphic)
        try self.zsynth.display.impl.graphic.render(gpa, renderer, dt, true);
}

/// Notes used by the melodic demonstration sequencer.
const sequencer_notes = [_]DSP.Note{
    .{ // A4
        .pitch = DSP.Note.Pitch.a.pitch(.natural, 4),
        .start_tick = 0,
        .duration_ticks = DSP.Node.MonophonicSequencer.quarter_note_ticks * 4,
    },
    .{ // B4
        .pitch = DSP.Note.Pitch.b.pitch(.natural, 4),
        .start_tick = DSP.Node.MonophonicSequencer.quarter_note_ticks * 4,
        .duration_ticks = DSP.Node.MonophonicSequencer.quarter_note_ticks * 2,
    },
    .{ // C4
        .pitch = DSP.Note.Pitch.c.pitch(.natural, 4),
        .start_tick = DSP.Node.MonophonicSequencer.quarter_note_ticks * 4 * 2,
        .duration_ticks = DSP.Node.MonophonicSequencer.quarter_note_ticks * 4,
    },
};

/// Notes used to trigger the demonstration percussion voice.
const beat_notes = [_]DSP.Note{ // Fed into a Noise node so we dont care about the pitch
    .{
        .pitch = DSP.Note.Pitch.a.pitch(.natural, 4),
        .start_tick = 0,
        .duration_ticks = DSP.Node.MonophonicSequencer.quarter_note_ticks / 2,
    },
    .{
        .pitch = DSP.Note.Pitch.a.pitch(.natural, 4),
        .start_tick = DSP.Node.MonophonicSequencer.quarter_note_ticks,
        .duration_ticks = DSP.Node.MonophonicSequencer.quarter_note_ticks / 2,
    },
    .{
        .pitch = DSP.Note.Pitch.a.pitch(.natural, 4),
        .start_tick = DSP.Node.MonophonicSequencer.quarter_note_ticks * 2,
        .duration_ticks = DSP.Node.MonophonicSequencer.quarter_note_ticks,
    },
};

fn addVisualNode(
    self: *Self,
    allocator: std.mem.Allocator,
    node: DSP.Node.Index,
    position: Space.Position,
) !void {
    std.debug.assert(node.idx == self.space.nodes.len);
    try self.space.nodes.append(allocator, .{
        .dsp_node = node,
        .position = position,
    });

    if (node.isNoop()) return;

    const footprint = self.space.nodeFootprint(node);
    for (0..footprint.width) |dx| {
        for (0..footprint.height) |dy| {
            const occupied = Space.Position{
                .x = footprint.x + @as(i32, @intCast(dx)),
                .y = footprint.y + @as(i32, @intCast(dy)),
            };
            std.debug.assert(self.space.occupied.get(occupied) == null);
            try self.space.occupied.put(allocator, occupied, node);
        }
    }
}

fn addNode(
    self: *Self,
    allocator: std.mem.Allocator,
    node: DSP.Node,
    position: Space.Position,
) !DSP.Node.Index {
    const index = try self.dsp.addNode(allocator, node);
    try addVisualNode(self, allocator, index, position);
    return index;
}

/// Create a simple DSP with a square waveform, modulation, sequencing, and effects.
fn simpleDSP(self: *Self, allocator: std.mem.Allocator) !void {
    const dsp = &self.dsp;

    // Create the three pitched voices used by the demo.
    // First voice
    const voice1 = try addNode(
        self,
        allocator,
        DSP.Node.Oscillator.create(
            "voice1",
            .{
                .waveform = .square,
                .default_frequency = 440,
                .default_amplitude = 0.5,
            },
        ),
        .{ .x = 5, .y = -12 },
    );

    // Second voice
    const voice2 = try addNode(
        self,
        allocator,
        DSP.Node.Oscillator.create(
            "voice2",
            .{
                .waveform = .square,
                .default_frequency = 587.33,
                .default_amplitude = 0.5,
            },
        ),
        .{ .x = 5, .y = -5 },
    );

    // Third voice
    const voice3 = try addNode(
        self,
        allocator,
        DSP.Node.Oscillator.create(
            "voice3",
            .{
                .waveform = .triangle,
                .default_frequency = 440,
                .default_amplitude = 0.6,
            },
        ),
        .{ .x = 5, .y = 7 },
    );

    // Create two low-frequency modulators.
    // LFO
    const lfo = try addNode(
        self,
        allocator,
        DSP.Node.Oscillator.create(
            "lfo",
            .{
                .waveform = .sine,
                .default_frequency = 5,
                .default_amplitude = 5,
            },
        ),
        .{ .x = -25, .y = -14 },
    );

    // Create the second LFO used as an amplitude modulation source.
    const lfo2 = try addNode(
        self,
        allocator,
        DSP.Node.Oscillator.create(
            "lfo2",
            .{
                .waveform = .sine,
                .default_frequency = 3,
                .default_amplitude = 3,
            },
        ),
        .{ .x = 25, .y = 17 },
    );

    // Combine the second LFO with the filtered third voice.
    const multiply = try addNode(
        self,
        allocator,
        DSP.Node.Multiply.create("multiply"),
        .{ .x = 50, .y = 7 },
    );

    // Create the constant and adder used to offset the first voice's pitch.
    // Emit single 440 value
    const constant = try addNode(
        self,
        allocator,
        DSP.Node.Constant.create("constant", .{ .constant = 440 }),
        .{ .x = -25, .y = -5 },
    );

    // Add so LFO modulates voice frequency instead of replace it
    // Add the LFO signal to the base 440 Hz frequency.
    const add = try addNode(
        self,
        allocator,
        DSP.Node.Add.create("add"),
        .{ .x = -8, .y = -10 },
    );

    // Create the mixer that combines melodic and percussion voices.
    // Mixer for 2 voices
    const mixer = try addNode(
        self,
        allocator,
        DSP.Node.Mixer.create(
            "mixer",
            .{
                .gain = 0.3,
                // Both voice at 0.5 gain and first voice 0.5 to the left and second 0.5 to the right
                .gains = [_]f32{ 0.1, 0.1, 0.6, 0.3, 0, 0, 0, 0 },
                .pans = [_]f32{ -0.7, 0.7, 0.0, 0.0, 0, 0, 0, 0 },
            },
        ),
        .{ .x = 68, .y = 5 },
    );

    // Create the melodic sequencer and its shaping effects.
    // Sequencer
    const sequencer = try addNode(
        self,
        allocator,
        DSP.Node.MonophonicSequencer.create(
            "sequencer",
            .{
                .notes = &sequencer_notes,
            },
        ),
        .{ .x = -25, .y = 7 },
    );

    // Add the filter, envelope, and bit crusher for the third voice.
    // High pass filter
    // Filter the third voice before its second modulation stage.
    const notch_filter = try addNode(
        self,
        allocator,
        DSP.Node.MultimodeFilter.create(
            "notch_filter",
            .{
                .type = .notch,
                .default_cutoff = 400,
                .default_resonance = 0.75,
            },
        ),
        .{ .x = 25, .y = 7 },
    );

    // ADSR
    // Shape the sequenced voice with an envelope.
    const adsr = try addNode(
        self,
        allocator,
        DSP.Node.ADSR.create(
            "adsr",
            .{
                .attack = 0.3,
                .attack_curve = .linear,
                .decay = 0.4,
                .sustain = 0.7,
                .release = 0.5,
            },
        ),
        .{ .x = -8, .y = 7 },
    );

    // BitCrusher (to get a 8bit/chip feel)
    // Reduce the mixed signal to give the demo an 8-bit character.
    const crusher = try addNode(
        self,
        allocator,
        DSP.Node.BitCrusher.create("crusher", .{}),
        .{ .x = 82, .y = 5 },
    );

    // Create the beat sequencer and noise generator.
    // Sequencer for beat, will be fed into Noise node
    const beat = try addNode(
        self,
        allocator,
        DSP.Node.MonophonicSequencer.create(
            "beat",
            .{
                .notes = &beat_notes,
            },
        ),
        .{ .x = -25, .y = 17 },
    );

    // Noise
    const noise = try addNode(
        self,
        allocator,
        DSP.Node.Noise.create(
            "noise",
            .{
                .seed = 0,
                .type = .pink,
            },
        ),
        .{ .x = -8, .y = 17 },
    );

    // Create the final output node and make it the DSP destination.
    // Final output to audio device
    const output = try addNode(
        self,
        allocator,
        DSP.Node.Output.create("output"),
        .{ .x = 96, .y = 5 },
    );
    dsp.output = output;

    // Connect modulation, sequencing, voices, effects, and output.
    // Plug everything together

    // LFO -> Add
    dsp.plug(lfo, 0, add, 0);
    // 440 -> Add
    dsp.plug(constant, 0, add, 1);
    // Add -> Voice1
    dsp.plug(add, 0, voice1, 0);
    // Sequencer.frequency -> Voice3.frequency
    dsp.plug(sequencer, 0, voice3, 0);
    // Sequencer.gate -> ADSR.gate
    dsp.plug(sequencer, 1, adsr, 0);
    // Sequencer.velocity -> ADSR.velocity
    dsp.plug(sequencer, 2, adsr, 1);
    // ADSR -> Voice3.amplitude
    dsp.plug(adsr, 0, voice3, 1);
    // Voice3 -> High pass filter
    dsp.plug(voice3, 0, notch_filter, 0);
    // High pass filter x LFO2
    dsp.plug(notch_filter, 0, multiply, 0);
    dsp.plug(lfo2, 0, multiply, 1);
    // Beat.gate -> Noise.amplitude
    dsp.plug(beat, 1, noise, 0);
    // Voice1, Voice2, Multiply, Noise -> Mixer
    dsp.plug(voice1, 0, mixer, 0);
    dsp.plug(voice2, 0, mixer, 1);
    dsp.plug(multiply, 0, mixer, 2);
    dsp.plug(noise, 0, mixer, 3);
    // Mixer -> BitCrusher
    dsp.plug(mixer, 0, crusher, 0);
    // Crusher -> Output
    dsp.plug(crusher, 0, output, 0);

    if (!try self.space.rebuildOccupancy(allocator))
        return error.InvalidVisualNodeLayout;

    // Compute link paths after the complete graph and all visual nodes exist.
    try self.space.computePaths(allocator);
}
