//! Visual representation of DSP node in unbounded space
const std = @import("std");
const assert = std.debug.assert;
const DSP = @import("DSP.zig");
const Display = @import("Display.zig");

const Self = @This();

/// Maximum number of nodes a single selection gesture can contain.
pub const max_selected_nodes = 16;

viewport: Viewport,
dsp: *DSP,
/// Determines which DSP nodes this layout exposes to its editor.
scope: Scope = .root,
nodes: std.MultiArrayList(VisualNode) = .empty,
/// Fixed-capacity set of currently selected visual nodes.
selected_nodes: [max_selected_nodes]VisualNode.Index = undefined,
/// Number of valid entries in `selected_nodes`.
selected_count: u8 = 0,
/// Whether the current selection is being previewed as a drag transaction.
selected_node_drag_active: bool = false,
/// Node indices captured when the current selection drag began.
dragged_nodes: [max_selected_nodes]VisualNode.Index = undefined,
/// Original positions used to validate or roll back the current selection drag.
drag_origin_positions: [max_selected_nodes]Position = undefined,
/// Number of valid entries in `dragged_nodes` and `drag_origin_positions`.
dragged_node_count: u8 = 0,
graph_north_west: Position = .{ .x = 0, .y = 0 },
graph_south_east: Position = .{ .x = 0, .y = 0 },
// Keep track of occupied positions
occupied: std.AutoHashMapUnmanaged(Position, VisualNode.Index) = .empty,
// Keep track of directions already used by computed paths
path_occupied: std.AutoHashMapUnmanaged(Position, u4) = .empty,
astar: AStar(Self, PathCriteria) = .{},

const Viewport = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

const Bound = Viewport;

/// Selects the input or output side of a node's displayed ports.
const PortDirection = enum { input, output };

/// Visual scope rendered by one editor state.
pub const Scope = union(enum) {
    /// The complete synth graph, excluding hidden group endpoints.
    root,
    /// One group's members and explicit boundary endpoint nodes.
    group: VisualNode.Index,
};

pub const SearchBound = struct {
    left: i64,
    top: i64,
    right: i64,
    bottom: i64,

    fn contains(self: SearchBound, position: Position) bool {
        const x = @as(i64, position.x);
        const y = @as(i64, position.y);
        return x >= self.left and x <= self.right and
            y >= self.top and y <= self.bottom;
    }
};

pub const Position = struct {
    x: i32,
    y: i32,
};

const Direction = struct {
    const left: u4 = 1 << 0;
    const right: u4 = 1 << 1;
    const up: u4 = 1 << 2;
    const down: u4 = 1 << 3;
};

const PathCell = struct {
    directions: u4 = 0,
    path_count: u32 = 0,
};

pub const VisualNode = struct {
    pub const Index = DSP.Node.Index;

    dsp_node: DSP.Node.Index,
    position: Position,
    /// Whether this node can contribute to the configured DSP output.
    output_reachable: bool = false,
    paths: [DSP.max_outlets]?Path = @splat(null),
    /// Routed parameter link entering this node from its source.
    parameter_path: ?Path = null,
};

pub const Outlet = struct {
    /// Audio and parameter connection endpoint kinds.
    pub const Kind = enum { input, output, parameter_source, parameter_target };

    node: VisualNode.Index,
    direction: Kind,
    port: u8,
    anchor: Position,
};

/// Return the static metadata associated with a visual outlet.
pub fn outletMetadata(self: *Self, outlet: Outlet) DSP.Node.OutletMetadata {
    const state = self.dsp.nodes.items(.state)[outlet.node.idx];
    const metadata = DSP.node_metadata.get(std.meta.activeTag(state));
    if (std.meta.activeTag(state) == .group) {
        return switch (outlet.direction) {
            .input => self.dsp.groupOutletMetadata(outlet.node, .input, outlet.port),
            .output => self.dsp.groupOutletMetadata(outlet.node, .output, outlet.port),
            .parameter_source => .{
                .name = "parameter source",
                .short_name = "src",
                .color = .curious_blue,
            },
            .parameter_target => .{
                .name = "parameter target",
                .short_name = "dst",
                .color = .curious_blue,
            },
        };
    }
    return switch (outlet.direction) {
        .input => metadata.inputs[outlet.port],
        .output => metadata.outputs[outlet.port],
        .parameter_source => .{
            .name = "parameter source",
            .short_name = "src",
            .color = .curious_blue,
        },
        .parameter_target => .{
            .name = "parameter target",
            .short_name = "dst",
            .color = .curious_blue,
        },
    };
}

/// Draw transient outlet labels on the transparent UI display.
pub fn writeUiOverlay(
    self: *Self,
    gpa: std.mem.Allocator,
    display: *Display,
    cell_x: u32,
    cell_y: u32,
) !void {
    if (self.singleSelectedNode()) |node|
        try self.writeSelectedOutletLabels(gpa, display, node);

    const hovered = self.outletAt(self.worldPositionAtDisplayCell(cell_x, cell_y)) orelse return;
    const metadata = self.outletMetadata(hovered);
    const label_x = @as(i64, cell_x) - @as(i64, @intCast(metadata.short_name.len / 2));
    try writeUiText(
        gpa,
        display,
        label_x,
        @as(i64, cell_y) + 1,
        metadata.short_name,
        metadata.color,
    );
}

fn writeSelectedOutletLabels(
    self: *Self,
    gpa: std.mem.Allocator,
    display: *Display,
    node: VisualNode.Index,
) !void {
    if (node.isNoop()) return;

    const footprint = self.nodeFootprint(node);
    const state = self.dsp.nodes.items(.state)[node.idx];
    const metadata = DSP.node_metadata.get(std.meta.activeTag(state));
    const screen_left = @as(i64, footprint.x) - @as(i64, self.viewport.x);
    const screen_top = @as(i64, footprint.y) - @as(i64, self.viewport.y);

    for (0..DSP.max_outlets) |slot| {
        const port = self.displayedPortAtSlot(node, .input, slot) orelse continue;
        const outlet = if (std.meta.activeTag(state) == .group)
            self.dsp.groupOutletMetadata(node, .input, port)
        else
            metadata.inputs[port];
        const y = screen_top + self.outletYOffset(
            footprint,
            self.displayedPortCount(node, .input),
            slot,
        );
        const x = screen_left - @as(i64, @intCast(outlet.short_name.len));
        try writeUiText(gpa, display, x, y, outlet.short_name, outlet.color);
    }

    for (0..DSP.max_outlets) |slot| {
        const port = self.displayedPortAtSlot(node, .output, slot) orelse continue;
        const outlet = if (std.meta.activeTag(state) == .group)
            self.dsp.groupOutletMetadata(node, .output, port)
        else
            metadata.outputs[port];
        const y = screen_top + self.outletYOffset(
            footprint,
            self.displayedPortCount(node, .output),
            slot,
        );
        const x = screen_left + @as(i64, @intCast(footprint.width));
        try writeUiText(gpa, display, x, y, outlet.short_name, outlet.color);
    }

    if (metadata.can_link_parameters) {
        const source_x = @as(i64, self.parameterSourceX(node)) - @as(i64, self.viewport.x);
        const target_x = @as(i64, self.parameterTargetX(node)) - @as(i64, self.viewport.x);
        try writeUiText(
            gpa,
            display,
            source_x - @as(i64, "src".len / 2),
            screen_top - 1,
            "src",
            .curious_blue,
        );
        try writeUiText(
            gpa,
            display,
            target_x - @as(i64, "dst".len / 2),
            screen_top + @as(i64, @intCast(footprint.height)),
            "dst",
            .curious_blue,
        );
    }
}

fn writeUiText(
    gpa: std.mem.Allocator,
    display: *Display,
    x: i64,
    y: i64,
    text: []const u8,
    color: Display.Color,
) !void {
    if (text.len == 0 or x < 0 or y < 0 or
        x > std.math.maxInt(u32) or y > std.math.maxInt(u32)) return;
    try display.write(gpa, text, @intCast(x), @intCast(y), .black, color);
}

/// Move the unbounded viewport by an integer number of space cells.
pub fn moveViewport(self: *Self, dx: i32, dy: i32) void {
    self.viewport.x += dx;
    self.viewport.y += dy;
}

/// Finds a deterministic free top-left position for a visual node.
///
/// Positions fully inside the current viewport are considered first. If all
/// visible positions are occupied, the search expands rectangular shells
/// around the viewport so a finite graph can always be extended in the
/// unbounded editor space.
pub fn findFreePosition(
    self: *Self,
    node: VisualNode.Index,
    preferred: Position,
) ?Position {
    const footprint = self.nodeFootprintAt(node, preferred);
    const viewport_left = @as(i64, self.viewport.x);
    const viewport_top = @as(i64, self.viewport.y);
    const viewport_right = viewport_left + @as(i64, self.viewport.width) -
        @as(i64, footprint.width);
    const viewport_bottom = viewport_top + @as(i64, self.viewport.height) -
        @as(i64, footprint.height);

    if (viewport_right >= viewport_left and viewport_bottom >= viewport_top) {
        const center_x = std.math.clamp(
            @as(i64, preferred.x) - @as(i64, footprint.width / 2),
            viewport_left,
            viewport_right,
        );
        const center_y = std.math.clamp(
            @as(i64, preferred.y) - @as(i64, footprint.height / 2),
            viewport_top,
            viewport_bottom,
        );
        if (self.canPlaceAt(node, .{ .x = @intCast(center_x), .y = @intCast(center_y) }))
            return .{ .x = @intCast(center_x), .y = @intCast(center_y) };

        var y = viewport_top;
        while (y <= viewport_bottom) : (y += 1) {
            var x = viewport_left;
            while (x <= viewport_right) : (x += 1) {
                if (x == center_x and y == center_y) continue;
                if (self.canPlaceAt(node, .{ .x = @intCast(x), .y = @intCast(y) }))
                    return .{ .x = @intCast(x), .y = @intCast(y) };
            }
        }
    }

    var radius: i64 = 1;
    while (radius <= std.math.maxInt(i32)) : (radius += 1) {
        const left = viewport_left - radius;
        const top = viewport_top - radius;
        const right = viewport_right + radius;
        const bottom = viewport_bottom + radius;

        var x = left;
        while (x <= right) : (x += 1) {
            if (self.canPlaceAtI64(node, x, top))
                return .{ .x = @intCast(x), .y = @intCast(top) };
            if (bottom != top and self.canPlaceAtI64(node, x, bottom))
                return .{ .x = @intCast(x), .y = @intCast(bottom) };
        }

        var y = top + 1;
        while (y < bottom) : (y += 1) {
            if (self.canPlaceAtI64(node, left, y))
                return .{ .x = @intCast(left), .y = @intCast(y) };
            if (right != left and self.canPlaceAtI64(node, right, y))
                return .{ .x = @intCast(right), .y = @intCast(y) };
        }
    }

    return null;
}

/// Finds one translation that places a group of nodes outside the occupied
/// layout while preserving each node's position relative to the group.
pub fn findFreeGroupOffset(
    self: *Self,
    nodes: []const VisualNode.Index,
    preferred: Position,
) ?Position {
    var radius: i64 = 0;
    while (radius <= std.math.maxInt(i32)) : (radius += 1) {
        const left = @as(i64, preferred.x) - radius;
        const right = @as(i64, preferred.x) + radius;
        const top = @as(i64, preferred.y) - radius;
        const bottom = @as(i64, preferred.y) + radius;

        if (self.canPlaceGroupAtI64(nodes, preferred.x, preferred.y))
            return preferred;
        if (radius == 0) continue;

        var x = left;
        while (x <= right) : (x += 1) {
            if (self.canPlaceGroupAtI64(nodes, x, top))
                return .{ .x = @intCast(x), .y = @intCast(top) };
            if (self.canPlaceGroupAtI64(nodes, x, bottom))
                return .{ .x = @intCast(x), .y = @intCast(bottom) };
        }
        var y = top + 1;
        while (y < bottom) : (y += 1) {
            if (self.canPlaceGroupAtI64(nodes, left, y))
                return .{ .x = @intCast(left), .y = @intCast(y) };
            if (self.canPlaceGroupAtI64(nodes, right, y))
                return .{ .x = @intCast(right), .y = @intCast(y) };
        }
    }
    return null;
}

/// Tests a translated group against existing occupancy and its own footprints.
fn canPlaceGroupAtI64(self: *Self, nodes: []const VisualNode.Index, offset_x: i64, offset_y: i64) bool {
    var positions: [max_selected_nodes]Position = undefined;
    var bounds: [max_selected_nodes]SearchBound = undefined;
    for (nodes, 0..) |node, index| {
        const source = self.nodePosition(node);
        const x = @as(i64, source.x) + offset_x;
        const y = @as(i64, source.y) + offset_y;
        if (x < std.math.minInt(i32) + 2 or y < std.math.minInt(i32) + 1 or
            x > std.math.maxInt(i32) - 32 or y > std.math.maxInt(i32) - 32)
            return false;
        positions[index] = .{ .x = @intCast(x), .y = @intCast(y) };
        const footprint = self.nodeFootprintAt(node, positions[index]);
        bounds[index] = .{
            .left = x - 2,
            .top = y - 1,
            .right = x + @as(i64, @intCast(footprint.width)),
            .bottom = y + @as(i64, @intCast(footprint.height)),
        };

        var occupied_y = bounds[index].top;
        while (occupied_y <= bounds[index].bottom) : (occupied_y += 1) {
            var occupied_x = bounds[index].left;
            while (occupied_x <= bounds[index].right) : (occupied_x += 1)
                if (self.occupied.get(.{
                    .x = @intCast(occupied_x),
                    .y = @intCast(occupied_y),
                }) != null)
                    return false;
        }
    }

    for (nodes, 0..) |_, first| {
        for (nodes[first + 1 ..], first + 1..) |_, second| {
            const first_bound = bounds[first];
            const second_bound = bounds[second];
            if (first_bound.left <= second_bound.right and
                first_bound.right >= second_bound.left and
                first_bound.top <= second_bound.bottom and
                first_bound.bottom >= second_bound.top)
                return false;
        }
    }
    return true;
}

/// Returns the world-space center cell of the current viewport.
pub fn viewportCenter(self: *Self) Position {
    return self.worldPositionAtDisplayCell(self.viewport.width / 2, self.viewport.height / 2);
}

/// Tests a candidate position after widening it to the integer search type.
fn canPlaceAtI64(self: *Self, node: VisualNode.Index, x: i64, y: i64) bool {
    if (x < std.math.minInt(i32) + 2 or y < std.math.minInt(i32) + 1)
        return false;
    if (x > std.math.maxInt(i32) - 32 or y > std.math.maxInt(i32) - 32)
        return false;
    return self.canPlaceAt(node, .{ .x = @intCast(x), .y = @intCast(y) });
}

/// Tests whether a node footprint and its immediate routing cells are free.
fn canPlaceAt(self: *Self, node: VisualNode.Index, position: Position) bool {
    const footprint = self.nodeFootprintAt(node, position);
    const left = @as(i64, position.x) - 2;
    const top = @as(i64, position.y) - 1;
    const right = @as(i64, position.x) + @as(i64, footprint.width);
    const bottom = @as(i64, position.y) + @as(i64, footprint.height);

    var y = top;
    while (y <= bottom) : (y += 1) {
        var x = left;
        while (x <= right) : (x += 1) {
            if (self.occupied.get(.{ .x = @intCast(x), .y = @intCast(y) }) != null)
                return false;
        }
    }
    return true;
}

/// Shift the viewport minimally so a node and its selected labels are visible.
pub fn revealNode(self: *Self, node: VisualNode.Index) bool {
    if (node.isNoop()) return false;

    const footprint = self.nodeFootprint(node);
    const state = self.dsp.nodes.items(.state)[node.idx];
    const metadata = DSP.node_metadata.get(std.meta.activeTag(state));
    var input_label_width: i64 = 0;
    for (0..metadata.input_count) |port|
        input_label_width = @max(input_label_width, @as(i64, @intCast(metadata.inputs[port].short_name.len)));
    var output_label_width: i64 = 0;
    for (0..metadata.output_count) |port|
        output_label_width = @max(output_label_width, @as(i64, @intCast(metadata.outputs[port].short_name.len)));

    const required_left = @as(i64, footprint.x) - input_label_width - 1;
    const required_top = @as(i64, footprint.y);
    const required_right = @as(i64, footprint.x) + @as(i64, footprint.width) + output_label_width;
    const required_bottom = @as(i64, footprint.y) + @as(i64, footprint.height);
    const viewport_left = @as(i64, self.viewport.x);
    const viewport_top = @as(i64, self.viewport.y);
    const viewport_width = @as(i64, self.viewport.width);
    const viewport_height = @as(i64, self.viewport.height);

    var viewport_x = viewport_left;
    if (required_right - required_left <= viewport_width) {
        if (required_left < viewport_left)
            viewport_x = required_left
        else if (required_right > viewport_left + viewport_width)
            viewport_x = required_right - viewport_width;
    } else {
        viewport_x = required_left;
    }

    var viewport_y = viewport_top;
    if (required_bottom - required_top <= viewport_height) {
        if (required_top < viewport_top)
            viewport_y = required_top
        else if (required_bottom > viewport_top + viewport_height)
            viewport_y = required_bottom - viewport_height;
    } else {
        viewport_y = required_top;
    }

    const changed = viewport_x != viewport_left or viewport_y != viewport_top;
    self.viewport.x = @intCast(viewport_x);
    self.viewport.y = @intCast(viewport_y);
    return changed;
}

/// Convert a display cell to its world-space position.
pub fn worldPositionAtDisplayCell(self: *Self, cell_x: u32, cell_y: u32) Position {
    return .{
        .x = self.viewport.x + @as(i32, @intCast(cell_x)),
        .y = self.viewport.y + @as(i32, @intCast(cell_y)),
    };
}

/// Return the top-left position of a visual node.
pub fn nodePosition(self: *Self, node: VisualNode.Index) Position {
    return self.nodes.items(.position)[node.idx];
}

/// Returns whether a DSP node is a group wrapper.
pub fn isGroup(self: *const Self, node: VisualNode.Index) bool {
    return std.meta.activeTag(self.dsp.nodes.items(.state)[node.idx]) == .group;
}

/// Returns whether a DSP node is an explicit group boundary endpoint.
pub fn isGroupEndpoint(self: *const Self, node: VisualNode.Index) bool {
    const tag = std.meta.activeTag(self.dsp.nodes.items(.state)[node.idx]);
    return tag == .group_input or tag == .group_output;
}

/// Returns the group that owns an explicit boundary endpoint.
pub fn endpointGroup(self: *const Self, node: VisualNode.Index) ?VisualNode.Index {
    if (!self.isGroupEndpoint(node)) return null;
    return switch (self.dsp.nodes.items(.state)[node.idx]) {
        .group_input => |endpoint| endpoint.group,
        .group_output => |endpoint| endpoint.group,
        else => null,
    };
}

/// Returns the boundary port represented by an explicit endpoint node.
pub fn endpointPort(self: *const Self, node: VisualNode.Index) ?u8 {
    if (!self.isGroupEndpoint(node)) return null;
    return switch (self.dsp.nodes.items(.state)[node.idx]) {
        .group_input => |endpoint| endpoint.port,
        .group_output => |endpoint| endpoint.port,
        else => null,
    };
}

/// Returns the number of displayed inputs or outputs for a node.
fn displayedPortCount(self: *const Self, node: VisualNode.Index, direction: PortDirection) u8 {
    const state = self.dsp.nodes.items(.state)[node.idx];
    if (state == .group) {
        var count: u8 = 0;
        const bindings = switch (direction) {
            .input => state.group.input_bindings,
            .output => state.group.output_bindings,
        };
        for (bindings) |binding| {
            if (binding != null) count += 1;
        }
        return count;
    }
    const metadata = DSP.node_metadata.get(std.meta.activeTag(state));
    return switch (direction) {
        .input => metadata.input_count,
        .output => metadata.output_count,
    };
}

/// Maps a DSP port number to its compact displayed row, if it is visible.
fn displayedPortSlot(
    self: *const Self,
    node: VisualNode.Index,
    direction: PortDirection,
    port: u8,
) ?usize {
    const state = self.dsp.nodes.items(.state)[node.idx];
    if (state != .group) {
        const count = self.displayedPortCount(node, direction);
        return if (port < count) port else null;
    }

    const bindings = switch (direction) {
        .input => state.group.input_bindings,
        .output => state.group.output_bindings,
    };
    if (port >= DSP.max_outlets or bindings[port] == null) return null;

    var slot: usize = 0;
    for (bindings[0..port]) |binding| {
        if (binding != null) slot += 1;
    }
    return slot;
}

/// Maps a compact displayed row back to its DSP port number.
fn displayedPortAtSlot(
    self: *const Self,
    node: VisualNode.Index,
    direction: PortDirection,
    slot: usize,
) ?u8 {
    const state = self.dsp.nodes.items(.state)[node.idx];
    if (state != .group) {
        const count = self.displayedPortCount(node, direction);
        return if (slot < count) @intCast(slot) else null;
    }

    const bindings = switch (direction) {
        .input => state.group.input_bindings,
        .output => state.group.output_bindings,
    };
    var current_slot: usize = 0;
    for (bindings, 0..) |binding, port| {
        if (binding == null) continue;
        if (current_slot == slot) return @intCast(port);
        current_slot += 1;
    }
    return null;
}

/// Returns the row offset for a node's displayed DSP port.
fn displayedPortYOffset(
    self: *const Self,
    node: VisualNode.Index,
    footprint: Bound,
    direction: PortDirection,
    port: u8,
) ?i32 {
    const slot = self.displayedPortSlot(node, direction, port) orelse return null;
    return self.outletYOffset(footprint, self.displayedPortCount(node, direction), slot);
}

/// Returns whether a node is outside the current visual scope.
fn isHiddenNode(self: *const Self, node: VisualNode.Index) bool {
    return !self.isVisibleNode(node);
}

/// Returns whether a node belongs to the active visual scope.
fn isVisibleNode(self: *const Self, node: VisualNode.Index) bool {
    if (node.isNoop()) return false;
    switch (self.scope) {
        .root => {
            if (self.isGroupEndpoint(node)) return false;
            if (self.isGroup(node)) return true;
            return self.groupIndexForMember(node) == null;
        },
        .group => |group| {
            if (self.endpointGroup(node)) |owner|
                return owner.idx == group.idx;
            if (self.isGroup(node)) return false;
            const state = self.dsp.nodes.items(.state)[group.idx];
            if (state != .group) return false;
            for (state.group.members[0..state.group.member_count]) |member|
                if (member.idx == node.idx) return true;
            return false;
        },
    }
}

/// Finds the group containing a member, if any.
pub fn groupIndexForMember(self: *const Self, member: VisualNode.Index) ?VisualNode.Index {
    for (self.dsp.nodes.items(.state), 0..) |state, index| {
        if (state != .group) continue;
        for (state.group.members[0..state.group.member_count]) |candidate|
            if (candidate.idx == member.idx)
                return .{ .idx = index };
    }
    return null;
}

/// Adds one visual node and reserves the cells covered by its footprint.
pub fn addNode(
    self: *Self,
    gpa: std.mem.Allocator,
    node: DSP.Node.Index,
    position: Position,
) !void {
    try self.nodes.append(gpa, .{
        .dsp_node = node,
        .position = position,
    });

    // Hidden nodes remain in the index-aligned visual array, but do not take
    // up layout space in this scope. Group wrappers and endpoints are also
    // positioned by the enclosing layout and are checked during the complete
    // occupancy rebuild.
    if (!node.isNoop() and
        (self.isHiddenNode(node) or self.isGroup(node) or self.isGroupEndpoint(node))) return;

    const footprint = if (node.isNoop()) null else self.nodeFootprint(node);
    if (footprint) |bounds| {
        for (0..bounds.width) |dx| {
            for (0..bounds.height) |dy| {
                const occupied = Position{
                    .x = bounds.x + @as(i32, @intCast(dx)),
                    .y = bounds.y + @as(i32, @intCast(dy)),
                };
                if (self.occupied.get(occupied) != null) {
                    _ = self.nodes.pop();
                    return error.InvalidVisualNodeLayout;
                }
            }
        }
        self.occupied.ensureUnusedCapacity(gpa, bounds.width * bounds.height) catch |err| {
            _ = self.nodes.pop();
            return err;
        };
    }

    if (footprint) |bounds| {
        for (0..bounds.width) |dx| {
            for (0..bounds.height) |dy| {
                const occupied = Position{
                    .x = bounds.x + @as(i32, @intCast(dx)),
                    .y = bounds.y + @as(i32, @intCast(dy)),
                };
                self.occupied.putAssumeCapacityNoClobber(occupied, node);
            }
        }
    }
}

/// Clears visual nodes and derived routing state while retaining the viewport.
pub fn reset(self: *Self, gpa: std.mem.Allocator) void {
    self.clearPaths(gpa);
    self.nodes.clearRetainingCapacity();
    self.occupied.clearRetainingCapacity();
    self.path_occupied.clearRetainingCapacity();
    self.clearSelection();
    self.selected_node_drag_active = false;
    self.dragged_node_count = 0;
    self.graph_north_west = .{ .x = 0, .y = 0 };
    self.graph_south_east = .{ .x = 0, .y = 0 };
}

/// Returns the selected node when the selection contains exactly one node.
pub fn singleSelectedNode(self: *const Self) ?VisualNode.Index {
    if (self.selected_count != 1) return null;
    return self.selected_nodes[0];
}

/// Clears every selected node.
pub fn clearSelection(self: *Self) void {
    self.selected_count = 0;
}

/// Captures the current selection as one drag transaction.
pub fn beginSelectedNodeDrag(self: *Self) bool {
    if (self.selected_count == 0) return false;

    self.dragged_node_count = self.selected_count;
    for (self.selected_nodes[0..self.selected_count], 0..) |node, index| {
        self.dragged_nodes[index] = node;
        self.drag_origin_positions[index] = self.nodePosition(node);
    }
    self.selected_node_drag_active = true;
    return true;
}

/// Moves the captured selection for preview without checking node occupancy.
pub fn previewSelectedNodeDrag(self: *Self, delta: Position) bool {
    if (!self.selected_node_drag_active) return false;

    var positions: [max_selected_nodes]Position = undefined;
    for (self.dragged_nodes[0..self.dragged_node_count], 0..) |_, index| {
        const origin = self.drag_origin_positions[index];
        const x = @as(i64, origin.x) + delta.x;
        const y = @as(i64, origin.y) + delta.y;
        if (x < std.math.minInt(i32) + 2 or y < std.math.minInt(i32) + 1 or
            x > std.math.maxInt(i32) - 32 or y > std.math.maxInt(i32) - 32)
            return false;
        positions[index] = .{ .x = @intCast(x), .y = @intCast(y) };
    }

    for (self.dragged_nodes[0..self.dragged_node_count], 0..) |node, index|
        self.nodes.items(.position)[node.idx] = positions[index];
    self.updateGraphBounds();
    return true;
}

/// Validates a selection drag, restoring its original positions on collision.
pub fn finishSelectedNodeDrag(self: *Self, gpa: std.mem.Allocator) !bool {
    if (!self.selected_node_drag_active) return false;

    var changed = false;
    for (self.dragged_nodes[0..self.dragged_node_count], 0..) |node, index|
        changed = changed or !std.meta.eql(self.nodePosition(node), self.drag_origin_positions[index]);

    if (!changed) {
        self.selected_node_drag_active = false;
        self.dragged_node_count = 0;
        return true;
    }

    if (try self.rebuildOccupancy(gpa)) {
        self.selected_node_drag_active = false;
        self.dragged_node_count = 0;
        return true;
    }

    for (self.dragged_nodes[0..self.dragged_node_count], 0..) |node, index|
        self.nodes.items(.position)[node.idx] = self.drag_origin_positions[index];
    self.updateGraphBounds();
    const restored = try self.rebuildOccupancy(gpa);
    assert(restored);
    self.selected_node_drag_active = false;
    self.dragged_node_count = 0;
    return false;
}

/// Returns whether a selection drag is currently previewing node positions.
pub fn isSelectedNodeDragActive(self: *const Self) bool {
    return self.selected_node_drag_active;
}

/// Returns whether a node is currently selected.
pub fn isSelected(self: *const Self, node: VisualNode.Index) bool {
    for (self.selected_nodes[0..self.selected_count]) |selected|
        if (selected.idx == node.idx) return true;
    return false;
}

/// Selects one node, preserving the editor's single-click behavior.
pub fn selectSingle(self: *Self, node: ?VisualNode.Index) void {
    self.clearSelection();
    if (node) |value| {
        if (!value.isNoop()) {
            self.selected_nodes[0] = value;
            self.selected_count = 1;
        }
    }
}

/// Adds or removes a node from the selection while keeping the output node
/// out of multi-selections.
pub fn toggleSelection(self: *Self, node: VisualNode.Index) void {
    if (node.isNoop()) return;

    if (self.isSelected(node)) {
        var index: usize = 0;
        while (index < self.selected_count) : (index += 1) {
            if (self.selected_nodes[index].idx != node.idx) continue;
            const last = self.selected_count - 1;
            if (index != last)
                self.selected_nodes[index] = self.selected_nodes[last];
            self.selected_count -= 1;
            return;
        }
    }

    const is_output = std.meta.activeTag(self.dsp.nodes.items(.state)[node.idx]) == .output;
    if (is_output) {
        self.selectSingle(node);
        return;
    }

    if (self.selected_count == 1) {
        const selected = self.selected_nodes[0];
        if (std.meta.activeTag(self.dsp.nodes.items(.state)[selected.idx]) == .output)
            self.clearSelection();
    }
    if (self.selected_count >= self.selected_nodes.len) return;
    self.selected_nodes[self.selected_count] = node;
    self.selected_count += 1;
}

/// Selects nodes whose footprints intersect the inclusive world-space drag
/// rectangle, excluding the output node when other nodes are selected.
pub fn selectRectangle(self: *Self, anchor: Position, endpoint: Position) void {
    self.clearSelection();

    const left = @as(i64, @min(anchor.x, endpoint.x));
    const top = @as(i64, @min(anchor.y, endpoint.y));
    const right = @as(i64, @max(anchor.x, endpoint.x)) + 1;
    const bottom = @as(i64, @max(anchor.y, endpoint.y)) + 1;
    var output: ?VisualNode.Index = null;

    for (self.nodes.items(.dsp_node), 0..) |node, node_index| {
        if (node.isNoop() or self.isHiddenNode(.{ .idx = node_index })) continue;
        const visual_node = VisualNode.Index{ .idx = node_index };
        const footprint = self.nodeFootprint(visual_node);
        const intersects = @as(i64, footprint.x) < right and
            @as(i64, footprint.x) + @as(i64, footprint.width) > left and
            @as(i64, footprint.y) < bottom and
            @as(i64, footprint.y) + @as(i64, footprint.height) > top;
        if (!intersects) continue;

        if (std.meta.activeTag(self.dsp.nodes.items(.state)[node_index]) == .output) {
            output = visual_node;
            continue;
        }
        if (self.selected_count < self.selected_nodes.len) {
            self.selected_nodes[self.selected_count] = visual_node;
            self.selected_count += 1;
        }
    }

    if (self.selected_count == 0)
        if (output) |node|
            self.selectSingle(node);
}

/// Move one visual node and rebuild the cells used by routing.
/// Returns false when the candidate position collides with the graph layout.
pub fn moveNode(
    self: *Self,
    gpa: std.mem.Allocator,
    node: VisualNode.Index,
    position: Position,
) !bool {
    const previous = self.nodePosition(node);
    if (std.meta.eql(previous, position)) return false;

    self.nodes.items(.position)[node.idx] = position;
    self.updateGraphBounds();
    if (try self.rebuildOccupancy(gpa)) return true;

    self.nodes.items(.position)[node.idx] = previous;
    self.updateGraphBounds();
    _ = try self.rebuildOccupancy(gpa);
    return false;
}

/// Moves every selected node by one shared delta and rolls back atomically if
/// the selection collides with another node or leaves the integer space.
pub fn moveSelectedNodes(self: *Self, gpa: std.mem.Allocator, delta: Position) !bool {
    if (self.selected_count == 0 or (delta.x == 0 and delta.y == 0)) return false;

    const moving = self.selected_nodes[0..self.selected_count];

    var previous: [max_selected_nodes]Position = undefined;
    for (moving, 0..) |node, index|
        previous[index] = self.nodePosition(node);

    for (moving, 0..) |node, index| {
        const x = @addWithOverflow(previous[index].x, delta.x);
        const y = @addWithOverflow(previous[index].y, delta.y);
        if (x[1] != 0 or y[1] != 0) return false;
        self.nodes.items(.position)[node.idx] = .{
            .x = x[0],
            .y = y[0],
        };
    }

    self.updateGraphBounds();
    if (try self.rebuildOccupancy(gpa)) return true;

    for (moving, 0..) |node, index|
        self.nodes.items(.position)[node.idx] = previous[index];
    self.updateGraphBounds();
    _ = try self.rebuildOccupancy(gpa);
    return false;
}

/// Recalculate the finite routing rectangle around the complete graph.
pub fn updateGraphBounds(self: *Self) void {
    var north_west = Position{
        .x = std.math.maxInt(i32),
        .y = std.math.maxInt(i32),
    };
    var south_east = Position{
        .x = std.math.minInt(i32),
        .y = std.math.minInt(i32),
    };
    var found_node = false;

    for (self.nodes.items(.dsp_node), 0..) |node, node_index| {
        if (node.isNoop() or self.isHiddenNode(.{ .idx = node_index })) continue;
        const position = self.nodes.items(.position)[node_index];
        north_west.x = @min(north_west.x, position.x);
        north_west.y = @min(north_west.y, position.y);
        south_east.x = @max(south_east.x, position.x);
        south_east.y = @max(south_east.y, position.y);
        found_node = true;
    }

    if (!found_node) {
        self.graph_north_west = .{ .x = 0, .y = 0 };
        self.graph_south_east = .{ .x = 0, .y = 0 };
        return;
    }

    self.graph_north_west = north_west;
    self.graph_south_east = south_east;
}

/// Return the routing rectangle expanded by one graph width and height.
fn searchBound(self: *Self) SearchBound {
    const graph_width = @as(i64, self.graph_south_east.x) -
        @as(i64, self.graph_north_west.x) + 1;
    const graph_height = @as(i64, self.graph_south_east.y) -
        @as(i64, self.graph_north_west.y) + 1;
    return .{
        .left = @as(i64, self.graph_north_west.x) - graph_width,
        .top = @as(i64, self.graph_north_west.y) - graph_height,
        .right = @as(i64, self.graph_south_east.x) + graph_width,
        .bottom = @as(i64, self.graph_south_east.y) + graph_height,
    };
}

fn searchBoundFor(self: *Self, from: Position, to: Position) SearchBound {
    const north_west = Position{
        .x = @min(self.graph_north_west.x, @min(from.x, to.x)),
        .y = @min(self.graph_north_west.y, @min(from.y, to.y)),
    };
    const south_east = Position{
        .x = @max(self.graph_south_east.x, @max(from.x, to.x)),
        .y = @max(self.graph_south_east.y, @max(from.y, to.y)),
    };
    const width = @as(i64, south_east.x) - @as(i64, north_west.x) + 1;
    const height = @as(i64, south_east.y) - @as(i64, north_west.y) + 1;
    return .{
        .left = @as(i64, north_west.x) - width,
        .top = @as(i64, north_west.y) - height,
        .right = @as(i64, south_east.x) + width,
        .bottom = @as(i64, south_east.y) + height,
    };
}

pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    self.clearPaths(gpa);
    self.nodes.deinit(gpa);
    self.occupied.deinit(gpa);
    self.path_occupied.deinit(gpa);
    self.astar.deinit(gpa);
}

/// Removes a visual node and rebuilds the spatial and routing state.
pub fn remove(self: *Self, gpa: std.mem.Allocator, node: VisualNode.Index) !void {
    if (self.selected_node_drag_active) {
        for (self.dragged_nodes[0..self.dragged_node_count], 0..) |dragged, index|
            self.nodes.items(.position)[dragged.idx] = self.drag_origin_positions[index];
        self.selected_node_drag_active = false;
        self.dragged_node_count = 0;
        self.updateGraphBounds();
    }

    self.clearPaths(gpa);
    self.path_occupied.clearRetainingCapacity();

    var selected_index: usize = 0;
    while (selected_index < self.selected_count) {
        const selected = self.selected_nodes[selected_index];
        if (selected.idx == node.idx) {
            const last_selected = self.selected_count - 1;
            if (selected_index != last_selected)
                self.selected_nodes[selected_index] = self.selected_nodes[last_selected];
            self.selected_count -= 1;
            continue;
        }
        if (selected.idx == self.nodes.len - 1 and node.idx != self.nodes.len - 1)
            self.selected_nodes[selected_index] = .{ .idx = node.idx };
        selected_index += 1;
    }

    const last_index = self.nodes.len - 1;
    self.nodes.swapRemove(node.idx);
    if (node.idx != last_index)
        self.nodes.items(.dsp_node)[node.idx] = .{ .idx = node.idx };
    self.updateGraphBounds();

    _ = try self.rebuildOccupancy(gpa);

    try self.computePaths(gpa);
}

pub fn write(
    self: *Self,
    gpa: std.mem.Allocator,
    display: *Display,
    draw_paths: bool,
) !void {
    // Draw groups before ordinary nodes so their selection outline remains stable.
    for (self.nodes.items(.dsp_node), 0..) |node, index| {
        if (node.isNoop() or !self.isGroup(.{ .idx = index }) or
            self.isHiddenNode(.{ .idx = index })) continue;
        if (draw_paths) {
            try self.writeNode(gpa, display, node);
        } else {
            try self.writeNodeBody(gpa, display, node, .black);
        }
    }
    for (self.nodes.items(.dsp_node), 0..) |node, index| {
        if (node.isNoop() or self.isGroup(.{ .idx = index }) or
            self.isHiddenNode(.{ .idx = index })) continue;
        if (draw_paths) {
            try self.writeNode(gpa, display, node);
        } else {
            try self.writeNodeBody(gpa, display, node, .black);
        }
    }

    for (self.selected_nodes[0..self.selected_count]) |node| {
        if (!node.isNoop() and !self.isHiddenNode(node)) {
            try self.writeNodeBody(gpa, display, node, .ebony);
            if (draw_paths)
                try self.writeOutgoingPaths(gpa, display, node, .ebony);
        }
    }

    if (draw_paths)
        try self.writeOutputTail(gpa, display);
}

/// Draws the transient amber marquee used to select nodes in empty space.
pub fn writeSelectionMarquee(
    self: *Self,
    gpa: std.mem.Allocator,
    display: *Display,
    anchor: Position,
    endpoint: Position,
) !void {
    const left = @as(i64, @min(anchor.x, endpoint.x)) - self.viewport.x;
    const top = @as(i64, @min(anchor.y, endpoint.y)) - self.viewport.y;
    const right = @as(i64, @max(anchor.x, endpoint.x)) - self.viewport.x;
    const bottom = @as(i64, @max(anchor.y, endpoint.y)) - self.viewport.y;

    var y = top;
    while (y <= bottom) : (y += 1) {
        var x = left;
        while (x <= right) : (x += 1) {
            if (x != left and x != right and y != top and y != bottom) continue;
            if (x < 0 or y < 0 or
                x >= self.viewport.width or y >= self.viewport.height)
                continue;
            try display.write(gpa, "+", @intCast(x), @intCast(y), .amber, .mine_shaft);
        }
    }
}

/// Draws the fixed external-audio marker beyond the configured output node.
fn writeOutputTail(self: *Self, gpa: std.mem.Allocator, display: *Display) !void {
    if (self.scope != .root) return;
    const output = self.dsp.output;
    if (output.isNoop()) return;

    const footprint = self.nodeFootprint(output);
    const state = self.dsp.nodes.items(.state)[output.idx];
    const metadata = DSP.node_metadata.get(std.meta.activeTag(state));
    const output_y = @as(i64, footprint.y) + @as(i64, @intCast(
        self.outletYOffset(footprint, metadata.output_count, 0),
    )) - @as(i64, self.viewport.y);
    const tail_start_x = @as(i64, footprint.x) + @as(i64, @intCast(footprint.width)) -
        @as(i64, self.viewport.x);
    const color = self.nodeColor(output);
    const line_glyph = [_]u8{0xC4};
    const marker = [_]u8{ 0x11, 0xF0 };

    // Keep the tail aligned with the output port while clipping each cell.
    for (0..3) |offset| {
        const x = tail_start_x + @as(i64, @intCast(offset));
        if (x >= 0 and output_y >= 0 and
            x <= std.math.maxInt(u32) and output_y <= std.math.maxInt(u32))
            try display.write(gpa, &line_glyph, @intCast(x), @intCast(output_y), .black, color);
    }
    for (marker, 0..) |glyph, offset| {
        const x = tail_start_x + 3 + @as(i64, @intCast(offset));
        const glyph_bytes = [_]u8{glyph};
        if (x >= 0 and output_y >= 0 and
            x <= std.math.maxInt(u32) and output_y <= std.math.maxInt(u32))
            try display.write(gpa, &glyph_bytes, @intCast(x), @intCast(output_y), .black, color);
    }
}

/// Returns whether a node can reach the DSP graph's configured output.
fn isOutputReachable(self: *Self, node: VisualNode.Index) bool {
    return self.nodes.items(.output_reachable)[node.idx];
}

pub fn writeNode(
    self: *Self,
    gpa: std.mem.Allocator,
    display: *Display,
    node: VisualNode.Index,
) !void {
    try self.writePaths(gpa, display, node, .black);
    try self.writeNodeBody(gpa, display, node, .black);
}

fn writeNodeBody(
    self: *Self,
    gpa: std.mem.Allocator,
    display: *Display,
    node: VisualNode.Index,
    background: Display.Color,
) !void {
    if (self.isHiddenNode(node)) return;
    const footprint = self.nodeFootprint(node);
    if (!self.intersectsViewport(footprint)) return;

    const x: i64 = @as(i64, footprint.x) - @as(i64, self.viewport.x);
    const y: i64 = @as(i64, footprint.y) - @as(i64, self.viewport.y);
    const state = self.dsp.nodes.items(.state)[node.idx];
    const metadata = DSP.node_metadata.get(std.meta.activeTag(state));
    const name = self.dsp.nodes.items(.name)[node.idx];
    const content_width = footprint.width - 2;
    const node_color = self.nodeColor(node);

    for (0..footprint.width) |dx| {
        for (0..footprint.height) |dy| {
            const cell_x = x + @as(i64, @intCast(dx));
            const cell_y = y + @as(i64, @intCast(dy));
            if (cell_x >= 0 and cell_y >= 0)
                try display.write(gpa, " ", @intCast(cell_x), @intCast(cell_y), background, .black);
        }
    }

    // Draw the border cell by cell so every edge is clipped independently.
    for (0..footprint.width) |dx| {
        const local_x = @as(i64, @intCast(dx));
        const top_glyph = [_]u8{if (dx == 0) 0xDA else if (dx + 1 == footprint.width) 0xBF else 0xC4};
        const bottom_glyph = [_]u8{if (dx == 0) 0xC0 else if (dx + 1 == footprint.width) 0xD9 else 0xC4};
        const top_x = x + local_x;
        const bottom_y = y + @as(i64, @intCast(footprint.height - 1));
        if (top_x >= 0 and y >= 0)
            try display.write(gpa, &top_glyph, @intCast(top_x), @intCast(y), background, node_color);
        if (top_x >= 0 and bottom_y >= 0)
            try display.write(gpa, &bottom_glyph, @intCast(top_x), @intCast(bottom_y), background, node_color);
    }
    for (1..footprint.height - 1) |dy| {
        const local_y = @as(i64, @intCast(dy));
        const glyph = [_]u8{0xB3};
        const left_y = y + local_y;
        const right_x = x + @as(i64, @intCast(footprint.width - 1));
        if (x >= 0 and left_y >= 0)
            try display.write(gpa, &glyph, @intCast(x), @intCast(left_y), background, node_color);
        if (right_x >= 0 and left_y >= 0)
            try display.write(gpa, &glyph, @intCast(right_x), @intCast(left_y), background, node_color);
    }

    // Keep one header cell available for the parameter-source outlet.
    const displayed_metadata_name = metadata.short_name;
    const metadata_name_x = x + 1;
    for (displayed_metadata_name, 0..) |character, index| {
        const glyph = [_]u8{character};
        const character_x = metadata_name_x + @as(i64, @intCast(index));
        if (character_x >= 0 and y >= 0)
            try display.write(gpa, &glyph, @intCast(character_x), @intCast(y), background, .white);
    }

    const voice_count = self.dsp.polyphonyForDisplay(.{ .idx = node.idx });
    if (voice_count > 1) {
        const voice_glyph = [_]u8{@intCast('0' + voice_count)};
        const marker_offset = footprint.width - @as(u32, if (self.isGroup(node)) 3 else 2);
        const marker_x = x + @as(i64, @intCast(marker_offset));
        if (marker_x >= 0 and y >= 0)
            try display.write(gpa, &voice_glyph, @intCast(marker_x), @intCast(y), background, .white);
    }

    const displayed_name = name[0..@min(name.len, content_width)];
    const name_x = x + 1 + @as(i64, @intCast((content_width - displayed_name.len) / 2));
    const name_y = y + @as(i64, @intCast((footprint.height - 1) / 2));
    for (displayed_name, 0..) |character, index| {
        const glyph = [_]u8{character};
        const character_x = name_x + @as(i64, @intCast(index));
        if (character_x >= 0 and name_y >= 0)
            try display.write(gpa, &glyph, @intCast(character_x), @intCast(name_y), background, .white);
    }

    if (self.isGroup(node)) {
        const marker = [_]u8{'+'};
        const marker_x = x + @as(i64, @intCast(footprint.width - 2));
        if (marker_x >= 0 and y >= 0)
            try display.write(gpa, &marker, @intCast(marker_x), @intCast(y), background, .white);
    }

    const outlet = [_]u8{0x09};
    const inputs = self.dsp.nodes.items(.inputs)[node.idx];
    for (0..DSP.max_outlets) |slot| {
        const port = self.displayedPortAtSlot(node, .input, slot) orelse continue;
        const outlet_y = y + @as(i64, @intCast(self.outletYOffset(
            footprint,
            self.displayedPortCount(node, .input),
            slot,
        )));
        const color = if (!self.isOutputReachable(node) or inputs[port].isNoop())
            Display.Color.gray
        else
            Display.Color.green;
        if (x >= 0 and outlet_y >= 0)
            try display.write(gpa, &outlet, @intCast(x), @intCast(outlet_y), background, color);
    }

    for (0..DSP.max_outlets) |slot| {
        const port = self.displayedPortAtSlot(node, .output, slot) orelse continue;
        const outlet_y = y + @as(i64, @intCast(self.outletYOffset(
            footprint,
            self.displayedPortCount(node, .output),
            slot,
        )));
        const color = if (self.isOutputReachable(node) and
            self.dsp.nodes.items(.output_connected)[node.idx][port])
            Display.Color.green
        else
            Display.Color.gray;
        const outlet_x = x + @as(i64, @intCast(footprint.width - 1));
        if (outlet_x >= 0 and outlet_y >= 0)
            try display.write(gpa, &outlet, @intCast(outlet_x), @intCast(outlet_y), background, color);
    }

    if (metadata.can_link_parameters) {
        const links = self.dsp.nodes.items(.parameter_link)[node.idx];
        const source_color = if (links.source != null)
            Display.Color.curious_blue
        else
            Display.Color.gray;
        const target_color = if (links.target != null)
            Display.Color.curious_blue
        else
            Display.Color.gray;
        const source_x = x + @as(i64, @intCast(self.parameterSourceX(node) - footprint.x));
        const target_x = x + @as(i64, @intCast(self.parameterTargetX(node) - footprint.x));
        const top_outlet = [_]u8{0x09};
        const bottom_outlet = [_]u8{0x09};
        if (source_x >= 0 and y >= 0)
            try display.write(gpa, &top_outlet, @intCast(source_x), @intCast(y), background, source_color);
        const bottom_y = y + @as(i64, @intCast(footprint.height - 1));
        if (target_x >= 0 and bottom_y >= 0)
            try display.write(
                gpa,
                &bottom_outlet,
                @intCast(target_x),
                @intCast(bottom_y),
                background,
                target_color,
            );
    }
}

fn writePaths(
    self: *Self,
    gpa: std.mem.Allocator,
    display: *Display,
    node: VisualNode.Index,
    background: Display.Color,
) !void {
    for (self.nodes.items(.paths)[node.idx]) |maybe_path|
        if (maybe_path) |path|
            try self.writePath(gpa, display, path, background);
    if (self.nodes.items(.parameter_path)[node.idx]) |path|
        try self.writePath(gpa, display, path, background);
}

fn writeOutgoingPaths(
    self: *Self,
    gpa: std.mem.Allocator,
    display: *Display,
    source: VisualNode.Index,
    background: Display.Color,
) !void {
    for (self.nodes.items(.paths)) |paths| {
        for (paths) |maybe_path| {
            if (maybe_path) |path| {
                if (path.source.idx == source.idx)
                    try self.writePath(gpa, display, path, background);
            }
        }
    }
    for (self.nodes.items(.parameter_path)) |maybe_path| {
        if (maybe_path) |path|
            if (path.source.idx == source.idx)
                try self.writePath(gpa, display, path, background);
    }
}

fn writePath(
    self: *Self,
    gpa: std.mem.Allocator,
    display: *Display,
    path: Path,
    background: Display.Color,
) !void {
    if (path.points.len == 0) return;

    const link_color = path.color;

    // Draw straight segments first. Point glyphs below then remain intact.
    for (path.points[0 .. path.points.len - 1], 0..) |from, index| {
        const to = path.points[index + 1];
        const step = Position{
            .x = std.math.sign(to.position.x - from.position.x),
            .y = std.math.sign(to.position.y - from.position.y),
        };
        var point = from.position;
        while (true) {
            point.x += step.x;
            point.y += step.y;
            if (point.x == to.position.x and point.y == to.position.y) break;
            const screen_x = @as(i64, point.x) - @as(i64, self.viewport.x);
            const screen_y = @as(i64, point.y) - @as(i64, self.viewport.y);
            const glyph = [_]u8{if (step.x != 0) 0xC4 else 0xB3};
            if (screen_x >= 0 and screen_y >= 0)
                try display.write(gpa, &glyph, @intCast(screen_x), @intCast(screen_y), background, link_color);
        }
    }

    for (path.points, 0..) |point, index| {
        const directions = if (point.directions != 0)
            point.directions
        else
            pathPointDirections(path, index);
        const symbol = glyphForDirections(directions);
        const screen_x = @as(i64, point.position.x) - @as(i64, self.viewport.x);
        const screen_y = @as(i64, point.position.y) - @as(i64, self.viewport.y);
        const glyph = [_]u8{symbol};
        if (screen_x >= 0 and screen_y >= 0)
            try display.write(gpa, &glyph, @intCast(screen_x), @intCast(screen_y), background, link_color);
    }

    const final_point = path.points[path.points.len - 1].position;
    // Horizontal audio arrows sit just beyond the destination anchor. A
    // vertical parameter arrow belongs on the vertical route itself; using
    // the horizontal offset would draw it beside the route.
    const arrow_x_offset: i64 = switch (path.end_direction) {
        Direction.left => -1,
        Direction.right => 1,
        else => 0,
    };
    const arrow_x = @as(i64, final_point.x) - @as(i64, self.viewport.x) + arrow_x_offset;
    const arrow_y = @as(i64, final_point.y) - @as(i64, self.viewport.y);
    const arrow = [_]u8{path.arrow};
    if (arrow_x >= 0 and arrow_y >= 0)
        try display.write(gpa, &arrow, @intCast(arrow_x), @intCast(arrow_y), background, link_color);
}

/// Draws a temporary path without making it part of the persistent graph.
pub fn writePreviewPath(
    self: *Self,
    gpa: std.mem.Allocator,
    display: *Display,
    path: Path,
) !void {
    try self.writePath(gpa, display, path, .black);
}

fn pathPointDirections(path: Path, index: usize) u4 {
    var directions: u4 = 0;
    if (index > 0)
        directions |= directionForStep(.{
            .x = path.points[index - 1].position.x - path.points[index].position.x,
            .y = path.points[index - 1].position.y - path.points[index].position.y,
        });
    if (index + 1 < path.points.len)
        directions |= directionForStep(.{
            .x = path.points[index + 1].position.x - path.points[index].position.x,
            .y = path.points[index + 1].position.y - path.points[index].position.y,
        });
    return if (directions == 0) Direction.right else directions;
}

fn glyphForDirections(directions: u4) u8 {
    return switch (directions) {
        Direction.left, Direction.right, Direction.left | Direction.right => 0xC4,
        Direction.up, Direction.down, Direction.up | Direction.down => 0xB3,
        Direction.left | Direction.down => 0xBF,
        Direction.right | Direction.down => 0xDA,
        Direction.left | Direction.up => 0xD9,
        Direction.right | Direction.up => 0xC0,
        Direction.left | Direction.right | Direction.down => 0xC2,
        Direction.left | Direction.right | Direction.up => 0xC1,
        Direction.left | Direction.up | Direction.down => 0xB4,
        Direction.right | Direction.up | Direction.down => 0xC3,
        Direction.left | Direction.right | Direction.up | Direction.down => 0xC5,
        else => @panic("Path point has no valid directions"),
    };
}

fn intersectsViewport(self: *Self, footprint: Bound) bool {
    const left = @as(i64, footprint.x);
    const top = @as(i64, footprint.y);
    const right = left + @as(i64, footprint.width);
    const bottom = top + @as(i64, footprint.height);
    const viewport_left = @as(i64, self.viewport.x);
    const viewport_top = @as(i64, self.viewport.y);
    const viewport_right = viewport_left + @as(i64, self.viewport.width);
    const viewport_bottom = viewport_top + @as(i64, self.viewport.height);

    return left < viewport_right and
        top < viewport_bottom and
        right > viewport_left and
        bottom > viewport_top;
}

pub fn nodeFootprint(self: *Self, node: VisualNode.Index) Bound {
    const position = self.nodes.items(.position)[node.idx];
    return self.nodeFootprintAt(node, position);
}

/// Returns the world-space x-coordinate of the top `src` outlet.
fn parameterSourceX(self: *Self, node: VisualNode.Index) i32 {
    const footprint = self.nodeFootprint(node);
    return footprint.x + @as(i32, @intCast(footprint.width / 2));
}

/// Returns the world-space x-coordinate of the bottom `dst` outlet.
fn parameterTargetX(self: *Self, node: VisualNode.Index) i32 {
    const footprint = self.nodeFootprint(node);
    return footprint.x + @as(i32, @intCast(footprint.width / 2));
}

/// Returns the footprint a node would occupy at a candidate position.
fn nodeFootprintAt(self: *Self, node: VisualNode.Index, position: Position) Bound {
    const state = self.dsp.nodes.items(.state)[node.idx];
    const metadata = DSP.node_metadata.get(std.meta.activeTag(state));

    const outlet_count = @max(
        @max(
            self.displayedPortCount(node, .input),
            self.displayedPortCount(node, .output),
        ),
        @as(u8, 1),
    );
    const label_width = self.dsp.nodes.items(.name)[node.idx].len + 4;
    const minimum_width_for_parameter_label = if (metadata.can_link_parameters)
        (metadata.short_name.len + 1) * 2
    else
        0;
    const minimum_width_for_header = metadata.short_name.len + 4 +
        @as(usize, @intFromBool(self.isGroup(node)));
    const width = @max(
        @max(@min(label_width, @as(usize, 16)), minimum_width_for_parameter_label),
        minimum_width_for_header,
    );

    return .{
        .x = position.x,
        .y = position.y,
        .width = @intCast(width),
        .height = @as(u32, outlet_count) * 2 + 1,
    };
}

pub fn nodeColor(self: *Self, node: VisualNode.Index) Display.Color {
    const state = self.dsp.nodes.items(.state)[node.idx];
    if (!self.isOutputReachable(node)) return Display.Color.gray;
    return DSP.node_metadata.get(std.meta.activeTag(state)).color;
}

fn outletYOffset(_: *const Self, footprint: Bound, outlet_count: u8, port: usize) i32 {
    if (outlet_count == 1)
        return @intCast(footprint.height / 2);
    return 1 + @as(i32, @intCast(port * 2));
}

/// Return the node whose actual footprint contains a world-space position.
pub fn nodeAt(self: *Self, position: Position) ?VisualNode.Index {
    // Group members sit behind their enclosing group in the root view.
    for (self.nodes.items(.dsp_node), 0..) |node, node_index| {
        if (node.isNoop() or self.isGroup(.{ .idx = node_index }) or
            self.isHiddenNode(.{ .idx = node_index })) continue;

        const footprint = self.nodeFootprint(.{ .idx = node_index });
        const x = @as(i64, position.x);
        const y = @as(i64, position.y);
        const left = @as(i64, footprint.x);
        const top = @as(i64, footprint.y);
        const right = left + @as(i64, footprint.width);
        const bottom = top + @as(i64, footprint.height);
        if (x >= left and x < right and y >= top and y < bottom)
            return .{ .idx = node_index };
    }

    for (self.nodes.items(.dsp_node), 0..) |node, node_index| {
        if (node.isNoop() or !self.isGroup(.{ .idx = node_index }) or
            self.isHiddenNode(.{ .idx = node_index })) continue;
        const footprint = self.nodeFootprint(.{ .idx = node_index });
        const x = @as(i64, position.x);
        const y = @as(i64, position.y);
        if (x >= footprint.x and
            x < @as(i64, footprint.x) + @as(i64, footprint.width) and
            y >= footprint.y and
            y < @as(i64, footprint.y) + @as(i64, footprint.height))
            return .{ .idx = node_index };
    }

    return null;
}

/// Return the outlet glyph at a world-space position, if any.
pub fn outletAt(self: *Self, position: Position) ?Outlet {
    for (self.nodes.items(.dsp_node), 0..) |node, node_index| {
        if (node.isNoop() or self.isHiddenNode(.{ .idx = node_index })) continue;

        const visual_node = VisualNode.Index{ .idx = node_index };
        const footprint = self.nodeFootprint(visual_node);
        const state = self.dsp.nodes.items(.state)[node_index];
        const metadata = DSP.node_metadata.get(std.meta.activeTag(state));

        for (0..DSP.max_outlets) |slot| {
            const port = self.displayedPortAtSlot(visual_node, .input, slot) orelse continue;
            const y = footprint.y + self.outletYOffset(
                footprint,
                self.displayedPortCount(visual_node, .input),
                slot,
            );
            if (position.x == footprint.x and position.y == y)
                return .{
                    .node = visual_node,
                    .direction = .input,
                    .port = @intCast(port),
                    .anchor = .{ .x = footprint.x - 2, .y = y },
                };
        }

        for (0..DSP.max_outlets) |slot| {
            const port = self.displayedPortAtSlot(visual_node, .output, slot) orelse continue;
            const y = footprint.y + self.outletYOffset(
                footprint,
                self.displayedPortCount(visual_node, .output),
                slot,
            );
            if (position.x == footprint.x + @as(i32, @intCast(footprint.width - 1)) and
                position.y == y)
                return .{
                    .node = visual_node,
                    .direction = .output,
                    .port = @intCast(port),
                    .anchor = .{ .x = footprint.x + @as(i32, @intCast(footprint.width)), .y = y },
                };
        }

        if (metadata.can_link_parameters) {
            if (position.x == self.parameterSourceX(visual_node) and
                position.y == footprint.y)
                return .{
                    .node = visual_node,
                    .direction = .parameter_source,
                    .port = 0,
                    .anchor = .{ .x = self.parameterSourceX(visual_node), .y = footprint.y - 1 },
                };

            if (position.x == self.parameterTargetX(visual_node) and
                position.y == footprint.y + @as(i32, @intCast(footprint.height - 1)))
                return .{
                    .node = visual_node,
                    .direction = .parameter_target,
                    .port = 0,
                    .anchor = .{
                        .x = self.parameterTargetX(visual_node),
                        .y = footprint.y + @as(i32, @intCast(footprint.height)),
                    },
                };
        }
    }

    return null;
}

/// Return the node under a display cell, translating through the viewport.
pub fn nodeAtDisplayCell(self: *Self, cell_x: u32, cell_y: u32) ?VisualNode.Index {
    return self.nodeAt(self.worldPositionAtDisplayCell(cell_x, cell_y));
}

/// Rebuild all node, link-anchor, and routing-margin occupancy cells.
pub fn rebuildOccupancy(self: *Self, gpa: std.mem.Allocator) !bool {
    self.occupied.clearRetainingCapacity();

    for (self.nodes.items(.dsp_node), 0..) |node, node_index| {
        const visual_node = VisualNode.Index{ .idx = node_index };
        if (node.isNoop() or self.isHiddenNode(visual_node)) continue;

        const footprint = self.nodeFootprint(visual_node);
        for (0..footprint.width) |dx| {
            for (0..footprint.height) |dy| {
                const position = Position{
                    .x = footprint.x + @as(i32, @intCast(dx)),
                    .y = footprint.y + @as(i32, @intCast(dy)),
                };
                if (self.occupied.get(position) != null) return false;
                try self.occupied.put(gpa, position, node);
            }
        }
    }

    for (self.nodes.items(.dsp_node), 0..) |node, node_index| {
        const visual_node = VisualNode.Index{ .idx = node_index };
        if (node.isNoop() or self.isHiddenNode(visual_node)) continue;

        const footprint = self.nodeFootprint(visual_node);
        const state = self.dsp.nodes.items(.state)[node_index];
        const metadata = DSP.node_metadata.get(std.meta.activeTag(state));

        for (0..DSP.max_outlets) |slot| {
            _ = self.displayedPortAtSlot(visual_node, .input, slot) orelse continue;
            const y = footprint.y + self.outletYOffset(
                footprint,
                self.displayedPortCount(visual_node, .input),
                slot,
            );
            if (!try self.tryOccupyLinkAnchor(gpa, .{ .x = footprint.x - 2, .y = y }, node) or
                !try self.tryOccupyLinkAnchor(gpa, .{ .x = footprint.x - 1, .y = y }, node))
                return false;
        }

        for (0..DSP.max_outlets) |slot| {
            _ = self.displayedPortAtSlot(visual_node, .output, slot) orelse continue;
            if (!try self.tryOccupyLinkAnchor(gpa, .{
                .x = footprint.x + @as(i32, @intCast(footprint.width)),
                .y = footprint.y + self.outletYOffset(
                    footprint,
                    self.displayedPortCount(visual_node, .output),
                    slot,
                ),
            }, node)) return false;
        }

        if (metadata.can_link_parameters) {
            if (!try self.tryOccupyLinkAnchor(gpa, .{
                .x = self.parameterSourceX(visual_node),
                .y = footprint.y - 1,
            }, node)) return false;
            if (!try self.tryOccupyLinkAnchor(gpa, .{
                .x = self.parameterTargetX(visual_node),
                .y = footprint.y + @as(i32, @intCast(footprint.height)),
            }, node)) return false;
        }
    }

    try self.occupyNodeMargins(gpa);
    return true;
}

/// Reserves the cells used by link starts, arrows, and destination anchors.
/// Other links must route around these cells so they cannot overwrite ports.
pub fn occupyLinkAnchors(self: *Self, gpa: std.mem.Allocator) !void {
    for (self.nodes.items(.dsp_node), 0..) |node, node_index| {
        const visual_node = VisualNode.Index{ .idx = node_index };
        if (node.isNoop() or self.isHiddenNode(visual_node)) continue;

        const footprint = self.nodeFootprint(visual_node);
        const state = self.dsp.nodes.items(.state)[node_index];
        const metadata = DSP.node_metadata.get(std.meta.activeTag(state));

        for (0..DSP.max_outlets) |slot| {
            _ = self.displayedPortAtSlot(visual_node, .input, slot) orelse continue;
            const y = footprint.y + self.outletYOffset(
                footprint,
                self.displayedPortCount(visual_node, .input),
                slot,
            );
            try self.occupyLinkAnchor(gpa, .{
                .x = footprint.x - 2,
                .y = y,
            }, node);
            try self.occupyLinkAnchor(gpa, .{
                .x = footprint.x - 1,
                .y = y,
            }, node);
        }

        for (0..DSP.max_outlets) |slot| {
            _ = self.displayedPortAtSlot(visual_node, .output, slot) orelse continue;
            try self.occupyLinkAnchor(gpa, .{
                .x = footprint.x + @as(i32, @intCast(footprint.width)),
                .y = footprint.y + self.outletYOffset(
                    footprint,
                    self.displayedPortCount(visual_node, .output),
                    slot,
                ),
            }, node);
        }

        if (metadata.can_link_parameters) {
            try self.occupyLinkAnchor(gpa, .{
                .x = self.parameterSourceX(visual_node),
                .y = footprint.y - 1,
            }, node);
            try self.occupyLinkAnchor(gpa, .{
                .x = self.parameterTargetX(visual_node),
                .y = footprint.y + @as(i32, @intCast(footprint.height)),
            }, node);
        }
    }
}

/// Reserves one routing-clearance cell around every node footprint.
pub fn occupyNodeMargins(self: *Self, gpa: std.mem.Allocator) !void {
    for (self.nodes.items(.dsp_node), 0..) |node, node_index| {
        const visual_node = VisualNode.Index{ .idx = node_index };
        if (node.isNoop() or self.isHiddenNode(visual_node)) continue;

        const footprint = self.nodeFootprint(visual_node);
        const right = footprint.x + @as(i32, @intCast(footprint.width));
        const bottom = footprint.y + @as(i32, @intCast(footprint.height));

        var y = footprint.y - 1;
        while (y <= bottom) : (y += 1) {
            var x = footprint.x - 1;
            while (x <= right) : (x += 1) {
                const position = Position{ .x = x, .y = y };
                if (self.occupied.get(position) == null)
                    try self.occupied.put(gpa, position, node);
            }
        }
    }
}

fn occupyLinkAnchor(
    self: *Self,
    gpa: std.mem.Allocator,
    position: Position,
    node: VisualNode.Index,
) !void {
    std.debug.assert(self.occupied.get(position) == null);
    try self.occupied.put(gpa, position, node);
}

fn tryOccupyLinkAnchor(
    self: *Self,
    gpa: std.mem.Allocator,
    position: Position,
    node: VisualNode.Index,
) !bool {
    if (self.occupied.get(position) != null) return false;
    try self.occupied.put(gpa, position, node);
    return true;
}

pub const PathCriteria = struct {
    from: Position,
    to: Position,
    bound: SearchBound,
};

/// Release the allocated point list owned by this path.
pub fn deinitPath(path: Path, gpa: std.mem.Allocator) void {
    gpa.free(path.points);
}

/// Find a temporary route without adding it to persistent path occupancy.
pub fn previewPath(
    self: *Self,
    gpa: std.mem.Allocator,
    from: Position,
    to: Position,
) !?Path {
    self.updateGraphBounds();
    self.astar.reset();
    return try self.astar.search(gpa, self, .{
        .from = from,
        .to = to,
        .bound = self.searchBoundFor(from, to),
    });
}

/// Compute one path for every connected input in the visual graph.
pub fn computePaths(self: *Self, gpa: std.mem.Allocator) !void {
    self.computeOutputReachability();
    self.updateGraphBounds();
    const bound = self.searchBound();
    self.clearPaths(gpa);
    self.path_occupied.clearRetainingCapacity();

    const inputs = self.dsp.nodes.items(.inputs);
    for (inputs, 0..) |node_inputs, node_index| {
        const node = VisualNode.Index{ .idx = node_index };
        if (node.isNoop() or self.isHiddenNode(node)) continue;
        const state = self.dsp.nodes.items(.state)[node_index];
        const metadata = DSP.node_metadata.get(std.meta.activeTag(state));

        for (0..metadata.input_count) |input_port| {
            const connection = node_inputs[input_port];
            if (connection.isNoop() or self.isHiddenNode(connection.node)) continue;
            try self.computePathForInput(gpa, node, input_port, bound);
        }
    }

    for (self.dsp.nodes.items(.parameter_link), 0..) |link, node_index| {
        const target = VisualNode.Index{ .idx = node_index };
        if (self.isHiddenNode(target)) continue;
        if (link.source) |source| {
            if (self.isHiddenNode(source)) continue;
            try self.computePathForParameter(
                gpa,
                source,
                target,
                bound,
            );
        }
    }

    try self.addPathJunctions(gpa);
}

/// Rebuilds the reverse-reachability cache for the configured DSP output.
fn computeOutputReachability(self: *Self) void {
    const output_reachable = self.nodes.items(.output_reachable);
    @memset(output_reachable, false);

    output_reachable[self.dsp.output.idx] = true;

    // Repeatedly propagate reachability from destinations to their sources.
    // This converges for cycles as well as ordinary acyclic DSP graphs.
    var changed = true;
    while (changed) {
        changed = false;
        for (self.dsp.nodes.items(.inputs), 0..) |node_inputs, destination_idx| {
            if (!output_reachable[destination_idx]) continue;
            const destination_state = self.dsp.nodes.items(.state)[destination_idx];
            if (destination_state == .group) {
                for (destination_state.group.output_bindings) |binding| {
                    const child = binding orelse continue;
                    if (!output_reachable[child.node.idx]) {
                        output_reachable[child.node.idx] = true;
                        changed = true;
                    }
                }
            }
            for (node_inputs) |connection| {
                if (connection.isNoop()) continue;
                if (output_reachable[connection.node.idx]) continue;
                output_reachable[connection.node.idx] = true;
                changed = true;
            }
        }

        for (self.dsp.nodes.items(.state), 0..) |state, group_index| {
            if (state != .group or !output_reachable[group_index]) continue;
            for (self.dsp.nodes.items(.inputs)[group_index]) |connection| {
                if (connection.isNoop()) continue;
                if (!output_reachable[connection.node.idx]) {
                    output_reachable[connection.node.idx] = true;
                    changed = true;
                }
            }
        }
    }
}

fn computePathForInput(
    self: *Self,
    gpa: std.mem.Allocator,
    destination: VisualNode.Index,
    input_port: usize,
    bound: SearchBound,
) !void {
    const connection = self.dsp.nodes.items(.inputs)[destination.idx][input_port];
    if (connection.isNoop()) return;

    const source = connection.node;
    const from_footprint = self.nodeFootprint(source);
    const to_footprint = self.nodeFootprint(destination);
    const source_y = self.displayedPortYOffset(
        source,
        from_footprint,
        .output,
        connection.output_port,
    ) orelse return;
    const destination_y = self.displayedPortYOffset(
        destination,
        to_footprint,
        .input,
        @intCast(input_port),
    ) orelse return;
    const from = Position{
        .x = from_footprint.x + @as(i32, @intCast(from_footprint.width)),
        .y = from_footprint.y + source_y,
    };
    const to = Position{
        .x = to_footprint.x - 2,
        .y = to_footprint.y + destination_y,
    };

    self.astar.reset();
    if (try self.astar.search(gpa, self, .{
        .from = from,
        .to = to,
        .bound = bound,
    })) |path| {
        var colored_path = path;
        colored_path.source = source;
        colored_path.color = self.nodeColor(source);
        try self.occupyPath(gpa, colored_path);
        self.nodes.items(.paths)[destination.idx][input_port] = colored_path;
    }
}

/// Computes the routed path from a parameter source's `dst` outlet to a
/// target node's `src` outlet.
fn computePathForParameter(
    self: *Self,
    gpa: std.mem.Allocator,
    source: VisualNode.Index,
    target: VisualNode.Index,
    bound: SearchBound,
) !void {
    const source_state = self.dsp.nodes.items(.state)[source.idx];
    if (!DSP.node_metadata.get(std.meta.activeTag(source_state)).can_link_parameters)
        return;

    const source_footprint = self.nodeFootprint(source);
    const target_footprint = self.nodeFootprint(target);
    const from = Position{
        .x = self.parameterTargetX(source),
        .y = source_footprint.y + @as(i32, @intCast(source_footprint.height)),
    };
    const to = Position{
        .x = self.parameterSourceX(target),
        .y = target_footprint.y - 1,
    };

    self.astar.reset();
    if (try self.astar.search(gpa, self, .{
        .from = from,
        .to = to,
        .bound = bound,
    })) |path| {
        var colored_path = path;
        colored_path.source = source;
        colored_path.color = self.nodeColor(source);
        colored_path.arrow = 0x19;
        colored_path.start_direction = Direction.up;
        colored_path.end_direction = Direction.down;
        try self.occupyPath(gpa, colored_path);
        self.nodes.items(.parameter_path)[target.idx] = colored_path;
    }
}

/// Recompute only paths entering or leaving one node.
pub fn recomputePathsForNode(self: *Self, gpa: std.mem.Allocator, node: VisualNode.Index) !void {
    self.updateGraphBounds();
    const bound = self.searchBound();
    self.clearPathsForNode(gpa, node);
    self.path_occupied.clearRetainingCapacity();
    try self.rebuildPathOccupancy(gpa);

    for (self.dsp.nodes.items(.inputs), 0..) |node_inputs, destination_index| {
        const destination = VisualNode.Index{ .idx = destination_index };
        if (destination.isNoop() or self.isHiddenNode(destination)) continue;
        const state = self.dsp.nodes.items(.state)[destination_index];
        const metadata = DSP.node_metadata.get(std.meta.activeTag(state));
        for (0..metadata.input_count) |input_port| {
            const connection = node_inputs[input_port];
            if (connection.isNoop() or self.isHiddenNode(connection.node)) continue;
            if (destination_index == node.idx or
                (!connection.isNoop() and connection.node.idx == node.idx))
                try self.computePathForInput(gpa, destination, input_port, bound);
        }
    }

    for (self.dsp.nodes.items(.parameter_link), 0..) |link, destination_index| {
        const destination = VisualNode.Index{ .idx = destination_index };
        if (self.isHiddenNode(destination)) continue;
        if (link.source) |source| {
            if (self.isHiddenNode(source)) continue;
            if (destination_index == node.idx or source.idx == node.idx)
                try self.computePathForParameter(
                    gpa,
                    source,
                    destination,
                    bound,
                );
        }
    }

    try self.addPathJunctions(gpa);
}

fn clearPathsForNode(self: *Self, gpa: std.mem.Allocator, node: VisualNode.Index) void {
    for (self.nodes.items(.paths), 0..) |*paths, destination_index| {
        for (paths) |*maybe_path| {
            const is_outbound = if (maybe_path.*) |path| path.source.idx == node.idx else false;
            if (destination_index != node.idx and !is_outbound) continue;
            if (maybe_path.*) |path| deinitPath(path, gpa);
            maybe_path.* = null;
        }
    }

    for (self.nodes.items(.parameter_path), 0..) |*maybe_path, destination_index| {
        const is_outbound = if (maybe_path.*) |path| path.source.idx == node.idx else false;
        if (destination_index != node.idx and !is_outbound) continue;
        if (maybe_path.*) |path| deinitPath(path, gpa);
        maybe_path.* = null;
    }
}

fn rebuildPathOccupancy(self: *Self, gpa: std.mem.Allocator) !void {
    for (self.nodes.items(.paths)) |paths| {
        for (paths) |maybe_path| {
            if (maybe_path) |path|
                try self.occupyPath(gpa, path);
        }
    }
    for (self.nodes.items(.parameter_path)) |maybe_path|
        if (maybe_path) |path|
            try self.occupyPath(gpa, path);
}

fn occupyPath(self: *Self, gpa: std.mem.Allocator, path: Path) !void {
    if (path.points.len == 0) return;

    try self.recordPathDirection(gpa, path.points[0].position, path.start_direction);

    for (path.points[0 .. path.points.len - 1], 0..) |from, index| {
        const to = path.points[index + 1];
        const step = Position{
            .x = std.math.sign(to.position.x - from.position.x),
            .y = std.math.sign(to.position.y - from.position.y),
        };
        const direction = directionForStep(step);
        const opposite = oppositeDirection(direction);
        var point = from.position;

        while (point.x != to.position.x or point.y != to.position.y) {
            const next = Position{
                .x = point.x + step.x,
                .y = point.y + step.y,
            };
            try self.recordPathDirection(gpa, point, direction);
            try self.recordPathDirection(gpa, next, opposite);
            point = next;
        }
    }

    try self.recordPathDirection(
        gpa,
        path.points[path.points.len - 1].position,
        path.end_direction,
    );
}

fn recordPathDirection(self: *Self, gpa: std.mem.Allocator, position: Position, direction: u4) !void {
    const entry = try self.path_occupied.getOrPut(gpa, position);
    if (!entry.found_existing)
        entry.value_ptr.* = 0;
    entry.value_ptr.* |= direction;
}

fn addPathJunctions(self: *Self, gpa: std.mem.Allocator) !void {
    var cells = std.AutoHashMapUnmanaged(Position, PathCell).empty;
    defer cells.deinit(gpa);

    for (self.nodes.items(.paths)) |paths| {
        for (paths) |maybe_path| {
            if (maybe_path) |path|
                try addPathCells(&cells, gpa, path);
        }
    }

    for (self.nodes.items(.parameter_path)) |maybe_path| {
        if (maybe_path) |path|
            try addPathCells(&cells, gpa, path);
    }

    for (self.nodes.items(.paths)) |*paths| {
        for (paths) |*maybe_path| {
            if (maybe_path.*) |*path|
                try insertJunctionPoints(path, &cells, gpa);
        }
    }

    for (self.nodes.items(.parameter_path)) |*maybe_path|
        if (maybe_path.*) |*path|
            try insertJunctionPoints(path, &cells, gpa);
}

fn addPathCells(
    cells: *std.AutoHashMapUnmanaged(Position, PathCell),
    gpa: std.mem.Allocator,
    path: Path,
) !void {
    if (path.points.len == 0) return;

    try recordPathCell(cells, gpa, path.points[0].position, path.start_direction, true);

    for (path.points[0 .. path.points.len - 1], 0..) |from, index| {
        const to = path.points[index + 1];
        const step = Position{
            .x = std.math.sign(to.position.x - from.position.x),
            .y = std.math.sign(to.position.y - from.position.y),
        };
        const direction = directionForStep(step);
        const opposite = oppositeDirection(direction);
        var point = from.position;

        while (point.x != to.position.x or point.y != to.position.y) {
            const next = Position{
                .x = point.x + step.x,
                .y = point.y + step.y,
            };
            try recordPathCell(cells, gpa, point, direction, false);
            try recordPathCell(cells, gpa, next, opposite, true);
            point = next;
        }
    }

    try recordPathCell(
        cells,
        gpa,
        path.points[path.points.len - 1].position,
        path.end_direction,
        false,
    );
}

fn recordPathCell(
    cells: *std.AutoHashMapUnmanaged(Position, PathCell),
    gpa: std.mem.Allocator,
    position: Position,
    directions: u4,
    count_path: bool,
) !void {
    const entry = try cells.getOrPut(gpa, position);
    if (!entry.found_existing)
        entry.value_ptr.* = .{};

    entry.value_ptr.directions |= directions;
    if (count_path)
        entry.value_ptr.path_count += 1;
}

fn insertJunctionPoints(
    path: *Path,
    cells: *const std.AutoHashMapUnmanaged(Position, PathCell),
    gpa: std.mem.Allocator,
) !void {
    if (path.points.len == 0) return;

    var points = std.ArrayList(Path.Point).empty;
    errdefer points.deinit(gpa);

    try appendPathPoint(&points, cells, gpa, path.points[0].position);

    for (path.points[0 .. path.points.len - 1], 0..) |from, index| {
        const to = path.points[index + 1];
        const step = Position{
            .x = std.math.sign(to.position.x - from.position.x),
            .y = std.math.sign(to.position.y - from.position.y),
        };
        var point = from.position;

        while (point.x != to.position.x or point.y != to.position.y) {
            point.x += step.x;
            point.y += step.y;

            const cell = cells.get(point) orelse unreachable;
            if (point.x == to.position.x and point.y == to.position.y or cell.path_count > 1)
                try appendPathPoint(&points, cells, gpa, point);
        }
    }

    const new_points = try points.toOwnedSlice(gpa);
    gpa.free(path.points);
    path.points = new_points;
}

fn appendPathPoint(
    points: *std.ArrayList(Path.Point),
    cells: *const std.AutoHashMapUnmanaged(Position, PathCell),
    gpa: std.mem.Allocator,
    position: Position,
) !void {
    const cell = cells.get(position) orelse unreachable;
    try points.append(gpa, .{
        .position = position,
        .directions = cell.directions,
    });
}

fn directionForStep(step: Position) u4 {
    if (step.x < 0) return Direction.left;
    if (step.x > 0) return Direction.right;
    if (step.y < 0) return Direction.up;
    if (step.y > 0) return Direction.down;
    unreachable;
}

fn oppositeDirection(direction: u4) u4 {
    return switch (direction) {
        Direction.left => Direction.right,
        Direction.right => Direction.left,
        Direction.up => Direction.down,
        Direction.down => Direction.up,
        else => unreachable,
    };
}

fn clearPaths(self: *Self, gpa: std.mem.Allocator) void {
    for (self.nodes.items(.paths)) |*paths| {
        for (paths) |*maybe_path| {
            if (maybe_path.*) |path| {
                deinitPath(path, gpa);
                maybe_path.* = null;
            }
        }
    }
    for (self.nodes.items(.parameter_path)) |*maybe_path| {
        if (maybe_path.*) |path| {
            deinitPath(path, gpa);
            maybe_path.* = null;
        }
    }
}

pub fn traversalCost(self: *Self, criteria: PathCriteria, from: Position, to: Position) ?u32 {
    if (!criteria.bound.contains(to)) return null;

    const is_path_anchor = std.meta.eql(to, criteria.from) or std.meta.eql(to, criteria.to);
    if (self.occupied.get(to) != null and !is_path_anchor)
        return null;

    const dx = @abs(@as(i64, to.x) - @as(i64, from.x));
    const dy = @abs(@as(i64, to.y) - @as(i64, from.y));
    if (!((dx == 1 and dy == 0) or (dx == 0 and dy == 1)))
        return null;

    return if (self.path_occupied.contains(to)) 10 else 1;
}

/// A path through the editor's unbounded, integer coordinate space.
///
/// The slice contains endpoints, turns, and cells shared with another path.
/// Shared cells carry the union of all directions passing through them.
pub const Path = struct {
    pub const Point = struct {
        position: Position,
        directions: u4 = 0,
    };

    points: []const Point,
    source: VisualNode.Index = .noop,
    color: Display.Color = Display.Color.curious_blue,
    /// CP437 arrow glyph used at the path destination.
    arrow: u8 = 0x1A,
    /// Direction connecting the path start to its source outlet.
    start_direction: u4 = Direction.left,
    /// Direction connecting the path end to its destination outlet.
    end_direction: u4 = Direction.right,
};

/// Generic A* path finder for unbounded orthogonal space.
///
/// Context is expected to provide:
///
///     pub fn traversalCost(
///         context: *Context,
///         criteria: PathCriteria,
///         from: Position,
///         to: Position,
///     ) ?u32
///
/// Returning null makes the destination cell impassable. `PathCriteria` is
/// expected to provide at least `from: Position` and `to: Position` fields.
pub fn AStar(comptime Context: type, comptime Criteria: type) type {
    return struct {
        const AStarSelf = @This();

        const Point = struct {
            generation: usize,
            /// Cost from the start through this point.
            g: u64 = std.math.maxInt(u64),
            /// Estimated remaining cost to the destination.
            h: u64 = std.math.maxInt(u64),
            previous: ?Position = null,
            closed: bool = false,
        };

        const OpenEntry = struct {
            position: Position,
            g: u64,
            h: u64,

            fn compare(_: void, a: OpenEntry, b: OpenEntry) std.math.Order {
                const a_score = a.g + a.h;
                const b_score = b.g + b.h;

                if (a_score < b_score) return .lt;
                if (a_score > b_score) return .gt;
                if (a.h < b.h) return .lt;
                if (a.h > b.h) return .gt;
                if (a.position.y < b.position.y) return .lt;
                if (a.position.y > b.position.y) return .gt;
                if (a.position.x < b.position.x) return .lt;
                if (a.position.x > b.position.x) return .gt;
                return .eq;
            }
        };

        generation: usize = 0,
        todo: std.PriorityQueue(OpenEntry, void, OpenEntry.compare) = .empty,
        points: std.AutoHashMapUnmanaged(Position, Point) = .empty,

        /// Releases the sparse point table and reusable search queue.
        pub fn deinit(self: *AStarSelf, gpa: std.mem.Allocator) void {
            self.todo.deinit(gpa);
            self.points.deinit(gpa);
        }

        /// Starts a new search while retaining allocated storage for reuse.
        pub fn reset(self: *AStarSelf) void {
            self.generation +%= 1;
            self.todo.clearRetainingCapacity();
        }

        pub fn search(
            self: *AStarSelf,
            gpa: std.mem.Allocator,
            context: *Context,
            criteria: Criteria,
        ) !?Path {
            const from: Position = criteria.from;
            const to: Position = criteria.to;

            {
                const start = try self.point(gpa, from);
                start.g = 0;
                start.h = 0;
                start.previous = null;
                start.closed = false;
            }

            try self.todo.push(gpa, .{
                .position = from,
                .g = 0,
                .h = 0,
            });

            while (self.todo.pop()) |current| {
                const current_point = self.points.get(current.position) orelse continue;

                // Ignore entries superseded by a cheaper route.
                if (current.g != current_point.g or current_point.closed)
                    continue;

                if (std.meta.eql(current.position, to))
                    return try self.buildPath(gpa, to);

                self.points.getPtr(current.position).?.closed = true;

                // The order is fixed so equivalent searches behave identically.
                for ([_]Position{
                    .{ .x = 0, .y = -1 },
                    .{ .x = 1, .y = 0 },
                    .{ .x = 0, .y = 1 },
                    .{ .x = -1, .y = 0 },
                }) |delta| {
                    const neighbor = Position{
                        .x = current.position.x + delta.x,
                        .y = current.position.y + delta.y,
                    };

                    const step_cost = Context.traversalCost(
                        context,
                        criteria,
                        current.position,
                        neighbor,
                    ) orelse continue;
                    const tentative_g = current.g + @as(u64, step_cost);
                    const h = manhattanDistance(neighbor, to);

                    const neighbor_point = try self.point(gpa, neighbor);
                    if (tentative_g >= neighbor_point.g)
                        continue;

                    neighbor_point.g = tentative_g;
                    neighbor_point.h = h;
                    neighbor_point.previous = current.position;
                    neighbor_point.closed = false;

                    try self.todo.push(gpa, .{
                        .position = neighbor,
                        .g = tentative_g,
                        .h = h,
                    });
                }
            }

            return null;
        }

        fn point(self: *AStarSelf, gpa: std.mem.Allocator, position: Position) !*Point {
            const entry = try self.points.getOrPut(gpa, position);
            if (!entry.found_existing or entry.value_ptr.generation != self.generation) {
                entry.value_ptr.* = .{ .generation = self.generation };
            }
            return entry.value_ptr;
        }

        fn buildPath(self: *AStarSelf, gpa: std.mem.Allocator, destination: Position) !Path {
            var path = std.ArrayList(Path.Point).empty;
            errdefer path.deinit(gpa);

            // Walk backwards from the destination and retain only endpoints
            // and positions where the incoming and outgoing directions differ.
            try path.append(gpa, .{ .position = destination });
            var child = destination;
            while (self.points.get(child).?.previous) |previous| {
                const before = self.points.get(previous).?.previous;
                if (before) |before_position| {
                    const incoming = .{
                        .x = previous.x - before_position.x,
                        .y = previous.y - before_position.y,
                    };
                    const outgoing = .{
                        .x = child.x - previous.x,
                        .y = child.y - previous.y,
                    };
                    if (incoming.x != outgoing.x or incoming.y != outgoing.y)
                        try path.append(gpa, .{ .position = previous });
                } else {
                    // The first position is always part of the compact path.
                    try path.append(gpa, .{ .position = previous });
                    break;
                }

                child = previous;
            }

            const points = try path.toOwnedSlice(gpa);
            std.mem.reverse(Path.Point, points);
            return .{ .points = points };
        }

        fn manhattanDistance(from: Position, to: Position) u64 {
            const dx = @as(i64, to.x) - @as(i64, from.x);
            const dy = @as(i64, to.y) - @as(i64, from.y);
            return @intCast(@abs(dx) + @abs(dy));
        }
    };
}
