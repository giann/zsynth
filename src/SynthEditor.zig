//! The synth editor state and its demonstration DSP graph.
const std = @import("std");
const assert = std.debug.assert;
const sdl = @import("zsdl3");
const DSP = @import("DSP.zig");
const StateStack = @import("StateStack.zig");
const ZSynth = @import("ZSynth.zig");
const Renderer = @import("Renderer.zig");
const Space = @import("Space.zig");
const Serializer = @import("Serializer.zig");
const Display = @import("Display.zig");
const VisualNode = Space.VisualNode;

const Self = @This();

/// Synthetic selected-pane field name used for editing a node's display name.
const node_name_field_name = "name";

/// Owns all state and reflection descriptors for selected-pane property edits.
const ParameterEditor = struct {
    /// Reusable field used to edit the active property value.
    text_field: TextField(*Self) = undefined,
    /// Selected-pane property receiving keyboard and text input, if any.
    active: ?ActiveParameter = null,
    /// Parameter cells generated during the last selected-pane render.
    cells: [32]ParameterCell = undefined,
    /// Number of valid entries in `cells`.
    cell_count: usize = 0,

    /// Coordinates and editability information for one selected-pane parameter.
    const ParameterCell = struct {
        /// Reflected parameter field name used for editing.
        field_name: []const u8,
        /// Fixed-array element index, or null for a scalar field.
        array_index: ?usize,
        /// Horizontal position of the rendered value.
        value_x: u32,
        /// Vertical position of the rendered row.
        value_y: u32,
        /// Number of display cells reserved for the value.
        value_width: u32,
        /// Whether this field has scalar or enum editing support.
        editable: bool,
    };

    /// Identifies the parameter currently being edited.
    const ActiveParameter = struct {
        /// Node containing the parameter.
        node: DSP.Node.Index,
        /// Reflected field name within the node parameter struct.
        field_name: []const u8,
        /// Fixed-array element index, or null for a scalar field.
        array_index: ?usize,
    };

    /// Context passed while committing a parameter under the graph lock.
    const CommitContext = struct {
        /// Editor owning the selected node and text field.
        editor: *Self,
        /// Whether the entered value was parsed and assigned successfully.
        accepted: bool = false,
    };
};

/// Number of parameter rows available after applying the pane padding.
const parameters_pane_padding: u32 = 1;
/// Maximum number of parameter rows packed into one selected-pane column.
const parameters_pane_max_rows: u32 = 5;

/// Runtime owning the display, renderer, and audio engine used by this state.
zsynth: *ZSynth,
/// DSP graph constructed when the editor enters the state stack.
dsp: DSP,
space: Space,
/// Protobuf serializer bound to the live graph and its visual layout.
serializer: Serializer,
/// Allocated path of the graph most recently saved or loaded.
document_path: ?[]u8 = null,
/// Allocated names entered for nodes created through the command palette.
owned_node_names: std.ArrayList([]u8) = .empty,
/// Output meter bound to the currently selected DSP node.
output_meter: OutputMeter = .{},
/// State used to edit scalar and enum properties in the selected pane.
parameter_editor: ParameterEditor = .{},

/// State-stack callbacks used by the synth editor context.
pub const vtable = StateStack.State.VTable{
    .enter = enter,
    .leave = leave,
    .quit = quit,
    .update = update,
    .render = render,
    .keyUpDown = keyUpDown,
    .textInput = textInput,
    .mouseMoved = mouseMoved,
    .mouseButton = mouseButton,
};

/// Initializes the editor DSP graph and writes its initial display text.
fn enter(
    state_stack: *StateStack,
    gpa: std.mem.Allocator,
    state: StateStack.State.Index,
) StateStack.State.Error!void {
    // Resolve this state index to the concrete editor context.
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;
    try sdl.startTextInput(self.zsynth.renderer.window);
    // Initialize the DSP against the runtime-owned audio engine.
    self.dsp.init(self.zsynth.audio_engine, gpa) catch return error.AudioError;
    self.serializer = .{
        .dsp = &self.dsp,
        .space = &self.space,
        .allocator = gpa,
        .io = self.zsynth.io,
    };
    self.space.dsp = &self.dsp;
    try addVisualNode(self, gpa, DSP.Node.Index.noop, .{ .x = 0, .y = 0 });
    // Start with only the audio output at the center of the empty space.
    try self.newGraph(gpa);
    // Show the editor status after audio is running.
    try self.write(gpa);
}

/// Replaces the current graph with a fresh no-op and output node.
fn newGraph(self: *Self, gpa: std.mem.Allocator) !void {
    self.parameter_editor.active = null;
    self.parameter_editor.cell_count = 0;
    self.output_meter = .{};

    self.dsp.reset(gpa);
    self.space.reset(gpa);
    self.serializer.clearOwned();
    if (self.document_path) |path| {
        gpa.free(path);
        self.document_path = null;
    }
    for (self.owned_node_names.items) |name|
        gpa.free(name);
    self.owned_node_names.clearRetainingCapacity();

    // DSP.reset() retains the runtime sentinel at index zero.
    try self.space.addNode(gpa, DSP.Node.Index.noop, .{ .x = 0, .y = 0 });
    const output = try addNode(
        self,
        gpa,
        DSP.Node.Output.create("output"),
        self.space.viewportCenter(),
    );
    self.dsp.output = output;
    if (!try self.space.rebuildOccupancy(gpa))
        return error.InvalidVisualNodeLayout;
    try self.space.computePaths(gpa);
    self.zsynth.cursor.dirty = true;
    try self.write(gpa);
}

/// Releases editor resources when the state is temporarily popped.
fn leave(
    state_stack: *StateStack,
    gpa: std.mem.Allocator,
    _: *Renderer,
    state: StateStack.State.Index,
) StateStack.State.Error!void {
    // Resolve the concrete editor context before releasing its DSP graph.
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;
    sdl.stopTextInput(self.zsynth.renderer.window) catch {};
    self.deinit(gpa);
}

/// Releases editor resources when the application is shutting down.
fn quit(
    state_stack: *StateStack,
    gpa: std.mem.Allocator,
    _: *Renderer,
    state: StateStack.State.Index,
) StateStack.State.Error!void {
    // Resolve the concrete editor context before releasing its DSP graph.
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;
    sdl.stopTextInput(self.zsynth.renderer.window) catch {};
    self.deinit(gpa);
}

/// Stops and deinitializes the DSP graph exactly once.
fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    self.serializer.deinit();
    self.dsp.deinit(gpa);
    self.space.deinit(gpa);
    if (self.document_path) |path|
        gpa.free(path);
    for (self.owned_node_names.items) |name|
        gpa.free(name);
    self.owned_node_names.deinit(gpa);
}

/// Updates the selected node's output meter from the main thread.
fn update(
    state_stack: *StateStack,
    _: std.mem.Allocator,
    state: StateStack.State.Index,
    dt: u64,
) StateStack.State.Error!void {
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;
    const selected_node = self.space.singleSelectedNode() orelse return;
    if (self.output_meter.output_count == 0) return;
    assert(self.output_meter.parameters.node.idx == selected_node.idx);
    self.output_meter.update(&self.dsp, dt);
}

/// Rebuilds the parameter editor and output meter for the current selection.
fn refreshSelectionUi(self: *Self) void {
    self.parameter_editor.active = null;
    self.parameter_editor.cell_count = 0;

    const previous_parameters = self.output_meter.parameters;
    self.output_meter = .{
        .parameters = .{
            .direction = previous_parameters.direction,
            .node = undefined,
            .meter_cell_count = previous_parameters.meter_cell_count,
        },
    };

    const selected_node = self.space.singleSelectedNode() orelse return;
    if (selected_node.idx >= self.dsp.nodes.len) return;

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
    self.output_meter.height = if (horizontal) 3 else self.output_meter.parameters.meter_cell_count + 2;

    for (metadata.outputs[0..metadata.output_count], 0..) |output, output_port| {
        self.output_meter.output_short_names[output_port] = output.short_name;
        const group_width = if (horizontal)
            @max(
                self.output_meter.parameters.meter_cell_count + 1,
                @as(u32, @intCast(output.short_name.len)),
            )
        else
            @max(2, @as(u32, @intCast(output.short_name.len)));
        self.output_meter.width += @max(group_width, @as(u32, @intCast(output.short_name.len)));
        if (output_port + 1 < metadata.output_count)
            self.output_meter.width += 1;
    }
}

/// Changes the single selection and resets the meter source to match it.
fn setNodeSelection(self: *Self, node: ?VisualNode.Index) void {
    const selected = if (node) |value| if (value.isNoop()) null else value else null;
    const previous_count = self.space.selected_count;
    const previous_single = self.space.singleSelectedNode();
    const selected_idx = if (selected) |current| current.idx else null;
    const changed = previous_count != 1 or
        (if (previous_single) |previous| previous.idx else null) != selected_idx;

    if (changed) {
        for (self.space.selected_nodes[0..self.space.selected_count]) |previous| {
            if (previous.idx < self.dsp.nodes.len and
                std.meta.activeTag(self.dsp.nodes.items(.state)[previous.idx]) == .keyboard)
                self.dsp.keyboardReleaseAll(.{ .idx = previous.idx });
        }
    }

    self.space.selectSingle(selected);
    if (changed) self.refreshSelectionUi();
}

/// Redraws the editor's status text in the runtime-owned display.
fn write(self: *Self, gpa: std.mem.Allocator) !void {
    self.zsynth.display.reset();
    try self.space.write(gpa, &self.zsynth.display);
    if (self.zsynth.cursor.selection_dragging)
        try self.space.writeSelectionMarquee(
            gpa,
            &self.zsynth.display,
            .{
                .x = self.zsynth.cursor.selection_anchor[0],
                .y = self.zsynth.cursor.selection_anchor[1],
            },
            .{
                .x = self.zsynth.cursor.drag_position[0],
                .y = self.zsynth.cursor.drag_position[1],
            },
        );
}

/// Remembers a successfully saved or loaded graph path for the UI title.
fn rememberDocumentPath(self: *Self, gpa: std.mem.Allocator, path: []const u8) !void {
    const owned = try gpa.dupe(u8, path);
    if (self.document_path) |previous|
        gpa.free(previous);
    self.document_path = owned;
    self.zsynth.cursor.dirty = true;
}

/// Saves the graph and updates the remembered document path after success.
fn saveDocument(self: *Self, gpa: std.mem.Allocator, path: []const u8) !void {
    try self.serializer.save(path);
    try self.rememberDocumentPath(gpa, path);
}

/// Loads the graph and updates the remembered document path after success.
fn loadDocument(self: *Self, gpa: std.mem.Allocator, path: []const u8) !void {
    try self.serializer.load(path);
    try self.rememberDocumentPath(gpa, path);
}

/// Returns the final filename without its path or final extension.
fn documentName(path: []const u8) []const u8 {
    var name_start: usize = 0;
    for (path, 0..) |character, index| {
        if (character == std.fs.path.sep)
            name_start = index + 1;
    }

    const name = path[name_start..];
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |extension_start|
        if (extension_start > 0)
            return name[0..extension_start];
    return name;
}

/// Draws the remembered document filename at the top-left of the UI overlay.
fn writeDocumentName(self: *Self, gpa: std.mem.Allocator) !void {
    const path = self.document_path orelse return;

    var name_start: usize = 0;
    for (path, 0..) |character, index| {
        if (character == '/' or character == '\\')
            name_start = index + 1;
    }

    const name = path[name_start..];
    const displayed_name = if (std.mem.lastIndexOfScalar(u8, name, '.')) |extension_start|
        if (extension_start > 0)
            name[0..extension_start]
        else
            name
    else
        name;

    try self.zsynth.ui_display.write(
        gpa,
        displayed_name,
        0,
        0,
        .black,
        .astral,
    );
}

/// Draws the selected node's reflected parameters in the bottom UI pane.
fn writeSelectedParametersPane(self: *Self, gpa: std.mem.Allocator) !void {
    self.parameter_editor.cell_count = 0;
    const display = &self.zsynth.ui_display;
    if (display.impl != .graphic) return;

    const graphic = &display.impl.graphic;
    const selected = self.space.singleSelectedNode() orelse return;
    if (selected.isNoop() or selected.idx >= self.dsp.nodes.len) return;

    if (graphic.height < 2 or graphic.width <= parameters_pane_padding * 2)
        return;

    const parameter_node = self.dsp.nodes.items(.parameter_link)[selected.idx].source orelse selected;
    const parameters_editable = self.dsp.nodes.items(.parameter_link)[selected.idx].source == null;
    const state = self.dsp.nodes.items(.state)[parameter_node.idx];
    switch (state) {
        inline else => |node_state| {
            if (@hasField(@TypeOf(node_state), "parameters")) {
                try self.writeReflectedParameters(
                    gpa,
                    display,
                    node_state.parameters,
                    self.dsp.nodes.items(.name)[selected.idx],
                    graphic.height,
                    graphic.width,
                    &self.output_meter,
                    parameters_editable,
                );
            } else {
                try self.writeReflectedParameters(
                    gpa,
                    display,
                    struct {}{},
                    self.dsp.nodes.items(.name)[selected.idx],
                    graphic.height,
                    graphic.width,
                    &self.output_meter,
                    parameters_editable,
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

/// Returns whether a reflected field can be edited by the selected-pane UI.
fn isEditableParameterType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => true,
        else => false,
    };
}

/// Counts the selected-pane cells produced by a reflected parameter struct.
fn reflectedParameterItemCount(comptime Parameters: type) usize {
    const field_names = @typeInfo(Parameters).@"struct".field_names;
    var count: usize = 1;
    inline for (field_names) |field_name| {
        const field_type = @TypeOf(@field(@as(Parameters, undefined), field_name));
        count += switch (@typeInfo(field_type)) {
            .array => |array| array.len,
            else => 1,
        };
    }
    return count;
}

/// Returns whether two selected-pane parameter references identify the same value.
fn sameParameter(
    left_field_name: []const u8,
    left_array_index: ?usize,
    right_field_name: []const u8,
    right_array_index: ?usize,
) bool {
    return std.mem.eql(u8, left_field_name, right_field_name) and
        std.meta.eql(left_array_index, right_array_index);
}

/// Reserves enough cells for an enum's longest tag or the formatted scalar.
fn parameterValueWidth(comptime T: type, formatted_len: usize) u32 {
    switch (@typeInfo(T)) {
        .@"enum" => {
            var width: usize = 0;
            inline for (std.meta.tags(T)) |tag|
                width = @max(width, @tagName(tag).len);
            return @intCast(width);
        },
        else => return @intCast(formatted_len),
    }
}

/// Writes reflected parameter fields in padded, row-limited columns.
fn writeReflectedParameters(
    self: *Self,
    gpa: std.mem.Allocator,
    display: *Display,
    parameters: anytype,
    node_name: []const u8,
    display_height: u32,
    display_width: u32,
    output_meter: *const OutputMeter,
    parameters_editable: bool,
) !void {
    const field_names = @typeInfo(@TypeOf(parameters)).@"struct".field_names;
    const item_count = comptime reflectedParameterItemCount(@TypeOf(parameters));
    var items: [item_count]Display.LabelValue = undefined;
    var value_buffers: [item_count][64]u8 = undefined;
    var value_widths: [item_count]u32 = undefined;
    var editable: [item_count]bool = undefined;
    var cell_names: [item_count][]const u8 = undefined;
    var cell_array_indices: [item_count]?usize = undefined;
    var label_buffers: [item_count][64]u8 = undefined;

    cell_names[0] = node_name_field_name;
    items[0] = .{
        .label = node_name_field_name,
        .value = node_name,
        .value_color = .white,
    };
    value_widths[0] = @intCast(@max(node_name.len, 1));
    editable[0] = true;
    cell_array_indices[0] = null;

    var reflected_item_index: usize = 1;
    inline for (field_names) |field_name| {
        const value = @field(parameters, field_name);
        switch (@typeInfo(@TypeOf(value))) {
            .array => |array| {
                inline for (0..array.len) |array_index| {
                    const element = value[array_index];
                    const formatted_value = formatParameterValue(
                        &value_buffers[reflected_item_index],
                        element,
                    );
                    const label = std.fmt.bufPrint(
                        &label_buffers[reflected_item_index],
                        "{s} #{d}",
                        .{ field_name, array_index + 1 },
                    ) catch field_name;
                    const value_color: Display.Color = switch (@typeInfo(@TypeOf(element))) {
                        .int, .float => .golden_rod,
                        .@"enum" => .science_blue,
                        else => .white,
                    };
                    items[reflected_item_index] = .{
                        .label = label,
                        .value = formatted_value,
                        .value_color = value_color,
                    };
                    value_widths[reflected_item_index] = parameterValueWidth(
                        @TypeOf(element),
                        formatted_value.len,
                    );
                    editable[reflected_item_index] = parameters_editable and
                        isEditableParameterType(@TypeOf(element));
                    cell_names[reflected_item_index] = field_name;
                    cell_array_indices[reflected_item_index] = array_index;
                    reflected_item_index += 1;
                }
            },
            else => {
                const formatted_value = formatParameterValue(
                    &value_buffers[reflected_item_index],
                    value,
                );
                const value_color: Display.Color = switch (@typeInfo(@TypeOf(value))) {
                    .int, .float => .golden_rod,
                    .@"enum" => .science_blue,
                    else => .white,
                };
                items[reflected_item_index] = .{
                    .label = field_name,
                    .value = formatted_value,
                    .value_color = value_color,
                };
                value_widths[reflected_item_index] = parameterValueWidth(
                    @TypeOf(value),
                    formatted_value.len,
                );
                editable[reflected_item_index] = parameters_editable and
                    isEditableParameterType(@TypeOf(value));
                cell_names[reflected_item_index] = field_name;
                cell_array_indices[reflected_item_index] = null;
                reflected_item_index += 1;
            },
        }
    }

    const pane_height = @min(
        display_height,
        @max(
            parameters_pane_max_rows + 2,
            output_meter.height + 2,
        ),
    );
    if (pane_height < 2) return;
    const row_count = @min(
        @as(u32, @intCast(items.len)),
        parameters_pane_max_rows,
    );
    const rows = @min(row_count, pane_height - 2);
    // Match the selected-pane column packing while retaining each value's
    // coordinates for mouse hit-testing and the active text field.
    var content_width: u32 = 0;
    if (items.len != 0 and row_count != 0) {
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
                    label_width +
                        1 +
                        value_widths[index],
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

    var column_x = parameter_x;
    var item_index: usize = 0;
    while (item_index < items.len and column_x < pane_width) {
        const column_end = @min(item_index + @as(usize, @intCast(rows)), items.len);
        var label_width: u32 = 0;
        var column_width: u32 = 0;
        for (item_index..column_end) |index|
            label_width = @max(
                label_width,
                @as(u32, @intCast(Display.countStripped(items[index].label))),
            );
        for (item_index..column_end) |index|
            column_width = @max(column_width, label_width + 1 + value_widths[index]);

        for (item_index..column_end) |index| {
            const row = @as(u32, @intCast(index - item_index));
            const value_x = column_x + label_width + 1;
            const value_y = pane_top + parameters_pane_padding + row;
            const cell = ParameterEditor.ParameterCell{
                .field_name = cell_names[index],
                .array_index = cell_array_indices[index],
                .value_x = value_x,
                .value_y = value_y,
                .value_width = value_widths[index],
                .editable = editable[index],
            };
            if (self.parameter_editor.cell_count < self.parameter_editor.cells.len) {
                self.parameter_editor.cells[self.parameter_editor.cell_count] = cell;
                self.parameter_editor.cell_count += 1;
            }

            try display.write(
                gpa,
                items[index].label,
                column_x,
                value_y,
                .ebony,
                .apple,
            );
            try display.write(
                gpa,
                items[index].value,
                value_x,
                value_y,
                .ebony,
                items[index].value_color,
            );
        }

        item_index = column_end;
        column_x += column_width + 1;
    }

    if (self.parameter_editor.active) |active| {
        if (self.space.singleSelectedNode()) |selected| {
            if (active.node.idx == selected.idx) {
                for (self.parameter_editor.cells[0..self.parameter_editor.cell_count]) |cell| {
                    if (!cell.editable or !sameParameter(
                        cell.field_name,
                        cell.array_index,
                        active.field_name,
                        active.array_index,
                    ))
                        continue;
                    self.parameter_editor.text_field.parameters.width = if (pane_width > cell.value_x + 1)
                        pane_width - cell.value_x - 1
                    else
                        1;
                    try self.parameter_editor.text_field.write(gpa, display, cell.value_x, cell.value_y);
                    break;
                }
            }
        }
    }
}

/// Moves the viewport and redraws the complete visible space.
fn moveViewport(self: *Self, gpa: std.mem.Allocator, dx: i32, dy: i32) !void {
    if (dx == 0 and dy == 0) return;
    self.space.moveViewport(dx, dy);
    self.zsynth.cursor.dirty = true;
    try self.write(gpa);
}

/// Handles editor commands and arrow keys used to move the viewport.
fn keyUpDown(
    state_stack: *StateStack,
    gpa: std.mem.Allocator,
    state: StateStack.State.Index,
    event: sdl.KeyboardEvent,
) StateStack.State.Error!bool {
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;

    if (self.parameter_editor.active == null) {
        if (self.space.singleSelectedNode()) |selected| {
            if (selected.idx < self.dsp.nodes.len and
                std.meta.activeTag(self.dsp.nodes.items(.state)[selected.idx]) == .keyboard)
            {
                const modifiers = std.mem.bytesToValue(u16, std.mem.asBytes(&event.mod));
                const command_modifiers = sdl.Keymod.ctrl |
                    sdl.Keymod.lgui |
                    sdl.Keymod.rgui |
                    sdl.Keymod.alt;
                if ((modifiers & command_modifiers) == 0) {
                    const handled = if (event.down)
                        self.dsp.keyboardKeyDown(.{ .idx = selected.idx }, event.key)
                    else
                        self.dsp.keyboardKeyUp(.{ .idx = selected.idx }, event.key);
                    if (handled) {
                        return true;
                    }
                }
            }
        }
    }

    if (!event.down) return self.parameter_editor.active != null;

    if (self.parameter_editor.active != null) {
        switch (event.key) {
            .escape => {
                self.cancelParameterEdit();
                self.zsynth.cursor.dirty = true;
            },
            .@"return", .kp_enter => {
                self.commitParameterEdit();
                self.cancelParameterEdit();
                self.zsynth.cursor.dirty = true;
            },
            .up => {
                self.commitParameterEdit();
                self.moveParameterEdit(-1);
                self.zsynth.cursor.dirty = true;
            },
            .down => {
                self.commitParameterEdit();
                self.moveParameterEdit(1);
                self.zsynth.cursor.dirty = true;
            },
            else => {
                self.parameter_editor.text_field.textUpDown(event);
                self.zsynth.cursor.dirty = true;
            },
        }
        return true;
    }

    const modifiers = std.mem.bytesToValue(u16, std.mem.asBytes(&event.mod));
    const shift = (modifiers & sdl.Keymod.shift) != 0;
    const delta: i32 = if (shift) 5 else 1;

    const command = (modifiers & (sdl.Keymod.lgui | sdl.Keymod.rgui)) != 0;

    switch (event.key) {
        .p => if (command) {
            _ = try state_stack.push(
                gpa,
                .{
                    .context = .{
                        .command_palette = .{
                            .editor = self,
                        },
                    },
                    .vtable = &CommandPalette.vtable,
                },
            );
        },
        .s => if (command) {
            self.saveDocument(gpa, "./simpleDSP.zsynth") catch return error.IoError;
        } else return false,
        .l => if (command) {
            self.loadDocument(gpa, "./simpleDSP.zsynth") catch return error.IoError;
            self.setNodeSelection(null);
            self.output_meter = .{};
            self.zsynth.cursor.dirty = true;
            try self.write(gpa);
        } else return false,
        .n => if (command) try self.newGraph(gpa) else return false,
        .up => try self.moveViewport(gpa, 0, -delta),
        .down => try self.moveViewport(gpa, 0, delta),
        .left => try self.moveViewport(gpa, -delta, 0),
        .right => try self.moveViewport(gpa, delta, 0),
        .space => {
            const was_playing = self.dsp.isPlaying();
            self.dsp.toggle() catch return error.AudioError;
            if (was_playing and self.output_meter.output_count != 0) {
                self.output_meter.reset();
                try self.writeSelectedParametersPane(gpa);
            }
        },
        .@"return", .kp_enter => {
            if (self.beginFirstParameterEdit())
                self.zsynth.cursor.dirty = true
            else
                return false;
        },
        .d => {
            if (command) {
                try self.duplicateSelectedNodes(gpa, shift);
            } else if (self.space.selected_count != 0) {
                try self.removeSelectedNodes(gpa);
            } else return false;
        },
        .escape => {
            self.setNodeSelection(null);
            self.zsynth.cursor.dirty = true;
            try self.write(gpa);
        },
        else => return false,
    }

    return true;
}

/// Duplicates the complete current selection using one shared group offset.
fn duplicateSelectedNodes(self: *Self, gpa: std.mem.Allocator, link_parameters: bool) !void {
    if (self.space.selected_count == 0) return;
    if (self.space.selected_count == 1) {
        try self.duplicateSelectedNode(gpa, self.space.selected_nodes[0], link_parameters);
        return;
    }

    var sources: [16]VisualNode.Index = undefined;
    var source_count: usize = 0;
    var north_west = Space.Position{ .x = std.math.maxInt(i32), .y = std.math.maxInt(i32) };
    var south_east = Space.Position{ .x = std.math.minInt(i32), .y = std.math.minInt(i32) };
    for (self.space.selected_nodes[0..self.space.selected_count]) |source| {
        if (std.meta.activeTag(self.dsp.nodes.items(.state)[source.idx]) == .output) continue;
        sources[source_count] = source;
        source_count += 1;
        const footprint = self.space.nodeFootprint(source);
        const position = self.space.nodePosition(source);
        north_west.x = @min(north_west.x, position.x);
        north_west.y = @min(north_west.y, position.y);
        south_east.x = @max(south_east.x, position.x + @as(i32, @intCast(footprint.width)));
        south_east.y = @max(south_east.y, position.y + @as(i32, @intCast(footprint.height)));
    }
    if (source_count == 0) return;

    const offset = self.space.findFreeGroupOffset(sources[0..source_count], .{
        .x = south_east.x - north_west.x + 3,
        .y = 0,
    }) orelse return error.InvalidVisualNodeLayout;

    var duplicates: [16]VisualNode.Index = undefined;
    var duplicate_count: usize = 0;
    errdefer {
        while (duplicate_count > 0) {
            duplicate_count -= 1;
            const duplicate = duplicates[duplicate_count];
            self.dsp.remove(gpa, duplicate);
            self.space.remove(gpa, duplicate) catch {};
        }
    }

    for (sources[0..source_count]) |source| {
        const position = self.space.nodePosition(source);
        duplicates[duplicate_count] = try self.duplicateNodeAt(
            gpa,
            source,
            .{ .x = position.x + offset.x, .y = position.y + offset.y },
            link_parameters,
        );
        duplicate_count += 1;
    }

    self.releaseSelectedKeyboards();
    self.space.selectSingle(duplicates[0]);
    for (duplicates[1..duplicate_count]) |duplicate|
        self.space.toggleSelection(duplicate);
    self.refreshSelectionUi();
    try self.space.computePaths(gpa);
    _ = self.space.revealNode(duplicates[0]);
    self.zsynth.cursor.dirty = true;
    try self.write(gpa);
}

/// Removes every currently selected node while preserving index validity.
fn removeSelectedNodes(self: *Self, gpa: std.mem.Allocator) !void {
    var nodes: [16]VisualNode.Index = undefined;
    const count = self.space.selected_count;
    @memcpy(nodes[0..count], self.space.selected_nodes[0..count]);
    self.releaseSelectedKeyboards();
    var index = count;
    while (index > 0) {
        index -= 1;
        try self.remove(gpa, nodes[index]);
    }
    self.setNodeSelection(null);
    try self.space.computePaths(gpa);
    self.zsynth.cursor.dirty = true;
    try self.write(gpa);
}

/// Creates a fresh runtime node with the same user-facing state as a source.
fn duplicateNodeState(self: *Self, source: VisualNode.Index) DSP.Node {
    const source_name = self.dsp.nodes.items(.name)[source.idx];
    return switch (self.dsp.nodes.items(.state)[source.idx]) {
        .add => DSP.Node.Add.create(source_name),
        .adsr => |value| DSP.Node.ADSR.create(source_name, value.parameters),
        .bit_crusher => |value| DSP.Node.BitCrusher.create(source_name, value.parameters),
        .constant => |value| DSP.Node.Constant.create(source_name, value.parameters),
        .keyboard => |value| DSP.Node.Keyboard.create(source_name, value.parameters),
        .mixer => |value| DSP.Node.Mixer.create(source_name, value.parameters),
        .monophonic_sequencer => |value| DSP.Node.MonophonicSequencer.create(source_name, value.parameters),
        .multimode_filter => |value| DSP.Node.MultimodeFilter.create(source_name, value.parameters),
        .multiply => DSP.Node.Multiply.create(source_name),
        .noise => |value| DSP.Node.Noise.create(source_name, value.parameters),
        .noop => unreachable,
        .oscillator => |value| DSP.Node.Oscillator.create(source_name, value.parameters),
        .output => DSP.Node.Output.create(source_name),
    };
}

/// Adds a duplicate at an explicit visual position and optionally links its parameters.
fn duplicateNodeAt(
    self: *Self,
    gpa: std.mem.Allocator,
    source: VisualNode.Index,
    position: Space.Position,
    link_parameters: bool,
) !VisualNode.Index {
    if (std.meta.activeTag(self.dsp.nodes.items(.state)[source.idx]) == .output)
        return error.InvalidVisualNodeLayout;
    const duplicate_index = try self.dsp.addNode(gpa, self.duplicateNodeState(source));
    errdefer self.dsp.remove(gpa, duplicate_index);
    try self.space.addNode(gpa, duplicate_index, position);
    errdefer self.space.remove(gpa, duplicate_index) catch {};
    if (!try self.space.rebuildOccupancy(gpa))
        return error.InvalidVisualNodeLayout;
    if (link_parameters)
        _ = self.dsp.linkParameters(source, duplicate_index);
    return duplicate_index;
}

/// Duplicates a node with fresh runtime state and rebuilds the editor graph.
fn duplicateSelectedNode(
    self: *Self,
    gpa: std.mem.Allocator,
    selected: VisualNode.Index,
    link_parameters: bool,
) !void {
    if (std.meta.activeTag(self.dsp.nodes.items(.state)[selected.idx]) == .output)
        return;

    const source_position = self.space.nodePosition(selected);
    const source_footprint = self.space.nodeFootprint(selected);
    const duplicate_position = self.space.findFreePosition(
        selected,
        .{
            .x = source_position.x + @as(i32, @intCast(source_footprint.width)) + 3,
            .y = source_position.y,
        },
    ) orelse return error.InvalidVisualNodeLayout;
    const duplicate_index = try self.duplicateNodeAt(
        gpa,
        selected,
        duplicate_position,
        link_parameters,
    );

    try self.space.computePaths(gpa);
    self.setNodeSelection(duplicate_index);
    _ = self.space.revealNode(duplicate_index);
    self.zsynth.cursor.dirty = true;
    try self.write(gpa);
}

/// Handles SDL text input for the active selected-pane property field.
fn textInput(
    state_stack: *StateStack,
    _: std.mem.Allocator,
    state: StateStack.State.Index,
    event: sdl.TextInputEvent,
) StateStack.State.Error!bool {
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;
    if (self.parameter_editor.active == null) return false;
    self.parameter_editor.text_field.textInput(event);
    self.zsynth.cursor.dirty = true;
    return true;
}

/// Returns the editable selected-pane value under a display cell.
fn parameterCellAt(self: *const Self, cell: [2]u32) ?ParameterEditor.ParameterCell {
    for (self.parameter_editor.cells[0..self.parameter_editor.cell_count]) |parameter| {
        if (cell[1] == parameter.value_y and
            cell[0] >= parameter.value_x and
            cell[0] < parameter.value_x + parameter.value_width)
            return parameter;
    }
    return null;
}

/// Starts editing the first editable property of the selected node.
fn beginFirstParameterEdit(self: *Self) bool {
    for (self.parameter_editor.cells[0..self.parameter_editor.cell_count]) |parameter| {
        if (parameter.editable) {
            self.beginParameterEdit(parameter);
            return true;
        }
    }
    return false;
}

/// Starts editing a selected-pane property and loads its current value.
fn beginParameterEdit(self: *Self, parameter: ParameterEditor.ParameterCell) void {
    if (self.parameter_editor.active) |active|
        if (sameParameter(
            active.field_name,
            active.array_index,
            parameter.field_name,
            parameter.array_index,
        ))
            return;

    if (self.parameter_editor.active != null)
        self.commitParameterEdit();

    const node = self.space.singleSelectedNode() orelse return;
    self.parameter_editor.active = .{
        .node = .{ .idx = node.idx },
        .field_name = parameter.field_name,
        .array_index = parameter.array_index,
    };
    self.parameter_editor.text_field = .init(self, .{
        .width = parameter.value_width,
        .completion = parameterCompletion,
        .label = "",
    });

    var buffer: [64]u8 = undefined;
    self.parameter_editor.text_field.setInput(
        self.formatNodeParameter(
            node.idx,
            parameter.field_name,
            parameter.array_index,
            &buffer,
        ),
    );
}

/// Commits the active field and moves to the adjacent editable property.
fn moveParameterEdit(self: *Self, direction: i2) void {
    const active = self.parameter_editor.active orelse return;
    var current_index: usize = 0;
    while (current_index < self.parameter_editor.cell_count) : (current_index += 1) {
        const parameter = self.parameter_editor.cells[current_index];
        if (parameter.editable and sameParameter(
            parameter.field_name,
            parameter.array_index,
            active.field_name,
            active.array_index,
        ))
            break;
    }
    if (current_index == self.parameter_editor.cell_count) return;

    if (direction < 0) {
        while (current_index > 0) {
            current_index -= 1;
            if (self.parameter_editor.cells[current_index].editable) {
                self.beginParameterEdit(self.parameter_editor.cells[current_index]);
                return;
            }
        }
    } else {
        current_index += 1;
        while (current_index < self.parameter_editor.cell_count) : (current_index += 1) {
            if (self.parameter_editor.cells[current_index].editable) {
                self.beginParameterEdit(self.parameter_editor.cells[current_index]);
                return;
            }
        }
    }
}

/// Cancels property editing without changing the node parameter.
fn cancelParameterEdit(self: *Self) void {
    self.parameter_editor.active = null;
}

/// Commits the active property or restores its original value on parse failure.
fn commitParameterEdit(self: *Self) void {
    if (self.parameter_editor.active == null) return;

    var context = ParameterEditor.CommitContext{ .editor = self };
    self.dsp.withGraphLock(&context, commitParameterLocked);
    var buffer: [64]u8 = undefined;
    const active = self.parameter_editor.active orelse return;
    const node = self.space.singleSelectedNode() orelse return;
    self.parameter_editor.text_field.setInput(
        self.formatNodeParameter(
            node.idx,
            active.field_name,
            active.array_index,
            &buffer,
        ),
    );
}

/// Parses and assigns an active property while the DSP graph is locked.
fn commitParameterLocked(context: *ParameterEditor.CommitContext) void {
    const self = context.editor;
    const active = self.parameter_editor.active orelse return;
    if (active.node.idx >= self.dsp.nodes.len) return;

    if (std.mem.eql(u8, active.field_name, node_name_field_name)) {
        const owned_name = self.serializer.allocator.dupe(
            u8,
            self.parameter_editor.text_field.inputSlice(),
        ) catch return;
        self.owned_node_names.append(self.serializer.allocator, owned_name) catch {
            self.serializer.allocator.free(owned_name);
            return;
        };
        self.dsp.nodes.items(.name)[active.node.idx] = owned_name;
        context.accepted = true;
        return;
    }

    const state = &self.dsp.nodes.items(.state)[active.node.idx];
    switch (state.*) {
        inline else => |*node_state| {
            if (@hasField(@TypeOf(node_state.*), "parameters"))
                context.accepted = assignReflectedParameter(
                    &node_state.parameters,
                    active.field_name,
                    active.array_index,
                    self.parameter_editor.text_field.inputSlice(),
                );
        },
    }
}

/// Formats one reflected property from a node's parameter struct.
fn formatNodeParameter(
    self: *const Self,
    node: usize,
    field_name: []const u8,
    array_index: ?usize,
    buffer: []u8,
) []const u8 {
    if (node >= self.dsp.nodes.len) return "";
    if (std.mem.eql(u8, field_name, node_name_field_name))
        return self.dsp.nodes.items(.name)[node];
    const state = self.dsp.nodes.items(.state)[node];
    return switch (state) {
        inline else => |node_state| if (@hasField(@TypeOf(node_state), "parameters"))
            formatReflectedParameter(node_state.parameters, field_name, array_index, buffer)
        else
            "",
    };
}

/// Formats a named scalar or fixed-array element from a reflected parameter struct.
fn formatReflectedParameter(
    parameters: anytype,
    field_name: []const u8,
    array_index: ?usize,
    buffer: []u8,
) []const u8 {
    const field_names = @typeInfo(@TypeOf(parameters)).@"struct".field_names;
    inline for (field_names) |name| {
        if (std.mem.eql(u8, name, field_name)) {
            const value = @field(parameters, name);
            switch (@typeInfo(@TypeOf(value))) {
                .array => |array| {
                    const index = array_index orelse return "";
                    if (index >= array.len) return "";
                    return formatParameterValue(buffer, value[index]);
                },
                else => {
                    if (array_index != null) return "";
                    return formatParameterValue(buffer, value);
                },
            }
        }
    }
    return "";
}

/// Returns an enum tag completing the active selected-pane input.
fn parameterCompletion(field: *const TextField(*Self)) []const u8 {
    const self = field.context;
    const active = self.parameter_editor.active orelse return "";
    if (active.node.idx >= self.dsp.nodes.len) return "";

    const state = self.dsp.nodes.items(.state)[active.node.idx];
    return switch (state) {
        inline else => |node_state| if (@hasField(@TypeOf(node_state), "parameters"))
            reflectedEnumCompletion(
                node_state.parameters,
                active.field_name,
                active.array_index,
                field.inputSlice(),
            )
        else
            "",
    };
}

/// Finds a matching enum tag for a reflected scalar or fixed-array element prefix.
fn reflectedEnumCompletion(
    parameters: anytype,
    field_name: []const u8,
    array_index: ?usize,
    input: []const u8,
) []const u8 {
    const field_names = @typeInfo(@TypeOf(parameters)).@"struct".field_names;
    inline for (field_names) |name| {
        if (std.mem.eql(u8, name, field_name)) {
            const value = @field(parameters, name);
            switch (@typeInfo(@TypeOf(value))) {
                .@"enum" => {
                    if (array_index != null) return "";
                    inline for (std.meta.tags(@TypeOf(value))) |tag|
                        if (parameterStartsWithIgnoreCase(@tagName(tag), input))
                            return @tagName(tag);
                },
                .array => |array| {
                    const index = array_index orelse return "";
                    if (index >= array.len) return "";
                    const element = value[index];
                    switch (@typeInfo(@TypeOf(element))) {
                        .@"enum" => inline for (std.meta.tags(@TypeOf(element))) |tag|
                            if (parameterStartsWithIgnoreCase(@tagName(tag), input))
                                return @tagName(tag),
                        else => {},
                    }
                },
                else => {},
            }
        }
    }
    return "";
}

/// Parses and assigns one supported reflected scalar or fixed-array element.
fn assignReflectedParameter(
    parameters: anytype,
    field_name: []const u8,
    array_index: ?usize,
    input: []const u8,
) bool {
    const field_names = @typeInfo(@TypeOf(parameters.*)).@"struct".field_names;
    inline for (field_names) |name| {
        if (std.mem.eql(u8, name, field_name)) {
            const value = &@field(parameters.*, name);
            switch (@typeInfo(@TypeOf(value.*))) {
                .array => |array| {
                    const index = array_index orelse return false;
                    if (index >= array.len) return false;
                    return assignReflectedScalar(&value.*[index], input);
                },
                else => {},
            }
            if (array_index != null) return false;
            return assignReflectedScalar(value, input);
        }
    }
    return false;
}

/// Parses and assigns one supported reflected scalar or enum value.
fn assignReflectedScalar(value: anytype, input: []const u8) bool {
    switch (@typeInfo(@TypeOf(value.*))) {
        .bool => {
            if (std.ascii.eqlIgnoreCase(input, "true")) {
                value.* = true;
                return true;
            }
            if (std.ascii.eqlIgnoreCase(input, "false")) {
                value.* = false;
                return true;
            }
        },
        .int => {
            value.* = std.fmt.parseInt(@TypeOf(value.*), input, 10) catch return false;
            return true;
        },
        .float => {
            value.* = std.fmt.parseFloat(@TypeOf(value.*), input) catch return false;
            return true;
        },
        .@"enum" => {
            inline for (std.meta.tags(@TypeOf(value.*))) |tag| {
                if (std.ascii.eqlIgnoreCase(input, @tagName(tag))) {
                    value.* = tag;
                    return true;
                }
            }
        },
        else => {},
    }
    return false;
}

/// Returns whether `candidate` begins with the case-insensitive prefix.
fn parameterStartsWithIgnoreCase(candidate: []const u8, prefix: []const u8) bool {
    return prefix.len <= candidate.len and
        std.ascii.eqlIgnoreCase(candidate[0..prefix.len], prefix);
}

/// Starts and stops viewport panning with the middle mouse button.
fn mouseButton(
    state_stack: *StateStack,
    gpa: std.mem.Allocator,
    state: StateStack.State.Index,
    event: sdl.MouseButtonEvent,
) StateStack.State.Error!bool {
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
        if (event.down) {
            self.zsynth.cursor.left_mouse_down = true;
            self.zsynth.cursor.left_mouse_moved = false;
            self.zsynth.cursor.selection_dragging = false;
            const keyboard_state = sdl.getKeyboardState();
            const control = (keyboard_state.len > @backingInt(sdl.Scancode.lctrl) and
                keyboard_state[@backingInt(sdl.Scancode.lctrl)]) or
                (keyboard_state.len > @backingInt(sdl.Scancode.rctrl) and
                    keyboard_state[@backingInt(sdl.Scancode.rctrl)]);
            const cell = self.zsynth.displayCellAtWindowPosition(.{ event.x, event.y });
            if (cell) |display_cell| {
                if (self.parameterCellAt(display_cell)) |parameter| {
                    if (parameter.editable) {
                        self.zsynth.cursor.left_mouse_down = false;
                        self.beginParameterEdit(parameter);
                        self.zsynth.cursor.dirty = true;
                        return true;
                    }
                    if (self.parameter_editor.active != null) {
                        self.zsynth.cursor.left_mouse_down = false;
                        self.commitParameterEdit();
                        self.cancelParameterEdit();
                        self.zsynth.cursor.dirty = true;
                        return true;
                    }
                }
            }
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

            const node = if (cell) |display_cell|
                self.space.nodeAtDisplayCell(display_cell[0], display_cell[1])
            else
                null;
            if (node) |selected| {
                if (control) {
                    self.releaseSelectedKeyboards();
                    self.space.toggleSelection(selected);
                    self.refreshSelectionUi();
                    self.zsynth.cursor.left_mouse_down = false;
                } else if (!(self.space.selected_count > 1 and self.space.isSelected(selected))) {
                    self.setNodeSelection(selected);
                } else {
                    self.refreshSelectionUi();
                }
            } else {
                self.setNodeSelection(null);
                if (cell) |display_cell| {
                    const world = self.space.worldPositionAtDisplayCell(
                        display_cell[0],
                        display_cell[1],
                    );
                    self.zsynth.cursor.selection_anchor = .{ world.x, world.y };
                    self.zsynth.cursor.drag_position = .{ world.x, world.y };
                    self.zsynth.cursor.selection_dragging = true;
                }
            }
            self.zsynth.cursor.dirty = true;

            if (cell) |display_cell| if (!control) if (self.space.nodeAtDisplayCell(
                display_cell[0],
                display_cell[1],
            )) |grabbed| {
                if (!grabbed.isNoop() and self.space.isSelected(grabbed)) {
                    _ = self.space.revealNode(grabbed);
                    const world = self.space.worldPositionAtDisplayCell(display_cell[0], display_cell[1]);
                    self.zsynth.cursor.drag_position = .{ world.x, world.y };
                }
            };
            try self.write(gpa);
        } else {
            self.zsynth.cursor.left_mouse_down = false;
            if (self.zsynth.cursor.selection_dragging) {
                self.space.selectRectangle(
                    .{
                        .x = self.zsynth.cursor.selection_anchor[0],
                        .y = self.zsynth.cursor.selection_anchor[1],
                    },
                    .{
                        .x = self.zsynth.cursor.drag_position[0],
                        .y = self.zsynth.cursor.drag_position[1],
                    },
                );
                self.refreshSelectionUi();
                self.zsynth.cursor.selection_dragging = false;
                self.zsynth.cursor.left_mouse_moved = false;
                try self.write(gpa);
            } else if (self.zsynth.cursor.left_mouse_moved) {
                try self.space.computePaths(gpa);
                self.zsynth.cursor.left_mouse_moved = false;
                try self.write(gpa);
            } else {
                self.zsynth.cursor.left_mouse_moved = false;
            }
        }
        return true;
    }

    if (event.button != 2) return false;

    self.zsynth.cursor.middle_mouse_down = event.down;
    self.zsynth.cursor.viewport_pan_remainder = .{ 0, 0 };
    return true;
}

/// Releases keyboard notes before a mouse selection replaces the current set.
fn releaseSelectedKeyboards(self: *Self) void {
    for (self.space.selected_nodes[0..self.space.selected_count]) |selected| {
        if (selected.idx < self.dsp.nodes.len and
            std.meta.activeTag(self.dsp.nodes.items(.state)[selected.idx]) == .keyboard)
            self.dsp.keyboardReleaseAll(.{ .idx = selected.idx });
    }
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
    if (first.node.idx == second.node.idx)
        return;

    const first_is_parameter = first.direction == .parameter_source or
        first.direction == .parameter_target;
    const second_is_parameter = second.direction == .parameter_source or
        second.direction == .parameter_target;
    if (first_is_parameter or second_is_parameter) {
        if (!first_is_parameter or !second_is_parameter or
            first.direction == second.direction)
            return;

        const source = if (first.direction == .parameter_target) first else second;
        const target = if (first.direction == .parameter_source) first else second;
        if (!self.dsp.linkParameters(source.node, target.node)) return;
        try self.space.computePaths(gpa);
        try self.write(gpa);
        return;
    }

    if (first.direction == second.direction)
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
        .parameter_source => self.dsp.disconnectParameterSource(outlet.node),
        .parameter_target => self.dsp.disconnectParameterTarget(outlet.node),
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
) StateStack.State.Error!bool {
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;

    if (self.zsynth.cursor.left_mouse_down) {
        if (event.state.left == 0) {
            self.zsynth.cursor.left_mouse_down = false;
            if (self.zsynth.cursor.selection_dragging) {
                self.space.selectRectangle(
                    .{
                        .x = self.zsynth.cursor.selection_anchor[0],
                        .y = self.zsynth.cursor.selection_anchor[1],
                    },
                    .{
                        .x = self.zsynth.cursor.drag_position[0],
                        .y = self.zsynth.cursor.drag_position[1],
                    },
                );
                self.refreshSelectionUi();
                self.zsynth.cursor.selection_dragging = false;
                self.zsynth.cursor.left_mouse_moved = false;
                try self.write(gpa);
            } else if (self.zsynth.cursor.left_mouse_moved) {
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
        const previous_world = cursor_position.drag_position;
        cursor_position.drag_position = .{ world.x, world.y };

        if (cursor_position.selection_dragging) {
            cursor_position.left_mouse_moved = true;
            try self.write(gpa);
        } else if (self.space.selected_count != 0) {
            const moved = try self.space.moveSelectedNodes(gpa, .{
                .x = world.x - previous_world[0],
                .y = world.y - previous_world[1],
            });
            if (moved) {
                cursor_position.left_mouse_moved = true;
                try self.space.computePaths(gpa);
                try self.write(gpa);
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
) StateStack.State.Error!void {
    // Resolve the concrete editor context for this frame.
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;
    // Redraw text before the runtime overlays the software cursor.
    try self.write(gpa);
    // Draw the remembered filename before transient editor overlays.
    try self.writeDocumentName(gpa);
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
    self.refreshSelectionUi();
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
    try self.space.addNode(allocator, node, position);
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

pub const CommandPalette = struct {
    editor: *Self,
    text_field: TextField(*CommandPalette) = undefined,
    selected_command: ?Command = null,
    selected_node_tag: ?DSP.Node.Tag = null,

    const Command = enum {
        addNode,
        save,
        load,
        quit,
    };

    pub const vtable = StateStack.State.VTable{
        .enter = CommandPalette.enter,
        .leave = CommandPalette.leave,
        .quit = CommandPalette.quit,
        .keyUpDown = CommandPalette.keyUpDown,
        .textInput = CommandPalette.textInput,
        .render = CommandPalette.render,
    };

    fn enter(
        state_stack: *StateStack,
        gpa: std.mem.Allocator,
        state: StateStack.State.Index,
    ) StateStack.State.Error!void {
        const self: *CommandPalette = &state_stack.stack.items(.context)[state.idx].command_palette;
        self.text_field = .init(self, .{
            .width = 0,
            .completion = CommandPalette.completion,
            .label = "Command:",
        });
        self.editor.zsynth.cursor.dirty = true;
        try self.write(gpa);
    }

    /// Releases the palette state when it is temporarily removed.
    fn leave(
        state_stack: *StateStack,
        _: std.mem.Allocator,
        _: *Renderer,
        _: StateStack.State.Index,
    ) StateStack.State.Error!void {
        _ = state_stack;
    }

    /// Releases the palette state while the application state stack is shutting down.
    fn quit(
        state_stack: *StateStack,
        _: std.mem.Allocator,
        _: *Renderer,
        _: StateStack.State.Index,
    ) StateStack.State.Error!void {
        _ = state_stack;
    }

    fn keyUpDown(
        state_stack: *StateStack,
        gpa: std.mem.Allocator,
        state: StateStack.State.Index,
        event: sdl.KeyboardEvent,
    ) StateStack.State.Error!bool {
        if (!event.down) return true;
        const self: *CommandPalette = &state_stack.stack.items(.context)[state.idx].command_palette;
        if (event.key == .escape) {
            self.editor.zsynth.cursor.dirty = true;
            try state_stack.pop(gpa, &self.editor.zsynth.renderer);
        } else if (event.key == .@"return" or event.key == .kp_enter) {
            try self.activate(state_stack, gpa);
        } else {
            self.text_field.textUpDown(event);
            try self.write(gpa);
        }
        return true;
    }

    fn textInput(
        state_stack: *StateStack,
        gpa: std.mem.Allocator,
        state: StateStack.State.Index,
        event: sdl.TextInputEvent,
    ) StateStack.State.Error!bool {
        const self: *CommandPalette = &state_stack.stack.items(.context)[state.idx].command_palette;
        self.text_field.textInput(event);
        try self.write(gpa);
        return true;
    }

    /// Draws the palette panel into the transparent UI overlay.
    fn write(self: *CommandPalette, gpa: std.mem.Allocator) !void {
        if (self.editor.zsynth.ui_display.impl != .graphic) return;
        const display = &self.editor.zsynth.ui_display.impl.graphic;
        if (display.width < 32 or display.height < 3) return;

        const panel_width: u32 = 32;
        const panel_height: u32 = 3;
        const panel_x = (display.width - panel_width) / 2;
        const panel_y = (display.height - panel_height) / 2;
        const inner_width: usize = 30;
        const label = if (self.selected_command) |command| switch (command) {
            .addNode => if (self.selected_node_tag == null) "Add node:" else "Name:",
            .save => "Save:",
            .load => "Load:",
            .quit => "Command:",
        } else "Command:";
        const field_width = inner_width - label.len;

        self.text_field.parameters.label = label;
        self.text_field.parameters.width = @intCast(field_width);
        try self.text_field.write(
            gpa,
            &self.editor.zsynth.ui_display,
            panel_x + 1,
            panel_y + 1,
        );

        // Draw the border last so text and the caret can never cover it.
        try self.editor.zsynth.ui_display.writeBox(
            gpa,
            panel_x,
            panel_y,
            panel_width,
            panel_height,
            .ebony,
            .curious_blue,
            .single,
        );

        // A three-row box has a one-cell vertical edge; write those cells
        // explicitly because the generic line helper omits point lines.
        try self.editor.zsynth.ui_display.write(
            gpa,
            "\xB3",
            panel_x,
            panel_y + 1,
            .ebony,
            .curious_blue,
        );
        try self.editor.zsynth.ui_display.write(
            gpa,
            "\xB3",
            panel_x + panel_width - 1,
            panel_y + 1,
            .ebony,
            .curious_blue,
        );
    }

    /// Renders the palette after the editor and after transient overlays reset.
    fn render(
        state_stack: *StateStack,
        gpa: std.mem.Allocator,
        state: StateStack.State.Index,
        _: *Renderer,
        _: u64,
    ) StateStack.State.Error!void {
        const self: *CommandPalette = &state_stack.stack.items(.context)[state.idx].command_palette;
        try self.write(gpa);
    }

    /// Executes the current command or advances to its argument field.
    fn activate(
        self: *CommandPalette,
        state_stack: *StateStack,
        gpa: std.mem.Allocator,
    ) StateStack.State.Error!void {
        if (self.selected_command == null) {
            const command = self.commandForInput() orelse return;
            self.selected_command = command;
            if (command == .quit) {
                try state_stack.quit(gpa, &self.editor.zsynth.renderer);
                return;
            }
            self.clearInput();
            try self.write(gpa);
            return;
        }

        switch (self.selected_command.?) {
            .save => {
                if (self.text_field.inputSlice().len == 0) return;
                self.editor.saveDocument(gpa, self.inputSlice()) catch return error.IoError;
                try self.finish(state_stack, gpa);
            },
            .load => {
                if (self.text_field.inputSlice().len == 0) return;
                self.editor.loadDocument(gpa, self.inputSlice()) catch return error.IoError;
                self.editor.setNodeSelection(null);
                self.editor.output_meter = .{};
                self.editor.zsynth.cursor.dirty = true;
                try self.editor.write(gpa);
                try self.finish(state_stack, gpa);
            },
            .addNode => {
                if (self.selected_node_tag == null) {
                    self.selected_node_tag = self.nodeTagForInput() orelse return;
                    self.clearInput();
                    try self.write(gpa);
                } else {
                    try self.addNode(state_stack, gpa);
                }
            },
            .quit => unreachable,
        }
    }

    /// Adds the requested node and reveals it in the unbounded editor space.
    fn addNode(
        self: *CommandPalette,
        state_stack: *StateStack,
        gpa: std.mem.Allocator,
    ) StateStack.State.Error!void {
        if (self.text_field.inputSlice().len == 0) return;

        const tag = self.selected_node_tag orelse return;
        const owned_name = try gpa.dupe(u8, self.inputSlice());
        self.editor.owned_node_names.append(gpa, owned_name) catch |err| {
            gpa.free(owned_name);
            return err;
        };
        const node = createNode(tag, owned_name);
        const index = self.editor.dsp.addNode(gpa, node) catch |err| {
            _ = self.editor.owned_node_names.pop();
            gpa.free(owned_name);
            return err;
        };
        errdefer self.editor.dsp.remove(gpa, index);

        const position = self.editor.space.findFreePosition(
            index,
            self.editor.space.viewportCenter(),
        ) orelse return error.InvalidVisualNodeLayout;

        try self.editor.space.addNode(gpa, index, position);
        errdefer self.editor.space.remove(gpa, index) catch {};
        if (!try self.editor.space.rebuildOccupancy(gpa))
            return error.InvalidVisualNodeLayout;
        try self.editor.space.computePaths(gpa);
        self.editor.setNodeSelection(index);
        _ = self.editor.space.revealNode(index);
        self.editor.zsynth.cursor.dirty = true;
        try self.editor.write(gpa);
        try self.finish(state_stack, gpa);
    }

    /// Removes the palette and requests the transient overlay to be cleared.
    fn finish(self: *CommandPalette, state_stack: *StateStack, gpa: std.mem.Allocator) !void {
        self.editor.zsynth.cursor.dirty = true;
        try state_stack.pop(gpa, &self.editor.zsynth.renderer);
    }

    /// Returns the input currently being edited.
    fn inputSlice(self: *const CommandPalette) []const u8 {
        return self.text_field.inputSlice();
    }

    /// Clears the argument input and places the cursor at its beginning.
    fn clearInput(self: *CommandPalette) void {
        self.text_field.clear();
    }

    /// Returns the command matching the input or its two-character completion.
    fn commandForInput(self: *const CommandPalette) ?Command {
        inline for (std.meta.tags(Command)) |command|
            if (std.ascii.eqlIgnoreCase(self.inputSlice(), commandName(command)))
                return command;

        if (self.inputSlice().len < 2) return null;
        const completion_value = self.text_field.completionSlice();
        inline for (std.meta.tags(Command)) |command|
            if (std.ascii.eqlIgnoreCase(completion_value, commandName(command)))
                return command;
        return null;
    }

    /// Returns the node type matching the input or its two-character completion.
    fn nodeTagForInput(self: *const CommandPalette) ?DSP.Node.Tag {
        inline for (std.meta.tags(DSP.Node.Tag)) |tag| {
            const name = nodeName(tag);
            if (name.len != 0 and std.ascii.eqlIgnoreCase(self.inputSlice(), name))
                return tag;
        }

        if (self.inputSlice().len < 2) return null;
        const completion_value = self.text_field.completionSlice();
        inline for (std.meta.tags(DSP.Node.Tag)) |tag| {
            const name = nodeName(tag);
            if (name.len != 0 and std.ascii.eqlIgnoreCase(completion_value, name))
                return tag;
        }
        return null;
    }

    /// Returns the full completion candidate for the field's current palette phase.
    fn completion(field: *const TextField(*CommandPalette)) []const u8 {
        const self = field.context;
        const input = field.inputSlice();
        if (input.len == 0) return "";

        if (self.selected_command == null) {
            inline for (std.meta.tags(Command)) |command| {
                const name = commandName(command);
                if (startsWithIgnoreCase(name, input))
                    return name;
            }
        } else if (self.selected_command.? == .addNode and self.selected_node_tag == null) {
            inline for (std.meta.tags(DSP.Node.Tag)) |tag| {
                const name = nodeName(tag);
                if (name.len != 0 and startsWithIgnoreCase(name, input))
                    return name;
            }
        }
        return "";
    }

    /// Returns whether `candidate` begins with the case-insensitive prefix.
    fn startsWithIgnoreCase(candidate: []const u8, prefix: []const u8) bool {
        return prefix.len <= candidate.len and
            std.ascii.eqlIgnoreCase(candidate[0..prefix.len], prefix);
    }

    /// Returns the stable spelling used for a palette command.
    fn commandName(command: Command) []const u8 {
        return switch (command) {
            .addNode => "addNode",
            .save => "save",
            .load => "load",
            .quit => "quit",
        };
    }

    /// Returns the stable palette spelling for a constructible processing node.
    fn nodeName(tag: DSP.Node.Tag) []const u8 {
        return switch (tag) {
            .noop, .output => "",
            else => DSP.node_metadata.get(tag).name,
        };
    }

    /// Constructs a processing node with safe default parameters.
    fn createNode(tag: DSP.Node.Tag, name: []const u8) DSP.Node {
        return switch (tag) {
            .add => DSP.Node.Add.create(name),
            .multiply => DSP.Node.Multiply.create(name),
            .constant => DSP.Node.Constant.create(name, .{}),
            .keyboard => DSP.Node.Keyboard.create(name, .{}),
            .oscillator => DSP.Node.Oscillator.create(name, .{
                .waveform = .sine,
                .default_frequency = 440,
                .default_amplitude = 1,
            }),
            .mixer => DSP.Node.Mixer.create(name, .{}),
            .monophonic_sequencer => DSP.Node.MonophonicSequencer.create(name, .{
                .notes = &.{},
            }),
            .adsr => DSP.Node.ADSR.create(name, .{}),
            .multimode_filter => DSP.Node.MultimodeFilter.create(name, .{
                .type = .low_pass,
                .default_cutoff = 1_000,
                .default_resonance = 0,
            }),
            .bit_crusher => DSP.Node.BitCrusher.create(name, .{}),
            .noise => DSP.Node.Noise.create(name, .{
                .seed = 0,
            }),
            .noop, .output => unreachable,
        };
    }
};

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
    ) StateStack.State.Error!void {
        const context = stateContext(state_stack, state);
        try context.updatePreview(gpa);
    }

    fn leave(
        state_stack: *StateStack,
        gpa: std.mem.Allocator,
        _: *Renderer,
        state: StateStack.State.Index,
    ) StateStack.State.Error!void {
        stateContext(state_stack, state).clearPreview(gpa);
    }

    fn quit(
        state_stack: *StateStack,
        gpa: std.mem.Allocator,
        _: *Renderer,
        state: StateStack.State.Index,
    ) StateStack.State.Error!void {
        stateContext(state_stack, state).clearPreview(gpa);
    }

    fn render(
        state_stack: *StateStack,
        gpa: std.mem.Allocator,
        state: StateStack.State.Index,
        _: *Renderer,
        _: u64,
    ) StateStack.State.Error!void {
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
    ) StateStack.State.Error!bool {
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
    ) StateStack.State.Error!bool {
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
    ) StateStack.State.Error!bool {
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

/// Creates a reusable single-line text field bound to an application context.
pub fn TextField(comptime Context: type) type {
    return struct {
        /// Concrete text-field type produced for the supplied context type.
        const Field = @This();

        /// Supplies the full completion value for the current field contents.
        pub const Completion = *const fn (field: *const Field) []const u8;

        /// Configures the visible field width, completion provider, and label.
        pub const Parameters = struct {
            /// Number of display cells available for the editable value.
            width: u32,
            /// Returns one complete value that may complete the current input.
            completion: Completion,
            /// Text rendered immediately before the editable value.
            label: []const u8,
        };

        /// Context supplied to the completion callback.
        context: Context,
        /// Current visual and completion configuration.
        parameters: Parameters,
        /// Storage for the current UTF-8 byte input.
        input: [256]u8 = @splat(0),
        /// Number of bytes currently in `input`.
        input_len: usize = 0,
        /// Byte offset of the insertion cursor.
        cursor: usize = 0,

        /// Constructs a text field with its owning context and parameters.
        pub fn init(context: Context, parameters: Parameters) Field {
            return .{
                .context = context,
                .parameters = parameters,
            };
        }

        /// Returns the bytes currently entered by the user.
        pub fn inputSlice(self: *const Field) []const u8 {
            return self.input[0..self.input_len];
        }

        /// Clears the field and moves its cursor to the beginning.
        pub fn clear(self: *Field) void {
            self.input = @splat(0);
            self.input_len = 0;
            self.cursor = 0;
        }

        /// Replaces the field contents and places the cursor at the end.
        pub fn setInput(self: *Field, value: []const u8) void {
            const copy_len = @min(value.len, self.input.len);
            self.input = @splat(0);
            @memcpy(self.input[0..copy_len], value[0..copy_len]);
            self.input_len = copy_len;
            self.cursor = copy_len;
        }

        /// Handles SDL Unicode text input by inserting it at the cursor.
        pub fn textInput(self: *Field, event: sdl.TextInputEvent) void {
            if (event.text) |text| {
                const spanned = std.mem.span(text);
                const insert_len = @min(spanned.len, self.input.len - self.input_len);
                var index = self.input_len;
                while (index > self.cursor) : (index -= 1)
                    self.input[index + insert_len - 1] = self.input[index - 1];
                @memcpy(
                    self.input[self.cursor .. self.cursor + insert_len],
                    spanned[0..insert_len],
                );
                self.input_len += insert_len;
                self.cursor += insert_len;
            }
        }

        /// Handles cursor movement, completion, and editing shortcuts.
        pub fn textUpDown(self: *Field, event: sdl.KeyboardEvent) void {
            if (!event.down) return;

            const control = (@backingInt(event.mod) & sdl.Keymod.ctrl) != 0;
            switch (event.key) {
                .left => {
                    if (control) {
                        while (self.cursor > 0 and std.ascii.isWhitespace(self.input[self.cursor - 1]))
                            self.cursor -= 1;
                        while (self.cursor > 0 and !std.ascii.isWhitespace(self.input[self.cursor - 1]))
                            self.cursor -= 1;
                    } else {
                        self.cursor -|= 1;
                    }
                },
                .right => {
                    if (control) {
                        while (self.cursor < self.input_len and std.ascii.isWhitespace(self.input[self.cursor]))
                            self.cursor += 1;
                        while (self.cursor < self.input_len and !std.ascii.isWhitespace(self.input[self.cursor]))
                            self.cursor += 1;
                    } else if (self.cursor < self.input_len) {
                        self.cursor += 1;
                    }
                },
                .a => {
                    if (control) self.cursor = 0;
                },
                .e => {
                    if (control) self.cursor = self.input_len;
                },
                .tab => self.complete(),
                .k => {
                    if (control) {
                        self.input_len = self.cursor;
                        if (self.input_len < self.input.len)
                            self.input[self.input_len] = 0;
                    }
                },
                .backspace => self.eraseLeft(),
                .escape, .@"return", .kp_enter => {},
                else => {},
            }
        }

        /// Draws the label, editable area, input, completion, and caret.
        pub fn write(
            self: *const Field,
            gpa: std.mem.Allocator,
            display: *Display,
            x: u32,
            y: u32,
        ) !void {
            const field_x = x + @as(u32, @intCast(self.parameters.label.len));
            try display.fill(
                gpa,
                .mine_shaft,
                .mine_shaft,
                ' ',
                field_x,
                y,
                self.parameters.width,
                1,
            );
            try display.write(gpa, self.parameters.label, x, y, .ebony, .curious_blue);

            const field_width: usize = self.parameters.width;
            if (field_width == 0) return;

            const input_start = if (self.input_len > field_width)
                @min(self.cursor, self.input_len - field_width)
            else
                0;
            const input_end = @min(self.input_len, input_start + field_width);
            const typed = self.input[input_start..input_end];
            try display.write(gpa, typed, field_x, y, .mine_shaft, .white);

            const cursor_offset = self.cursor - input_start;
            if (cursor_offset < field_width) {
                try display.write(
                    gpa,
                    "\xB3",
                    field_x + @as(u32, @intCast(cursor_offset)),
                    y,
                    .mine_shaft,
                    .amber,
                );
            }

            const candidate = self.completionSlice();
            if (input_start == 0 and input_end == self.input_len and typed.len + 1 < field_width and
                candidate.len > self.input_len)
            {
                const completion_len = @min(
                    candidate.len - self.input_len,
                    field_width - typed.len - 1,
                );
                if (completion_len != 0) {
                    try display.write(
                        gpa,
                        candidate[self.input_len .. self.input_len + completion_len],
                        field_x + @as(u32, @intCast(typed.len + 1)),
                        y,
                        .mine_shaft,
                        .logan,
                    );
                }
            }
        }

        /// Replaces the entire field with its current completion candidate.
        fn complete(self: *Field) void {
            const candidate = self.completionSlice();
            if (candidate.len == 0) return;

            const copy_len = @min(candidate.len, self.input.len);
            self.input = @splat(0);
            @memcpy(self.input[0..copy_len], candidate[0..copy_len]);
            self.input_len = copy_len;
            self.cursor = self.input_len;
        }

        /// Deletes the byte immediately before the cursor.
        fn eraseLeft(self: *Field) void {
            if (self.cursor == 0) return;

            var index = self.cursor - 1;
            while (index < self.input_len - 1) : (index += 1)
                self.input[index] = self.input[index + 1];
            self.input_len -= 1;
            self.cursor -= 1;
            self.input[self.input_len] = 0;
        }

        /// Returns a valid full completion, or an empty string when none exists.
        /// Returns the full completion matching the current input prefix.
        pub fn completionSlice(self: *const Field) []const u8 {
            const candidate = (self.parameters.completion)(self);
            if (self.input_len == 0 or candidate.len < self.input_len) return "";
            if (!std.ascii.eqlIgnoreCase(candidate[0..self.input_len], self.inputSlice())) return "";
            return candidate;
        }
    };
}
