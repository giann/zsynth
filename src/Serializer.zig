//! Protobuf persistence for the DSP graph and SynthEditor layout.
const std = @import("std");
const DSP = @import("DSP.zig");
const Space = @import("Space.zig");
const P = @import("zsynth.pb.zig");

/// Current on-disk protobuf schema version.
const schema_version: u32 = 1;

/// Saves and loads one live DSP graph without serializing runtime audio state.
pub const Serializer = @This();

/// DSP graph being persisted.
dsp: *DSP,
/// Visual graph layout being persisted.
space: *Space,
/// Allocator owning names and sequencer notes retained by loaded nodes.
allocator: std.mem.Allocator,
/// Process I/O context used to access the current working directory.
io: std.Io,
owned_names: std.ArrayList([]u8) = .empty,
owned_notes: std.ArrayList([]DSP.Note) = .empty,

/// Releases allocations retained by the current loaded document.
pub fn deinit(self: *Serializer) void {
    for (self.owned_names.items) |name|
        self.allocator.free(name);
    for (self.owned_notes.items) |notes|
        self.allocator.free(notes);
    self.owned_names.deinit(self.allocator);
    self.owned_notes.deinit(self.allocator);
}

/// Releases names and note arrays retained by the current document.
pub fn clearOwned(self: *Serializer) void {
    self.releaseOwned();
}

/// Writes the current graph, visual node positions, and viewport position to a protobuf file.
pub fn save(self: *Serializer, path: []const u8) !void {
    if (path.len == 0)
        return error.EmptySynthPath;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const arena_gpa = arena.allocator();

    var document = P.SynthDocument{
        .schema_version = schema_version,
        .output_node = @intCast(self.dsp.output.idx),
        .viewport_x = self.space.viewport.x,
        .viewport_y = self.space.viewport.y,
    };

    if (self.space.nodes.len != self.dsp.nodes.len)
        return error.InvalidVisualGraph;

    for (self.dsp.nodes.items(.state), 0..) |state, index| {
        var node = P.Node{
            .kind = @tagName(std.meta.activeTag(state)),
            .name = self.dsp.nodes.items(.name)[index],
            .x = self.space.nodePosition(.{ .idx = index }).x,
            .y = self.space.nodePosition(.{ .idx = index }).y,
        };

        for (self.dsp.nodes.items(.inputs)[index], 0..) |connection, input_port| {
            if (connection.isNoop()) continue;
            try node.inputs.append(arena_gpa, .{
                .input_port = @intCast(input_port),
                .source_node = @intCast(connection.node.idx),
                .source_port = connection.output_port,
            });
        }

        node.parameters = try parametersToProto(state, arena_gpa);
        try document.nodes.append(arena_gpa, node);
    }

    var file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
    defer file.close(self.io);
    var buffer: [1024]u8 = undefined;
    var writer = file.writer(self.io, &buffer);
    try document.encode(&writer.interface, arena_gpa);
    try writer.interface.flush();
}

/// Loads a document, replacing the current graph and viewport while preserving play state.
pub fn load(self: *Serializer, path: []const u8) !void {
    if (path.len == 0)
        return error.EmptySynthPath;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const arena_gpa = arena.allocator();

    var file = try std.Io.Dir.cwd().openFile(self.io, path, .{ .mode = .read_only });
    defer file.close(self.io);
    var buffer: [1024]u8 = undefined;
    var reader = file.reader(self.io, &buffer);
    var document = try P.SynthDocument.decode(&reader.interface, arena_gpa);

    try validateDocument(document);

    const was_playing = self.dsp.isPlaying();
    try self.dsp.stop();
    self.dsp.reset(self.allocator);
    self.space.reset(self.allocator);
    self.space.viewport.x = document.viewport_x;
    self.space.viewport.y = document.viewport_y;
    self.releaseOwned();

    // DSP.reset() retains the runtime sentinel at index zero.
    try self.space.addNode(self.allocator, .noop, .{
        .x = document.nodes.items[0].x,
        .y = document.nodes.items[0].y,
    });

    for (document.nodes.items[1..], 1..) |serialized, index| {
        const name = try self.ownName(serialized.name);
        const node = try nodeFromProto(self, serialized, name);
        const actual = try self.dsp.addNode(self.allocator, node);
        std.debug.assert(actual.idx == index);
        try self.space.addNode(self.allocator, actual, .{
            .x = serialized.x,
            .y = serialized.y,
        });
    }

    self.dsp.output = .{ .idx = @intCast(document.output_node) };
    for (document.nodes.items, 0..) |serialized, destination_index| {
        for (serialized.inputs.items) |connection| {
            self.dsp.plug(
                .{ .idx = @intCast(connection.source_node) },
                @intCast(connection.source_port),
                .{ .idx = destination_index },
                @intCast(connection.input_port),
            );
        }
    }

    if (!try self.space.rebuildOccupancy(self.allocator))
        return error.InvalidVisualNodeLayout;
    try self.space.computePaths(self.allocator);
    if (was_playing)
        try self.dsp.start();
}

/// Frees names and note arrays retained by the previous loaded graph.
fn releaseOwned(self: *Serializer) void {
    for (self.owned_names.items) |name|
        self.allocator.free(name);
    for (self.owned_notes.items) |notes|
        self.allocator.free(notes);
    self.owned_names.clearRetainingCapacity();
    self.owned_notes.clearRetainingCapacity();
}

/// Copies a protobuf node name into storage that outlives the decode arena.
fn ownName(self: *Serializer, name: []const u8) ![]const u8 {
    const owned = try self.allocator.dupe(u8, name);
    self.owned_names.append(self.allocator, owned) catch |err| {
        self.allocator.free(owned);
        return err;
    };
    return owned;
}

/// Copies sequencer notes into storage owned by the live editor graph.
fn ownNotes(self: *Serializer, notes: []DSP.Note) ![]const DSP.Note {
    try self.owned_notes.append(self.allocator, notes);
    return notes;
}

/// Converts a runtime node state to its typed protobuf configuration.
fn parametersToProto(
    state: DSP.Node.State,
    gpa: std.mem.Allocator,
) !?P.Node.parameters_union {
    return switch (state) {
        .noop, .add, .multiply, .output => null,
        .keyboard => |value| .{ .keyboard = .{
            .octave = value.parameters.octave,
        } },
        .constant => |value| .{ .constant = .{ .constant = value.parameters.constant } },
        .oscillator => |value| .{ .oscillator = .{
            .waveform = @tagName(value.parameters.waveform),
            .phase_offset = value.parameters.phase_offset,
            .default_frequency = value.parameters.default_frequency,
            .default_amplitude = value.parameters.default_amplitude,
        } },
        .mixer => |value| blk: {
            var result = P.MixerParameters{ .gain = value.parameters.gain };
            for (value.parameters.gains) |gain|
                try result.gains.append(gpa, gain);
            for (value.parameters.pans) |pan|
                try result.pans.append(gpa, pan);
            break :blk .{ .mixer = result };
        },
        .monophonic_sequencer => |value| blk: {
            var result = P.SequencerParameters{
                .bpm = value.parameters.bpm,
                .loop = value.parameters.loop,
            };
            for (value.parameters.notes) |note| {
                try result.notes.append(gpa, .{
                    .pitch = note.pitch orelse 0,
                    .has_pitch = note.pitch != null,
                    .start_tick = note.start_tick,
                    .duration_ticks = note.duration_ticks,
                    .velocity = note.velocity,
                });
            }
            break :blk .{ .sequencer = result };
        },
        .adsr => |value| .{ .adsr = .{
            .attack = value.parameters.attack,
            .attack_curve = @tagName(value.parameters.attack_curve),
            .decay = value.parameters.decay,
            .decay_curve = @tagName(value.parameters.decay_curve),
            .sustain = value.parameters.sustain,
            .release = value.parameters.release,
            .release_curve = @tagName(value.parameters.release_curve),
        } },
        .multimode_filter => |value| .{ .filter = .{
            .type = @tagName(value.parameters.type),
            .default_cutoff = value.parameters.default_cutoff,
            .default_resonance = value.parameters.default_resonance,
        } },
        .bit_crusher => |value| .{ .bit_crusher = .{
            .target_sample_rate = value.parameters.target_sample_rate,
            .bit_depth = value.parameters.bit_depth,
        } },
        .noise => |value| .{ .noise = .{
            .seed = value.parameters.seed,
            .type = @tagName(value.parameters.type),
            .amplitude = value.parameters.amplitude,
        } },
    };
}

/// Creates a runtime node from a validated protobuf node.
fn nodeFromProto(
    self: *Serializer,
    serialized: P.Node,
    name: []const u8,
) !DSP.Node {
    if (std.mem.eql(u8, serialized.kind, "add")) return DSP.Node.Add.create(name);
    if (std.mem.eql(u8, serialized.kind, "multiply")) return DSP.Node.Multiply.create(name);
    if (std.mem.eql(u8, serialized.kind, "output")) return DSP.Node.Output.create(name);
    if (std.mem.eql(u8, serialized.kind, "noop")) return DSP.Node.Noop.create(name);

    if (std.mem.eql(u8, serialized.kind, "constant")) {
        const value = try requiredParameters(serialized, .constant);
        return DSP.Node.Constant.create(name, .{
            .constant = value.constant orelse 0,
        });
    }
    if (std.mem.eql(u8, serialized.kind, "oscillator")) {
        const value = try requiredParameters(serialized, .oscillator);
        return DSP.Node.Oscillator.create(name, .{
            .waveform = try enumFromString(DSP.Node.Oscillator.Waveform, value.waveform orelse ""),
            .phase_offset = value.phase_offset orelse 0,
            .default_frequency = value.default_frequency orelse 0,
            .default_amplitude = value.default_amplitude orelse 0,
        });
    }
    if (std.mem.eql(u8, serialized.kind, "mixer")) {
        const value = try requiredParameters(serialized, .mixer);
        if (value.gains.items.len != DSP.max_outlets or value.pans.items.len != DSP.max_outlets)
            return error.InvalidNodeParameters;
        return DSP.Node.Mixer.create(name, .{
            .gain = value.gain orelse 1,
            .gains = value.gains.items[0..DSP.max_outlets].*,
            .pans = value.pans.items[0..DSP.max_outlets].*,
        });
    }
    if (std.mem.eql(u8, serialized.kind, "monophonic_sequencer")) {
        const value = try requiredParameters(serialized, .sequencer);
        var notes = try self.allocator.alloc(DSP.Note, value.notes.items.len);
        for (value.notes.items, 0..) |note, index| {
            notes[index] = .{
                .pitch = if (note.has_pitch orelse false) blk: {
                    const pitch = note.pitch orelse {
                        self.allocator.free(notes);
                        return error.InvalidNodeParameters;
                    };
                    if (pitch > std.math.maxInt(u7)) {
                        self.allocator.free(notes);
                        return error.InvalidNodeParameters;
                    }
                    break :blk @intCast(pitch);
                } else null,
                .start_tick = note.start_tick orelse 0,
                .duration_ticks = note.duration_ticks orelse 0,
                .velocity = note.velocity orelse 1,
            };
        }
        const owned_notes = self.ownNotes(notes) catch |err| {
            self.allocator.free(notes);
            return err;
        };
        return DSP.Node.MonophonicSequencer.create(name, .{
            .bpm = @intCast(value.bpm orelse 120),
            .notes = owned_notes,
            .loop = value.loop orelse true,
        });
    }
    if (std.mem.eql(u8, serialized.kind, "adsr")) {
        const value = try requiredParameters(serialized, .adsr);
        return DSP.Node.ADSR.create(name, .{
            .attack = value.attack orelse 0,
            .attack_curve = try enumFromString(DSP.Node.ADSR.Curve, value.attack_curve orelse "exponential"),
            .decay = value.decay orelse 0,
            .decay_curve = try enumFromString(DSP.Node.ADSR.Curve, value.decay_curve orelse "exponential"),
            .sustain = value.sustain orelse 1,
            .release = value.release orelse 1,
            .release_curve = try enumFromString(DSP.Node.ADSR.Curve, value.release_curve orelse "exponential"),
        });
    }
    if (std.mem.eql(u8, serialized.kind, "multimode_filter")) {
        const value = try requiredParameters(serialized, .filter);
        return DSP.Node.MultimodeFilter.create(name, .{
            .type = try enumFromString(DSP.Node.MultimodeFilter.Type, value.type orelse "low_pass"),
            .default_cutoff = value.default_cutoff orelse 0,
            .default_resonance = value.default_resonance orelse 0,
        });
    }
    if (std.mem.eql(u8, serialized.kind, "bit_crusher")) {
        const value = try requiredParameters(serialized, .bit_crusher);
        const bit_depth = value.bit_depth orelse 8;
        if (bit_depth > std.math.maxInt(u5)) return error.InvalidNodeParameters;
        return DSP.Node.BitCrusher.create(name, .{
            .target_sample_rate = value.target_sample_rate orelse 8_000,
            .bit_depth = @intCast(bit_depth),
        });
    }
    if (std.mem.eql(u8, serialized.kind, "noise")) {
        const value = try requiredParameters(serialized, .noise);
        return DSP.Node.Noise.create(name, .{
            .seed = value.seed orelse 0,
            .type = try enumFromString(DSP.Node.Noise.Type, value.type orelse "white"),
            .amplitude = value.amplitude orelse 1,
        });
    }
    if (std.mem.eql(u8, serialized.kind, "keyboard")) {
        const value = try requiredParameters(serialized, .keyboard);
        const octave = value.octave orelse 4;
        if (octave < std.math.minInt(i8) or octave > std.math.maxInt(i8))
            return error.InvalidNodeParameters;
        return DSP.Node.Keyboard.create(name, .{
            .octave = @intCast(octave),
        });
    }
    return error.UnknownNodeKind;
}

/// Extracts one required protobuf oneof alternative.
fn requiredParameters(
    node: P.Node,
    comptime expected: P.Node._parameters_case,
) !@TypeOf(@field(@as(P.Node.parameters_union, undefined), @tagName(expected))) {
    return switch (node.parameters orelse return error.MissingNodeParameters) {
        expected => |value| value,
        else => return error.InvalidNodeParameters,
    };
}

/// Converts a serialized enum name to a runtime enum value.
fn enumFromString(comptime E: type, name: []const u8) !E {
    return std.meta.stringToEnum(E, name) orelse error.InvalidNodeParameters;
}

/// Validates all references before replacing the active graph.
fn validateDocument(document: P.SynthDocument) !void {
    if (document.schema_version != schema_version)
        return error.UnsupportedSynthSchema;
    if (document.nodes.items.len == 0 or document.nodes.items[0].kind.len == 0)
        return error.InvalidSynthDocument;
    if (document.output_node >= document.nodes.items.len)
        return error.InvalidGraphReference;

    for (document.nodes.items, 0..) |node, index| {
        if (node.kind.len == 0 or node.name.len == 0)
            return error.InvalidSynthDocument;
        if (index == 0 and !std.mem.eql(u8, node.kind, "noop"))
            return error.InvalidSynthDocument;
        if (index != 0 and std.mem.eql(u8, node.kind, "noop"))
            return error.InvalidSynthDocument;

        const tag = std.meta.stringToEnum(DSP.Node.Tag, node.kind) orelse
            return error.UnknownNodeKind;
        const metadata = DSP.node_metadata.get(tag);
        if (index != 0) {
            switch (tag) {
                .noop => unreachable,
                .add, .multiply, .output, .constant, .keyboard, .oscillator, .mixer, .monophonic_sequencer, .adsr, .multimode_filter, .bit_crusher, .noise => try validateNodeParameters(node, tag),
            }
        }
        for (node.inputs.items, 0..) |connection, connection_index| {
            if (connection.source_node == 0 or
                connection.input_port >= metadata.input_count or
                connection.source_node >= document.nodes.items.len or
                connection.source_port >= DSP.node_metadata.get(
                    std.meta.stringToEnum(DSP.Node.Tag, document.nodes.items[connection.source_node].kind) orelse
                        return error.UnknownNodeKind,
                ).output_count)
                return error.InvalidGraphReference;

            for (node.inputs.items, 0..) |other, other_index| {
                if (other_index >= connection_index) break;
                if (other.input_port == connection.input_port)
                    return error.InvalidGraphReference;
            }

            for (document.nodes.items, 0..) |other_node, other_node_index| {
                for (other_node.inputs.items, 0..) |other, other_index| {
                    if (other_node_index == index and other_index == connection_index)
                        continue;
                    if (other.source_node == connection.source_node and
                        other.source_port == connection.source_port)
                        return error.InvalidGraphReference;
                }
            }
        }
    }
}

/// Validates the typed parameter message for one node kind without mutation.
fn validateNodeParameters(node: P.Node, tag: DSP.Node.Tag) !void {
    switch (tag) {
        .constant => _ = try requiredParameters(node, .constant),
        .oscillator => {
            const value = try requiredParameters(node, .oscillator);
            _ = try enumFromString(DSP.Node.Oscillator.Waveform, value.waveform orelse "");
        },
        .mixer => {
            const value = try requiredParameters(node, .mixer);
            if (value.gains.items.len != DSP.max_outlets or value.pans.items.len != DSP.max_outlets)
                return error.InvalidNodeParameters;
        },
        .monophonic_sequencer => {
            const value = try requiredParameters(node, .sequencer);
            if (value.notes.items.len == 0 or (value.bpm orelse 120) == 0)
                return error.InvalidNodeParameters;
            for (value.notes.items) |note| {
                if (note.has_pitch orelse false) {
                    const pitch = note.pitch orelse return error.InvalidNodeParameters;
                    if (pitch > std.math.maxInt(u7)) return error.InvalidNodeParameters;
                }
            }
        },
        .adsr => {
            const value = try requiredParameters(node, .adsr);
            _ = try enumFromString(DSP.Node.ADSR.Curve, value.attack_curve orelse "exponential");
            _ = try enumFromString(DSP.Node.ADSR.Curve, value.decay_curve orelse "exponential");
            _ = try enumFromString(DSP.Node.ADSR.Curve, value.release_curve orelse "exponential");
        },
        .multimode_filter => {
            const value = try requiredParameters(node, .filter);
            _ = try enumFromString(DSP.Node.MultimodeFilter.Type, value.type orelse "low_pass");
        },
        .bit_crusher => {
            const value = try requiredParameters(node, .bit_crusher);
            if ((value.bit_depth orelse 8) > std.math.maxInt(u5))
                return error.InvalidNodeParameters;
        },
        .noise => {
            const value = try requiredParameters(node, .noise);
            _ = try enumFromString(DSP.Node.Noise.Type, value.type orelse "white");
        },
        .keyboard => {
            const value = try requiredParameters(node, .keyboard);
            const octave = value.octave orelse 4;
            if (octave < std.math.minInt(i8) or octave > std.math.maxInt(i8))
                return error.InvalidNodeParameters;
        },
        .add, .multiply, .noop, .output => {},
    }
}
