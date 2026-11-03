//! Visual representation of DSP node in unbounded space
const std = @import("std");
const DSP = @import("DSP.zig");
const Display = @import("Display.zig");

const Self = @This();

viewport: Viewport,
dsp: *DSP,
nodes: std.MultiArrayList(VisualNode) = .empty,
selected_node: ?VisualNode.Index = null,
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
};

pub const Outlet = struct {
    pub const Kind = enum { input, output };

    node: VisualNode.Index,
    direction: Kind,
    port: u8,
    anchor: Position,
};

/// Return the static metadata associated with a visual outlet.
pub fn outletMetadata(self: *Self, outlet: Outlet) DSP.Node.OutletMetadata {
    const state = self.dsp.nodes.items(.state)[outlet.node.idx];
    const metadata = DSP.node_metadata.get(std.meta.activeTag(state));
    return switch (outlet.direction) {
        .input => metadata.inputs[outlet.port],
        .output => metadata.outputs[outlet.port],
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
    if (self.selected_node) |node|
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

    for (0..metadata.input_count) |port| {
        const outlet = metadata.inputs[port];
        const y = screen_top + self.outletYOffset(footprint, metadata.input_count, port);
        const x = screen_left - @as(i64, @intCast(outlet.short_name.len));
        try writeUiText(gpa, display, x, y, outlet.short_name, outlet.color);
    }

    for (0..metadata.output_count) |port| {
        const outlet = metadata.outputs[port];
        const y = screen_top + self.outletYOffset(footprint, metadata.output_count, port);
        const x = screen_left + @as(i64, @intCast(footprint.width));
        try writeUiText(gpa, display, x, y, outlet.short_name, outlet.color);
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
        if (node.isNoop()) continue;
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
    if (node.isNoop() or node.idx >= self.nodes.len)
        return;

    self.clearPaths(gpa);
    self.path_occupied.clearRetainingCapacity();

    if (self.selected_node) |selected| {
        if (selected.idx == node.idx) {
            self.selected_node = null;
        } else if (selected.idx == self.nodes.len - 1) {
            self.selected_node = .{ .idx = node.idx };
        }
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
) !void {
    for (self.nodes.items(.dsp_node)) |node|
        if (!node.isNoop())
            try self.writeNode(gpa, display, node);

    if (self.selected_node) |node| {
        if (!node.isNoop()) {
            try self.writeNodeBody(gpa, display, node, .ebony);
            try self.writeOutgoingPaths(gpa, display, node, .ebony);
        }
    }

    try self.writeOutputTail(gpa, display);
}

/// Draws the fixed external-audio marker beyond the configured output node.
fn writeOutputTail(self: *Self, gpa: std.mem.Allocator, display: *Display) !void {
    const output = self.dsp.output;
    if (output.isNoop() or output.idx >= self.nodes.len) return;

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
    const footprint = self.nodeFootprint(node);
    if (!self.intersectsViewport(footprint)) return;

    const x: i64 = @as(i64, footprint.x) - @as(i64, self.viewport.x);
    const y: i64 = @as(i64, footprint.y) - @as(i64, self.viewport.y);
    const state = self.dsp.nodes.items(.state)[node.idx];
    const metadata = DSP.node_metadata.get(std.meta.activeTag(state));
    const name = self.dsp.nodes.items(.name)[node.idx];
    const content_width = footprint.width - 2;
    const node_color = self.nodeColor(node);

    // Clear the complete footprint first, clipping cells outside the display.
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

    const displayed_metadata_name = metadata.short_name[0..@min(metadata.short_name.len, content_width)];
    const metadata_name_x = x + 1;
    for (displayed_metadata_name, 0..) |character, index| {
        const glyph = [_]u8{character};
        const character_x = metadata_name_x + @as(i64, @intCast(index));
        if (character_x >= 0 and y >= 0)
            try display.write(gpa, &glyph, @intCast(character_x), @intCast(y), background, .white);
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

    const outlet = [_]u8{0x09};
    const inputs = self.dsp.nodes.items(.inputs)[node.idx];
    for (0..metadata.input_count) |port| {
        const outlet_y = y + @as(i64, @intCast(self.outletYOffset(footprint, metadata.input_count, port)));
        const color = if (!self.isOutputReachable(node) or inputs[port].isNoop())
            Display.Color.gray
        else
            Display.Color.green;
        if (x >= 0 and outlet_y >= 0)
            try display.write(gpa, &outlet, @intCast(x), @intCast(outlet_y), background, color);
    }

    for (0..metadata.output_count) |port| {
        const outlet_y = y + @as(i64, @intCast(self.outletYOffset(footprint, metadata.output_count, port)));
        const color = if (self.isOutputReachable(node) and
            self.dsp.nodes.items(.output_connected)[node.idx][port])
            Display.Color.green
        else
            Display.Color.gray;
        const outlet_x = x + @as(i64, @intCast(footprint.width - 1));
        if (outlet_x >= 0 and outlet_y >= 0)
            try display.write(gpa, &outlet, @intCast(outlet_x), @intCast(outlet_y), background, color);
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
    const arrow_x = @as(i64, final_point.x) - @as(i64, self.viewport.x) + 1;
    const arrow_y = @as(i64, final_point.y) - @as(i64, self.viewport.y);
    const arrow = [_]u8{0x1A};
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
    const state = self.dsp.nodes.items(.state)[node.idx];
    const metadata = DSP.node_metadata.get(std.meta.activeTag(state));

    const outlet_count = @max(
        @max(metadata.input_count, metadata.output_count),
        @as(u8, 1),
    );
    const label_width = self.dsp.nodes.items(.name)[node.idx].len + 4;
    const width = @min(label_width, @as(usize, 16));

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

fn outletYOffset(_: *Self, footprint: Bound, outlet_count: u8, port: usize) i32 {
    if (outlet_count == 1)
        return @intCast(footprint.height / 2);
    return 1 + @as(i32, @intCast(port * 2));
}

/// Return the node whose actual footprint contains a world-space position.
pub fn nodeAt(self: *Self, position: Position) ?VisualNode.Index {
    for (self.nodes.items(.dsp_node), 0..) |node, node_index| {
        if (node.isNoop()) continue;

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

    return null;
}

/// Return the outlet glyph at a world-space position, if any.
pub fn outletAt(self: *Self, position: Position) ?Outlet {
    for (self.nodes.items(.dsp_node), 0..) |node, node_index| {
        if (node.isNoop()) continue;

        const visual_node = VisualNode.Index{ .idx = node_index };
        const footprint = self.nodeFootprint(visual_node);
        const state = self.dsp.nodes.items(.state)[node_index];
        const metadata = DSP.node_metadata.get(std.meta.activeTag(state));

        for (0..metadata.input_count) |port| {
            const y = footprint.y + self.outletYOffset(footprint, metadata.input_count, port);
            if (position.x == footprint.x and position.y == y)
                return .{
                    .node = visual_node,
                    .direction = .input,
                    .port = @intCast(port),
                    .anchor = .{ .x = footprint.x - 2, .y = y },
                };
        }

        for (0..metadata.output_count) |port| {
            const y = footprint.y + self.outletYOffset(footprint, metadata.output_count, port);
            if (position.x == footprint.x + @as(i32, @intCast(footprint.width - 1)) and
                position.y == y)
                return .{
                    .node = visual_node,
                    .direction = .output,
                    .port = @intCast(port),
                    .anchor = .{ .x = footprint.x + @as(i32, @intCast(footprint.width)), .y = y },
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
        if (node.isNoop()) continue;

        const visual_node = VisualNode.Index{ .idx = node_index };
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
        if (node.isNoop()) continue;

        const visual_node = VisualNode.Index{ .idx = node_index };
        const footprint = self.nodeFootprint(visual_node);
        const state = self.dsp.nodes.items(.state)[node_index];
        const metadata = DSP.node_metadata.get(std.meta.activeTag(state));

        for (0..metadata.input_count) |port| {
            const y = footprint.y + self.outletYOffset(footprint, metadata.input_count, port);
            if (!try self.tryOccupyLinkAnchor(gpa, .{ .x = footprint.x - 2, .y = y }, node) or
                !try self.tryOccupyLinkAnchor(gpa, .{ .x = footprint.x - 1, .y = y }, node))
                return false;
        }

        for (0..metadata.output_count) |port| {
            if (!try self.tryOccupyLinkAnchor(gpa, .{
                .x = footprint.x + @as(i32, @intCast(footprint.width)),
                .y = footprint.y + self.outletYOffset(footprint, metadata.output_count, port),
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
        if (node.isNoop()) continue;

        const visual_node = VisualNode.Index{ .idx = node_index };
        const footprint = self.nodeFootprint(visual_node);
        const state = self.dsp.nodes.items(.state)[node_index];
        const metadata = DSP.node_metadata.get(std.meta.activeTag(state));

        for (0..metadata.input_count) |port| {
            const y = footprint.y + self.outletYOffset(footprint, metadata.input_count, port);
            try self.occupyLinkAnchor(gpa, .{
                .x = footprint.x - 2,
                .y = y,
            }, node);
            try self.occupyLinkAnchor(gpa, .{
                .x = footprint.x - 1,
                .y = y,
            }, node);
        }

        for (0..metadata.output_count) |port| {
            try self.occupyLinkAnchor(gpa, .{
                .x = footprint.x + @as(i32, @intCast(footprint.width)),
                .y = footprint.y + self.outletYOffset(footprint, metadata.output_count, port),
            }, node);
        }
    }
}

/// Reserves one routing-clearance cell around every node footprint.
pub fn occupyNodeMargins(self: *Self, gpa: std.mem.Allocator) !void {
    for (self.nodes.items(.dsp_node), 0..) |node, node_index| {
        if (node.isNoop()) continue;

        const visual_node = VisualNode.Index{ .idx = node_index };
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
        const state = self.dsp.nodes.items(.state)[node_index];
        const metadata = DSP.node_metadata.get(std.meta.activeTag(state));

        for (0..metadata.input_count) |input_port| {
            _ = node_inputs;
            try self.computePathForInput(gpa, node, input_port, bound);
        }
    }

    try self.addPathJunctions(gpa);
}

/// Rebuilds the reverse-reachability cache for the configured DSP output.
fn computeOutputReachability(self: *Self) void {
    const node_count = self.dsp.nodes.len;
    const output_reachable = self.nodes.items(.output_reachable);
    @memset(output_reachable, false);

    if (self.dsp.output.idx >= node_count) return;
    output_reachable[self.dsp.output.idx] = true;

    // Repeatedly propagate reachability from destinations to their sources.
    // This converges for cycles as well as ordinary acyclic DSP graphs.
    var changed = true;
    while (changed) {
        changed = false;
        for (self.dsp.nodes.items(.inputs), 0..) |node_inputs, destination_idx| {
            if (!output_reachable[destination_idx]) continue;
            for (node_inputs) |connection| {
                if (connection.isNoop() or connection.node.idx >= node_count) continue;
                if (output_reachable[connection.node.idx]) continue;
                output_reachable[connection.node.idx] = true;
                changed = true;
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
    const source_state = self.dsp.nodes.items(.state)[source.idx];
    const source_metadata = DSP.node_metadata.get(std.meta.activeTag(source_state));
    const destination_state = self.dsp.nodes.items(.state)[destination.idx];
    const destination_metadata = DSP.node_metadata.get(std.meta.activeTag(destination_state));
    const from = Position{
        .x = from_footprint.x + @as(i32, @intCast(from_footprint.width)),
        .y = from_footprint.y + self.outletYOffset(
            from_footprint,
            source_metadata.output_count,
            connection.output_port,
        ),
    };
    const to = Position{
        .x = to_footprint.x - 2,
        .y = to_footprint.y + self.outletYOffset(
            to_footprint,
            destination_metadata.input_count,
            input_port,
        ),
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

/// Recompute only paths entering or leaving one node.
pub fn recomputePathsForNode(self: *Self, gpa: std.mem.Allocator, node: VisualNode.Index) !void {
    self.updateGraphBounds();
    const bound = self.searchBound();
    self.clearPathsForNode(gpa, node);
    self.path_occupied.clearRetainingCapacity();
    try self.rebuildPathOccupancy(gpa);

    for (self.dsp.nodes.items(.inputs), 0..) |node_inputs, destination_index| {
        const destination = VisualNode.Index{ .idx = destination_index };
        const state = self.dsp.nodes.items(.state)[destination_index];
        const metadata = DSP.node_metadata.get(std.meta.activeTag(state));
        for (0..metadata.input_count) |input_port| {
            const connection = node_inputs[input_port];
            if (destination_index == node.idx or
                (!connection.isNoop() and connection.node.idx == node.idx))
                try self.computePathForInput(gpa, destination, input_port, bound);
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
}

fn rebuildPathOccupancy(self: *Self, gpa: std.mem.Allocator) !void {
    for (self.nodes.items(.paths)) |paths| {
        for (paths) |maybe_path| {
            if (maybe_path) |path|
                try self.occupyPath(gpa, path);
        }
    }
}

fn occupyPath(self: *Self, gpa: std.mem.Allocator, path: Path) !void {
    if (path.points.len == 0) return;

    try self.recordPathDirection(gpa, path.points[0].position, Direction.left);

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
        Direction.right,
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

    for (self.nodes.items(.paths)) |*paths| {
        for (paths) |*maybe_path| {
            if (maybe_path.*) |*path|
                try insertJunctionPoints(path, &cells, gpa);
        }
    }
}

fn addPathCells(
    cells: *std.AutoHashMapUnmanaged(Position, PathCell),
    gpa: std.mem.Allocator,
    path: Path,
) !void {
    if (path.points.len == 0) return;

    try recordPathCell(cells, gpa, path.points[0].position, Direction.left, true);

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
        Direction.right,
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
