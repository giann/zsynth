//! The synth editor state and its demonstration DSP graph.
const std = @import("std");
const assert = std.debug.assert;
const sdl = @import("zsdl3");
const DSP = @import("DSP.zig");
const StateStack = @import("StateStack.zig");
const ZSynth = @import("ZSynth.zig");
const Renderer = @import("Renderer.zig");
const Space = @import("Space.zig");
const Display = @import("Display.zig");
const VisualNode = Space.VisualNode;

const Self = @This();

/// Number of parameter rows available after applying the pane padding.
const parameters_pane_padding: u32 = 1;

/// Runtime owning the display, renderer, and audio engine used by this state.
zsynth: *ZSynth,
/// DSP graph constructed when the editor enters the state stack.
dsp: DSP,
space: Space,
/// Output meter bound to the currently selected DSP node.
output_meter: OutputMeter = .{},

/// State-stack callbacks used by the synth editor context.
pub const vtable = StateStack.State.VTable{
    .enter = enter,
    .leave = leave,
    .quit = quit,
    .update = update,
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

/// Updates the selected node's output meter from the main thread.
fn update(
    state_stack: *StateStack,
    _: std.mem.Allocator,
    state: StateStack.State.Index,
    dt: u64,
) anyerror!void {
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;
    const selected_node = self.space.selected_node orelse return;
    if (self.output_meter.output_count == 0) return;
    assert(self.output_meter.parameters.node.idx == selected_node.idx);
    self.output_meter.update(&self.dsp, dt);
}

/// Changes the selected node and resets the meter source to match it.
fn setNodeSelection(self: *Self, node: ?VisualNode.Index) void {
    const selected = if (node) |value| if (value.isNoop()) null else value else null;
    const previous_parameters = self.output_meter.parameters;
    self.space.selected_node = selected;
    self.output_meter = .{
        .parameters = .{
            .direction = previous_parameters.direction,
            .node = undefined,
            .meter_cell_count = previous_parameters.meter_cell_count,
        },
    };

    const selected_node = selected orelse return;
    if (selected_node.idx >= self.dsp.nodes.len) {
        self.space.selected_node = null;
        self.output_meter = .{};
        return;
    }

    const state = self.dsp.nodes.items(.state)[selected_node.idx];
    const metadata = DSP.node_metadata.get(std.meta.activeTag(state));
    if (!metadata.meterable) return;

    self.output_meter.parameters.node = selected_node;
    self.output_meter.output_count = metadata.output_count;
    assert(self.output_meter.parameters.meter_cell_count > 0);

    const horizontal = switch (self.output_meter.parameters.direction) {
        .left, .right => true,
        .up, .down => false,
    };
    self.output_meter.height = if (horizontal)
        3
    else
        self.output_meter.parameters.meter_cell_count + 2;

    for (metadata.outputs[0..metadata.output_count], 0..) |output, output_port| {
        self.output_meter.output_short_names[output_port] = output.short_name;
        const group_width = if (horizontal)
            @max(
                self.output_meter.parameters.meter_cell_count + 1,
                @as(u32, @intCast(output.short_name.len)),
            )
        else
            @max(2, @as(u32, @intCast(output.short_name.len)));
        self.output_meter.width += @max(
            group_width,
            @as(u32, @intCast(output.short_name.len)),
        );
        if (output_port + 1 < metadata.output_count)
            self.output_meter.width += 1;
    }
}

/// Redraws the editor's status text in the runtime-owned display.
fn write(self: *Self, gpa: std.mem.Allocator) !void {
    self.zsynth.display.reset();
    try self.space.write(gpa, &self.zsynth.display);
}

/// Draws the selected node's reflected parameters in the bottom UI pane.
fn writeSelectedParametersPane(self: *Self, gpa: std.mem.Allocator) !void {
    const display = &self.zsynth.ui_display;
    if (display.impl != .graphic) return;

    const graphic = &display.impl.graphic;
    const selected = self.space.selected_node orelse return;
    if (selected.isNoop() or selected.idx >= self.dsp.nodes.len) return;

    if (graphic.height < 2 or graphic.width <= parameters_pane_padding * 2)
        return;

    const state = self.dsp.nodes.items(.state)[selected.idx];
    switch (state) {
        inline else => |node_state| {
            if (@hasField(@TypeOf(node_state), "parameters")) {
                try writeReflectedParameters(
                    gpa,
                    display,
                    node_state.parameters,
                    graphic.height,
                    graphic.width,
                    &self.output_meter,
                );
            } else {
                try writeReflectedParameters(
                    gpa,
                    display,
                    struct {}{},
                    graphic.height,
                    graphic.width,
                    &self.output_meter,
                );
            }
        },
    }
}

/// Formats one reflected parameter value, collapsing non-scalar values.
fn formatParameterValue(buffer: []u8, value: anytype) []const u8 {
    var result: []const u8 = "...";
    switch (@typeInfo(@TypeOf(value))) {
        .bool, .int, .float => {
            result = std.fmt.bufPrint(buffer, "{}", .{value}) catch "...";
        },
        .@"enum" => {
            result = std.fmt.bufPrint(buffer, "{s}", .{@tagName(value)}) catch "...";
        },
        else => {},
    }
    return result;
}

/// Writes reflected parameter fields in padded, row-limited columns.
fn writeReflectedParameters(
    gpa: std.mem.Allocator,
    display: *Display,
    parameters: anytype,
    display_height: u32,
    display_width: u32,
    output_meter: *const OutputMeter,
) !void {
    const field_names = @typeInfo(@TypeOf(parameters)).@"struct".field_names;
    var items: [field_names.len]Display.LabelValue = undefined;
    var value_buffers: [field_names.len][64]u8 = undefined;

    inline for (field_names, 0..) |field_name, index| {
        const value = @field(parameters, field_name);
        const value_color: Display.Color = switch (@typeInfo(@TypeOf(value))) {
            .int, .float => .golden_rod,
            .@"enum" => .science_blue,
            else => .white,
        };
        const formatted_value = formatParameterValue(&value_buffers[index], value);
        items[index] = .{
            .label = field_name,
            .value = formatted_value,
            .value_color = value_color,
        };
    }

    const pane_height = @min(
        display_height,
        @max(
            @as(u32, 5),
            @max(
                @as(u32, @intCast(field_names.len)) + 2,
                output_meter.height + 2,
            ),
        ),
    );
    if (pane_height < 2) return;
    const row_count = @min(
        @as(u32, @intCast(field_names.len)),
        pane_height - 2,
    );
    // Match writeLabelValueColumns' column packing so the pane reserves the
    // same width that the parameter renderer will consume.
    var content_width: u32 = 0;
    if (items.len != 0 and row_count != 0) {
        const rows = @min(row_count, @as(u32, @intCast(items.len)));
        var item_index: usize = 0;
        while (item_index < items.len) {
            const column_end = @min(
                item_index + @as(usize, @intCast(rows)),
                items.len,
            );
            var label_width: u32 = 0;
            var column_width: u32 = 0;

            for (item_index..column_end) |index|
                label_width = @max(
                    label_width,
                    @as(u32, @intCast(Display.countStripped(items[index].label))),
                );

            for (item_index..column_end) |index|
                column_width = @max(
                    column_width,
                    label_width + 2 +
                        @as(u32, @intCast(Display.countStripped(items[index].value))),
                );

            content_width += column_width;
            item_index = column_end;
            if (item_index < items.len)
                content_width += 1;
        }
    }
    const parameter_x = parameters_pane_padding + output_meter.width +
        @as(u32, @intFromBool(output_meter.output_count != 0));
    const required_meter_width = output_meter.width + parameters_pane_padding * 2;
    const required_parameter_width = parameter_x + content_width + parameters_pane_padding;
    const pane_width = @min(display_width, @max(required_meter_width, required_parameter_width));
    if (pane_width < 2) return;
    const pane_top = display_height - pane_height;
    try display.fill(
        gpa,
        .ebony,
        .white,
        ' ',
        0,
        pane_top,
        pane_width,
        pane_height,
    );
    try display.writeBox(
        gpa,
        0,
        pane_top,
        pane_width,
        pane_height,
        .ebony,
        .port_gore,
        .single,
    );

    if (output_meter.output_count != 0)
        try output_meter.write(
            gpa,
            display,
            .{ parameters_pane_padding, pane_top + parameters_pane_padding },
        );

    if (content_width != 0)
        try display.writeLabelValueColumns(
            gpa,
            &items,
            parameter_x,
            pane_top + parameters_pane_padding,
            pane_width,
            row_count,
            .ebony,
            .apple,
        );
}

/// Moves the viewport and redraws the complete visible space.
fn moveViewport(self: *Self, gpa: std.mem.Allocator, dx: i32, dy: i32) !void {
    if (dx == 0 and dy == 0) return;
    self.space.moveViewport(dx, dy);
    self.zsynth.cursor.dirty = true;
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
        .up => try self.moveViewport(gpa, 0, -delta),
        .down => try self.moveViewport(gpa, 0, delta),
        .left => try self.moveViewport(gpa, -delta, 0),
        .right => try self.moveViewport(gpa, delta, 0),
        .space => {
            const was_playing = self.dsp.isPlaying();
            try self.dsp.toggle();
            if (was_playing and self.output_meter.output_count != 0) {
                self.output_meter.reset();
                try self.writeSelectedParametersPane(gpa);
            }
        },
        .d => if (self.space.selected_node) |selected|
            try self.remove(gpa, selected),
        .escape => {
            self.setNodeSelection(null);
            self.zsynth.cursor.dirty = true;
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

    if (event.button == 3 and event.down) {
        if (self.zsynth.displayCellAtWindowPosition(.{ event.x, event.y })) |cell| {
            const world = self.space.worldPositionAtDisplayCell(cell[0], cell[1]);
            if (self.space.outletAt(world)) |outlet|
                try self.disconnectOutlet(gpa, outlet);
        }
        return true;
    }

    if (event.button == 1) {
        self.zsynth.cursor.left_mouse_down = event.down;
        self.zsynth.cursor.left_mouse_moved = false;

        if (event.down) {
            const cell = self.zsynth.displayCellAtWindowPosition(.{ event.x, event.y });
            if (cell) |display_cell| {
                const world = self.space.worldPositionAtDisplayCell(display_cell[0], display_cell[1]);
                if (self.space.outletAt(world)) |outlet| {
                    self.zsynth.cursor.left_mouse_down = false;
                    _ = self.space.revealNode(outlet.node);
                    self.zsynth.cursor.dirty = true;
                    const connection_position = self.space.worldPositionAtDisplayCell(
                        display_cell[0],
                        display_cell[1],
                    );
                    try self.beginOutletConnection(
                        state_stack,
                        gpa,
                        outlet,
                        connection_position,
                    );
                    return true;
                }
            }

            self.setNodeSelection(if (cell) |display_cell|
                self.space.nodeAtDisplayCell(display_cell[0], display_cell[1])
            else
                null);
            self.zsynth.cursor.dirty = true;

            if (cell) |display_cell| if (self.space.selected_node) |node| {
                if (!node.isNoop()) {
                    _ = self.space.revealNode(node);
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

/// Enter the temporary state used while connecting an outlet to another outlet.
fn beginOutletConnection(
    self: *Self,
    state_stack: *StateStack,
    gpa: std.mem.Allocator,
    outlet: Space.Outlet,
    mouse_position: Space.Position,
) !void {
    self.setNodeSelection(outlet.node);
    _ = try state_stack.push(gpa, .{
        .context = .{ .outlet_connection = .{
            .editor = self,
            .outlet = outlet,
            .mouse_position = mouse_position,
        } },
        .vtable = &OutletConnection.vtable,
    });
}

/// Connect two outlets after normalizing their input and output roles.
fn connectOutlets(
    self: *Self,
    gpa: std.mem.Allocator,
    first: Space.Outlet,
    second: Space.Outlet,
) !void {
    if (first.node.idx == second.node.idx or first.direction == second.direction)
        return;

    const output = if (first.direction == .output) first else second;
    const input = if (first.direction == .input) first else second;

    // An output can feed only one input, so replace its existing connection.
    self.dsp.disconnectOutput(output.node, output.port);
    self.dsp.plug(output.node, output.port, input.node, input.port);
    try self.space.computePaths(gpa);
    try self.write(gpa);
}

/// Remove the connection attached to an outlet.
fn disconnectOutlet(self: *Self, gpa: std.mem.Allocator, outlet: Space.Outlet) !void {
    switch (outlet.direction) {
        .input => self.dsp.disconnectInput(outlet.node, outlet.port),
        .output => self.dsp.disconnectOutput(outlet.node, outlet.port),
    }
    try self.space.computePaths(gpa);
    try self.write(gpa);
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
    // Draw selected-node parameters in the editor-owned transparent overlay.
    try self.writeSelectedParametersPane(gpa);
    // Draw outlet labels before the runtime adds the generic cursor glyph.
    if (self.zsynth.cursor.visible and self.zsynth.ui_display.impl == .graphic) {
        if (self.zsynth.displayCellAtWindowPosition(self.zsynth.cursor.position)) |cell| {
            try self.space.writeUiOverlay(gpa, &self.zsynth.ui_display, cell[0], cell[1]);
        }
    }
    // Submit the graphic display only when that display backend is active.
    if (self.zsynth.display.impl == .graphic)
        try self.zsynth.display.impl.graphic.render(gpa, renderer, dt, true);
}

/// Removes a DSP node and its synchronized visual representation.
fn remove(self: *Self, gpa: std.mem.Allocator, node: VisualNode.Index) !void {
    self.dsp.remove(gpa, node);
    try self.space.remove(gpa, node);
    self.setNodeSelection(self.space.selected_node);
    self.zsynth.cursor.dirty = true;
    try self.write(gpa);
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
    assert(node.idx == self.space.nodes.len);
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
            assert(self.space.occupied.get(occupied) == null);
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

/// Overlay state used to connect one DSP outlet to another.
pub const OutletConnection = struct {
    editor: *Self,
    outlet: Space.Outlet,
    mouse_position: Space.Position,
    preview_path: ?Space.Path = null,

    pub const vtable = StateStack.State.VTable{
        .enter = OutletConnection.enter,
        .leave = OutletConnection.leave,
        .quit = OutletConnection.quit,
        .render = OutletConnection.render,
        .keyUpDown = OutletConnection.keyUpDown,
        .mouseMoved = OutletConnection.mouseMoved,
        .mouseButton = OutletConnection.mouseButton,
    };

    fn enter(
        state_stack: *StateStack,
        gpa: std.mem.Allocator,
        state: StateStack.State.Index,
    ) anyerror!void {
        const context = stateContext(state_stack, state);
        try context.updatePreview(gpa);
    }

    fn leave(
        state_stack: *StateStack,
        gpa: std.mem.Allocator,
        _: *Renderer,
        state: StateStack.State.Index,
    ) anyerror!void {
        stateContext(state_stack, state).clearPreview(gpa);
    }

    fn quit(
        state_stack: *StateStack,
        gpa: std.mem.Allocator,
        _: *Renderer,
        state: StateStack.State.Index,
    ) anyerror!void {
        stateContext(state_stack, state).clearPreview(gpa);
    }

    fn render(
        state_stack: *StateStack,
        gpa: std.mem.Allocator,
        state: StateStack.State.Index,
        _: *Renderer,
        _: u64,
    ) anyerror!void {
        // The editor rendered the base display first; this state only overlays the preview.
        const context = stateContext(state_stack, state);
        if (context.preview_path) |path|
            try context.editor.space.writePreviewPath(
                gpa,
                &context.editor.zsynth.display,
                path,
            );
    }

    fn keyUpDown(
        state_stack: *StateStack,
        gpa: std.mem.Allocator,
        state: StateStack.State.Index,
        event: sdl.KeyboardEvent,
    ) anyerror!bool {
        if (!event.down) return true;
        if (event.key == .escape) {
            const context = stateContext(state_stack, state);
            try state_stack.pop(gpa, &context.editor.zsynth.renderer);
        } else if (event.key == .d) {
            const context = stateContext(state_stack, state);
            try context.editor.disconnectOutlet(gpa, context.outlet);
            try state_stack.pop(gpa, &context.editor.zsynth.renderer);
        }
        return true;
    }

    fn mouseMoved(
        state_stack: *StateStack,
        gpa: std.mem.Allocator,
        state: StateStack.State.Index,
        event: sdl.MouseMotionEvent,
    ) anyerror!bool {
        const context = stateContext(state_stack, state);
        if (context.editor.zsynth.displayCellAtWindowPosition(.{ event.x, event.y })) |cell| {
            context.mouse_position = context.editor.space.worldPositionAtDisplayCell(cell[0], cell[1]);
            try context.updatePreview(gpa);
        }
        return true;
    }

    fn mouseButton(
        state_stack: *StateStack,
        gpa: std.mem.Allocator,
        state: StateStack.State.Index,
        event: sdl.MouseButtonEvent,
    ) anyerror!bool {
        const context = stateContext(state_stack, state);
        const cell = context.editor.zsynth.displayCellAtWindowPosition(.{ event.x, event.y });
        const clicked = if (cell) |display_cell|
            context.editor.space.outletAt(
                context.editor.space.worldPositionAtDisplayCell(display_cell[0], display_cell[1]),
            )
        else
            null;

        if (event.button == 3 and event.down) {
            try state_stack.pop(gpa, &context.editor.zsynth.renderer);
            return true;
        }

        if (event.button != 1 or !event.down) return true;
        const target = clicked orelse return true;
        if (target.node.idx == context.outlet.node.idx or
            target.direction == context.outlet.direction)
            return true;

        try context.editor.connectOutlets(gpa, context.outlet, target);
        try state_stack.pop(gpa, &context.editor.zsynth.renderer);
        return true;
    }

    fn stateContext(state_stack: *StateStack, state: StateStack.State.Index) *OutletConnection {
        return &state_stack.stack.items(.context)[state.idx].outlet_connection;
    }

    fn updatePreview(self: *OutletConnection, gpa: std.mem.Allocator) !void {
        self.clearPreview(gpa);
        const mouse_target = if (self.editor.space.outletAt(self.mouse_position)) |outlet|
            outlet.anchor
        else
            self.mouse_position;
        const from = if (self.outlet.direction == .output)
            self.outlet.anchor
        else
            mouse_target;
        const to = if (self.outlet.direction == .output)
            mouse_target
        else
            self.outlet.anchor;
        if (try self.editor.space.previewPath(gpa, from, to)) |path| {
            var colored_path = path;
            colored_path.color = if (self.outlet.direction == .output)
                self.editor.space.nodeColor(self.outlet.node)
            else
                Display.Color.curious_blue;
            self.preview_path = colored_path;
        }
    }

    fn clearPreview(self: *OutletConnection, gpa: std.mem.Allocator) void {
        if (self.preview_path) |path| {
            Space.deinitPath(path, gpa);
            self.preview_path = null;
        }
    }
};

/// Main-thread output meter reading one node's per-node SampleTap.
pub const OutputMeter = struct {
    /// Duration of samples accumulated before publishing a new meter value.
    const observe_duration_ms = 300;
    /// Duration for which a clipping indicator remains visible.
    const clipping_hold_ms: u64 = 1000;
    /// Number of stereo frames in one meter observation window.
    const observe_frame_count = (observe_duration_ms * DSP.sample_rate) / 1000;
    /// Number of interleaved samples in one meter observation window.
    const observe_sample_count = observe_frame_count * 2;

    /// Queue type used by the node's SampleTap.
    const Queue = DSP.SampleTap.Queue;

    /// Direction in which a meter grows from its empty end to its full end.
    pub const Direction = enum {
        /// Horizontal meter filling from right to left.
        left,
        /// Horizontal meter filling from left to right.
        right,
        /// Vertical meter filling from bottom to top.
        up,
        /// Vertical meter filling from top to bottom.
        down,
    };

    /// User-configurable source and geometry for an output meter.
    pub const Parameters = struct {
        /// Direction in which each meter fills.
        direction: Direction = .right,
        /// Node whose rendered outputs are analyzed; valid only when selected.
        node: DSP.Node.Index = undefined,
        /// Number of cells used by each meter itself.
        meter_cell_count: u32 = 10,
    };

    /// Source and geometry settings for this meter.
    parameters: Parameters = .{},
    /// Number of declared outputs shown by the meter.
    output_count: u8 = 0,
    /// Short names displayed beneath the output meter groups.
    output_short_names: [DSP.max_outlets][]const u8 = @splat(""),
    /// Total width of all output groups and their single-cell separators.
    width: u32 = 0,
    /// Height required by one output group including its labels.
    height: u32 = 0,
    /// Independent reader cursor for the node's SampleTap history.
    reader: ?Queue.Reader = null,
    /// Number of interleaved samples accumulated in the current window.
    sample_cursor: usize = 0,
    /// Running squared sums indexed by output port and stereo channel.
    sum_squared: [DSP.max_outlets][2]f32 = @splat(.{ 0, 0 }),
    /// Running absolute peaks indexed by output port and stereo channel.
    peak: [DSP.max_outlets][2]f32 = @splat(.{ 0, 0 }),
    /// Peak-hold amplitudes indexed by output port and stereo channel.
    peak_hold: [DSP.max_outlets][2]f32 = @splat(.{ 0, 0 }),
    /// RMS level in dBFS indexed by output port and stereo channel.
    rms_dbfs: [DSP.max_outlets][2]f32 = @splat(.{ -120, -120 }),
    /// Peak level in dBFS indexed by output port and stereo channel.
    peak_dbfs: [DSP.max_outlets][2]f32 = @splat(.{ -120, -120 }),
    /// Remaining clipping-indicator time in milliseconds per output/channel.
    clipping_remaining_ms: [DSP.max_outlets][2]u64 = @splat(.{ 0, 0 }),

    /// Resets every measured value while preserving the meter source and layout.
    pub fn reset(self: *OutputMeter) void {
        // Clearing the reader makes the next update begin at the queue's
        // current tail, so samples rendered before the pause are discarded.
        self.reader = null;
        self.sample_cursor = 0;
        self.sum_squared = @splat(.{ 0, 0 });
        self.peak = @splat(.{ 0, 0 });
        self.peak_hold = @splat(.{ 0, 0 });
        self.rms_dbfs = @splat(.{ -120, -120 });
        self.peak_dbfs = @splat(.{ -120, -120 });
        self.clipping_remaining_ms = @splat(.{ 0, 0 });
    }

    /// Draws all output meter groups and their metadata labels.
    pub fn write(
        self: *const OutputMeter,
        gpa: std.mem.Allocator,
        display: *Display,
        position: [2]u32,
    ) !void {
        if (display.impl != .graphic or self.output_count == 0)
            return;

        const graphic = &display.impl.graphic;
        assert(self.parameters.meter_cell_count > 0);
        if (position[1] >= graphic.height or
            self.height > graphic.height - position[1])
            return;

        const horizontal = switch (self.parameters.direction) {
            .left, .right => true,
            .up, .down => false,
        };
        const grows_forward = switch (self.parameters.direction) {
            .right, .down => true,
            .left, .up => false,
        };
        const meter_cell_count = self.parameters.meter_cell_count;
        const meter_count: usize = @intCast(self.output_count);
        var group_x = position[0];

        for (0..meter_count) |output_port| {
            const short_name = self.output_short_names[output_port];
            const meter_group_width = if (horizontal) meter_cell_count + 1 else 2;
            const group_width = if (horizontal)
                @max(meter_group_width, @as(u32, @intCast(short_name.len)))
            else
                @max(2, @as(u32, @intCast(short_name.len)));
            const meter_x = group_x + (group_width - meter_group_width) / 2;
            const label_x = group_x +
                (group_width - @as(u32, @intCast(short_name.len))) / 2;
            const label_y = if (horizontal)
                position[1] + 2
            else
                position[1] + meter_cell_count + 1;

            try display.write(gpa, short_name, label_x, label_y, .ebony, .logan);

            const meter_cell_count_f32: f32 = @floatFromInt(meter_cell_count);
            for (0..2) |channel| {
                const rms_fraction = std.math.clamp(
                    (self.rms_dbfs[output_port][channel] + 60) / 60,
                    0,
                    1,
                );
                const peak_fraction = std.math.clamp(
                    (self.peak_dbfs[output_port][channel] + 60) / 60,
                    0,
                    1,
                );
                const rms_cells: u32 = @intFromFloat(@ceil(rms_fraction * meter_cell_count_f32));
                const peak_cells: u32 = @intFromFloat(@ceil(peak_fraction * meter_cell_count_f32));
                const channel_label = if (channel == 0) "L" else "R";
                const channel_x = if (horizontal)
                    meter_x
                else
                    meter_x + @as(u32, @intCast(channel));
                const channel_y = if (horizontal)
                    position[1] + @as(u32, @intCast(channel))
                else
                    position[1] + meter_cell_count;

                try display.write(
                    gpa,
                    channel_label,
                    channel_x,
                    channel_y,
                    .ebony,
                    .logan,
                );

                for (0..meter_cell_count) |cell| {
                    const cell_index: u32 = @intCast(cell);
                    const level_cell = if (grows_forward)
                        cell_index
                    else
                        meter_cell_count - 1 - cell_index;
                    var color = Display.Color.logan;

                    if (level_cell < rms_cells) {
                        const gradient = if (meter_cell_count == 1)
                            0
                        else
                            @as(f32, @floatFromInt(level_cell)) /
                                @as(f32, @floatFromInt(meter_cell_count - 1));
                        color = Display.Color.apple.interpolate(.punch, gradient);
                    }

                    const has_distinct_peak =
                        self.peak_dbfs[output_port][channel] > self.rms_dbfs[output_port][channel];
                    const peak_cell = if (grows_forward)
                        peak_cells -| 1
                    else
                        meter_cell_count - peak_cells;
                    if (has_distinct_peak and peak_cells > 0 and cell_index == peak_cell) {
                        color = .curious_blue;
                    }

                    if (self.clipping_remaining_ms[output_port][channel] > 0 and
                        peak_cells > 0 and cell_index == peak_cell)
                        color = .punch;

                    const glyph = [_]u8{0x07};
                    const cell_x = if (horizontal)
                        meter_x + 1 + cell_index
                    else
                        channel_x;
                    const cell_y = if (horizontal)
                        position[1] + @as(u32, @intCast(channel))
                    else
                        position[1] + cell_index;
                    try display.write(
                        gpa,
                        glyph[0..],
                        cell_x,
                        cell_y,
                        .ebony,
                        color,
                    );
                }
            }

            group_x += group_width;
            if (output_port + 1 < meter_count)
                group_x += 1;
        }
    }

    /// Drains the selected node's SampleTap and updates meter observations.
    pub fn update(self: *OutputMeter, dsp: *DSP, elapsed_ms: u64) void {
        for (&self.clipping_remaining_ms) |*channels| {
            for (channels) |*remaining|
                remaining.* = remaining.* -| elapsed_ms;
        }
        const node = self.parameters.node;
        const sample_tap = dsp.sampleTap(node) orelse return;
        if (self.reader == null)
            self.reader = sample_tap.queue.reader();
        const reader = &self.reader.?;

        while (sample_tap.queue.front(reader)) |block| {
            defer sample_tap.queue.pop(reader);

            assert(block.sample_count <= DSP.block_size * 2);
            assert(block.output_count <= DSP.max_outlets);
            var incoming_cursor: usize = 0;
            const output_count: usize = @intCast(block.output_count);

            while (incoming_cursor < block.sample_count) {
                const available = observe_sample_count - self.sample_cursor;
                const copy_count = @min(available, block.sample_count - incoming_cursor);
                const segment_end = incoming_cursor + copy_count;
                var sample_index = incoming_cursor;

                // Analyze complete SIMD vectors while preserving separate
                // reductions for the interleaved left and right channels.
                if (std.simd.suggestVectorLength(f32)) |lanes| {
                    const V = @Vector(lanes, f32);
                    const BoolV = @Vector(lanes, bool);
                    var even_mask: BoolV = undefined;
                    var odd_mask: BoolV = undefined;
                    inline for (0..lanes) |lane| {
                        even_mask[lane] = lane % 2 == 0;
                        odd_mask[lane] = lane % 2 != 0;
                    }

                    while (sample_index + lanes <= segment_end) : (sample_index += lanes) {
                        const left_mask = if (sample_index % 2 == 0) even_mask else odd_mask;
                        const right_mask = if (sample_index % 2 == 0) odd_mask else even_mask;
                        const zero: V = @splat(0);

                        for (0..output_count) |output_port| {
                            const values: V = @bitCast(
                                block.samples[output_port][sample_index..][0..lanes].*,
                            );
                            const absolute = @abs(values);
                            const squared = values * values;
                            const left_squared = @select(f32, left_mask, squared, zero);
                            const right_squared = @select(f32, right_mask, squared, zero);
                            const left_absolute = @select(f32, left_mask, absolute, zero);
                            const right_absolute = @select(f32, right_mask, absolute, zero);
                            const left_peak = @reduce(.Max, left_absolute);
                            const right_peak = @reduce(.Max, right_absolute);

                            self.sum_squared[output_port][0] += @reduce(.Add, left_squared);
                            self.sum_squared[output_port][1] += @reduce(.Add, right_squared);
                            self.peak[output_port][0] = @max(
                                self.peak[output_port][0],
                                left_peak,
                            );
                            self.peak[output_port][1] = @max(
                                self.peak[output_port][1],
                                right_peak,
                            );
                            if (left_peak > self.peak_hold[output_port][0]) {
                                self.peak_hold[output_port][0] = left_peak;
                            }
                            if (right_peak > self.peak_hold[output_port][1]) {
                                self.peak_hold[output_port][1] = right_peak;
                            }
                            if (left_peak >= 1)
                                self.clipping_remaining_ms[output_port][0] = clipping_hold_ms;
                            if (right_peak >= 1)
                                self.clipping_remaining_ms[output_port][1] = clipping_hold_ms;
                        }
                    }
                }

                // Analyze the non-vector tail, if any.
                while (sample_index < segment_end) : (sample_index += 1) {
                    const channel = sample_index % 2;
                    for (0..output_count) |output_port| {
                        const sample = block.samples[output_port][sample_index];
                        const absolute = @abs(sample);
                        self.sum_squared[output_port][channel] += sample * sample;
                        self.peak[output_port][channel] = @max(
                            self.peak[output_port][channel],
                            absolute,
                        );
                        if (absolute > self.peak_hold[output_port][channel]) {
                            self.peak_hold[output_port][channel] = absolute;
                        }
                        if (absolute >= 1)
                            self.clipping_remaining_ms[output_port][channel] = clipping_hold_ms;
                    }
                }

                self.sample_cursor += copy_count;
                incoming_cursor += copy_count;

                if (self.sample_cursor == observe_sample_count) {
                    const frame_count: f32 = @floatFromInt(observe_frame_count);
                    for (0..output_count) |output_port| {
                        for (0..2) |channel| {
                            const rms = @sqrt(self.sum_squared[output_port][channel] / frame_count);
                            self.rms_dbfs[output_port][channel] = dbfs(rms);
                            self.peak_dbfs[output_port][channel] = dbfs(
                                self.peak_hold[output_port][channel],
                            );
                        }
                    }
                    self.sum_squared = @splat(.{ 0, 0 });
                    self.peak = @splat(.{ 0, 0 });
                    self.sample_cursor = 0;
                }
            }
        }
    }
};

/// Converts a linear amplitude into decibels relative to full scale.
fn dbfs(value: f32) f32 {
    const floor: f32 = 0.000001; // -120 dBFS
    return 20 * std.math.log10(@max(value, floor));
}
