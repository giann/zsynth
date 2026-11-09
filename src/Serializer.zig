//! Protobuf persistence for the DSP graph and SynthEditor layout.
const std = @import("std");
const DSP = @import("DSP.zig");
const pa = @import("portaudio.zig");
const pm = @import("portmidi.zig");
const Space = @import("Space.zig");
const P = @import("zsynth.pb.zig");

/// Current on-disk protobuf schema version.
const schema_version: u32 = 1;

/// Returns the ordered member slot for a serialized group member.
fn serializedGroupMemberSlot(group: P.Node, member: u32) ?u8 {
    for (group.group_members.items, 0..) |candidate, slot|
        if (candidate == member) return @intCast(slot);
    return null;
}

/// Builds and hashes the exact bounded identity used to validate a serialized group link.
fn serializedGroupSubgraphHash(nodes: []const P.Node, group_index: usize) ?u64 {
    if (group_index >= nodes.len or !std.mem.eql(u8, nodes[group_index].kind, "group")) return null;
    const group = nodes[group_index];
    if (group.group_members.items.len > DSP.max_group_members) return null;
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(&[_]u8{@intCast(group.group_members.items.len)});

    for (group.group_members.items) |member| {
        if (member >= nodes.len) return null;
        const tag = std.meta.stringToEnum(DSP.Node.Tag, nodes[member].kind) orelse return null;
        hasher.update(&[_]u8{@backingInt(tag)});
        for (0..DSP.max_outlets) |input_port| {
            var found = false;
            for (nodes[member].inputs.items) |connection| {
                if (connection.input_port != input_port) continue;
                found = true;
                if (connection.source_port >= DSP.max_outlets) return null;
                if (serializedGroupMemberSlot(group, connection.source_node)) |source_slot| {
                    hasher.update(&[_]u8{ 1, source_slot, @intCast(connection.source_port) });
                } else if (connection.source_node < nodes.len and
                    std.mem.eql(u8, nodes[connection.source_node].kind, "group_input") and
                    (nodes[connection.source_node].group_owner orelse std.math.maxInt(u32)) == group_index)
                {
                    const group_port = nodes[connection.source_node].group_port orelse return null;
                    if (group_port >= DSP.max_outlets) return null;
                    hasher.update(&[_]u8{ 2, @intCast(group_port), 0 });
                } else {
                    return null;
                }
                break;
            }
            if (!found) hasher.update(&[_]u8{ 0, 0, 0 });
        }
        if (nodes[member].parameter_source != 0) {
            if (serializedGroupMemberSlot(group, nodes[member].parameter_source)) |source_slot|
                hasher.update(&[_]u8{ 1, source_slot })
            else
                return null;
        } else {
            hasher.update(&[_]u8{0});
        }
    }

    for (0..DSP.max_outlets) |group_port| {
        var found = false;
        for (group.group_inputs.items) |binding| {
            if (binding.group_port != group_port) continue;
            found = true;
            if (binding.member_port >= DSP.max_outlets) return null;
            const slot = serializedGroupMemberSlot(group, binding.member_node) orelse return null;
            hasher.update(&[_]u8{ 1, slot, @intCast(binding.member_port) });
            break;
        }
        if (!found) hasher.update(&[_]u8{0});
    }
    for (0..DSP.max_outlets) |group_port| {
        var found = false;
        for (group.group_outputs.items) |binding| {
            if (binding.group_port != group_port) continue;
            found = true;
            if (binding.member_port >= DSP.max_outlets) return null;
            const slot = serializedGroupMemberSlot(group, binding.member_node) orelse return null;
            hasher.update(&[_]u8{ 1, slot, @intCast(binding.member_port) });
            break;
        }
        if (!found) hasher.update(&[_]u8{0});
    }
    return hasher.final();
}

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

        if (std.meta.activeTag(state) == .group) {
            const group = state.group;
            for (group.members[0..group.member_count]) |member|
                try node.group_members.append(arena_gpa, @intCast(member.idx));
            for (group.input_bindings, 0..) |binding, group_port| {
                if (binding) |value|
                    try node.group_inputs.append(arena_gpa, .{
                        .group_port = @intCast(group_port),
                        .member_node = @intCast(value.node.idx),
                        .member_port = value.port,
                    });
            }
            for (group.output_bindings, 0..) |binding, group_port| {
                if (binding) |value|
                    try node.group_outputs.append(arena_gpa, .{
                        .group_port = @intCast(group_port),
                        .member_node = @intCast(value.node.idx),
                        .member_port = value.port,
                    });
            }
        }

        switch (state) {
            .group_input => |endpoint| {
                node.group_owner = @intCast(endpoint.group.idx);
                node.group_port = endpoint.port;
            },
            .group_output => |endpoint| {
                node.group_owner = @intCast(endpoint.group.idx);
                node.group_port = endpoint.port;
            },
            else => {},
        }

        if (self.dsp.nodes.items(.parameter_link)[index].source) |source|
            node.parameter_source = @intCast(source.idx);

        for (self.dsp.nodes.items(.inputs)[index], 0..) |connection, input_port| {
            if (connection.isNoop()) continue;
            try node.inputs.append(arena_gpa, .{
                .input_port = @intCast(input_port),
                .source_node = @intCast(connection.node.idx),
                .source_port = connection.output_port,
            });
        }

        node.parameters = try parametersToProto(
            state,
            arena_gpa,
            self.dsp.devices,
            self.dsp.midi_devices,
        );
        try document.nodes.append(arena_gpa, node);
    }

    // Do not persist a graph whose swap-remove references have already
    // diverged.  Loading validates before mutating the live graph, so saving
    // must apply the same invariant before creating or truncating the file.
    try validateDocument(document);

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
        switch (node.state) {
            .group_input => |endpoint| {
                std.debug.assert(endpoint.group.idx < self.dsp.nodes.len);
                std.debug.assert(endpoint.port < DSP.max_outlets);
                self.dsp.nodes.items(.state)[endpoint.group.idx].group.input_nodes[endpoint.port] = actual;
            },
            .group_output => |endpoint| {
                std.debug.assert(endpoint.group.idx < self.dsp.nodes.len);
                std.debug.assert(endpoint.port < DSP.max_outlets);
                self.dsp.nodes.items(.state)[endpoint.group.idx].group.output_nodes[endpoint.port] = actual;
            },
            else => {},
        }
    }

    // Older group documents predate explicit endpoint nodes. Append their
    // deterministic endpoint set after restoring the persisted graph.
    var endpoint_group_index: usize = 1;
    while (endpoint_group_index < self.dsp.nodes.len) : (endpoint_group_index += 1) {
        const state = self.dsp.nodes.items(.state)[endpoint_group_index];
        if (state != .group or !state.group.input_nodes[0].isNoop()) continue;
        const group = DSP.Node.Index{ .idx = endpoint_group_index };
        try self.dsp.addGroupEndpoints(self.allocator, group);
        const position = self.space.nodePosition(group);
        const endpoints = self.dsp.nodes.items(.state)[endpoint_group_index].group;
        for (0..DSP.max_outlets) |port| {
            try self.space.addNode(self.allocator, endpoints.input_nodes[port], position);
            try self.space.addNode(self.allocator, endpoints.output_nodes[port], position);
        }
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

    for (document.nodes.items, 0..) |serialized, group_index| {
        if (!std.mem.eql(u8, serialized.kind, "group")) continue;
        for (serialized.group_inputs.items) |binding| {
            const bound = self.dsp.bindGroupInput(
                .{ .idx = group_index },
                @intCast(binding.group_port),
                .{ .idx = @intCast(binding.member_node) },
                @intCast(binding.member_port),
            );
            std.debug.assert(bound);
        }
        for (serialized.group_outputs.items) |binding| {
            const bound = self.dsp.bindGroupOutput(
                .{ .idx = group_index },
                @intCast(binding.group_port),
                .{ .idx = @intCast(binding.member_node) },
                @intCast(binding.member_port),
            );
            std.debug.assert(bound);
        }
    }

    // Restore member links before group links so every cached group identity
    // already includes the complete internal parameter-link topology.
    for (0..2) |pass| {
        const restoring_group_links = pass == 1;
        for (document.nodes.items, 0..) |serialized, target_index| {
            if (serialized.parameter_source == 0 or
                (std.mem.eql(u8, serialized.kind, "group") != restoring_group_links))
                continue;
            const linked = self.dsp.linkParameters(
                .{ .idx = @intCast(serialized.parameter_source) },
                .{ .idx = target_index },
            );
            std.debug.assert(linked);
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
    devices: []const pa.Device,
    midi_devices: []const pm.Device,
) !?P.Node.parameters_union {
    return switch (state) {
        .noop, .add, .multiply, .group, .group_input, .group_output => null,
        .output => |value| blk: {
            const device = pa.deviceById(devices, value.parameters.device) orelse
                return error.InvalidOutputDevice;
            break :blk .{ .output = .{
                .host_api_name = device.host_api_name,
                .device_name = device.name,
            } };
        },
        .midi => |value| blk: {
            const device = pm.deviceById(midi_devices, value.parameters.device);
            break :blk .{
                .midi = .{
                    // Preserve PortMidi's -1 no-device sentinel in the uint32 field.
                    .source = if (value.parameters.device < 0)
                        std.math.maxInt(u32)
                    else
                        @intCast(value.parameters.device),
                    .interface_name = if (device) |current| current.interface_name else null,
                    .device_name = if (device) |current| current.name else null,
                },
            };
        },
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
    if (std.mem.eql(u8, serialized.kind, "output")) {
        const default_device = pa.defaultDevice(self.dsp.devices) orelse self.dsp.devices[0].id;
        const device_id = if (serialized.parameters) |parameters| switch (parameters) {
            .output => |value| pa.findDevice(
                self.dsp.devices,
                value.host_api_name orelse "",
                value.device_name orelse "",
            ) orelse default_device,
            else => default_device,
        } else default_device;
        return DSP.Node.Output.create(name, device_id);
    }
    if (std.mem.eql(u8, serialized.kind, "noop")) return DSP.Node.Noop.create(name);
    if (std.mem.eql(u8, serialized.kind, "group")) {
        var members: [DSP.max_group_members]DSP.Node.Index = undefined;
        if (serialized.group_members.items.len > members.len)
            return error.InvalidGraphReference;
        for (serialized.group_members.items, 0..) |member, index|
            members[index] = .{ .idx = @intCast(member) };
        return DSP.Node.Group.create(name, members[0..serialized.group_members.items.len]);
    }
    if (std.mem.eql(u8, serialized.kind, "group_input"))
        return DSP.Node.GroupInput.create(name, .{ .idx = @intCast(serialized.group_owner orelse 0) }, @intCast(serialized.group_port orelse 0));
    if (std.mem.eql(u8, serialized.kind, "group_output"))
        return DSP.Node.GroupOutput.create(name, .{ .idx = @intCast(serialized.group_owner orelse 0) }, @intCast(serialized.group_port orelse 0));

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
    if (std.mem.eql(u8, serialized.kind, "midi")) {
        const value = try requiredParameters(serialized, .midi);
        const default_device = pm.defaultInputDevice(self.dsp.midi_devices) orelse pm.NoDevice;
        const source = if (value.interface_name != null or value.device_name != null)
            pm.findDevice(
                self.dsp.midi_devices,
                value.interface_name orelse "",
                value.device_name orelse "",
            ) orelse default_device
        else if (value.source == std.math.maxInt(u32))
            pm.NoDevice
        else if (value.source <= @as(u32, std.math.maxInt(pm.DeviceId))) blk: {
            const legacy_device: pm.DeviceId = @intCast(value.source);
            break :blk if (pm.deviceById(self.dsp.midi_devices, legacy_device) != null)
                legacy_device
            else
                default_device;
        } else default_device;
        return DSP.Node.MIDI.create(
            name,
            .{ .device = source },
        );
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
                .add,
                .multiply,
                .output,
                .constant,
                .keyboard,
                .oscillator,
                .mixer,
                .monophonic_sequencer,
                .adsr,
                .multimode_filter,
                .bit_crusher,
                .noise,
                .midi,
                => try validateNodeParameters(node, tag),
                .group => try validateGroup(node, index, document.nodes.items),
                .group_input, .group_output => try validateGroupEndpoint(node, index, document.nodes.items),
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

        if (node.parameter_source != 0) {
            if (node.parameter_source >= document.nodes.items.len or
                node.parameter_source == index)
                return error.InvalidGraphReference;

            const source_tag = std.meta.stringToEnum(
                DSP.Node.Tag,
                document.nodes.items[node.parameter_source].kind,
            ) orelse return error.UnknownNodeKind;
            if (source_tag == .group and tag == .group) {
                const source_hash = serializedGroupSubgraphHash(document.nodes.items, node.parameter_source) orelse
                    return error.InvalidGraphReference;
                const target_hash = serializedGroupSubgraphHash(document.nodes.items, index) orelse
                    return error.InvalidGraphReference;
                if (source_hash != target_hash) return error.InvalidGraphReference;
            } else if (source_tag != tag or
                !DSP.node_metadata.get(tag).has_parameters or
                !DSP.node_metadata.get(tag).can_link_parameters)
                return error.InvalidGraphReference;

            for (document.nodes.items, 0..) |other, other_index| {
                if (other_index != index and other.parameter_source == node.parameter_source)
                    return error.InvalidGraphReference;
            }

            var ancestor = node.parameter_source;
            while (document.nodes.items[ancestor].parameter_source != 0) {
                ancestor = document.nodes.items[ancestor].parameter_source;
                if (ancestor == index)
                    return error.InvalidGraphReference;
            }
        }
    }
}

/// Validates a non-nested group and every persisted port binding.
fn validateGroup(node: P.Node, group_index: usize, nodes: []const P.Node) !void {
    if (node.group_members.items.len < 2 or node.group_members.items.len > DSP.max_group_members)
        return error.InvalidGraphReference;
    for (node.group_members.items) |member| {
        if (member == 0 or member >= nodes.len or member >= group_index)
            return error.InvalidGraphReference;
        if (std.mem.eql(u8, nodes[member].kind, "group"))
            return error.InvalidGraphReference;
    }
    for (node.group_inputs.items) |binding|
        try validateGroupBinding(binding, group_index, node.group_members.items, nodes, true);
    for (node.group_outputs.items) |binding|
        try validateGroupBinding(binding, group_index, node.group_members.items, nodes, false);
}

/// Validates the owner and port carried by an explicit group endpoint node.
fn validateGroupEndpoint(node: P.Node, endpoint_index: usize, nodes: []const P.Node) !void {
    const owner = node.group_owner orelse return error.InvalidGraphReference;
    const port = node.group_port orelse return error.InvalidGraphReference;
    if (owner == 0 or owner >= nodes.len or owner >= endpoint_index or port >= DSP.max_outlets)
        return error.InvalidGraphReference;
    if (!std.mem.eql(u8, nodes[owner].kind, "group"))
        return error.InvalidGraphReference;
}

/// Validates one persisted group port-to-child binding.
fn validateGroupBinding(
    binding: P.GroupBinding,
    group_index: usize,
    members: []const u32,
    nodes: []const P.Node,
    input: bool,
) !void {
    if (binding.group_port >= DSP.max_outlets or binding.member_node == 0 or
        binding.member_node >= nodes.len or binding.member_node == group_index)
        return error.InvalidGraphReference;
    var is_member = false;
    for (members) |member| {
        if (member == binding.member_node) is_member = true;
    }
    if (!is_member or std.mem.eql(u8, nodes[binding.member_node].kind, "group"))
        return error.InvalidGraphReference;
    const tag = std.meta.stringToEnum(DSP.Node.Tag, nodes[binding.member_node].kind) orelse
        return error.UnknownNodeKind;
    const metadata = DSP.node_metadata.get(tag);
    const count = if (input) metadata.input_count else metadata.output_count;
    if (binding.member_port >= count) return error.InvalidGraphReference;
}

/// Validates the typed parameter message for one node kind without mutation.
fn validateNodeParameters(node: P.Node, tag: DSP.Node.Tag) !void {
    switch (tag) {
        .constant => _ = try requiredParameters(node, .constant),
        .midi => _ = try requiredParameters(node, .midi),
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
        .output => if (node.parameters) |parameters| switch (parameters) {
            .output => {},
            else => return error.InvalidNodeParameters,
        },
        .add, .multiply, .noop, .group, .group_input, .group_output => {},
    }
}
