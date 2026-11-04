const std = @import("std");
const sdl = @import("zsdl3");
const Renderer = @import("Renderer.zig");
const G = @import("graphics.zig");
const Assets = @import("assets.zig");

const Self = @This();
const assert = std.debug.assert;

/// Persistent sampler requests used by queued renderer commands.
const sampler_requests = [_]G.Sampler{.NearestClamp};

/// Border styles supported by boxed display content.
pub const Border = enum {
    /// CP437 single-line box drawing characters.
    single,
    /// CP437 double-line box drawing characters.
    double,
};

/// A label/value pair rendered with independently colored text.
pub const LabelValue = struct {
    /// Text shown before the separator.
    label: []const u8,
    /// Text shown after the separator.
    value: []const u8,
    /// Foreground color used for the value text.
    value_color: Color,
};

pub const Impl = union(enum) {
    headless: void,
    graphic: GraphicDisplay,
};

impl: Impl,

pub fn write(
    self: *Self,
    gpa: std.mem.Allocator,
    str: []const u8,
    ox: u32,
    oy: u32,
    bg: Color,
    fg: Color,
) !void {
    if (self.impl == .graphic) {
        _ = try self.impl.graphic.write(gpa, str, ox, oy, bg, fg);
    }
}

/// Writes a display sequence repeatedly at consecutive cell positions.
pub fn writeRepeated(
    self: *Self,
    gpa: std.mem.Allocator,
    str: []const u8,
    ox: u32,
    oy: u32,
    repeat: u32,
    bg: Color,
    fg: Color,
) !void {
    var index: u32 = 0;
    while (index < repeat) : (index += 1)
        try self.write(gpa, str, ox + index, oy, bg, fg);
}

/// Writes a sixteen-cell horizontal bar with optional secondary and empty segments.
pub fn writeHorizontalBar(
    self: *Self,
    gpa: std.mem.Allocator,
    ox: u32,
    oy: u32,
    amount: u32,
    capacity: u32,
    bg: Color,
    fg: Color,
    secondary_amount: u32,
    secondary_fg: Color,
    empty_fg: Color,
) !void {
    const filled = barWidth(amount, capacity);
    const secondary = @min(16 - filled, barWidth(secondary_amount, capacity));
    const empty = 16 - filled - secondary;

    try self.writeRepeated(gpa, "\xF8", ox, oy, filled, bg, fg);
    try self.writeRepeated(gpa, "\xF8", ox + filled, oy, secondary, bg, secondary_fg);
    try self.writeRepeated(gpa, "\xF9", ox + filled + secondary, oy, empty, bg, empty_fg);
}

pub fn fill(
    self: *Self,
    gpa: std.mem.Allocator,
    bg: Color,
    fg: Color,
    char: u8,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) !void {
    if (self.impl == .graphic)
        try self.impl.graphic.fill(gpa, bg, fg, char, x, y, width, height);
}

/// Writes label/value pairs in padded columns with vertically aligned values.
pub fn writeLabelValueColumns(
    self: *Self,
    gpa: std.mem.Allocator,
    items: []const LabelValue,
    x: u32,
    y: u32,
    width: u32,
    row_count: u32,
    bg: Color,
    label_color: Color,
) !void {
    if (items.len == 0 or row_count == 0 or x >= width) return;

    const rows = @min(row_count, @as(u32, @intCast(items.len)));
    var column_x = x;
    var item_index: usize = 0;
    while (item_index < items.len and column_x < width) {
        const column_end = @min(item_index + @as(usize, @intCast(rows)), items.len);
        var label_width: u32 = 0;
        var column_width: u32 = 0;

        for (item_index..column_end) |index|
            label_width = @max(label_width, @as(u32, @intCast(countStripped(items[index].label))));

        for (item_index..column_end) |index|
            column_width = @max(
                column_width,
                label_width + 2 + @as(u32, @intCast(countStripped(items[index].value))),
            );

        for (item_index..column_end) |index| {
            const row = @as(u32, @intCast(index - item_index));
            const item = items[index];
            const label_width_for_item = @as(u32, @intCast(countStripped(item.label)));
            try self.write(gpa, item.label, column_x, y + row, bg, label_color);
            try self.write(
                gpa,
                ": ",
                column_x + label_width_for_item,
                y + row,
                bg,
                label_color,
            );
            try self.write(
                gpa,
                item.value,
                column_x + label_width + 2,
                y + row,
                bg,
                item.value_color,
            );
        }

        item_index = column_end;
        column_x += column_width + 1;
    }
}

/// Converts an amount and capacity into a sixteen-cell bar width.
fn barWidth(amount: u32, capacity: u32) u32 {
    if (capacity == 0) return 0;
    return @min(16, @divFloor(amount * 16, capacity));
}

/// Writes a straight border line to the display grid.
pub fn writeLine(
    self: *Self,
    gpa: std.mem.Allocator,
    from_x: u32,
    from_y: u32,
    to_x: u32,
    to_y: u32,
    bg: Color,
    fg: Color,
    border: Border,
) !void {
    if (self.impl == .graphic)
        try self.impl.graphic.writeLine(gpa, from_x, from_y, to_x, to_y, bg, fg, border);
}

/// Writes a border to the display grid.
pub fn writeBox(
    self: *Self,
    gpa: std.mem.Allocator,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    bg: Color,
    fg: Color,
    border: Border,
) !void {
    if (self.impl == .graphic)
        try self.impl.graphic.writeBox(gpa, x, y, width, height, bg, fg, border);
}

/// Write by wrapping text beyond given width. Returns how many lines were written.
pub fn writeWrapped(
    self: *Self,
    gpa: std.mem.Allocator,
    str: []const u8,
    width: u32,
    ox: u32,
    oy: u32,
    bg: Color,
    fg: Color,
) !u32 {
    if (self.impl == .graphic) {
        return try self.impl.graphic.writeWrapped(gpa, str, width, ox, oy, bg, fg);
    }

    return 0;
}

/// Count display cells in a string by stripping @RGB escape codes.
pub fn countStripped(string: []const u8) usize {
    var len: usize = 0;
    var index: usize = 0;

    while (index < string.len) : (index += 1) {
        if (string[index] == '@' and index + 5 <= string.len) {
            // @\x01\xFF\xFF\xFF changes the active color without writing a cell.
            index += 4;
            continue;
        }

        len += 1;
    }

    return len;
}

/// Count how many lines the string takes
pub fn countWrappedLines(string: []const u8, width: usize) usize {
    var lines: usize = 1;
    var line_it = std.mem.splitScalar(u8, string, '\n');

    while (line_it.next()) |line| {
        var leading_spaces: usize = 0;
        while (leading_spaces < line.len and line[leading_spaces] == ' ')
            leading_spaces += 1;

        var x: usize = leading_spaces;
        var word_it = std.mem.tokenizeAny(u8, line, " ");

        while (word_it.next()) |word| {
            const word_len = countStripped(word);

            if (x + word_len > width) {
                x = 0;
                lines += 1;
            }

            x += word_len + 1;
        }

        if (line_it.peek() != null)
            lines += 1;
    }

    return lines;
}

pub fn reset(self: *Self) void {
    if (self.impl == .graphic)
        self.impl.graphic.reset();
}

pub fn resetTransparent(self: *Self) void {
    if (self.impl == .graphic)
        self.impl.graphic.resetTransparent();
}

pub const GraphicDisplay = struct {
    pub const Cell = struct {
        symbol: u8 = 255,
        fg: Color = .black,
        bg: Color = .black,
    };

    width: u32,
    height: u32,

    /// Integer factor used when the display texture is composited to the frame.
    scale: u32,

    /// Width of one display cell in pixels at scale one.
    cell_width: u32,
    /// Height of one display cell in pixels at scale one.
    cell_height: u32,

    /// Horizontal pixel offset of the exact cell grid within the render target.
    content_origin_x: u32,
    /// Vertical pixel offset of the exact cell grid within the render target.
    content_origin_y: u32,

    grid: std.MultiArrayList(Cell),
    dirty_cells: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,

    sheet: Renderer.AssetResource,

    /// Persistent asset request storage used by queued renderer commands.
    asset_requests: [1]Assets.Asset,

    /// Where we draw the display
    target_texture: Renderer.TextureHandle,
    target_texture_format: sdl.GPUTextureFormat,
    /// Initialized once so we don't reallocate this everytime
    sprite_positions: struct {
        /// Slice into positions
        slice: []const G.ShaderTypes.Sprite,
        /// Size == grid.len
        positions: []G.ShaderTypes.Sprite,
    },
    /// If true, texture will be cleared before drawing (starts at true for the first render)
    clear: bool = true,

    pub const Options = struct {
        sheet_asset: Assets.Asset,
        render_width: u32,
        render_height: u32,
        scale: u32 = 1,
    };

    pub fn init(
        gpa: std.mem.Allocator,
        renderer: *Renderer,
        options: Options,
    ) !GraphicDisplay {
        if (options.scale == 0)
            @panic("Display scale must be greater than zero");

        const scaled_render_width = options.render_width / options.scale;
        const scaled_render_height = options.render_height / options.scale;

        const sheet = try renderer.loadImageAssetToTexture(gpa, options.sheet_asset);
        const target_texture_create_info = std.mem.zeroInit(
            sdl.GPUTextureCreateInfo,
            .{
                .type = .texturetype_2d,
                .format = .r8g8b8a8_unorm,
                .width = scaled_render_width,
                .height = scaled_render_height,
                .layer_count_or_depth = 1,
                .num_levels = 1,
                // The display is rendered into this texture, then sampled by
                // the composite pass when it is copied to the swapchain.
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

        const width = scaled_render_width / (sheet.image.width / 16);
        const height = scaled_render_height / (sheet.image.height / 16);
        const cell_width = sheet.image.width / 16;
        const cell_height = sheet.image.height / 16;
        const content_width = width * cell_width;
        const content_height = height * cell_height;
        var self = GraphicDisplay{
            .width = width,
            .height = height,
            .scale = options.scale,
            .cell_width = cell_width,
            .cell_height = cell_height,
            .content_origin_x = (scaled_render_width - content_width) / 2,
            .content_origin_y = (scaled_render_height - content_height) / 2,
            .grid = try .initCapacity(gpa, width * height),
            .sheet = sheet,
            .asset_requests = .{options.sheet_asset},
            .target_texture = target_texture,
            .target_texture_format = target_texture_create_info.format,
            .sprite_positions = .{
                .positions = try gpa.alloc(G.ShaderTypes.Sprite, width * height),
                .slice = &.{},
            },
        };

        for (0..self.grid.capacity) |_|
            self.grid.appendAssumeCapacity(.{});

        return self;
    }

    pub fn deinit(self: *GraphicDisplay, gpa: std.mem.Allocator, renderer: *Renderer) void {
        self.grid.deinit(gpa);
        gpa.free(self.sprite_positions.positions);
        sdl.releaseGPUTexture(renderer.device, self.target_texture.getColumns().texture);
        _ = self.target_texture.pool.removeIfLive(self.target_texture.handle);
    }

    pub fn reset(self: *GraphicDisplay) void {
        self.clear = true;
        @memset(self.grid.items(.fg), .black);
        @memset(self.grid.items(.bg), .black);
        @memset(self.grid.items(.symbol), ' ');
    }

    pub fn resetTransparent(self: *GraphicDisplay) void {
        self.clear = true;
        @memset(self.grid.items(.fg), .transparent);
        @memset(self.grid.items(.bg), .transparent);
        @memset(self.grid.items(.symbol), ' ');
    }

    /// Writes the current display grid as a true-color ANSI snapshot.
    pub fn dump(self: *const GraphicDisplay, writer: *std.Io.Writer) !void {
        var foreground: ?Color = null;
        var background: ?Color = null;

        try writer.writeAll("\x1b[0m");

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const cell = self.grid.get(y * self.width + x);
                const next_foreground: ?Color = if (cell.fg.isTransparent()) null else cell.fg;
                const next_background: ?Color = if (cell.bg.isTransparent()) null else cell.bg;

                if (!std.meta.eql(foreground, next_foreground)) {
                    if (next_foreground) |color| {
                        try writer.print(
                            "\x1b[38;2;{d};{d};{d}m",
                            .{ color.r(), color.g(), color.b() },
                        );
                    } else {
                        try writer.writeAll("\x1b[39m");
                    }
                    foreground = next_foreground;
                }

                if (!std.meta.eql(background, next_background)) {
                    if (next_background) |color| {
                        try writer.print(
                            "\x1b[48;2;{d};{d};{d}m",
                            .{ color.r(), color.g(), color.b() },
                        );
                    } else {
                        try writer.writeAll("\x1b[49m");
                    }
                    background = next_background;
                }

                try writer.writeAll(cp437_utf8[cell.symbol]);
            }

            try writer.writeByte('\n');
        }

        try writer.writeAll("\x1b[0m\n");
    }

    pub fn fill(
        self: *GraphicDisplay,
        gpa: std.mem.Allocator,
        bg: Color,
        fg: Color,
        char: u8,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    ) !void {
        if (x >= self.width or y >= self.height or width == 0 or height == 0)
            return;

        const symbols = self.grid.items(.symbol);
        const fgs = self.grid.items(.fg);
        const bgs = self.grid.items(.bg);
        const nwidth = @min(self.width - x, width);
        const nheight = @min(self.height - y, height);

        for (y..y + nheight) |ly| {
            const start = ly * self.width + x;

            for (start..start + nwidth) |idx|
                try self.dirty_cells.put(gpa, @intCast(idx), {});

            @memset(symbols[start .. start + nwidth], char);
            @memset(fgs[start .. start + nwidth], fg);
            @memset(bgs[start .. start + nwidth], bg);
        }
    }

    /// Writes a straight border line to the display grid.
    pub fn writeLine(
        self: *GraphicDisplay,
        gpa: std.mem.Allocator,
        from_x: u32,
        from_y: u32,
        to_x: u32,
        to_y: u32,
        bg: Color,
        fg: Color,
        border: Border,
    ) !void {
        if (from_x == to_x and from_y == to_y)
            return;

        assert(from_x == to_x or from_y == to_y);

        const glyph: u8 = switch (border) {
            .single => if (from_y == to_y) 0xC4 else 0xB3,
            .double => if (from_y == to_y) 0xCD else 0xBA,
        };
        const glyph_string = [_]u8{glyph};

        if (from_y == to_y) {
            const start = @min(from_x, to_x);
            const end = @max(from_x, to_x);
            var x = start;
            while (true) {
                if (x < self.width and from_y < self.height)
                    _ = try self.write(gpa, glyph_string[0..], x, from_y, bg, fg);
                if (x == end)
                    break;
                x += 1;
            }
        } else {
            const start = @min(from_y, to_y);
            const end = @max(from_y, to_y);
            var y = start;
            while (true) {
                if (from_x < self.width and y < self.height)
                    _ = try self.write(gpa, glyph_string[0..], from_x, y, bg, fg);
                if (y == end)
                    break;
                y += 1;
            }
        }
    }

    /// Writes a border to the display grid.
    pub fn writeBox(
        self: *GraphicDisplay,
        gpa: std.mem.Allocator,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        bg: Color,
        fg: Color,
        border: Border,
    ) !void {
        assert(width >= 2 and height >= 2);
        if (x >= self.width or y >= self.height)
            return;

        const Glyphs = struct {
            top_left: u8,
            top_right: u8,
            bottom_left: u8,
            bottom_right: u8,
        };
        const glyphs: Glyphs = switch (border) {
            .single => .{
                .top_left = 0xDA,
                .top_right = 0xBF,
                .bottom_left = 0xC0,
                .bottom_right = 0xD9,
            },
            .double => .{
                .top_left = 0xC9,
                .top_right = 0xBB,
                .bottom_left = 0xC8,
                .bottom_right = 0xBC,
            },
        };

        const top_left = [_]u8{glyphs.top_left};
        const top_right = [_]u8{glyphs.top_right};
        const bottom_left = [_]u8{glyphs.bottom_left};
        const bottom_right = [_]u8{glyphs.bottom_right};
        const right = x + width - 1;
        const bottom_y = y + height - 1;

        if (y < self.height) {
            if (x < self.width)
                _ = try self.write(gpa, top_left[0..], x, y, bg, fg);
            if (width > 2)
                try self.writeLine(gpa, x + 1, y, right - 1, y, bg, fg, border);
            if (right < self.width)
                _ = try self.write(gpa, top_right[0..], right, y, bg, fg);
        }

        if (height > 2) {
            try self.writeLine(gpa, x, y + 1, x, bottom_y - 1, bg, fg, border);
            try self.writeLine(gpa, right, y + 1, right, bottom_y - 1, bg, fg, border);
        }

        if (bottom_y < self.height) {
            if (x < self.width)
                _ = try self.write(gpa, bottom_left[0..], x, bottom_y, bg, fg);
            if (width > 2)
                try self.writeLine(gpa, x + 1, bottom_y, right - 1, bottom_y, bg, fg, border);
            if (right < self.width)
                _ = try self.write(gpa, bottom_right[0..], right, bottom_y, bg, fg);
        }
    }

    /// Write to the display. Ignore out-of-bound writes. Mark changed cells as dirty for the rendering to consider.
    pub fn write(
        self: *GraphicDisplay,
        gpa: std.mem.Allocator,
        str: []const u8,
        ox: u32,
        oy: u32,
        bg: Color,
        fg: Color,
    ) !u32 {
        var background = bg;
        var foreground = fg;
        const x = ox;
        var y = oy;
        if (x >= self.width or y >= self.height)
            return 0;

        var i = x;
        var s: usize = 0;
        var inc: u32 = 1;
        while (i < self.width and s < str.len and y < self.height) : ({
            i += inc;
            s += 1;
        }) {
            inc = 1;
            var symbol = str[s];

            // Handle new line
            if (symbol == '\n') {
                y += 1;
                i = @min(self.width - 1, ox);
                inc = 0;
                continue;
            }

            // Set color
            if (symbol == '@' and str.len > 1) {
                if (str[s + 1] == 1) {
                    foreground = .fromStr(str[s + 2 .. s + 5]);
                } else {
                    background = .fromStr(str[s + 2 .. s + 5]);
                }

                s += 5;

                if (s >= str.len)
                    return y - oy + 1;

                symbol = str[s];
            }

            const index = y * self.width + i;
            const cell = self.grid.get(index);
            const new_cell = Cell{
                .bg = background,
                .fg = foreground,
                .symbol = symbol,
            };

            if (!std.meta.eql(cell, new_cell)) {
                try self.dirty_cells.put(gpa, index, {});
                self.grid.set(index, new_cell);
            }
        }

        return y - oy + 1;
    }

    pub fn writeWrapped(
        self: *GraphicDisplay,
        gpa: std.mem.Allocator,
        str: []const u8,
        width: u32,
        ox: u32,
        oy: u32,
        bg: Color,
        fg: Color,
    ) !u32 {
        var x = @min(self.width - 1, @max(0, ox));
        var y = oy;
        var it = std.mem.tokenizeAny(u8, str, "\n");
        while (it.next()) |line| {
            var leading_spaces: usize = 0;
            while (leading_spaces < line.len and line[leading_spaces] == ' ')
                leading_spaces += 1;

            x = @min(
                self.width - 1,
                ox + @as(u32, @intCast(leading_spaces)),
            );

            var it2 = std.mem.tokenizeAny(u8, line, " ");
            while (it2.next()) |word| {
                const word_len = countStripped(word);

                if (x + word_len > ox + width) {
                    x = ox;
                    y += 1;
                }

                _ = try self.write(gpa, word, x, y, bg, fg);

                x += @as(u32, @intCast(word_len)) + 1;
            }

            x = ox;
            y += 1;
        }

        return y - oy + 1;
    }

    fn bucketSizeForCurrentRender(self: *GraphicDisplay) struct {
        storage_bucket: Renderer.BufferMapBucketedPool.Pool.Size,
        transfer_bucket: Renderer.TransferBufferMapBucketedPool.Pool.Size,
    } {
        const size_needed = if (self.clear)
            self.width * self.height * @sizeOf(G.ShaderTypes.Sprite)
        else
            self.dirty_cells.count() * @sizeOf(G.ShaderTypes.Sprite);

        return .{
            .storage_bucket = Renderer.BufferMapBucketedPool.bucketSizeFor(size_needed),
            .transfer_bucket = Renderer.TransferBufferMapBucketedPool.bucketSizeFor(size_needed),
        };
    }

    pub fn render(
        self: *GraphicDisplay,
        gpa: std.mem.Allocator,
        renderer: *Renderer,
        _: u64,
        present: bool,
    ) !void {
        const bucket_sizes = self.bucketSizeForCurrentRender();

        var storage_buffers = std.EnumMap(Renderer.BufferMapBucketedPool.Pool.Size, u8).init(.{});
        storage_buffers.put(bucket_sizes.storage_bucket, 1);

        var transfer_buffers = std.EnumMap(Renderer.TransferBufferMapBucketedPool.Pool.Size, u8).init(.{});
        transfer_buffers.put(bucket_sizes.transfer_bucket, 1);

        try renderer.commands.append(
            gpa,
            .init(
                self.target_texture.getColumns().texture,
                GraphicDisplay,
                self,
                worker,
                .{
                    .samplers = sampler_requests[0..],
                    .assets = self.asset_requests[0..],
                    .storage_buffers = storage_buffers,
                    .upload_transfer_buffers = transfer_buffers,
                },
                present,
            ),
        );
    }

    pub fn worker(
        self: *GraphicDisplay,
        gpa: std.mem.Allocator,
        io: std.Io,
        renderer: *Renderer,
        _: *sdl.GPUTexture,
        acquired: Renderer.Resources.Acquired,
        cmd_buffer: *sdl.GPUCommandBuffer,
    ) Renderer.WorkerError!void {
        const bucket_sizes = self.bucketSizeForCurrentRender();

        // Update target_texture if we have dirty cells, or redraw every cell when clearing.
        if (!self.clear and self.dirty_cells.count() == 0) return;
        defer self.clear = false;
        const sprite_width = 2.0 / @as(f32, @floatFromInt(self.width));
        const sprite_height = 2.0 / @as(f32, @floatFromInt(self.height));

        // Build Sprite list for the vertext shader
        var source_index: usize = 0;
        var sprite_count: usize = 0;
        while (true) {
            const idx: usize = if (self.clear) blk: {
                if (source_index >= self.grid.len)
                    break;

                defer source_index += 1;
                break :blk source_index;
            } else blk: {
                const kv = self.dirty_cells.pop() orelse break;
                break :blk @intCast(kv.key);
            };
            const sprite_index = self.grid.items(.symbol)[idx];
            const x = idx % self.width;
            const y = idx / self.width;

            const sprite_x = sprite_index % 16;
            const sprite_y = sprite_index / 16;

            // Convert the selected spritesheet cell into normalized UV coordinates.
            const u_min: f32 = @as(f32, @floatFromInt(sprite_x)) / 16.0;
            const v_min: f32 = @as(f32, @floatFromInt(sprite_y)) / 16.0;
            const u_max = u_min + 1.0 / 16.0;
            const v_max = v_min + 1.0 / 16.0;

            self.sprite_positions.positions[sprite_count] = .{
                .position = .{
                    // Add 0.5 so the position is the center of the grid cell.
                    // Clip-space Y is inverted here so row zero is at the top.
                    -1.0 + (@as(f32, @floatFromInt(x)) + 0.5) * sprite_width,
                    1.0 - (@as(f32, @floatFromInt(y)) + 0.5) * sprite_height,
                },
                // Size is the full clip-space dimensions of the sprite rectangle.
                .size = .{ sprite_width, sprite_height },
                // The shader remaps the quad's 0..1 UVs into this rectangle.
                .uv_rect = .{ u_min, v_min, u_max, v_max },
                .fg = self.grid.items(.fg)[idx].color,
                .bg = self.grid.items(.bg)[idx].color,
            };
            sprite_count += 1;
        }

        if (self.clear)
            self.dirty_cells.clearRetainingCapacity();

        self.sprite_positions.slice = self.sprite_positions.positions[0..sprite_count];

        const pipeline = renderer.getGraphicsPipeline(
            gpa,
            io,
            .SpriteGrid,
            self.target_texture_format,
        ) catch @panic("Could not get graphics pipeline"); // TODO: properly handle error set

        // Upload grid of Sprite to GPU
        const grid_bytes = std.mem.sliceAsBytes(self.sprite_positions.slice[0..]);
        const upload_transfer_buffer = acquired.upload_transfer_buffers
            .get(bucket_sizes.transfer_bucket).?[0]
            .getColumns().buffer;
        const storage_buffer = acquired.storage_buffers
            .get(bucket_sizes.storage_bucket).?[0]
            .getColumns().buffer;

        const mapped_transfer_buffer: [*]u8 = @ptrCast(
            try sdl.mapGPUTransferBuffer(
                renderer.device,
                upload_transfer_buffer,
                true,
            ),
        );

        // Copy data to upload transfer buffer
        @memcpy(mapped_transfer_buffer[0..grid_bytes.len], grid_bytes);

        sdl.unmapGPUTransferBuffer(renderer.device, upload_transfer_buffer);

        // Actual upload to GPU is done in a copy pass
        const copy_pass = sdl.beginGPUCopyPass(cmd_buffer);

        sdl.uploadToGPUBuffer(
            copy_pass,
            &.{ .transfer_buffer = upload_transfer_buffer, .offset = 0 },
            &.{ .buffer = storage_buffer, .offset = 0, .size = @intCast(grid_bytes.len) },
            true,
        );

        sdl.endGPUCopyPass(copy_pass);

        // Now we draw the grid in a renderpass
        const render_pass = sdl.beginGPURenderPass(
            cmd_buffer,
            @ptrCast(
                &.{
                    std.mem.zeroInit(
                        sdl.GPUColorTargetInfo,
                        .{
                            .texture = self.target_texture.getColumns().texture,
                            .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                            .load_op = if (self.clear) sdl.GPULoadOp.clear else sdl.GPULoadOp.load,
                            .store_op = .store,
                        },
                    ),
                },
            ),
            1,
            null,
        );

        sdl.bindGPUFragmentSamplers(
            render_pass,
            0,
            @ptrCast(
                &.{
                    sdl.GPUTextureSamplerBinding{
                        .texture = acquired.assets[0].texture,
                        .sampler = acquired.samplers[0],
                    },
                },
            ),
            1,
        );
        sdl.bindGPUGraphicsPipeline(render_pass, pipeline);
        sdl.bindGPUVertexStorageBuffers(
            render_pass,
            0,
            @ptrCast(
                &.{
                    std.mem.zeroInit(
                        sdl.GPUBufferBinding,
                        .{
                            .buffer = storage_buffer,
                        },
                    ),
                },
            ),
            1,
        );

        var viewport = sdl.GPUViewport{
            .x = @floatFromInt(self.content_origin_x),
            .y = @floatFromInt(self.content_origin_y),
            .w = @floatFromInt(self.width * self.cell_width),
            .h = @floatFromInt(self.height * self.cell_height),
            .min_depth = 0,
            .max_depth = 1,
        };
        sdl.setGPUViewport(render_pass, &viewport);

        sdl.drawGPUPrimitives(
            render_pass,
            @intCast(self.sprite_positions.slice.len * 6),
            1,
            0,
            0,
        );

        sdl.endGPURenderPass(render_pass);
    }
};

/// An RGBA8 color packed as 0xRRGGBBAA.
pub const Color = struct {
    color: u32,

    pub const transparent = Color{ .color = 0x00000000 };

    pub fn isTransparent(self: Color) bool {
        return (self.color & 0xff) == 0;
    }

    pub fn r(self: Color) u8 {
        return @intCast((self.color >> 24) & 0xff);
    }

    pub fn g(self: Color) u8 {
        return @intCast((self.color >> 16) & 0xff);
    }

    pub fn b(self: Color) u8 {
        return @intCast((self.color >> 8) & 0xff);
    }

    pub fn a(self: Color) u8 {
        return @intCast(self.color & 0xff);
    }

    pub fn withAlpha(self: Color, alpha: u8) Color {
        return .{ .color = (self.color & 0xffffff00) | @as(u32, alpha) };
    }

    pub fn withAlphaFactor(self: Color, factor: f32) Color {
        return self.withAlpha(
            capFloat(@as(f32, @floatFromInt(self.a())) * factor),
        );
    }

    pub fn brightness(self: Color, factor: i32) Color {
        const red_value = @as(i32, @intCast((self.color >> 24) & 0xff));
        const green_value = @as(i32, @intCast((self.color >> 16) & 0xff));
        const blue_value = @as(i32, @intCast((self.color >> 8) & 0xff));
        const alpha_value = @as(u8, @intCast(self.color & 0xff));

        return .rgba(
            @intCast(std.math.clamp(red_value + factor, 0, 255)),
            @intCast(std.math.clamp(green_value + factor, 0, 255)),
            @intCast(std.math.clamp(blue_value + factor, 0, 255)),
            alpha_value,
        );
    }

    fn capFloat(value: f32) u8 {
        return @as(u8, @intFromFloat(std.math.clamp(value, 0.0, 255.0)));
    }

    pub fn interpolate(source: Color, destination: Color, fraction: f32) Color {
        const source_r = @as(f32, @floatFromInt(source.r()));
        const source_g = @as(f32, @floatFromInt(source.g()));
        const source_b = @as(f32, @floatFromInt(source.b()));
        const source_a = @as(f32, @floatFromInt(source.a()));
        const destination_r = @as(f32, @floatFromInt(destination.r()));
        const destination_g = @as(f32, @floatFromInt(destination.g()));
        const destination_b = @as(f32, @floatFromInt(destination.b()));
        const destination_a = @as(f32, @floatFromInt(destination.a()));

        return .rgba(
            capFloat(std.math.lerp(source_r, destination_r, fraction)),
            capFloat(std.math.lerp(source_g, destination_g, fraction)),
            capFloat(std.math.lerp(source_b, destination_b, fraction)),
            capFloat(std.math.lerp(source_a, destination_a, fraction)),
        );
    }

    pub fn composite(base: Color, overlay: Color) Color {
        const base_r = @as(f32, @floatFromInt(base.r())) / 255.0;
        const base_g = @as(f32, @floatFromInt(base.g())) / 255.0;
        const base_b = @as(f32, @floatFromInt(base.b())) / 255.0;
        const base_a = @as(f32, @floatFromInt(base.a())) / 255.0;

        const overlay_r = @as(f32, @floatFromInt(overlay.r())) / 255.0;
        const overlay_g = @as(f32, @floatFromInt(overlay.g())) / 255.0;
        const overlay_b = @as(f32, @floatFromInt(overlay.b())) / 255.0;
        const overlay_a = @as(f32, @floatFromInt(overlay.a())) / 255.0;

        const merged_a = (1.0 - overlay_a) * base_a + overlay_a;
        if (merged_a == 0.0) return .clear;

        return .rgba(
            capFloat((((1.0 - overlay_a) * base_a * base_r + overlay_a * overlay_r) / merged_a) * 255.0),
            capFloat((((1.0 - overlay_a) * base_a * base_g + overlay_a * overlay_g) / merged_a) * 255.0),
            capFloat((((1.0 - overlay_a) * base_a * base_b + overlay_a * overlay_b) / merged_a) * 255.0),
            capFloat(merged_a * 255.0),
        );
    }

    pub fn fromStr(str: []const u8) Color {
        return .rgba(str[0], str[1], str[2], 255);
    }

    /// Creates an RGBA color from normalized floating-point channels.
    pub fn rgbaF32(values: [4]f32) Color {
        return .rgba(
            @intFromFloat(std.math.clamp(@round(values[0] * 255.0), 0.0, 255.0)),
            @intFromFloat(std.math.clamp(@round(values[1] * 255.0), 0.0, 255.0)),
            @intFromFloat(std.math.clamp(@round(values[2] * 255.0), 0.0, 255.0)),
            @intFromFloat(std.math.clamp(@round(values[3] * 255.0), 0.0, 255.0)),
        );
    }

    /// Converts this color to normalized floating-point RGBA channels.
    pub fn colorToF32(self: Color) [4]f32 {
        return .{
            @as(f32, @floatFromInt(self.r())) / 255.0,
            @as(f32, @floatFromInt(self.g())) / 255.0,
            @as(f32, @floatFromInt(self.b())) / 255.0,
            @as(f32, @floatFromInt(self.a())) / 255.0,
        };
    }

    pub fn rgba(red_value: u8, green_value: u8, blue_value: u8, alpha_value: u8) Color {
        return .{
            .color = (@as(u32, red_value) << 24) |
                (@as(u32, green_value) << 16) |
                (@as(u32, blue_value) << 8) |
                @as(u32, alpha_value),
        };
    }

    pub fn toBytes(self: Color) [4]u8 {
        return [_]u8{ self.r(), self.g(), self.b(), self.a() };
    }

    pub const alto = Color{ .color = 0xDCDCDCff };
    pub const alto_light = Color{ .color = 0xA4A4A4ff };
    pub const amber = Color{ .color = 0xFFC000ff };
    pub const anakiwa = Color{ .color = 0x9BE1FFff };
    pub const apple = Color{ .color = 0x52AF42ff };
    pub const astral = Color{ .color = 0x3182A5ff };
    pub const black = Color{ .color = 0x000000ff };
    pub const black_pearl = Color{ .color = 0x071824ff };
    pub const black_russian = Color{ .color = 0x03001cff };
    pub const blue = Color{ .color = 0x0000FFff };
    pub const bunker = Color{ .color = 0x070A0Dff };
    pub const cape_palliser = Color{ .color = 0x9D6942ff };
    pub const cerulean = Color{ .color = 0x009DE0ff };
    pub const cerulean_dark = Color{ .color = 0x004766ff };
    pub const cinnabar = Color{ .color = 0xe2472fff };
    pub const clear = Color{ .color = 0x00000000 };
    pub const cod_gray = Color{ .color = 0x1E1E1Eff };
    pub const confetti = Color{ .color = 0xE8D463ff };
    pub const cornflower = Color{ .color = 0x84B0E3ff };
    pub const cream_brulee = Color{ .color = 0xFFE9A1ff };
    pub const curious_blue = Color{ .color = 0x2589D0ff };
    pub const desert = Color{ .color = 0xAC5520ff };
    pub const dove_gray = Color{ .color = 0x646464ff };
    pub const ebony = Color{ .color = 0x111126ff };
    pub const feijoa = Color{ .color = 0xABDB88ff };
    pub const fuschia_pink = Color{ .color = 0xC261B9ff };
    pub const geraldine = Color{ .color = 0xFA7883ff };
    pub const golden_rod = Color{ .color = 0xFED769ff };
    pub const grandis = Color{ .color = 0xFFD68Aff };
    pub const gray = Color{ .color = 0x828282ff };
    pub const gray_chateau = Color{ .color = 0x969eaaff };
    pub const green = Color{ .color = 0x00FF00ff };
    pub const green_pea = Color{ .color = 0x1C7546ff };
    pub const havelock_blue = Color{ .color = 0x5698E3ff };
    pub const logan = Color{ .color = 0xAAAAC8ff };
    pub const malibu = Color{ .color = 0x76B6FFff };
    pub const metallic_bronze = Color{ .color = 0x492D1Cff };
    pub const midnight_blue = Color{ .color = 0x00366Eff };
    pub const midnight_moss = Color{ .color = 0x071807ff };
    pub const midnight_moss_light = Color{ .color = 0x103610ff };
    pub const mine_shaft = Color{ .color = 0x282828ff };
    pub const mine_shaft_light = Color{ .color = 0x2A2A2Aff };
    pub const mustard = Color{ .color = 0xFFD455ff };
    pub const persimmon = Color{ .color = 0xFF5F5Aff };
    pub const pink_flamingo = Color{ .color = 0xFF5AEFff };
    pub const port_gore = Color{ .color = 0x1E2541ff };
    pub const punch = Color{ .color = 0xDB3232ff };
    pub const red = Color{ .color = 0xFF0000ff };
    pub const rose_bud = Color{ .color = 0xFBA9A9ff };
    pub const science_blue = Color{ .color = 0x005CBBff };
    pub const silver = Color{ .color = 0xC1C1C1ff };
    pub const silver_chalice = Color{ .color = 0xAAAAAAff };
    pub const sundance = Color{ .color = 0xCDA458ff };
    pub const texas_rose = Color{ .color = 0xFFAF5Fff };
    pub const white = Color{ .color = 0xFFFFFFff };
    pub const onion = Color{ .color = 0x2E260Dff };
    pub const carnation = Color{ .color = 0xF25862ff };
    pub const salmon = Color{ .color = 0xF88B6Fff };
    pub const rajah = Color{ .color = 0xFAB76Aff };

    pub const ambient_night_light = Color.ebony.withAlpha(178);
    pub const ambient_warm_light = Color{ .color = 0xFFC0001A };
    pub const ambient_cold_light = Color{ .color = 0xC1BCFF1A };

    pub const fog_of_war_fg = Color.mine_shaft;
    pub const fog_of_war_bg = Color.black;

    pub const conquered_border_fg = Color.curious_blue;
    pub const conquered_border_bg = Color.bunker;

    pub const selected_bg = Color.amber;

    pub const menu_background = Color.black;
    pub const menu_border = Color.port_gore.brightness(-20);
    pub const menu_header = Color.apple;
    pub const root_header = Color.apple.brightness(25);
    pub const description_foreground = Color.logan;
    pub const tab_background_on = Color.amber;
    pub const tab_background_off = Color.port_gore.interpolate(Color.amber, 0.3);
};

// zig fmt: off
pub const cp437_utf8 = [256][]const u8{
    "␀", "☺", "☻", "♥", "♦", "♣", "♠", "•",
    "◘", "○", "◙", "♂", "♀", "♪", "♫", "☼",
    "►", "◄", "↕", "‼", "¶", "§", "▬", "↨",
    "↑", "↓", "→", "←", "∟", "↔", "▲", "▼",
    " ", "!", "\"", "#", "$", "%", "&", "'",
    "(", ")", "*", "+", ",", "-", ".", "/",
    "0", "1", "2", "3", "4", "5", "6", "7",
    "8", "9", ":", ";", "<", "=", ">", "?",
    "@", "A", "B", "C", "D", "E", "F", "G",
    "H", "I", "J", "K", "L", "M", "N", "O",
    "P", "Q", "R", "S", "T", "U", "V", "W",
    "X", "Y", "Z", "[", "\\", "]", "^", "_",
    "`", "a", "b", "c", "d", "e", "f", "g",
    "h", "i", "j", "k", "l", "m", "n", "o",
    "p", "q", "r", "s", "t", "u", "v", "w",
    "x", "y", "z", "{", "|", "}", "~", "⌂",
    "Ç", "ü", "é", "â", "ä", "à", "å", "ç",
    "ê", "ë", "è", "ï", "î", "ì", "Ä", "Å",
    "É", "æ", "Æ", "ô", "ö", "ò", "û", "ù",
    "ÿ", "Ö", "Ü", "¢", "£", "¥", "₧", "ƒ",
    "á", "í", "ó", "ú", "ñ", "Ñ", "ª", "º",
    "¿", "⌐", "¬", "½", "¼", "¡", "«", "»",
    "░", "▒", "▓", "│", "┤", "╡", "╢", "╖",
    "╕", "╣", "║", "╗", "╝", "╜", "╛", "┐",
    "└", "┴", "┬", "├", "─", "┼", "╞", "╟",
    "╚", "╔", "╩", "╦", "╠", "═", "╬", "╧",
    "╨", "╤", "╥", "╙", "╘", "╒", "╓", "╫",
    "╪", "┘", "┌", "█", "▄", "▌", "▐", "▀",
    "α", "ß", "Γ", "π", "Σ", "σ", "µ", "τ",
    "Φ", "Θ", "Ω", "δ", "∞", "φ", "ε", "∩",
    "≡", "±", "≥", "≤", "⌠", "⌡", "÷", "≈",
    "°", "∙", "·", "√", "ⁿ", "²", "■", " ",
};
// zig fmt: on
