const std = @import("std");
const stbi = @import("zstbi");

pub const Kind = enum {
    image,
    audio,
};

pub const Metadata = union(Kind) {
    image: struct {
        path: [:0]const u8,
    },
    audio: struct {
        path: [:0]const u8,
    },
};

pub const Asset = enum {
    buddy,
    cheepicus,
    default,
    giann_shaded,
    giann,
    hallow,
    rcurses,
    // redjack,
    scientifica,
    sm,
    taffer,
    tergel,

    fn loadRaw(self: @This(), gpa: std.mem.Allocator, io: std.Io) ![]const u8 {
        const metadata = assets_metadata.get(self);

        std.debug.assert(metadata == .image);

        const file = try std.Io.Dir.cwd().openFile(
            io,
            metadata.image.path,
            .{},
        );
        defer file.close(io);

        const data = try gpa.alloc(u8, (try file.stat(io)).size);
        _ = try file.readPositionalAll(io, data, 0);

        return data;
    }

    pub fn loadImage(self: @This()) !stbi.Image {
        const metadata = assets_metadata.get(self);

        std.debug.assert(metadata == .image);

        // All GPU image textures are created as RGBA8, so expand source
        // images with fewer channels before uploading their pixel data.
        return try stbi.Image.loadFromFile(metadata.image.path, 4);
    }
};

pub const assets_metadata = std.EnumArray(Asset, Metadata).init(
    .{
        .buddy = .{ .image = .{ .path = "assets/fonts/buddy.png" } },
        .cheepicus = .{ .image = .{ .path = "assets/fonts/cheepicus.png" } },
        .default = .{ .image = .{ .path = "assets/fonts/default.png" } },
        .giann_shaded = .{ .image = .{ .path = "assets/fonts/giann-shaded.png" } },
        .giann = .{ .image = .{ .path = "assets/fonts/giann.png" } },
        .hallow = .{ .image = .{ .path = "assets/fonts/hallow.png" } },
        .rcurses = .{ .image = .{ .path = "assets/fonts/rcurses.png" } },
        // .redjack = .{ .image = .{ .path = "assets/fonts/redjack.png" } },
        .scientifica = .{ .image = .{ .path = "assets/fonts/scientifica.png" } },
        .sm = .{ .image = .{ .path = "assets/fonts/sm.png" } },
        .taffer = .{ .image = .{ .path = "assets/fonts/taffer.png" } },
        .tergel = .{ .image = .{ .path = "assets/fonts/tergel.png" } },
    },
);
