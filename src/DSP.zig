//! Graph-based small DSP
const std = @import("std");
const assert = std.debug.assert;
const pa = @import("portaudio.zig");
const sdl = @import("zsdl3");
const Display = @import("Display.zig");
const utils = @import("utils.zig");
const SpmcQueue = utils.SpmcQueue;
const pm = @import("portmidi.zig");
const midi = @import("MIDI.zig");

/// Module type containing the DSP graph, node definitions, and PortAudio bridge.
const DSP = @This();

pub const sample_rate = 48_000;

/// Errors returned while opening, starting, or switching the audio stream.
pub const AudioError = pa.Error || error{InvalidDevice};

/// Maximum number of interleaved stereo samples rendered in one graph block.
pub const block_size = 64;
/// Maximum number of input or output ports exposed by a node.
pub const max_outlets = 8;
/// Maximum number of parallel voices the graph can render.
pub const max_polyphony = 8;
/// Maximum number of ordinary nodes that one non-nested group may contain.
pub const max_group_members = 16;
/// Errors returned while constructing a group's fixed endpoint nodes.
pub const GroupEndpointError = error{ OutOfMemory, InvalidGroup };
/// Number of rendered blocks retained by each node's SampleTap.
pub const sample_tap_capacity = 64;

/// Per-node, audio-thread-safe history of rendered signal blocks.
pub const SampleTap = struct {
    /// One rendered block containing every tapped output signal.
    pub const Block = struct {
        /// Interleaved stereo samples indexed by tapped signal.
        samples: [max_outlets][block_size * 2]f32,
        /// Number of valid interleaved samples in each tapped signal.
        sample_count: usize,
        /// Number of tapped output signals represented by this block.
        output_count: u8,
    };

    /// Queue type used to publish blocks to independent main-thread readers.
    pub const Queue = SpmcQueue(Block);

    /// Queue descriptor owning its heap-allocated ring storage.
    queue: Queue = undefined,
};

/// Output devices cached by the application for this DSP's lifetime.
devices: []const pa.Device,
/// Input devices cached by the application for this DSP's lifetime.
input_devices: []const pa.InputDevice,
/// MIDI input devices cached by the application for this DSP's lifetime.
midi_devices: []const pm.Device,

/// Node whose first output is copied to the audio device.
output: Node.Index = .{ .idx = 1 },
/// Struct-of-arrays storage for all graph nodes.
nodes: std.MultiArrayList(Node) = .empty,
/// Synchronizes graph mutation with the audio callback's graph traversal.
graph_mutex: std.atomic.Mutex = .unlocked,

/// Generation of the currently rendered audio block.
render_generation: u64 = 0,
/// Voice index currently being evaluated by the recursive graph renderer.
render_voice: u8 = 0,

/// PortAudio output stream, opened when playback starts.
audio_stream: ?*pa.Stream = null,
/// Device ID currently bound to `audio_stream`, if one is open.
stream_device: pa.DeviceId = pa.no_device,
/// Whether the PortAudio stream is currently running.
playing: bool = false,

/// Initializes graph storage and retains the application's supported devices.
pub fn init(
    self: *DSP,
    devices: []const pa.Device,
    input_devices: []const pa.InputDevice,
    midi_devices: []const pm.Device,
    gpa: std.mem.Allocator,
) !void {
    assert(devices.len != 0);
    // Initialize graph-owned fields before creating dependent resources.
    self.* = DSP{
        .devices = devices,
        .input_devices = input_devices,
        .midi_devices = midi_devices,
    };

    // Install the sentinel node first so every default connection is valid.
    _ = try self.addNode(
        gpa,
        Node.Noop.create("noop"),
    );
}

/// Stops and releases every audio resource owned by the graph.
pub fn deinit(self: *DSP, gpa: std.mem.Allocator) void {
    self.stop() catch {};
    if (self.audio_stream) |pa_stream| {
        pa.closeStream(pa_stream) catch {};
        self.audio_stream = null;
    }
    self.lockGraph();
    defer self.unlockGraph();
    // Release node-owned device streams before freeing their node state.
    for (self.nodes.items(.deinitialize), 0..) |deinitialize, index| {
        const node = Node.Index{ .idx = index };
        self.releaseVoiceStorage(node, gpa);
        if (deinitialize) |callback|
            callback(self, node, 0, gpa);
    }
    for (self.nodes.items(.sample_tap)) |*sample_tap|
        sample_tap.queue.deinit(gpa);
    // Release all node storage using the allocator supplied at init time.
    self.nodes.deinit(gpa);
}

/// Removes every user node while retaining the no-op sentinel at index zero.
pub fn reset(self: *DSP, gpa: std.mem.Allocator) void {
    self.lockGraph();
    defer self.unlockGraph();

    while (self.nodes.len > 1) {
        const index = self.nodes.len - 1;
        // Graph replacement must close external resources before dropping nodes.
        self.releaseVoiceStorage(.{ .idx = index }, gpa);
        if (self.nodes.items(.deinitialize)[index]) |deinitialize|
            deinitialize(self, .{ .idx = index }, 0, gpa);
        self.nodes.items(.sample_tap)[index].queue.deinit(gpa);
        _ = self.nodes.pop();
    }
    self.output = .noop;
    self.render_generation = 0;
}

/// Opens and starts the selected output device.
pub fn start(self: *DSP) AudioError!void {
    if (self.playing) return;
    try self.ensureOutputStream();
    for (self.nodes.items(.state)) |*state| {
        if (state.* != .input) continue;
        const input = &state.input;
        if (input.stream == null or input.capture_started) continue;
        pa.startStream(input.stream.?) catch |err| {
            self.stopInputStreams() catch {};
            return err;
        };
        input.capture_started = true;
    }
    pa.startStream(self.audio_stream.?) catch |err| {
        self.stopInputStreams() catch {};
        return err;
    };
    self.playing = true;
}

/// Stops streaming while keeping the selected device open.
pub fn stop(self: *DSP) AudioError!void {
    var first_error: ?pa.Error = null;
    if (self.playing) {
        pa.stopStream(self.audio_stream.?) catch |err| {
            first_error = err;
        };
        if (first_error == null) self.playing = false;
    }
    self.stopInputStreams() catch |err| {
        if (first_error == null) first_error = err;
    };
    if (first_error) |err| return err;
}

/// Stops every active input capture stream while preserving its open handle.
fn stopInputStreams(self: *DSP) pa.Error!void {
    var first_error: ?pa.Error = null;
    for (self.nodes.items(.state)) |*state| {
        if (state.* != .input) continue;
        const input = &state.input;
        if (!input.capture_started) continue;
        pa.stopStream(input.stream.?) catch |err| {
            if (first_error == null) first_error = err;
            continue;
        };
        input.capture_started = false;
    }
    if (first_error) |err| return err;
}

/// Reports whether the PortAudio output stream is currently playing.
pub fn isPlaying(self: *const DSP) bool {
    return self.playing;
}

/// Changes the root output device and resumes playback if it was active.
pub fn setOutputDevice(self: *DSP, node: Node.Index, device_id: pa.DeviceId) AudioError!void {
    assert(node.idx == self.output.idx);
    assert(self.nodes.items(.state)[node.idx] == .output);
    assert(pa.deviceById(self.devices, device_id) != null);

    const output_parameters = &self.nodes.items(.state)[node.idx].output.parameters;
    const previous_device = output_parameters.device;
    if (previous_device == device_id and
        (self.audio_stream == null or self.stream_device == device_id))
        return;

    const was_playing = self.playing;
    try self.stop();
    if (self.audio_stream) |pa_stream| {
        try pa.closeStream(pa_stream);
        self.audio_stream = null;
        self.stream_device = pa.no_device;
    }

    self.lockGraph();
    output_parameters.device = device_id;
    self.unlockGraph();

    if (!was_playing) return;

    self.start() catch |switch_error| {
        self.lockGraph();
        output_parameters.device = previous_device;
        self.unlockGraph();
        self.start() catch {};
        return switch_error;
    };
}

/// Replaces a MIDI node's input stream with the selected cached device.
pub fn setMidiDevice(self: *DSP, node: Node.Index, device_id: pm.DeviceId) pm.Error!void {
    assert(self.nodes.items(.state)[node.idx] == .midi);
    assert(device_id == pm.NoDevice or pm.deviceById(self.midi_devices, device_id) != null);

    self.lockGraph();
    const current = &self.nodes.items(.state)[node.idx].midi;
    const already_open = current.parameters.device == device_id and
        (device_id == pm.NoDevice or current.stream != null);
    self.unlockGraph();
    if (already_open) return;

    // Opening a PortMidi stream can block, so do it before taking the graph
    // lock; the current stream remains usable if the replacement fails.
    var next_stream: ?*pm.MidiStream = null;
    if (device_id != pm.NoDevice) {
        var opened: *pm.MidiStream = undefined;
        try pm.openInput(&opened, device_id, block_size, null, null);
        next_stream = opened;
    }

    self.lockGraph();
    const state = &self.nodes.items(.state)[node.idx].midi;
    const previous_stream = state.stream;
    state.stream = next_stream;
    state.parameters.device = device_id;
    for (&state.held) |*held| held.gate = 0;
    self.unlockGraph();

    // The callback can only have held the old pointer before the locked swap.
    if (previous_stream) |old_stream|
        old_stream.close() catch {};
}

/// Replaces an Input node's source and resumes capture when playback is active.
pub fn setInputDevice(
    self: *DSP,
    gpa: std.mem.Allocator,
    node: Node.Index,
    device_id: pa.DeviceId,
) pa.Error!void {
    assert(self.nodes.items(.state)[node.idx] == .input);
    assert(device_id == pa.no_device or pa.inputDeviceById(self.input_devices, device_id) != null);

    self.lockGraph();
    const current = &self.nodes.items(.state)[node.idx].input;
    const already_open = current.parameters.input == device_id and
        (device_id == pa.no_device or current.stream != null);
    self.unlockGraph();
    if (already_open) return;

    // Build and optionally start replacement resources before publishing them;
    // a failure leaves the existing source usable.
    var next_capture: ?*Node.Input.Capture = null;
    var next_stream: ?*pa.Stream = null;
    if (device_id != pa.no_device) {
        const device = pa.inputDeviceById(self.input_devices, device_id) orelse return error.InvalidDevice;
        const opened = try Node.Input.openCapture(gpa, device);
        next_capture = opened.capture;
        next_stream = opened.stream;
    }
    const was_playing = self.playing;
    if (was_playing) {
        if (next_stream) |capture_stream| {
            pa.startStream(capture_stream) catch |err| {
                pa.closeStream(capture_stream) catch {};
                Node.Input.closeCapture(gpa, next_capture.?);
                return err;
            };
        }
    }

    self.lockGraph();
    const state = &self.nodes.items(.state)[node.idx].input;
    const previous_stream = state.stream;
    const previous_capture = state.capture;
    const previous_started = state.capture_started;
    state.stream = next_stream;
    state.capture = next_capture;
    state.capture_started = was_playing and next_stream != null;
    state.parameters.input = device_id;
    state.last_render_generation = std.math.maxInt(u64);
    self.unlockGraph();

    if (previous_stream) |capture_stream| {
        if (previous_started) pa.stopStream(capture_stream) catch {};
        pa.closeStream(capture_stream) catch {};
    }
    if (previous_capture) |capture|
        Node.Input.closeCapture(gpa, capture);
}

/// Opens or replaces the stream when the output node's device has changed.
fn ensureOutputStream(self: *DSP) AudioError!void {
    assert(self.nodes.items(.state)[self.output.idx] == .output);
    const device_id = self.nodes.items(.state)[self.output.idx].output.parameters.device;
    if (self.audio_stream) |pa_stream| {
        if (self.stream_device == device_id) return;
        try pa.closeStream(pa_stream);
        self.audio_stream = null;
        self.stream_device = pa.no_device;
    }

    const device = pa.deviceById(self.devices, device_id) orelse return error.InvalidDevice;
    self.audio_stream = try pa.openOutputStream(
        device,
        sample_rate,
        onAudioCallback,
        self,
    );
    self.stream_device = device_id;
}

/// Feeds PortAudio requests into the graph in bounded, fixed-size chunks.
fn onAudioCallback(
    _: ?*const anyopaque,
    output: ?*anyopaque,
    frame_count: c_ulong,
    _: ?*const pa.StreamCallbackTimeInfo,
    _: c_ulong,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    const destination = output orelse return 2;
    const self: *DSP = @ptrCast(@alignCast(user_data.?));
    const samples: [*]f32 = @ptrCast(@alignCast(destination));
    var remaining_frames: usize = @intCast(frame_count);
    var offset_samples: usize = 0;

    while (remaining_frames > 0) {
        const chunk_frames: u32 = if (remaining_frames > block_size)
            block_size
        else
            @intCast(remaining_frames);
        assert(chunk_frames <= block_size);
        const chunk_samples: usize = @as(usize, chunk_frames) * 2;
        self.stream(samples[offset_samples .. offset_samples + chunk_samples]);
        remaining_frames -= chunk_frames;
        offset_samples += chunk_samples;
    }

    return 0;
}

pub fn toggle(self: *DSP) AudioError!void {
    if (self.playing)
        try self.stop()
    else
        try self.start();
}

pub fn plug(
    self: *DSP,
    source: Node.Index,
    source_output_port: u8,
    destination: Node.Index,
    destination_port: u8,
) void {
    self.lockGraph();
    defer self.unlockGraph();

    // Validate the destination input before replacing the connection.
    const destination_tag = std.meta.activeTag(self.nodes.items(.state)[destination.idx]);
    const destination_metadata = node_metadata.get(destination_tag);
    assert(destination_port < destination_metadata.input_count);

    const inputs = self.nodes.items(.inputs);
    const output_connected = self.nodes.items(.output_connected);
    const previous = inputs[destination.idx][destination_port];

    const replacing_same_connection = !previous.isNoop() and
        previous.node.idx == source.idx and
        previous.output_port == source_output_port;
    assert(replacing_same_connection or !output_connected[source.idx][source_output_port]);

    if (!previous.isNoop())
        output_connected[previous.node.idx][previous.output_port] = false;

    inputs[destination.idx][destination_port] = .{
        .node = source,
        .output_port = source_output_port,
    };
    output_connected[source.idx][source_output_port] = true;

    if (std.meta.activeTag(self.nodes.items(.state)[destination.idx]) == .group)
        self.syncGroupInputLocked(destination, destination_port);
    self.refreshMemberGroupHashLocked(source);
    self.refreshMemberGroupHashLocked(destination);
}

/// Disconnects the edge feeding one input port.
pub fn disconnectInput(self: *DSP, destination: Node.Index, destination_port: u8) void {
    self.lockGraph();
    defer self.unlockGraph();

    assert(destination_port < max_outlets);

    const inputs = self.nodes.items(.inputs);
    const output_connected = self.nodes.items(.output_connected);
    const previous = inputs[destination.idx][destination_port];
    if (!previous.isNoop())
        output_connected[previous.node.idx][previous.output_port] = false;
    inputs[destination.idx][destination_port] = .{};

    if (std.meta.activeTag(self.nodes.items(.state)[destination.idx]) == .group)
        self.syncGroupInputLocked(destination, destination_port);
    self.refreshMemberGroupHashLocked(destination);
}

/// Disconnects every edge leaving one output port.
pub fn disconnectOutput(self: *DSP, source: Node.Index, source_output_port: u8) void {
    self.lockGraph();
    defer self.unlockGraph();

    const inputs = self.nodes.items(.inputs);
    for (inputs, 0..) |*node_inputs, destination_idx| {
        for (node_inputs, 0..) |*connection, destination_port| {
            if (!connection.isNoop() and
                connection.node.idx == source.idx and
                connection.output_port == source_output_port)
            {
                connection.* = .{};
                if (std.meta.activeTag(self.nodes.items(.state)[destination_idx]) == .group)
                    self.syncGroupInputLocked(.{ .idx = destination_idx }, @intCast(destination_port));
                self.refreshMemberGroupHashLocked(.{ .idx = destination_idx });
            }
        }
    }
    self.nodes.items(.output_connected)[source.idx][source_output_port] = false;
    self.refreshMemberGroupHashLocked(source);
}

/// Returns whether an index identifies a group.
fn isGroupLocked(self: *DSP, group: Node.Index) bool {
    return std.meta.activeTag(self.nodes.items(.state)[group.idx]) == .group;
}

/// Returns whether a node is a member with a valid input or output port.
fn validGroupMemberPortLocked(
    self: *DSP,
    group: Node.Index,
    member: Node.Index,
    port: u8,
    input: bool,
) bool {
    if (group.idx == member.idx) return false;
    const group_state = self.nodes.items(.state)[group.idx];
    if (group_state != .group) return false;
    var is_member = false;
    for (group_state.group.members[0..group_state.group.member_count]) |candidate| {
        if (candidate.idx == member.idx) {
            is_member = true;
            break;
        }
    }
    if (!is_member or std.meta.activeTag(self.nodes.items(.state)[member.idx]) == .group)
        return false;
    const metadata = node_metadata.get(std.meta.activeTag(self.nodes.items(.state)[member.idx]));
    return port < if (input) metadata.input_count else metadata.output_count;
}

/// Returns the ordered slot occupied by a member of a group.
fn groupMemberSlotLocked(self: *const DSP, group: Node.Index, member: Node.Index) ?u8 {
    const state = self.nodes.items(.state)[group.idx];
    if (state != .group) return null;
    for (state.group.members[0..state.group.member_count], 0..) |candidate, slot|
        if (candidate.idx == member.idx) return @intCast(slot);
    return null;
}

/// Rebuilds one cached group hash after a structural graph mutation.
fn rebuildGroupSubgraphHashLocked(self: *DSP, group: Node.Index) void {
    assert(std.meta.activeTag(self.nodes.items(.state)[group.idx]) == .group);

    const old_hash = self.nodes.items(.group_subgraph_hash)[group.idx];
    var hasher = std.hash.Fnv1a_64.init();
    const group_state = self.nodes.items(.state)[group.idx].group;
    hasher.update(&[_]u8{group_state.member_count});

    for (group_state.members[0..group_state.member_count]) |member| {
        hasher.update(&[_]u8{@backingInt(std.meta.activeTag(self.nodes.items(.state)[member.idx]))});

        for (self.nodes.items(.inputs)[member.idx]) |connection| {
            if (connection.isNoop()) {
                hasher.update(&[_]u8{ 0, 0, 0 });
            } else if (self.groupMemberSlotLocked(group, connection.node)) |source_slot| {
                hasher.update(&[_]u8{ 1, source_slot, connection.output_port });
            } else switch (self.nodes.items(.state)[connection.node.idx]) {
                .group_input => |endpoint| if (endpoint.group.idx == group.idx) {
                    hasher.update(&[_]u8{ 2, endpoint.port, 0 });
                } else {
                    assert(false);
                    unreachable;
                },
                else => {
                    assert(false);
                    unreachable;
                },
            }
        }

        if (self.nodes.items(.parameter_link)[member.idx].source) |source| {
            if (self.groupMemberSlotLocked(group, source)) |source_slot| {
                hasher.update(&[_]u8{ 1, source_slot });
            } else {
                assert(false);
                unreachable;
            }
        } else {
            hasher.update(&[_]u8{0});
        }
    }

    for (group_state.input_bindings) |binding| {
        if (binding) |value| {
            const slot = self.groupMemberSlotLocked(group, value.node) orelse {
                assert(false);
                unreachable;
            };
            hasher.update(&[_]u8{ 1, slot, value.port });
        } else {
            hasher.update(&[_]u8{0});
        }
    }
    for (group_state.output_bindings) |binding| {
        if (binding) |value| {
            const slot = self.groupMemberSlotLocked(group, value.node) orelse {
                assert(false);
                unreachable;
            };
            hasher.update(&[_]u8{ 1, slot, value.port });
        } else {
            hasher.update(&[_]u8{0});
        }
    }

    const hash = hasher.final();
    self.nodes.items(.group_subgraph_hash)[group.idx] = hash;
    if (old_hash == hash) return;

    const links = self.nodes.items(.parameter_link);
    if (links[group.idx].source) |source| {
        if (std.meta.activeTag(self.nodes.items(.state)[source.idx]) == .group and
            self.nodes.items(.group_subgraph_hash)[source.idx] != hash)
        {
            links[source.idx].target = null;
            links[group.idx].source = null;
        }
    }
    if (links[group.idx].target) |target| {
        if (std.meta.activeTag(self.nodes.items(.state)[target.idx]) == .group and
            hash != self.nodes.items(.group_subgraph_hash)[target.idx])
        {
            links[target.idx].source = null;
            links[group.idx].target = null;
        }
    }
}

/// Rebuilds the cached identity for every group after index repair.
fn rebuildAllGroupSubgraphHashesLocked(self: *DSP) void {
    var index: usize = 0;
    while (index < self.nodes.len) : (index += 1) {
        if (std.meta.activeTag(self.nodes.items(.state)[index]) == .group)
            self.rebuildGroupSubgraphHashLocked(.{ .idx = index });
    }
}

/// Refreshes the cached identity of the group containing a member node.
fn refreshMemberGroupHashLocked(self: *DSP, member: Node.Index) void {
    for (self.nodes.items(.state), 0..) |state, index| {
        if (state != .group) continue;
        if (self.groupMemberSlotLocked(.{ .idx = index }, member) != null) {
            self.rebuildGroupSubgraphHashLocked(.{ .idx = index });
            return;
        }
    }
}

/// Clears a group input binding and disconnects its child proxy connection.
fn clearGroupInputBindingLocked(self: *DSP, group: Node.Index, group_port: u8) void {
    const group_state = &self.nodes.items(.state)[group.idx].group;
    const binding = group_state.input_bindings[group_port] orelse return;
    const child_input = &self.nodes.items(.inputs)[binding.node.idx][binding.port];
    if (!child_input.isNoop() and
        child_input.node.idx == group_state.input_nodes[group_port].idx and
        child_input.output_port == 0)
    {
        child_input.* = .{};
        if (!group_state.input_nodes[group_port].isNoop())
            self.nodes.items(.output_connected)[group_state.input_nodes[group_port].idx][0] = false;
    }
    group_state.input_bindings[group_port] = null;
}

/// Mirrors a bound group input into its child input proxy.
fn syncGroupInputLocked(self: *DSP, group: Node.Index, group_port: u8) void {
    const group_state = &self.nodes.items(.state)[group.idx].group;
    const binding = group_state.input_bindings[group_port] orelse return;

    const child_input = &self.nodes.items(.inputs)[binding.node.idx][binding.port];
    if (!child_input.isNoop())
        self.nodes.items(.output_connected)[child_input.node.idx][child_input.output_port] = false;
    const group_input = self.nodes.items(.inputs)[group.idx][group_port];
    if (group_input.isNoop()) {
        // Preserve the child's own defaults until this group port has a source.
        child_input.* = .{};
        return;
    }
    child_input.* = .{
        .node = group_state.input_nodes[group_port],
        .output_port = 0,
    };
    self.nodes.items(.output_connected)[group_state.input_nodes[group_port].idx][0] = true;
}

/// Binds one group input to one member input and replaces the member's current source.
pub fn bindGroupInput(
    self: *DSP,
    group: Node.Index,
    group_port: u8,
    member: Node.Index,
    member_port: u8,
) bool {
    self.lockGraph();
    defer self.unlockGraph();

    if (!self.isGroupLocked(group) or
        !self.validGroupMemberPortLocked(group, member, member_port, true))
        return false;

    self.clearGroupInputBindingLocked(group, group_port);
    self.nodes.items(.state)[group.idx].group.input_bindings[group_port] = .{
        .node = member,
        .port = member_port,
    };
    self.syncGroupInputLocked(group, group_port);
    self.rebuildGroupSubgraphHashLocked(group);
    return true;
}

/// Binds one group output to one member output, replacing the old binding.
pub fn bindGroupOutput(
    self: *DSP,
    group: Node.Index,
    group_port: u8,
    member: Node.Index,
    member_port: u8,
) bool {
    self.lockGraph();
    defer self.unlockGraph();

    if (!self.isGroupLocked(group) or
        !self.validGroupMemberPortLocked(group, member, member_port, false))
        return false;

    const group_state = &self.nodes.items(.state)[group.idx].group;
    const endpoint = group_state.output_nodes[group_port];
    if (!endpoint.isNoop()) {
        const previous_input = &self.nodes.items(.inputs)[endpoint.idx][0];
        if (!previous_input.isNoop())
            self.nodes.items(.output_connected)[previous_input.node.idx][previous_input.output_port] = false;
        previous_input.* = .{};
    }
    group_state.output_bindings[group_port] = .{
        .node = member,
        .port = member_port,
    };
    if (!endpoint.isNoop()) {
        self.nodes.items(.inputs)[endpoint.idx][0] = .{
            .node = member,
            .output_port = member_port,
        };
        self.nodes.items(.output_connected)[member.idx][member_port] = true;
    }
    self.rebuildGroupSubgraphHashLocked(group);
    return true;
}

/// Removes a group input binding while leaving its external group connection intact.
pub fn unbindGroupInput(self: *DSP, group: Node.Index, group_port: u8) void {
    self.lockGraph();
    defer self.unlockGraph();
    if (!self.isGroupLocked(group)) return;
    self.clearGroupInputBindingLocked(group, group_port);
    self.rebuildGroupSubgraphHashLocked(group);
}

/// Removes a group output binding while leaving its external group connection intact.
pub fn unbindGroupOutput(self: *DSP, group: Node.Index, group_port: u8) void {
    self.lockGraph();
    defer self.unlockGraph();
    if (!self.isGroupLocked(group)) return;
    const group_state = &self.nodes.items(.state)[group.idx].group;
    const endpoint = group_state.output_nodes[group_port];
    if (!endpoint.isNoop()) {
        const previous = self.nodes.items(.inputs)[endpoint.idx][0];
        if (!previous.isNoop())
            self.nodes.items(.output_connected)[previous.node.idx][previous.output_port] = false;
        self.nodes.items(.inputs)[endpoint.idx][0] = .{};
    }
    group_state.output_bindings[group_port] = null;
    self.rebuildGroupSubgraphHashLocked(group);
}

/// Returns the child port metadata currently exposed by a group port.
/// Bound group outputs use a waveform observer for the selected group pane.
pub fn groupOutletMetadata(
    self: *const DSP,
    group: Node.Index,
    direction: enum { input, output },
    port: u8,
) Node.OutletMetadata {
    const state = self.nodes.items(.state)[group.idx];
    if (state != .group) return .{};
    const binding = switch (direction) {
        .input => state.group.input_bindings[port],
        .output => state.group.output_bindings[port],
    } orelse return switch (direction) {
        .input => .{ .name = "group input", .short_name = "in", .color = .gray },
        .output => .{ .name = "group output", .short_name = "out", .color = .gray },
    };
    const metadata = node_metadata.get(std.meta.activeTag(self.nodes.items(.state)[binding.node.idx]));
    var outlet = switch (direction) {
        .input => metadata.inputs[binding.port],
        .output => metadata.outputs[binding.port],
    };
    if (direction == .output)
        outlet.observer = .waveform;
    return outlet;
}

/// Connects one node's parameter source to another node's parameter target.
///
/// Parameter links are one-to-one and may form acyclic chains. Existing links
/// at either endpoint are replaced, matching the editor's audio-link behavior.
pub fn linkParameters(self: *DSP, source: Node.Index, target: Node.Index) bool {
    self.lockGraph();
    defer self.unlockGraph();

    if (source.idx == target.idx) return false;

    const states = self.nodes.items(.state);
    const source_state = states[source.idx];
    const target_state = states[target.idx];
    const source_tag = std.meta.activeTag(source_state);
    const target_tag = std.meta.activeTag(target_state);
    if (source_tag == .group or target_tag == .group) {
        if (source_tag != .group or target_tag != .group or
            self.nodes.items(.group_subgraph_hash)[source.idx] !=
                self.nodes.items(.group_subgraph_hash)[target.idx])
            return false;
    } else if (source_tag != target_tag or
        !node_metadata.get(source_tag).has_parameters or
        !node_metadata.get(source_tag).can_link_parameters)
        return false;

    // Walking toward the root source detects whether this link would close a cycle.
    var ancestor = source;
    while (self.nodes.items(.parameter_link)[ancestor.idx].source) |next| {
        if (next.idx == target.idx) return false;
        ancestor = next;
    }

    const links = self.nodes.items(.parameter_link);
    if (links[target.idx].source) |previous_source| {
        links[previous_source.idx].target = null;
        self.refreshMemberGroupHashLocked(previous_source);
    }
    if (links[source.idx].target) |previous_target| {
        links[previous_target.idx].source = null;
        self.refreshMemberGroupHashLocked(previous_target);
    }

    links[source.idx].target = target;
    links[target.idx].source = source;
    return true;
}

/// Disconnects the parameter source feeding a node.
pub fn disconnectParameterSource(self: *DSP, target: Node.Index) void {
    self.lockGraph();
    defer self.unlockGraph();

    const links = self.nodes.items(.parameter_link);
    if (links[target.idx].source) |source| {
        links[source.idx].target = null;
        links[target.idx].source = null;
        self.refreshMemberGroupHashLocked(source);
        self.refreshMemberGroupHashLocked(target);
    }
}

/// Disconnects the parameter target fed by a node.
pub fn disconnectParameterTarget(self: *DSP, source: Node.Index) void {
    self.lockGraph();
    defer self.unlockGraph();

    const links = self.nodes.items(.parameter_link);
    if (links[source.idx].target) |target| {
        links[target.idx].source = null;
        links[source.idx].target = null;
        self.refreshMemberGroupHashLocked(source);
        self.refreshMemberGroupHashLocked(target);
    }
}

/// Removes a node, releases its SampleTap, and repairs graph references.
pub fn remove(self: *DSP, gpa: std.mem.Allocator, node: Node.Index) void {
    self.lockGraph();
    defer self.unlockGraph();

    self.releaseVoiceStorage(node, gpa);
    if (self.nodes.items(.deinitialize)[node.idx]) |deinitialize|
        deinitialize(self, node, 0, gpa);

    const last_index = self.nodes.len - 1;
    const removing_output = self.output.idx == node.idx;

    // Detach parameter links before removing the node and repair the moved
    // node's indices after swapRemove below.
    const links = self.nodes.items(.parameter_link);
    if (links[node.idx].source) |source| {
        links[source.idx].target = null;
    }
    if (links[node.idx].target) |target| {
        links[target.idx].source = null;
    }

    // Unplug every input owned by the removed node.
    const removed_inputs = self.nodes.items(.inputs)[node.idx];
    const output_connected = self.nodes.items(.output_connected);
    for (removed_inputs) |connection| {
        if (!connection.isNoop())
            output_connected[connection.node.idx][connection.output_port] = false;
    }

    // Remove every edge whose source is the node being removed.
    const inputs = self.nodes.items(.inputs);
    for (inputs, 0..) |*node_inputs, destination_idx| {
        for (node_inputs, 0..) |*connection, destination_port| {
            if (connection.node.idx == node.idx) {
                connection.* = .{};
                if (std.meta.activeTag(self.nodes.items(.state)[destination_idx]) == .group)
                    self.syncGroupInputLocked(.{ .idx = destination_idx }, @intCast(destination_port));
            }
        }
    }

    self.nodes.items(.sample_tap)[node.idx].queue.deinit(gpa);
    self.nodes.swapRemove(node.idx);

    if (removing_output) {
        self.output = .noop;
    } else if (self.output.idx == last_index) {
        self.output = .{ .idx = node.idx };
    }

    // The last node moved into the removed slot. Rewrite references to its old index.
    if (node.idx != last_index) {
        for (self.nodes.items(.inputs)) |*node_inputs| {
            for (node_inputs) |*connection| {
                if (!connection.isNoop() and connection.node.idx == last_index)
                    connection.node = .{ .idx = node.idx };
            }
        }

        for (self.nodes.items(.parameter_link)) |*link| {
            if (link.source) |source| {
                if (source.idx == last_index)
                    link.source = .{ .idx = node.idx };
            }
            if (link.target) |target| {
                if (target.idx == last_index)
                    link.target = .{ .idx = node.idx };
            }
        }

        for (self.nodes.items(.state)) |*state| {
            switch (state.*) {
                .group_input => |*endpoint| {
                    if (endpoint.group.idx == last_index)
                        endpoint.group = .{ .idx = node.idx };
                },
                .group_output => |*endpoint| {
                    if (endpoint.group.idx == last_index)
                        endpoint.group = .{ .idx = node.idx };
                },
                else => {},
            }
        }
    }

    // Repair or clear group bindings after swap removal. Groups are not
    // nested, but their fixed binding tables still contain node indices.
    for (self.nodes.items(.state)) |*state| {
        if (state.* != .group) continue;
        var group = &state.group;
        var member_count: usize = 0;
        for (group.members[0..group.member_count]) |member| {
            if (member.idx == node.idx) continue;
            var repaired = member;
            if (node.idx != last_index and member.idx == last_index)
                repaired = .{ .idx = node.idx };
            group.members[member_count] = repaired;
            member_count += 1;
        }
        group.member_count = @intCast(member_count);
        for (&group.input_bindings) |*binding| {
            if (binding.*) |value| {
                if (value.node.idx == node.idx) binding.* = null else if (node.idx != last_index and value.node.idx == last_index)
                    binding.*.?.node = .{ .idx = node.idx };
            }
        }
        for (&group.output_bindings) |*binding| {
            if (binding.*) |value| {
                if (value.node.idx == node.idx) binding.* = null else if (node.idx != last_index and value.node.idx == last_index)
                    binding.*.?.node = .{ .idx = node.idx };
            }
        }
        for (&group.input_nodes) |*endpoint| {
            if (endpoint.*.idx == node.idx) endpoint.* = .noop else if (node.idx != last_index and endpoint.*.idx == last_index)
                endpoint.* = .{ .idx = node.idx };
        }
        for (&group.output_nodes) |*endpoint| {
            if (endpoint.*.idx == node.idx) endpoint.* = .noop else if (node.idx != last_index and endpoint.*.idx == last_index)
                endpoint.* = .{ .idx = node.idx };
        }
    }
    self.rebuildAllGroupSubgraphHashesLocked();
}

/// Appends the sixteen fixed boundary endpoint nodes owned by a group.
pub fn addGroupEndpoints(self: *DSP, gpa: std.mem.Allocator, group: Node.Index) GroupEndpointError!void {
    self.lockGraph();
    defer self.unlockGraph();

    if (self.nodes.items(.state)[group.idx] != .group)
        return error.InvalidGroup;

    var input_nodes: [max_outlets]Node.Index = @splat(.noop);
    var output_nodes: [max_outlets]Node.Index = @splat(.noop);
    const group_voice_capacity = self.groupVoiceCapacity(group);
    for (0..max_outlets) |port| {
        try self.nodes.append(gpa, Node.GroupInput.create("group input", group, @intCast(port)));
        const input_index = self.nodes.len - 1;
        self.nodes.items(.sample_tap)[input_index].queue =
            try SampleTap.Queue.initCapacity(gpa, sample_tap_capacity);
        try self.ensureCacheCapacity(gpa, .{ .idx = input_index }, group_voice_capacity);
        input_nodes[port] = .{ .idx = input_index };

        try self.nodes.append(gpa, Node.GroupOutput.create("group output", group, @intCast(port)));
        const output_index = self.nodes.len - 1;
        self.nodes.items(.sample_tap)[output_index].queue =
            try SampleTap.Queue.initCapacity(gpa, sample_tap_capacity);
        try self.ensureCacheCapacity(gpa, .{ .idx = output_index }, group_voice_capacity);
        output_nodes[port] = .{ .idx = output_index };
    }
    self.nodes.items(.state)[group.idx].group.input_nodes = input_nodes;
    self.nodes.items(.state)[group.idx].group.output_nodes = output_nodes;
}

/// Adds one ordinary node to a non-nested group's member table.
pub fn addGroupMember(
    self: *DSP,
    gpa: std.mem.Allocator,
    group: Node.Index,
    member: Node.Index,
) bool {
    self.lockGraph();
    defer self.unlockGraph();
    if (group.idx == member.idx) return false;
    if (std.meta.activeTag(self.nodes.items(.state)[group.idx]) != .group)
        return false;
    const member_tag = std.meta.activeTag(self.nodes.items(.state)[member.idx]);
    if (member_tag == .group or member_tag == .group_input or member_tag == .group_output)
        return false;
    var state = &self.nodes.items(.state)[group.idx].group;
    if (state.member_count >= max_group_members) return false;
    for (state.members[0..state.member_count]) |existing|
        if (existing.idx == member.idx) return true;
    const capacity = @max(
        self.groupVoiceCapacity(group),
        self.nodes.items(.polyphony)[member.idx],
    );
    self.ensureCacheCapacity(gpa, group, capacity) catch return false;
    for (state.input_nodes) |endpoint|
        if (!endpoint.isNoop())
            self.ensureCacheCapacity(gpa, endpoint, capacity) catch return false;
    for (state.output_nodes) |endpoint|
        if (!endpoint.isNoop())
            self.ensureCacheCapacity(gpa, endpoint, capacity) catch return false;
    state.members[state.member_count] = member;
    state.member_count += 1;
    self.rebuildGroupSubgraphHashLocked(group);
    return true;
}

/// Ensures a loaded group's cache and serialized boundary endpoints match its members' voices.
pub fn prepareGroupVoiceStorage(
    self: *DSP,
    gpa: std.mem.Allocator,
    group: Node.Index,
) std.mem.Allocator.Error!void {
    assert(group.idx < self.nodes.len);
    self.lockGraph();
    defer self.unlockGraph();
    assert(self.nodes.items(.state)[group.idx] == .group);

    const state = self.nodes.items(.state)[group.idx].group;
    const capacity = self.groupVoiceCapacity(group);
    try self.ensureCacheCapacity(gpa, group, capacity);
    for (state.input_nodes) |endpoint|
        if (!endpoint.isNoop())
            try self.ensureCacheCapacity(gpa, endpoint, capacity);
    for (state.output_nodes) |endpoint|
        if (!endpoint.isNoop())
            try self.ensureCacheCapacity(gpa, endpoint, capacity);
}

/// Appends a node and returns its index in the graph.
pub fn addNode(self: *DSP, gpa: std.mem.Allocator, node: Node) !Node.Index {
    self.lockGraph();
    defer self.unlockGraph();

    try self.nodes.append(gpa, node);
    const new_index = self.nodes.len - 1;

    self.nodes.items(.sample_tap)[new_index].queue =
        try SampleTap.Queue.initCapacity(gpa, sample_tap_capacity);
    if (std.meta.activeTag(self.nodes.items(.state)[new_index]) == .group)
        self.rebuildGroupSubgraphHashLocked(.{ .idx = new_index });

    const index = Node.Index{ .idx = new_index };

    if (node.initialize) |initialize|
        try initialize(self, index, 0, gpa);

    if (std.meta.activeTag(self.nodes.items(.state)[new_index]) == .group)
        try self.ensureCacheCapacity(gpa, index, self.groupVoiceCapacity(index))
    else if (node.polyphony > 1)
        try self.ensureVoiceStorage(gpa, index, node.polyphony);

    return index;
}

/// Errors returned while changing a node's configured voice count.
pub const PolyphonyError = error{ InvalidNode, InvalidPolyphony, OutOfMemory };

/// Changes one ordinary node's voice limit and prepares its off-thread resources.
pub fn setNodePolyphony(
    self: *DSP,
    gpa: std.mem.Allocator,
    node: Node.Index,
    count: u8,
) PolyphonyError!void {
    assert(node.idx < self.nodes.len);
    if (count == 0 or count > max_polyphony) return error.InvalidPolyphony;

    self.lockGraph();
    defer self.unlockGraph();

    const tag = std.meta.activeTag(self.nodes.items(.state)[node.idx]);
    if (tag == .group or tag == .group_input or tag == .group_output or
        tag == .output or tag == .noop)
        return error.InvalidNode;

    const previous = self.nodes.items(.polyphony)[node.idx];
    if (previous == count) return;

    if (count > previous) {
        self.ensureVoiceStorage(gpa, node, count) catch |err| {
            if (previous == 1) {
                self.releaseVoiceStorage(node, gpa);
            } else {
                self.releaseAdditionalVoiceStates(node, previous - 1, gpa);
            }
            return err;
        };
        self.nodes.items(.polyphony)[node.idx] = count;
        self.ensureParentGroupStorage(gpa, node) catch |err| {
            self.nodes.items(.polyphony)[node.idx] = previous;
            if (previous == 1) {
                self.releaseVoiceStorage(node, gpa);
                self.refreshGroupStorageAfterShrink(gpa);
            } else {
                self.releaseAdditionalVoiceStates(node, previous - 1, gpa);
            }
            return err;
        };
        self.nodes.items(.state)[node.idx].reset(0);
        if (node_metadata.get(tag).has_per_voice_state) {
            const states = self.nodes.items(.additional_states)[node.idx] orelse unreachable;
            assert(self.nodes.items(.additional_state_count)[node.idx] >= count - 1);
            for (states[0 .. count - 1], 1..) |*state, voice|
                state.reset(@intCast(voice));
        }
        return;
    }

    self.nodes.items(.polyphony)[node.idx] = count;
    if (count == 1) {
        self.releaseVoiceStorage(node, gpa);
    } else {
        self.releaseAdditionalVoiceStates(node, count - 1, gpa);
    }
    self.refreshGroupStorageAfterShrink(gpa);
}

/// Returns the displayed voice count for an ordinary node or a group wrapper.
pub fn polyphonyForDisplay(self: *const DSP, node: Node.Index) u8 {
    if (self.nodes.items(.state)[node.idx] == .group)
        return self.groupVoiceCapacity(node);
    return self.nodes.items(.polyphony)[node.idx];
}

/// Allocates fixed-size voice caches and initializes storage for additional voices.
fn ensureVoiceStorage(
    self: *DSP,
    gpa: std.mem.Allocator,
    node: Node.Index,
    count: u8,
) std.mem.Allocator.Error!void {
    assert(count > 1 and count <= max_polyphony);
    try self.ensureCacheCapacity(gpa, node, count);

    const tag = std.meta.activeTag(self.nodes.items(.state)[node.idx]);
    if (!node_metadata.get(tag).has_per_voice_state) return;

    if (self.nodes.items(.additional_states)[node.idx] == null) {
        const states = try gpa.create([max_polyphony]Node.State);
        self.nodes.items(.additional_states)[node.idx] = states;
    }
    const states = self.nodes.items(.additional_states)[node.idx].?;
    while (self.nodes.items(.additional_state_count)[node.idx] < count - 1) {
        const voice = self.nodes.items(.additional_state_count)[node.idx] + 1;
        var fresh = self.nodes.items(.state)[node.idx];
        if (fresh == .delay)
            // A delay voice owns its history buffer, so never inherit the source slice.
            fresh.delay.dry_history = &.{};
        fresh.reset(voice);
        states[voice - 1] = fresh;
        self.nodes.items(.additional_state_count)[node.idx] += 1;
        if (self.nodes.items(.initialize_voice)[node.idx]) |initialize|
            initialize(self, node, voice, gpa) catch |err| {
                if (self.nodes.items(.deinitialize)[node.idx]) |deinitialize|
                    deinitialize(self, node, voice, gpa);
                self.nodes.items(.additional_state_count)[node.idx] -= 1;
                return err;
            };
    }
}

/// Allocates a node's extra cache array when its effective capacity exceeds one.
fn ensureCacheCapacity(
    self: *DSP,
    gpa: std.mem.Allocator,
    node: Node.Index,
    count: u8,
) std.mem.Allocator.Error!void {
    assert(count >= 1 and count <= max_polyphony);
    if (count == 1 or self.nodes.items(.additional_caches)[node.idx] != null) return;
    const caches = try gpa.create([max_polyphony]Node.Cache);
    for (caches) |*cache| cache.* = .{};
    self.nodes.items(.additional_caches)[node.idx] = caches;
}

/// Releases a node's additional caches and deinitializes its extra voice states.
fn releaseVoiceStorage(self: *DSP, node: Node.Index, gpa: std.mem.Allocator) void {
    if (self.nodes.items(.additional_states)[node.idx]) |states| {
        self.releaseAdditionalVoiceStates(node, 0, gpa);
        gpa.destroy(states);
        self.nodes.items(.additional_states)[node.idx] = null;
        self.nodes.items(.additional_state_count)[node.idx] = 0;
    }

    if (self.nodes.items(.additional_caches)[node.idx]) |caches| {
        gpa.destroy(caches);
        self.nodes.items(.additional_caches)[node.idx] = null;
    }
}

/// Deinitializes removed extra voices without disturbing retained voices.
fn releaseAdditionalVoiceStates(
    self: *DSP,
    node: Node.Index,
    keep_count: u8,
    gpa: std.mem.Allocator,
) void {
    if (self.nodes.items(.additional_states)[node.idx] == null) return;
    const state_count = self.nodes.items(.additional_state_count)[node.idx];
    assert(keep_count <= state_count);
    if (self.nodes.items(.deinitialize)[node.idx]) |deinitialize|
        for (keep_count..state_count) |voice_index|
            deinitialize(self, node, @intCast(voice_index + 1), gpa);
    self.nodes.items(.additional_state_count)[node.idx] = keep_count;
}

/// Returns the maximum configured voice capacity among a group's direct members.
fn groupVoiceCapacity(self: *const DSP, group: Node.Index) u8 {
    const state = self.nodes.items(.state)[group.idx].group;
    var count: u8 = 1;
    for (state.members[0..state.member_count]) |member|
        count = @max(count, self.nodes.items(.polyphony)[member.idx]);
    return count;
}

/// Ensures the containing group's caches can carry a member's new voice count.
fn ensureParentGroupStorage(
    self: *DSP,
    gpa: std.mem.Allocator,
    member: Node.Index,
) std.mem.Allocator.Error!void {
    for (self.nodes.items(.state), 0..) |state, group_index| {
        if (state != .group) continue;
        var contains_member = false;
        for (state.group.members[0..state.group.member_count]) |candidate|
            if (candidate.idx == member.idx) {
                contains_member = true;
                break;
            };
        if (!contains_member) continue;

        const group = Node.Index{ .idx = group_index };
        const capacity = self.groupVoiceCapacity(group);
        try self.ensureCacheCapacity(gpa, group, capacity);
        for (state.group.input_nodes) |endpoint|
            if (!endpoint.isNoop())
                try self.ensureCacheCapacity(gpa, endpoint, capacity);
        for (state.group.output_nodes) |endpoint|
            if (!endpoint.isNoop())
                try self.ensureCacheCapacity(gpa, endpoint, capacity);
    }
}

/// Frees derived group caches after all their members have returned to one voice.
fn refreshGroupStorageAfterShrink(self: *DSP, gpa: std.mem.Allocator) void {
    for (self.nodes.items(.state), 0..) |state, group_index| {
        if (state != .group or self.groupVoiceCapacity(.{ .idx = group_index }) > 1) continue;
        const group = state.group;
        self.releaseCacheStorage(.{ .idx = group_index }, gpa);
        for (group.input_nodes) |endpoint|
            if (!endpoint.isNoop())
                self.releaseCacheStorage(endpoint, gpa);
        for (group.output_nodes) |endpoint|
            if (!endpoint.isNoop())
                self.releaseCacheStorage(endpoint, gpa);
    }
}

/// Releases only a node's extra output and group-input buffers.
fn releaseCacheStorage(self: *DSP, node: Node.Index, gpa: std.mem.Allocator) void {
    if (self.nodes.items(.additional_caches)[node.idx]) |caches| {
        gpa.destroy(caches);
        self.nodes.items(.additional_caches)[node.idx] = null;
    }
}

/// Presses a key on a keyboard node using its atomic voice state.
pub fn keyboardKeyDown(self: *DSP, node: Node.Index, key: sdl.Keycode) bool {
    switch (self.nodes.items(.state)[node.idx]) {
        .keyboard => |*keyboard| return keyboard.press(key),
        else => return false,
    }
}

/// Releases a key on a keyboard node using its atomic voice state.
pub fn keyboardKeyUp(self: *DSP, node: Node.Index, key: sdl.Keycode) bool {
    switch (self.nodes.items(.state)[node.idx]) {
        .keyboard => |*keyboard| return keyboard.release(key),
        else => return false,
    }
}

/// Releases all keys held by a keyboard node using atomic stores.
pub fn keyboardReleaseAll(self: *DSP, node: Node.Index) void {
    switch (self.nodes.items(.state)[node.idx]) {
        .keyboard => |*keyboard| keyboard.releaseAll(),
        else => {},
    }
}

/// Returns a node's SampleTap for immediate main-thread reads. The graph output
/// sink publishes its final rendered signal as one tap despite having no outlet.
///
/// The returned pointer must not be retained across graph mutation. The UI
/// stores only the node index and resolves the tap again for each update.
pub fn sampleTap(self: *DSP, node: Node.Index) *SampleTap {
    return &self.nodes.items(.sample_tap)[node.idx];
}

/// Renders one interleaved stereo block into the audio callback buffer.
fn stream(self: *DSP, into: []f32) void {
    if (!self.graph_mutex.tryLock()) {
        @memset(into, 0);
        return;
    }
    defer self.unlockGraph();

    // The callback may request a short block, but never more than one block.
    assert(into.len <= block_size * 2);
    assert(into.len % 2 == 0);

    // A new generation invalidates all node caches from the previous block.
    self.render_generation += 1;
    // The output node folds parallel voices into its one device-facing buffer.
    self.renderNode(self.output, 0, @intCast(into.len)) catch {
        @memset(into, 0);
        return;
    };
    const output_buffer = &self.nodes.items(.cache)[self.output.idx].outputs[0];
    @memcpy(into, output_buffer.samples[0..into.len]);
}

fn lockGraph(self: *DSP) void {
    while (!self.graph_mutex.tryLock())
        std.atomic.spinLoopHint();
}

fn unlockGraph(self: *DSP) void {
    self.graph_mutex.unlock();
}

/// Runs a bounded main-thread update while excluding the audio graph traversal.
pub fn withGraphLock(self: *DSP, context: anytype, callback: anytype) void {
    self.lockGraph();
    defer self.unlockGraph();
    callback(context);
}

/// Returns a node's cache for one voice, using the inline cache for voice zero.
fn cacheForVoice(self: *DSP, node: Node.Index, voice: u8) *Node.Cache {
    assert(voice < max_polyphony);
    if (voice == 0) return &self.nodes.items(.cache)[node.idx];
    const additional = self.nodes.items(.additional_caches)[node.idx] orelse unreachable;
    return &additional[voice - 1];
}

/// Resolves a node's primary state or an additional state by voice index.
fn stateForVoice(self: *DSP, node: Node.Index, voice: u8) *Node.State {
    assert(voice < max_polyphony);
    const tag = std.meta.activeTag(self.nodes.items(.state)[node.idx]);
    if (voice == 0 or !node_metadata.get(tag).has_per_voice_state)
        return &self.nodes.items(.state)[node.idx];
    assert(voice <= self.nodes.items(.additional_state_count)[node.idx]);
    const additional = self.nodes.items(.additional_states)[node.idx] orelse unreachable;
    return &additional[voice - 1];
}

/// Returns the concrete runtime state for the voice currently being rendered.
fn processingState(self: *DSP, node: Node.Index) *Node.State {
    return self.stateForVoice(node, self.render_voice);
}

/// Returns the voice count available from one node output port.
fn outputVoiceCount(self: *DSP, node: Node.Index, port: u8) u8 {
    const state = self.nodes.items(.state)[node.idx];
    if (state == .group) {
        const binding = state.group.output_bindings[port] orelse return 1;
        return self.effectiveVoiceCount(binding.node);
    }
    return self.effectiveVoiceCount(node);
}

/// Returns the configured and input-limited voice count for one node.
fn effectiveVoiceCount(self: *DSP, node: Node.Index) u8 {
    const state = self.nodes.items(.state)[node.idx];
    switch (state) {
        .output => {
            return 1;
        },
        .group => {
            var count: u8 = 1;
            for (state.group.output_bindings) |binding| {
                if (binding) |value|
                    count = @max(count, self.effectiveVoiceCount(value.node));
            }
            return count;
        },
        .group_input => {
            const endpoint = state.group_input;
            const input = self.nodes.items(.inputs)[endpoint.group.idx][endpoint.port];
            // An unconnected group input supplies silence, but must not cap
            // the voices of another connected input on the same child node.
            return if (input.isNoop()) max_polyphony else self.outputVoiceCount(input.node, input.output_port);
        },
        .group_output => {
            const input = self.nodes.items(.inputs)[node.idx][0];
            return if (input.isNoop()) 1 else self.outputVoiceCount(input.node, input.output_port);
        },
        else => {},
    }

    const metadata = node_metadata.get(std.meta.activeTag(state));
    var count = self.nodes.items(.polyphony)[node.idx];
    for (self.nodes.items(.inputs)[node.idx][0..metadata.input_count]) |input| {
        if (input.isNoop()) continue;
        count = @min(count, self.outputVoiceCount(input.node, input.output_port));
    }
    return count;
}

/// Evaluates one node voice and its matching input voices for the requested block.
fn renderNode(self: *DSP, node: Node.Index, voice: u8, sample_count: u32) !void {
    assert(voice < self.effectiveVoiceCount(node));
    const cache = self.cacheForVoice(node, voice);
    const source_tag = std.meta.activeTag(self.nodes.items(.state)[node.idx]);
    const output_count = if (node.idx == self.output.idx)
        1
    else
        node_metadata.get(source_tag).output_count;

    // Reuse a result already rendered during this generation and block size.
    if (cache.generation == self.render_generation and
        cache.sample_count == sample_count)
        return;

    // Clear every output so partially written ports cannot expose stale audio.
    const active_sample_count: usize = @intCast(sample_count);
    for (&cache.outputs) |*output| {
        output.sample_count = sample_count;
        @memset(output.samples[0..active_sample_count], 0);
    }

    // Adapt inline cache storage to the process callback's slice interface.
    var outputs: [max_outlets]*Buffer = undefined;
    for (&cache.outputs, 0..) |*output, i| {
        outputs[i] = output;
    }

    // If has parameter link, copy parameters from source
    if (self.nodes.items(.parameter_link)[node.idx].source) |source| {
        const destination = &self.nodes.items(.state)[node.idx];
        const source_state = &self.nodes.items(.state)[source.idx];
        if (destination.* == .group and source_state.* == .group) {
            self.copyGroupParameters(source, node);
        } else switch (destination.*) {
            inline else => |*destination_state| {
                if (@hasField(@TypeOf(destination_state.*), "parameters")) {
                    switch (source_state.*) {
                        inline else => |source_value| {
                            if (@TypeOf(destination_state.*) == @TypeOf(source_value) and
                                @hasField(@TypeOf(source_value), "parameters"))
                                destination_state.parameters = source_value.parameters;
                        },
                    }
                }
            },
        }
    }

    // Parameters are shared by voices; copy them into this voice's runtime
    // state after parameter links have updated the node's primary state.
    if (voice > 0 and node_metadata.get(source_tag).has_per_voice_state)
        self.copyVoiceParameters(node, voice);

    // The node recursively requests any connected inputs during processing.
    const previous_voice = self.render_voice;
    self.render_voice = voice;
    defer self.render_voice = previous_voice;
    try self.nodes.items(.process)[node.idx](
        self,
        node,
        outputs[0..],
    );

    // Publish the completed cache only after processing succeeds.
    cache.sample_count = sample_count;
    cache.generation = self.render_generation;

    // Each node has one SampleTap; publish its primary voice after rendering.
    if (voice == 0)
        self.publishSampleTap(node, voice, outputs[0..], active_sample_count, output_count);
}

/// Publishes one primary-voice cache to the node's non-blocking sample queue.
fn publishSampleTap(
    self: *DSP,
    node: Node.Index,
    voice: u8,
    outputs: []const *Buffer,
    sample_count: usize,
    output_count: u8,
) void {
    assert(voice == 0);
    const sample_tap = &self.nodes.items(.sample_tap)[node.idx];
    var block: SampleTap.Block = .{
        .samples = undefined,
        .sample_count = sample_count,
        .output_count = output_count,
    };
    for (0..@intCast(output_count)) |output_port| {
        @memcpy(
            block.samples[output_port][0..sample_count],
            outputs[output_port].samples[0..sample_count],
        );
    }
    _ = sample_tap.queue.tryPush(block);
}

/// Copies shared parameter payloads into one stateful voice without changing its DSP history.
fn copyVoiceParameters(self: *DSP, node: Node.Index, voice: u8) void {
    const primary = self.nodes.items(.state)[node.idx];
    const additional = self.nodes.items(.additional_states)[node.idx] orelse unreachable;
    const destination = &additional[voice - 1];
    switch (primary) {
        inline else => |source_state| {
            if (@hasField(@TypeOf(source_state), "parameters")) {
                switch (destination.*) {
                    inline else => |*destination_state| {
                        if (@TypeOf(source_state) == @TypeOf(destination_state.*) and
                            @hasField(@TypeOf(destination_state.*), "parameters"))
                            destination_state.parameters = source_state.parameters;
                    },
                }
            }
        },
    }
}

/// Copies parameter payloads between corresponding members of linked groups.
fn copyGroupParameters(self: *DSP, source: Node.Index, destination: Node.Index) void {
    const source_group = self.nodes.items(.state)[source.idx].group;
    const destination_group = &self.nodes.items(.state)[destination.idx].group;
    assert(source_group.member_count == destination_group.member_count);
    for (0..source_group.member_count) |slot| {
        const source_state = &self.nodes.items(.state)[source_group.members[slot].idx];
        const destination_state = &self.nodes.items(.state)[destination_group.members[slot].idx];
        // Delay history capacity is sized outside rendering, so a group link
        // must not copy live delay settings into a differently sized ring.
        if (destination_state.* == .delay) continue;
        switch (destination_state.*) {
            inline else => |*destination_value| {
                if (@hasField(@TypeOf(destination_value.*), "parameters")) {
                    switch (source_state.*) {
                        inline else => |source_value| {
                            if (@TypeOf(destination_value.*) == @TypeOf(source_value) and
                                @hasField(@TypeOf(source_value), "parameters"))
                                destination_value.parameters = source_value.parameters;
                        },
                    }
                }
            },
        }
    }
}

/// Resolves a connection by rendering its source and returning the requested port.
fn getOutput(
    self: *DSP,
    connection: Node.Connection,
    sample_count: u32,
) !*Buffer {
    // Rendering is cached, so repeated requests for this source are cheap.
    try self.renderNode(connection.node, self.render_voice, sample_count);

    return &self.cacheForVoice(connection.node, self.render_voice).outputs[
        @intCast(connection.output_port)
    ];
}

/// Fixed-size interleaved audio storage used for node outputs.
const Buffer = struct {
    /// Stereo-interleaved samples, with capacity for one graph block.
    samples: [block_size * 2]f32,
    /// Number of valid interleaved samples in `samples`.
    sample_count: u32 = block_size * 2,

    /// Creates a buffer and fills its complete capacity with one value.
    pub fn init(default: f32, sample_count: u32) Buffer {
        var buffer = Buffer{
            .samples = undefined,
            .sample_count = sample_count,
        };

        // Initialize the entire capacity so unused portions are deterministic.
        @memset(buffer.samples[0..], default);

        return buffer;
    }
};

/// Musical note data consumed by a monophonic sequencer.
pub const Note = struct {
    /// MIDI-compatible seven-bit pitch representation.
    pub const RawPitch = u7;

    /// Semitone offset applied to a natural pitch.
    pub const Accidental = enum(i8) {
        /// One semitone below the natural pitch.
        flat = -1,
        /// The natural pitch with no offset.
        natural = 0,
        /// One semitone above the natural pitch.
        sharp = 1,
    };

    /// Natural note names represented as semitone offsets within an octave.
    pub const Pitch = enum(i8) {
        /// C natural.
        c = 0,
        /// D natural.
        d = 2,
        /// E natural.
        e = 4,
        /// F natural.
        f = 5,
        /// G natural.
        g = 7,
        /// A natural.
        a = 9,
        /// B natural.
        b = 11,

        /// Converts a note name, accidental, and octave into a MIDI pitch.
        pub fn pitch(self: Pitch, accidental: Accidental, octave: i16) RawPitch {
            // Combine octave, natural pitch, and accidental into a MIDI number.
            const value = (octave + 1) * 12 +
                @backingInt(self) +
                @backingInt(accidental);

            // Reject values outside the representable MIDI range.
            assert(value >= 0 and value <= 127);

            // The assertion makes this narrowing conversion safe.
            return @intCast(value);
        }
    };

    /// MIDI pitch, or null for a rest.
    pitch: ?RawPitch,
    /// Tick at which the note begins.
    start_tick: u64,
    /// Duration of the note in ticks.
    duration_ticks: u64,
    /// Normalized note velocity.
    velocity: f32 = 1,

    /// Converts the MIDI pitch to frequency in hertz.
    fn frequency(self: Note) f32 {
        return if (self.pitch) |pitch|
            440 *
                std.math.pow(
                    f32,
                    2,
                    @as(f32, @floatFromInt(@as(i16, @intCast(pitch)) - 69)) / 12,
                )
        else
            0;
    }
};

/// A processable node in the audio graph.
pub const Node = struct {
    /// Concrete node parameters and mutable runtime state.
    state: State,
    /// Cached hash of the group's structural identity.
    group_subgraph_hash: u64 = 0,
    /// Display name assigned by the graph owner.
    name: []const u8,
    /// Connections feeding each input port.
    inputs: [max_outlets]Connection = @splat(.{}),
    /// Whether each output port is connected to a destination input.
    output_connected: [max_outlets]bool = @splat(false),
    /// Configured voice limit for this node; group and output wrappers derive theirs.
    polyphony: u8 = 1,
    /// Per-generation output cache.
    cache: Cache = .{},
    /// Lazily allocated caches for voices after the inline first voice.
    additional_caches: ?*[max_polyphony]Cache = null,
    /// Per-voice copies of persistent DSP state for stateful node kinds.
    additional_states: ?*[max_polyphony]State = null,
    /// Number of initialized entries in `additional_states`.
    additional_state_count: u8 = 0,
    /// Main-thread-readable history of this node's rendered outputs.
    sample_tap: SampleTap = .{},
    /// Function used to render this node's outputs.
    process: Process,
    initialize: ?Initialize = null,
    /// Allocates resources owned separately by each additional voice.
    initialize_voice: ?VoiceInitialize = null,
    deinitialize: ?Deinitialize = null,
    /// Reciprocal parameter source and target links.
    parameter_link: ParameterLink = .{},

    pub const Tag = enum {
        add,
        adsr,
        bit_crusher,
        constant,
        duplicate,
        keyboard,
        input,
        mixer,
        monophonic_sequencer,
        multimode_filter,
        multiply,
        noise,
        noop,
        oscillator,
        output,
        delay,
        group,
        group_input,
        group_output,
        midi,
    };

    /// Tagged union containing the concrete state for each node kind.
    pub const State = union(Tag) {
        /// Sum node state.
        add: Add,
        /// Envelope generator state.
        adsr: ADSR,
        /// Sample-rate and bit-depth reduction state.
        bit_crusher: BitCrusher,
        /// Constant-value source state.
        constant: Constant,
        /// One-input signal splitter state.
        duplicate: Duplicate,
        /// Computer-keyboard note source state.
        keyboard: Keyboard,
        /// PortAudio audio capture source state.
        input: Input,
        /// Multi-input mixer state.
        mixer: Mixer,
        /// Monophonic note sequencer state.
        monophonic_sequencer: MonophonicSequencer,
        /// State-variable filter state.
        multimode_filter: MultimodeFilter,
        /// Product node state.
        multiply: Multiply,
        /// Colored-noise generator state.
        noise: Noise,
        /// Unplugged-input sentinel state.
        noop: Noop,
        /// Oscillator state.
        oscillator: Oscillator,
        /// Graph output forwarding state.
        output: Output,
        /// Multi-tap delay effect state.
        delay: Delay,
        /// Non-nested proxy around a fixed set of member nodes.
        group: Group,
        group_input: GroupInput,
        group_output: GroupOutput,
        midi: MIDI,

        /// Resets the active node payload while preserving its configuration.
        pub fn reset(self: *State, voice: u8) void {
            switch (self.*) {
                inline else => |*node_state| {
                    if (comptime @hasDecl(@TypeOf(node_state.*), "reset"))
                        node_state.reset(voice);
                },
            }
        }
    };

    /// Reciprocal one-to-one parameter relationships for a node.
    pub const ParameterLink = struct {
        /// Node whose parameters this node copies, if any.
        source: ?Node.Index = null,
        /// Node that copies this node's parameters, if any.
        target: ?Node.Index = null,
    };

    /// UI observer used to visualize one output port.
    pub const Observer = enum {
        /// Display the output level with an audio meter.
        meter,
        /// Display recent output samples as a line plot.
        line_plot,
        /// Display recent audio samples as a filled stereo waveform.
        waveform,
        /// Do not display an output observer.
        none,
    };

    /// Static metadata for one node input or output.
    pub const OutletMetadata = struct {
        name: []const u8 = "",
        short_name: []const u8 = "",
        unit: []const u8 = "",
        color: Display.Color = .transparent,
        /// Observer shown for this output when its node is selected.
        observer: Observer = .none,
    };

    /// Static port metadata for a node kind.
    pub const Metadata = struct {
        name: []const u8,
        short_name: []const u8,
        color: Display.Color,
        /// Whether this node exposes a parameter payload that can be linked.
        has_parameters: bool = false,
        /// Whether the node needs separate DSP state for each graph voice.
        has_per_voice_state: bool = false,
        /// Whether the editor exposes parameter-link outlets for this node.
        can_link_parameters: bool = true,
        inputs: [max_outlets]OutletMetadata = @splat(.{}),
        outputs: [max_outlets]OutletMetadata = @splat(.{}),
        output_count: u8 = 1,
        input_count: u8 = 1,
        duplicatable: bool = true,
    };

    /// One child port exposed through a group boundary.
    pub const PortBinding = struct {
        /// Member node owning the exposed port.
        node: Index,
        /// Input or output port on `node`.
        port: u8,
    };

    /// Index into the DSP node list.
    pub const Index = struct {
        /// Index zero is reserved for the no-op sentinel node.
        pub const noop = Index{ .idx = 0 };

        /// Position in the DSP node list.
        idx: usize,

        /// Returns whether this index refers to the no-op sentinel.
        pub fn isNoop(self: Index) bool {
            return self.idx == 0;
        }
    };

    /// One directed edge from a source node output to a destination input.
    pub const Connection = struct {
        /// Source node, or the no-op sentinel when unplugged.
        node: Index = .noop,
        /// Output port read from the source node.
        output_port: u8 = 0,

        /// Returns whether this input is currently unplugged.
        pub fn isNoop(self: Connection) bool {
            return self.node.isNoop();
        }
    };

    /// Per-node output cache for the current render generation.
    pub const Cache = struct {
        /// Generation in which these outputs were rendered.
        generation: u64 = 0,
        /// Number of valid samples in each cached output.
        sample_count: u32 = 0,
        /// Cached output buffers for all possible ports.
        outputs: [max_outlets]Buffer = undefined,
        /// Preallocated buffers carrying external signals into group members.
        input_buffers: [max_outlets]Buffer = undefined,
    };

    /// Error set reserved for node processing failures.
    pub const ProcessError = error{} || pm.Error;
    /// Signature implemented by every node's audio-processing function.
    pub const Process = *const fn (
        dsp: *DSP,
        node: Index,
        outputs: []const *Buffer,
    ) ProcessError!void;
    pub const InitializeError = error{OutOfMemory} || pm.Error || pa.Error;
    /// Initializes node-level resources when the node is added to the graph.
    pub const Initialize = *const fn (
        dsp: *DSP,
        node: Index,
        voice: u8,
        allocator: std.mem.Allocator,
    ) InitializeError!void;
    /// Initializes allocator-owned resources for an additional node voice.
    pub const VoiceInitialize = *const fn (
        dsp: *DSP,
        node: Index,
        voice: u8,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!void;
    /// Releases resources owned by one node voice before it is discarded.
    pub const Deinitialize = *const fn (
        dsp: *DSP,
        node: Index,
        voice: u8,
        allocator: std.mem.Allocator,
    ) void;

    /// A node that produces silence and represents an unplugged connection.
    pub const Noop = struct {
        /// Port metadata for the no-op sentinel.
        pub const metadata = Node.Metadata{
            .name = "No-op",
            .short_name = "noop",
            .color = .gray,
            .outputs = .{
                .{ .name = "output", .short_name = "out", .color = .gray },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .input_count = 0,
        };

        /// Creates the graph's no-op sentinel node.
        pub fn create(name: []const u8) Node {
            return .{
                .state = .{ .noop = .{} },
                .name = name,
                .process = process,
            };
        }

        /// Leaves all output samples at the values supplied by the renderer.
        fn process(
            _: *DSP,
            _: Index,
            _: []const *Buffer,
        ) ProcessError!void {}
    };

    /// Root node of the graph; forwards its input into PortAudio's stream.
    pub const Output = struct {
        /// User-selectable PortAudio output device.
        parameters: Parameters,

        /// Settings persisted and edited for a graph output node.
        pub const Parameters = struct {
            /// Runtime PortAudio index selected for this output node.
            device: pa.DeviceId,
        };

        /// Port metadata for the graph output node.
        pub const metadata = Node.Metadata{
            .name = "Output",
            .short_name = "out",
            .color = .persimmon,
            .can_link_parameters = false,
            .duplicatable = false,
            .output_count = 0,
            .outputs = .{
                .{ .name = "out", .short_name = "out", .color = .persimmon, .observer = .waveform },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .inputs = .{
                .{ .name = "audio", .short_name = "in", .color = .persimmon },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
        };

        /// Creates a graph output node bound to the supplied runtime device.
        pub fn create(name: []const u8, device: pa.DeviceId) Node {
            return .{
                .state = .{
                    .output = .{ .parameters = .{ .device = device } },
                },
                .name = name,
                .process = process,
            };
        }

        /// Combines the connected source voices into the device-facing buffer.
        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            // Read the one input connection assigned to the output node.
            const input = dsp.nodes.items(.inputs)[node.idx][0];

            // An unconnected output remains silent after the renderer's clear.
            if (input.isNoop()) return;

            // Render each available source voice and combine them for the device.
            @memset(into[0].samples[0..into[0].sample_count], 0);
            const voice_count = dsp.outputVoiceCount(input.node, input.output_port);
            for (0..voice_count) |voice| {
                try dsp.renderNode(input.node, @intCast(voice), into[0].sample_count);
                const source = &dsp.cacheForVoice(input.node, @intCast(voice)).outputs[
                    @intCast(input.output_port)
                ];
                for (
                    into[0].samples[0..into[0].sample_count],
                    source.samples[0..source.sample_count],
                ) |*sample, voice_sample| sample.* += voice_sample;
            }
        }
    };

    /// Proxy node exposing selected child ports at a reusable graph boundary.
    pub const Group = struct {
        /// Port metadata for an unbound group boundary.
        pub const metadata = Node.Metadata{
            .name = "Group",
            .short_name = "grp",
            .color = .astral,
            .has_parameters = true,
            .can_link_parameters = true,
            .inputs = @splat(.{ .name = "group input", .short_name = "in", .color = .gray }),
            .outputs = @splat(.{ .name = "group output", .short_name = "out", .color = .gray }),
            .input_count = max_outlets,
            .output_count = max_outlets,
        };

        /// Member nodes owned by this group.
        members: [max_group_members]Index = @splat(.noop),
        /// Number of valid entries in `members`.
        member_count: u8 = 0,
        /// Child inputs exposed through group inputs.
        input_bindings: [max_outlets]?Node.PortBinding = @splat(null),
        /// Child outputs exposed through group outputs.
        output_bindings: [max_outlets]?Node.PortBinding = @splat(null),
        /// Explicit nodes displayed at the left boundary of the group editor.
        input_nodes: [max_outlets]Index = @splat(.noop),
        /// Explicit nodes displayed at the right boundary of the group editor.
        output_nodes: [max_outlets]Index = @splat(.noop),
        /// Creates a group with an initially empty port-binding table.
        pub fn create(name: []const u8, members: []const Index) Node {
            assert(members.len <= max_group_members);
            var group = Group{};
            for (members, 0..) |member, index|
                group.members[index] = member;
            group.member_count = @intCast(members.len);
            return .{
                .state = .{ .group = group },
                .name = name,
                .process = process,
            };
        }

        /// Renders bound member outputs and feeds bound member inputs.
        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            const voice = dsp.render_voice;
            const cache = dsp.cacheForVoice(node, voice);
            const group_inputs = dsp.nodes.items(.inputs)[node.idx];

            // Materialize each external group input in fixed storage before
            // rendering children. The audio callback never allocates here.
            for (0..max_outlets) |port| {
                const input = group_inputs[port];
                const buffer = &cache.input_buffers[port];
                buffer.sample_count = into[0].sample_count;
                if (input.isNoop()) {
                    @memset(buffer.samples[0..buffer.sample_count], 0);
                    continue;
                }
                if (voice >= dsp.outputVoiceCount(input.node, input.output_port)) {
                    @memset(buffer.samples[0..buffer.sample_count], 0);
                    continue;
                }
                const source = try dsp.getOutput(input, into[0].sample_count);
                @memcpy(
                    buffer.samples[0..buffer.sample_count],
                    source.samples[0..source.sample_count],
                );
            }

            const state = dsp.nodes.items(.state)[node.idx].group;
            for (state.output_bindings, 0..) |binding, port| {
                const selected = binding orelse continue;
                if (voice >= dsp.outputVoiceCount(selected.node, selected.port)) continue;
                try dsp.renderNode(selected.node, voice, into[port].sample_count);
                const source = &dsp.cacheForVoice(selected.node, voice).outputs[selected.port];
                @memcpy(
                    into[port].samples[0..into[port].sample_count],
                    source.samples[0..source.sample_count],
                );
            }
        }
    };

    /// A fixed boundary node exposing one external group input.
    pub const GroupInput = struct {
        /// Group owning this endpoint.
        group: Index,
        /// Port exposed by the owning group.
        port: u8,

        /// Port metadata for a group input endpoint.
        pub const metadata = Node.Metadata{
            .name = "Group Input",
            .short_name = "in",
            .color = .gray,
            .can_link_parameters = false,
            .inputs = @splat(.{}),
            .outputs = @splat(.{ .name = "group input", .short_name = "out", .color = .gray }),
            .input_count = 0,
        };

        /// Creates a group input endpoint.
        pub fn create(name: []const u8, group: Index, port: u8) Node {
            return .{ .state = .{ .group_input = .{ .group = group, .port = port } }, .name = name, .process = process };
        }

        /// Copies the owning group's materialized input buffer.
        fn process(dsp: *DSP, node: Index, into: []const *Buffer) ProcessError!void {
            const state = dsp.nodes.items(.state)[node.idx].group_input;
            const source = &dsp.cacheForVoice(state.group, dsp.render_voice).input_buffers[state.port];
            @memcpy(into[0].samples[0..source.sample_count], source.samples[0..source.sample_count]);
        }
    };

    /// A fixed boundary node receiving one internal group output.
    pub const GroupOutput = struct {
        /// Group owning this endpoint.
        group: Index,
        /// Port exposed by the owning group.
        port: u8,

        /// Port metadata for a group output endpoint.
        pub const metadata = Node.Metadata{
            .name = "Group Output",
            .short_name = "out",
            .color = .gray,
            .can_link_parameters = false,
            .inputs = @splat(.{ .name = "group output", .short_name = "in", .color = .gray }),
            .outputs = @splat(.{}),
            .output_count = 0,
        };

        /// Creates a group output endpoint.
        pub fn create(name: []const u8, group: Index, port: u8) Node {
            return .{ .state = .{ .group_output = .{ .group = group, .port = port } }, .name = name, .process = process };
        }

        /// Forwards the member signal into the endpoint cache.
        fn process(dsp: *DSP, node: Index, into: []const *Buffer) ProcessError!void {
            const input = dsp.nodes.items(.inputs)[node.idx][0];
            if (input.isNoop()) return;
            const source = try dsp.getOutput(input, into[0].sample_count);
            @memcpy(into[0].samples[0..source.sample_count], source.samples[0..source.sample_count]);
        }
    };

    /// Adds all connected input signals sample by sample.
    pub const Add = struct {
        /// Port metadata for the addition node.
        pub const metadata = Node.Metadata{
            .name = "Add",
            .short_name = "add",
            .color = .amber,
            .can_link_parameters = false,
            .inputs = .{
                .{ .name = "input 1", .short_name = "in1", .color = .amber },
                .{ .name = "input 2", .short_name = "in2", .color = .amber },
                .{ .name = "input 3", .short_name = "in3", .color = .amber },
                .{ .name = "input 4", .short_name = "in4", .color = .amber },
                .{ .name = "input 5", .short_name = "in5", .color = .amber },
                .{ .name = "input 6", .short_name = "in6", .color = .amber },
                .{ .name = "input 7", .short_name = "in7", .color = .amber },
                .{ .name = "input 8", .short_name = "in8", .color = .amber },
            },
            .outputs = .{
                .{ .name = "sum", .short_name = "sum", .color = .amber },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .input_count = max_outlets,
        };

        /// Creates an addition node with all input ports initially unplugged.
        pub fn create(name: []const u8) Node {
            return .{
                .state = .{
                    .add = .{},
                },
                .name = name,
                .process = process,
            };
        }

        /// Resolves inputs, sums vector-sized chunks, then sums the tail scalarly.
        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            const input_outlets = dsp.nodes.items(.inputs)[node.idx];
            const output = into[0];

            // Resolve every connected input before entering the sample loop.
            var inputs: [max_outlets]*Buffer = undefined;
            var input_count: usize = 0;
            for (0..inputs.len) |i| {
                const input = input_outlets[i];
                if (input.isNoop()) continue;

                inputs[input_count] = try dsp.getOutput(input, into[0].sample_count);
                input_count += 1;
            }

            // Sum complete SIMD vectors for the common fast path.
            var offset: usize = 0;
            if (std.simd.suggestVectorLength(f32)) |lanes| {
                const V = @Vector(lanes, f32);

                while (offset + lanes <= output.sample_count) : (offset += lanes) {
                    var sum: V = @splat(0);

                    for (0..input_count) |i| {
                        const values: V = @bitCast(inputs[i].samples[offset..][0..lanes].*);
                        sum += values;
                    }

                    output.samples[offset..][0..lanes].* = @bitCast(sum);
                }
            }

            // Sum any samples that did not fill a complete SIMD vector.
            while (offset < output.sample_count) : (offset += 1) {
                var sum: f32 = 0;

                for (0..input_count) |i|
                    sum += inputs[i].samples[offset];

                output.samples[offset] = sum;
            }
        }
    };

    /// Copies one input signal to each connected output port.
    pub const Duplicate = struct {
        /// Port metadata for the signal splitter.
        pub const metadata = Node.Metadata{
            .name = "Duplicate",
            .short_name = "dup",
            .color = .astral,
            .can_link_parameters = false,
            .inputs = .{
                .{ .name = "input", .short_name = "in", .color = .astral },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .outputs = .{
                .{ .name = "output 1", .short_name = "out1", .color = .astral },
                .{ .name = "output 2", .short_name = "out2", .color = .astral },
                .{ .name = "output 3", .short_name = "out3", .color = .astral },
                .{ .name = "output 4", .short_name = "out4", .color = .astral },
                .{ .name = "output 5", .short_name = "out5", .color = .astral },
                .{ .name = "output 6", .short_name = "out6", .color = .astral },
                .{ .name = "output 7", .short_name = "out7", .color = .astral },
                .{ .name = "output 8", .short_name = "out8", .color = .astral },
            },
            .input_count = 1,
            .output_count = max_outlets,
        };

        /// Creates a splitter with one input and every output initially unused.
        pub fn create(name: []const u8) Node {
            return .{
                .state = .{ .duplicate = .{} },
                .name = name,
                .process = process,
            };
        }

        /// Copies the input buffer only to output ports with graph connections.
        fn process(dsp: *DSP, node: Index, into: []const *Buffer) ProcessError!void {
            const input = dsp.nodes.items(.inputs)[node.idx][0];
            if (input.isNoop()) return;

            const output_connected = dsp.nodes.items(.output_connected)[node.idx];
            var has_connected_output = false;
            for (output_connected) |connected| {
                if (connected) {
                    has_connected_output = true;
                    break;
                }
            }
            if (!has_connected_output) return;

            const source = try dsp.getOutput(input, into[0].sample_count);
            for (output_connected, 0..) |connected, output_port| {
                if (!connected) continue;
                @memcpy(
                    into[output_port].samples[0..source.sample_count],
                    source.samples[0..source.sample_count],
                );
            }
        }
    };

    /// Multiplies all connected input signals sample by sample.
    pub const Multiply = struct {
        /// Port metadata for the multiplication node.
        pub const metadata = Node.Metadata{
            .name = "Multiply",
            .short_name = "mul",
            .color = .cinnabar,
            .can_link_parameters = false,
            .inputs = .{
                .{ .name = "input 1", .short_name = "in1", .color = .cinnabar },
                .{ .name = "input 2", .short_name = "in2", .color = .cinnabar },
                .{ .name = "input 3", .short_name = "in3", .color = .cinnabar },
                .{ .name = "input 4", .short_name = "in4", .color = .cinnabar },
                .{ .name = "input 5", .short_name = "in5", .color = .cinnabar },
                .{ .name = "input 6", .short_name = "in6", .color = .cinnabar },
                .{ .name = "input 7", .short_name = "in7", .color = .cinnabar },
                .{ .name = "input 8", .short_name = "in8", .color = .cinnabar },
            },
            .outputs = .{
                .{ .name = "product", .short_name = "prod", .color = .cinnabar },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .input_count = max_outlets,
        };

        /// Creates a multiplication node with all input ports initially unplugged.
        pub fn create(name: []const u8) Node {
            return .{
                .state = .{
                    .multiply = .{},
                },
                .name = name,
                .process = process,
            };
        }

        /// Resolves inputs, multiplies vector-sized chunks, then handles the tail.
        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            const input_outlets = dsp.nodes.items(.inputs)[node.idx];
            const output = into[0];

            // Resolve every connected input before entering the sample loop.
            var inputs: [max_outlets]*Buffer = undefined;
            var input_count: usize = 0;
            for (0..inputs.len) |i| {
                const input = input_outlets[i];
                if (input.isNoop()) continue;

                inputs[input_count] = try dsp.getOutput(input, into[0].sample_count);
                input_count += 1;
            }

            // Multiply complete SIMD vectors for the common fast path.
            var offset: usize = 0;
            if (std.simd.suggestVectorLength(f32)) |lanes| {
                const V = @Vector(lanes, f32);

                while (offset + lanes <= output.sample_count) : (offset += lanes) {
                    var result: V = @splat(1);

                    for (0..input_count) |i| {
                        const values: V = @bitCast(inputs[i].samples[offset..][0..lanes].*);
                        result *= values;
                    }

                    output.samples[offset..][0..lanes].* = @bitCast(result);
                }
            }

            // Multiply any samples that did not fill a complete SIMD vector.
            while (offset < output.sample_count) : (offset += 1) {
                var result: f32 = 0;

                for (0..input_count) |i|
                    result *= inputs[i].samples[offset];

                output.samples[offset] = result;
            }
        }
    };

    /// Emits one constant value on every output sample.
    pub const Constant = struct {
        /// Port metadata for the constant node.
        pub const metadata = Node.Metadata{
            .name = "Constant",
            .short_name = "cst",
            .color = .golden_rod,
            .has_parameters = true,
            .outputs = .{
                .{ .name = "value", .short_name = "val", .color = .golden_rod },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .input_count = 0,
        };

        /// User-controlled value emitted by the node.
        pub const Parameters = struct {
            constant: f32 = 0,
        };

        /// Immutable configuration used by the process function.
        parameters: Parameters,

        /// Creates a constant node from its output value.
        pub fn create(name: []const u8, parameters: Parameters) Node {
            return .{
                .state = .{
                    .constant = .{ .parameters = parameters },
                },
                .name = name,
                .process = process,
            };
        }

        /// Fills the output buffer with the configured constant.
        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            @memset(
                into[0].samples[0..],
                dsp.nodes.items(.state)[node.idx].constant.parameters.constant,
            );
        }
    };

    /// Emits up to eight simultaneously held keyboard notes as frequencies.
    pub const Keyboard = struct {
        /// Sentinel MIDI value used before a voice has played a note.
        const empty_pitch: u8 = std.math.maxInt(u8);

        /// Port metadata for the keyboard node.
        pub const metadata = Node.Metadata{
            .name = "Keyboard",
            .short_name = "kbd",
            .color = .feijoa,
            .has_parameters = true,
            .can_link_parameters = false,
            .outputs = .{
                .{ .name = "Frequency", .short_name = "freq", .unit = "Hz", .color = .feijoa },
                .{ .name = "Gate", .short_name = "gate", .color = .feijoa },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .input_count = 0,
            .output_count = 2,
        };

        /// User-controlled octave of the lower keyboard row.
        pub const Parameters = struct {
            /// MIDI octave containing the lower row's C key.
            octave: i8 = 4,
        };

        /// Configuration copied at creation time.
        parameters: Parameters,
        /// SDL keycode assigned to each voice, or unknown for an unused voice.
        voice_keys: [max_polyphony]std.atomic.Value(u32) = @splat(.{ .raw = 0 }),
        /// Last MIDI pitch assigned to each voice, or empty_pitch if unused.
        voice_pitches: [max_polyphony]std.atomic.Value(u8) = @splat(.{ .raw = empty_pitch }),

        /// Creates a keyboard node with all voices released.
        pub fn create(name: []const u8, parameters: Parameters) Node {
            return .{
                .state = .{
                    .keyboard = .{ .parameters = parameters },
                },
                .name = name,
                .process = process,
            };
        }

        /// Presses a mapped key into the first available voice slot.
        pub fn press(self: *Keyboard, key: sdl.Keycode) bool {
            const pitch = self.pitchForKey(key) orelse return false;
            if (self.voiceForKey(key) != null) return true;

            for (0..max_polyphony) |voice| {
                if (self.voice_keys[voice].load(.acquire) == @backingInt(sdl.Keycode.unknown)) {
                    self.voice_pitches[voice].store(@intCast(pitch), .release);
                    self.voice_keys[voice].store(@backingInt(key), .release);
                    return true;
                }
            }
            return true;
        }

        /// Releases the voice currently assigned to a mapped key.
        pub fn release(self: *Keyboard, key: sdl.Keycode) bool {
            const voice = self.voiceForKey(key) orelse return self.pitchForKey(key) != null;
            self.voice_keys[voice].store(@backingInt(sdl.Keycode.unknown), .release);
            return true;
        }

        /// Releases every active keyboard voice.
        pub fn releaseAll(self: *Keyboard) void {
            for (&self.voice_keys) |*voice|
                voice.store(@backingInt(sdl.Keycode.unknown), .release);
        }

        /// Releases held notes and clears their remembered pitches.
        pub fn reset(self: *Keyboard, _: u8) void {
            self.releaseAll();
            for (&self.voice_pitches) |*pitch|
                pitch.store(empty_pitch, .release);
        }

        /// Returns the voice assigned to a key, if it is currently held.
        fn voiceForKey(self: *const Keyboard, key: sdl.Keycode) ?usize {
            for (&self.voice_keys, 0..) |*voice_key, voice| {
                if (voice_key.load(.acquire) == @backingInt(key)) return voice;
            }
            return null;
        }

        /// Converts a mapped key to its MIDI pitch under the configured octave.
        fn pitchForKey(self: *const Keyboard, key: sdl.Keycode) ?u7 {
            const offset: ?i16 = switch (key) {
                .z => 0,
                .s => 1,
                .x => 2,
                .d => 3,
                .c => 4,
                .v => 5,
                .g => 6,
                .b => 7,
                .h => 8,
                .n => 9,
                .j => 10,
                .m => 11,
                .q => 12,
                .@"2" => 13,
                .w => 14,
                .@"3" => 15,
                .e => 16,
                .r => 17,
                .@"5" => 18,
                .t => 19,
                .@"6" => 20,
                .y => 21,
                .@"7" => 22,
                .u => 23,
                .i => 24,
                else => null,
            };
            const pitch_offset = offset orelse return null;
            const pitch = (@as(i16, self.parameters.octave) + 1) * 12 + pitch_offset;
            if (pitch < 0 or pitch > std.math.maxInt(u7)) return null;
            return @intCast(pitch);
        }

        /// Converts a MIDI pitch to its equal-tempered frequency in hertz.
        fn frequency(pitch: u7) f32 {
            return 440 * std.math.pow(
                f32,
                2,
                @as(f32, @floatFromInt(@as(i16, @intCast(pitch)) - 69)) / 12,
            );
        }

        /// Emits the frequency and gate belonging to the currently rendered voice.
        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            const state = &dsp.nodes.items(.state)[node.idx].keyboard;
            const voice = dsp.render_voice;
            const raw_key = state.voice_keys[voice].load(.acquire);
            const raw_pitch = state.voice_pitches[voice].load(.acquire);
            const pitch = if (raw_key != @backingInt(sdl.Keycode.unknown))
                state.pitchForKey(@fromBackingInt(@intCast(raw_key))) orelse
                    if (raw_pitch != empty_pitch) @as(u7, @intCast(raw_pitch)) else null
            else if (raw_pitch != empty_pitch)
                @as(u7, @intCast(raw_pitch))
            else
                null;
            const sample = if (pitch) |value| frequency(value) else 0;
            @memset(into[0].samples[0..into[0].sample_count], sample);
            @memset(
                into[1].samples[0..into[1].sample_count],
                if (raw_key == @backingInt(sdl.Keycode.unknown)) 0 else 1,
            );
        }
    };

    /// Captures one mono or stereo PortAudio input and fans it out to graph voices.
    pub const Input = struct {
        /// Input source configuration.
        parameters: Parameters,
        /// Stable callback context and queued audio shared by every graph voice.
        capture: ?*Capture = null,
        /// PortAudio stream opened while this node is initialized.
        stream: ?*pa.Stream = null,
        /// Whether the capture stream currently runs during DSP playback.
        capture_started: bool = false,
        /// Last block read once and reused by every voice in a render generation.
        last_block: [block_size * 2]f32 = @splat(0),
        /// Generation in which this node last consumed captured input frames.
        last_render_generation: u64 = std.math.maxInt(u64),

        /// Fixed queue depth in captured audio frames.
        const capture_queue_capacity = 512;

        /// One captured frame converted to the graph's stereo layout.
        pub const Frame = struct {
            /// Captured or duplicated left channel sample.
            left: f32,
            /// Captured right channel sample.
            right: f32,
        };

        /// Stable callback context and bounded queue, separately allocated because node storage moves.
        pub const Capture = struct {
            /// Single-producer queue filled by PortAudio and consumed by DSP rendering.
            queue: utils.SpscQueue(Frame),
            /// One for mono capture or two for stereo capture.
            channel_count: u8,
        };

        /// Opened stream and capture context created together.
        pub const OpenedCapture = struct {
            /// Stable context written by the PortAudio callback.
            capture: *Capture,
            /// Stopped input stream ready for playback to start.
            stream: *pa.Stream,
        };

        /// Device selection edited in the selected-node parameters pane.
        pub const Parameters = struct {
            /// Runtime PortAudio ID selected for audio capture.
            input: pa.DeviceId,
        };

        /// Port metadata for a graph audio-input source.
        pub const metadata = Node.Metadata{
            .name = "Input",
            .short_name = "in",
            .color = .havelock_blue,
            .has_parameters = true,
            .can_link_parameters = false,
            .duplicatable = false,
            .input_count = 0,
            .output_count = 1,
            .outputs = .{
                .{ .name = "audio", .short_name = "out", .color = .havelock_blue, .observer = .waveform },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
        };

        /// Creates an Input node using the selected runtime PortAudio device.
        pub fn create(name: []const u8, parameters: Parameters) Node {
            return .{
                .state = .{ .input = .{ .parameters = parameters } },
                .name = name,
                .process = process,
                .initialize = initialize,
                .deinitialize = deinitialize,
            };
        }

        /// Allocates a stable callback context and opens its stopped PortAudio stream.
        pub fn openCapture(
            gpa: std.mem.Allocator,
            device: *const pa.InputDevice,
        ) pa.Error!OpenedCapture {
            const capture = gpa.create(Capture) catch @panic("Out of memory allocating input capture");
            const queue = utils.SpscQueue(Frame).initCapacity(gpa, capture_queue_capacity) catch
                @panic("Out of memory allocating input frame queue");
            capture.* = .{
                .queue = queue,
                .channel_count = @intCast(device.channel_count),
            };
            const capture_stream = pa.openInputStream(
                device,
                sample_rate,
                onInputCallback,
                @ptrCast(capture),
            ) catch |err| {
                capture.queue.deinit(gpa);
                gpa.destroy(capture);
                return err;
            };
            return .{ .capture = capture, .stream = capture_stream };
        }

        /// Releases queue storage and the stable callback context after stream closure.
        pub fn closeCapture(gpa: std.mem.Allocator, capture: *Capture) void {
            capture.queue.deinit(gpa);
            gpa.destroy(capture);
        }

        /// Opens the configured input unless no device is selected or it is unavailable.
        fn initialize(dsp: *DSP, node: Index, _: u8, gpa: std.mem.Allocator) InitializeError!void {
            const state = &dsp.nodes.items(.state)[node.idx].input;
            if (state.parameters.input == pa.no_device) return;

            const device = pa.inputDeviceById(dsp.input_devices, state.parameters.input) orelse {
                state.parameters.input = pa.no_device;
                return;
            };
            const opened = try openCapture(gpa, device);
            if (dsp.playing) {
                pa.startStream(opened.stream) catch |err| {
                    pa.closeStream(opened.stream) catch {};
                    closeCapture(gpa, opened.capture);
                    return err;
                };
            }
            state.capture = opened.capture;
            state.stream = opened.stream;
            state.capture_started = dsp.playing;
        }

        /// Stops and closes this node's stream before releasing callback storage.
        fn deinitialize(dsp: *DSP, node: Index, _: u8, gpa: std.mem.Allocator) void {
            const state = &dsp.nodes.items(.state)[node.idx].input;
            if (state.stream) |capture_stream| {
                if (state.capture_started) pa.stopStream(capture_stream) catch {};
                pa.closeStream(capture_stream) catch {};
                state.stream = null;
            }
            state.capture_started = false;
            if (state.capture) |capture| {
                closeCapture(gpa, capture);
                state.capture = null;
            }
        }

        /// Copies one captured block to every requested voice without blocking rendering.
        fn process(dsp: *DSP, node: Index, into: []const *Buffer) ProcessError!void {
            const state = &dsp.nodes.items(.state)[node.idx].input;
            const sample_count: usize = @intCast(into[0].sample_count);
            assert(sample_count <= state.last_block.len and sample_count % 2 == 0);

            if (state.last_render_generation != dsp.render_generation) {
                state.last_render_generation = dsp.render_generation;
                @memset(state.last_block[0..sample_count], 0);
                if (state.capture) |capture| {
                    const frame_count = sample_count / 2;
                    for (0..frame_count) |frame_index| {
                        const queued = capture.queue.front() orelse break;
                        state.last_block[frame_index * 2] = queued.left;
                        state.last_block[frame_index * 2 + 1] = queued.right;
                        capture.queue.pop();
                    }
                }
            }

            @memcpy(into[0].samples[0..sample_count], state.last_block[0..sample_count]);
        }

        /// Converts captured frames to stereo and publishes them without waiting for the renderer.
        fn onInputCallback(
            input: ?*const anyopaque,
            _: ?*anyopaque,
            frame_count: c_ulong,
            _: ?*const pa.StreamCallbackTimeInfo,
            _: c_ulong,
            user_data: ?*anyopaque,
        ) callconv(.c) c_int {
            const source = input orelse return 0;
            const capture: *Capture = @ptrCast(@alignCast(user_data.?));
            const samples: [*]const f32 = @ptrCast(@alignCast(source));
            const channels: usize = capture.channel_count;
            for (0..@intCast(frame_count)) |frame_index| {
                const sample_index = frame_index * channels;
                const left = samples[sample_index];
                const right = if (channels == 1) left else samples[sample_index + 1];
                _ = capture.queue.tryPush(.{ .left = left, .right = right });
            }
            return 0;
        }
    };

    /// Generates a stereo oscillator with optional frequency and amplitude inputs.
    pub const Oscillator = struct {
        /// Port metadata for the oscillator node.
        pub const metadata = Node.Metadata{
            .name = "Oscillator",
            .short_name = "osc",
            .color = .curious_blue,
            .has_parameters = true,
            .has_per_voice_state = true,
            .inputs = .{
                .{ .name = "frequency", .short_name = "freq", .unit = "Hz", .color = .curious_blue },
                .{ .name = "amplitude", .short_name = "amp", .color = .curious_blue },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .outputs = .{
                .{ .name = "audio", .short_name = "out", .color = .curious_blue, .observer = .line_plot },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .input_count = 2,
        };

        /// Available periodic wave shapes.
        pub const Waveform = enum {
            /// Sine wave.
            sine,
            /// Sawtooth ramp from -1 to +1.
            sawtooth,
            /// Triangle wave.
            triangle,
            /// Bipolar square wave.
            square,
        };

        /// One full cycle in radians.
        const tau: f32 = @floatCast(std.math.tau);

        /// User-controlled oscillator configuration.
        pub const Parameters = struct {
            /// Wave shape used for each generated sample.
            waveform: Waveform,
            /// Phase added to the running phase before waveform evaluation.
            phase_offset: f32 = 0,
            /// Frequency used when no frequency input is connected.
            default_frequency: f32,
            /// Amplitude used when no amplitude input is connected.
            default_amplitude: f32,
        };

        /// Configuration copied at creation time.
        parameters: Parameters,
        /// Mutable phase accumulator, in radians.
        phase: f32 = 0,

        /// Clears oscillator history while retaining its waveform settings.
        pub fn reset(self: *Oscillator, _: u8) void {
            const parameters = self.parameters;
            self.* = .{ .parameters = parameters };
        }

        /// Creates an oscillator with a reset phase accumulator.
        pub fn create(name: []const u8, parameters: Parameters) Node {
            return .{
                .state = .{
                    .oscillator = .{ .parameters = parameters },
                },
                .name = name,
                .process = process,
            };
        }

        /// Renders one stereo block, applying optional per-sample modulation.
        fn process(dsp: *DSP, node: Index, into: []const *Buffer) ProcessError!void {
            // Load graph connections and persistent oscillator state.
            const state = &dsp.processingState(node).oscillator;
            const input_outlets = dsp.nodes.items(.inputs)[node.idx];
            const frequency_connection = input_outlets[0];
            const amplitude_connection = input_outlets[1];

            // Resolve optional modulation sources once for this block.
            const frequency_buffer: ?*Buffer = if (frequency_connection.isNoop())
                null
            else
                try dsp.getOutput(frequency_connection, into[0].sample_count);
            const amplitude_buffer: ?*Buffer = if (amplitude_connection.isNoop())
                null
            else
                try dsp.getOutput(amplitude_connection, into[0].sample_count);

            // Convert the engine rate to float for phase integration.
            const f_sample_rate: f32 = @floatFromInt(sample_rate);
            const parameters = state.parameters;

            assert(into[0].sample_count % 2 == 0);
            const frame_count: usize = @intCast(into[0].sample_count / 2);
            // Generate one value per stereo frame and duplicate it to both channels.
            for (0..frame_count) |frame| {
                const sample_index = frame * 2;
                const frequency_input = if (frequency_buffer) |buffer|
                    buffer.samples[sample_index]
                else
                    null;
                const amplitude_input = if (amplitude_buffer) |buffer|
                    buffer.samples[sample_index]
                else
                    null;
                // Use modulation when present, otherwise use the configured defaults.
                const frequency = frequency_input orelse parameters.default_frequency;
                const amplitude = amplitude_input orelse parameters.default_amplitude;
                const phase = state.phase + parameters.phase_offset;
                // Normalize phase to one cycle for discontinuous waveforms.
                const phase_in_cycles = phase / tau;
                const normalized_phase: f32 = phase_in_cycles - @floor(phase_in_cycles);

                const unit_sample: f32 = switch (parameters.waveform) {
                    .sine => @sin(phase),
                    // Ramps from -1 to +1, then jumps back to -1.
                    .sawtooth => 2 * normalized_phase - 1,
                    // Starts at -1, reaches +1 halfway through the cycle.
                    .triangle => 1 - 4 * @abs(normalized_phase - 0.5),
                    // Starts high and changes to low halfway through the cycle.
                    .square => if (normalized_phase < 0.5) 1 else -1,
                };
                // Apply amplitude and write a mono value into both stereo channels.
                const sample = amplitude * unit_sample;

                into[0].samples[sample_index] = sample;
                into[0].samples[sample_index + 1] = sample;

                // Integrate frequency into phase so
                // frequency modulation works correctly across frames.
                state.phase += tau * frequency / f_sample_rate;

                // Keep phase bounded. This assumes normal oscillator
                // frequencies whose per-frame increment is below tau.
                if (state.phase >= tau)
                    state.phase -= tau;
                if (state.phase < 0)
                    state.phase += tau;
            }
        }
    };

    /// Mixes up to `max_outlets` stereo inputs with gain and pan controls.
    pub const Mixer = struct {
        /// Port metadata for the mixer node.
        pub const metadata = Node.Metadata{
            .name = "Mixer",
            .short_name = "mix",
            .color = .cerulean,
            .has_parameters = true,
            .can_link_parameters = false,
            .inputs = .{
                .{ .name = "input 1", .short_name = "in1", .color = .cerulean },
                .{ .name = "input 2", .short_name = "in2", .color = .cerulean },
                .{ .name = "input 3", .short_name = "in3", .color = .cerulean },
                .{ .name = "input 4", .short_name = "in4", .color = .cerulean },
                .{ .name = "input 5", .short_name = "in5", .color = .cerulean },
                .{ .name = "input 6", .short_name = "in6", .color = .cerulean },
                .{ .name = "input 7", .short_name = "in7", .color = .cerulean },
                .{ .name = "input 8", .short_name = "in8", .color = .cerulean },
            },
            .outputs = .{
                .{ .name = "mix", .short_name = "mix", .color = .cerulean, .observer = .waveform },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .input_count = max_outlets,
        };

        /// User-controlled mix configuration.
        pub const Parameters = struct {
            /// Master gain applied after summing all inputs.
            gain: f32 = 1,
            /// Per-input gain values.
            gains: [max_outlets]f32 = @splat(1),
            /// Per-input pan values, from -1 left to +1 right.
            pans: [max_outlets]f32 = @splat(0),
        };

        /// Configuration copied at creation time.
        parameters: Parameters,

        /// Creates a mixer from its gain and pan configuration.
        pub fn create(name: []const u8, parameters: Parameters) Node {
            return .{
                .state = .{
                    .mixer = .{ .parameters = parameters },
                },
                .name = name,
                .process = process,
            };
        }

        /// Resolves inputs, applies constant-power panning, and sums the mix.
        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            const state = &dsp.nodes.items(.state)[node.idx].mixer;
            const input_outlets = dsp.nodes.items(.inputs)[node.idx];
            const output = into[0];
            const parameters = state.parameters;

            // Resolve connected inputs and precompute their channel gains.
            var inputs: [max_outlets]*Buffer = undefined;
            var input_count: usize = 0;
            var left_gains: [max_outlets]f32 = @splat(0);
            var right_gains: [max_outlets]f32 = @splat(0);
            var mix_gains: [max_outlets]f32 = @splat(0);
            for (0..inputs.len) |i| {
                const input = input_outlets[i];
                if (input.isNoop()) continue;

                inputs[input_count] = try dsp.getOutput(input, output.sample_count);

                // Convert pan into constant-power left/right gains.
                const angle = (parameters.pans[i] + 1) * std.math.pi / 4;
                left_gains[input_count] = @cos(angle);
                right_gains[input_count] = @sin(angle);
                mix_gains[input_count] = parameters.gains[i];

                input_count += 1;
            }

            assert(output.sample_count % 2 == 0);

            // Mix complete SIMD vectors, preserving the interleaved channel gains.
            var offset: usize = 0;
            if (std.simd.suggestVectorLength(f32)) |lanes| {
                const V = @Vector(lanes, f32);

                while (offset + lanes <= output.sample_count) : (offset += lanes) {
                    var result: V = @splat(0);

                    for (0..input_count) |i| {
                        // Create an interleaved vector of left/right gains.
                        var gains: V = undefined;
                        inline for (0..lanes) |lane|
                            gains[lane] = (if (lane % 2 == 0) left_gains[i] else right_gains[i]) *
                                mix_gains[i];

                        const input: V = @bitCast(inputs[i].samples[offset..][0..lanes].*);

                        result += input * gains;
                    }

                    output.samples[offset..][0..lanes].* = @bitCast(result * @as(V, @splat(parameters.gain)));
                }
            }

            // Process the remaining stereo frames that do not fill a SIMD vector.
            while (offset < output.sample_count) : (offset += 2) {
                var left: f32 = 0;
                var right: f32 = 0;

                for (0..input_count) |i| {
                    const input = inputs[i];

                    const sample_left = input.samples[offset] * left_gains[i];
                    const sample_right = input.samples[offset + 1] * right_gains[i];

                    // Accumulate this input into the left and right sums.
                    left += sample_left * mix_gains[i];
                    right += sample_right * mix_gains[i];
                }

                // Write the summed stereo frame and apply master gain.
                output.samples[offset] = left * parameters.gain;
                output.samples[offset + 1] = right * parameters.gain;
            }
        }
    };

    /// Emits frequency, gate, and velocity signals from a monophonic note sequence.
    pub const MonophonicSequencer = struct {
        /// Port metadata for the monophonic sequencer node.
        pub const metadata = Node.Metadata{
            .name = "Monophonic Sequencer",
            .short_name = "seq",
            .color = .feijoa,
            .has_parameters = true,
            .has_per_voice_state = true,
            .can_link_parameters = false,
            .outputs = .{
                .{ .name = "frequency", .short_name = "freq", .unit = "Hz", .color = .feijoa },
                .{ .name = "gate", .short_name = "gate", .color = .feijoa },
                .{ .name = "velocity", .short_name = "vel", .color = .feijoa },
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .input_count = 0,
            .output_count = 3,
        };

        /// Number of ticks in one quarter note.
        pub const quarter_note_ticks = 960;

        /// User-controlled sequence playback configuration.
        pub const Parameters = struct {
            /// Playback tempo in beats per minute.
            bpm: u8 = 120,
            /// Ordered note events to play.
            notes: []const Note,
            /// Whether playback wraps at the final note.
            loop: bool = true,
        };

        /// Configuration copied at creation time.
        parameters: Parameters,
        /// Current position in ticks.
        position: f64 = 0,
        /// Index of the note currently being searched or played.
        note_index: usize = 0,
        /// Last played frequency, retained through gaps and after non-looping playback.
        last_frequency: f32 = 0,

        /// Returns playback state to the beginning and preserves the note sequence.
        pub fn reset(self: *MonophonicSequencer, _: u8) void {
            const parameters = self.parameters;
            self.* = .{ .parameters = parameters };
        }

        /// Creates a three-output sequencer with reset playback state.
        pub fn create(name: []const u8, parameters: Parameters) Node {
            return .{
                .state = .{
                    .monophonic_sequencer = .{ .parameters = parameters },
                },
                .name = name,
                .process = process,
            };
        }

        /// Converts a musical duration from ticks to rounded interleaved samples.
        fn ticksToSamples(self: *MonophonicSequencer, ticks: u64) u64 {
            const samples_f64 =
                @as(f64, @floatFromInt(ticks)) *
                60.0 *
                @as(f64, @floatFromInt(sample_rate)) /
                (@as(f64, @floatFromInt(self.parameters.bpm)) *
                    @as(f64, @floatFromInt(quarter_note_ticks)));

            return @intFromFloat(@round(samples_f64));
        }

        /// Advances the sequence and emits frequency, gate, and velocity per frame.
        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            const state = &dsp.processingState(node).monophonic_sequencer;
            const parameters = state.parameters;

            // Convert one audio frame into musical ticks at the configured tempo.
            const ticks_per_frame: f64 =
                @as(f64, @floatFromInt(parameters.bpm)) *
                @as(f64, @floatFromInt(quarter_note_ticks)) /
                (60.0 * @as(f64, @floatFromInt(sample_rate)));

            // The graph uses interleaved stereo samples, so frames are pairs.
            assert(into[0].sample_count % 2 == 0);
            const frame_count: usize = @intCast(into[0].sample_count / 2);

            assert(parameters.notes.len > 0);
            // Compute the end of the final note for loop and stop handling.
            const sequence_end = @as(
                f64,
                @floatFromInt(
                    parameters.notes[parameters.notes.len - 1].start_tick +
                        parameters.notes[parameters.notes.len - 1].duration_ticks,
                ),
            );

            for (0..frame_count) |frame| {
                const sample_index = frame * 2;

                var frequency: f32 = state.last_frequency;
                var gate: f32 = 0;
                var velocity: f32 = 0;

                // Wrap or silence when the playback cursor passes the sequence end.
                if (state.position >= sequence_end) {
                    if (parameters.loop) { // Go back to start
                        // Some amount of time past when the sequence should have starte again might have passed
                        // So we dont set position at 0 but at the remainder
                        state.position = @mod(state.position, sequence_end);
                        state.note_index = 0;
                    } else { // Doesn't loop and sequence over, just write 0
                        into[0].samples[sample_index] = state.last_frequency;
                        into[0].samples[sample_index + 1] = state.last_frequency;
                        into[1].samples[sample_index] = 0;
                        into[1].samples[sample_index + 1] = 0;
                        into[2].samples[sample_index] = 0;
                        into[2].samples[sample_index + 1] = 0;
                        continue;
                    }
                }

                // Advance the note cursor until it reaches the current tick.
                const tick: u64 = @intFromFloat(state.position);
                while (state.note_index < parameters.notes.len) {
                    const note = parameters.notes[state.note_index];
                    // If inside note's tick range, select this note
                    if (tick < note.start_tick or
                        tick - note.start_tick < note.duration_ticks)
                        break;
                    state.note_index += 1;
                }

                // Emit note values when the cursor is inside a pitched note.
                if (state.note_index < parameters.notes.len) {
                    const note = parameters.notes[state.note_index];
                    if (tick >= note.start_tick and note.pitch != null) {
                        frequency = note.frequency();
                        state.last_frequency = frequency;
                        gate = 1;
                        velocity = note.velocity;
                    }
                } // else it's a gap and values are already at 0

                // Duplicate each control value across the stereo frame.
                into[0].samples[sample_index] = frequency;
                into[0].samples[sample_index + 1] = frequency;
                into[1].samples[sample_index] = gate;
                into[1].samples[sample_index + 1] = gate;
                into[2].samples[sample_index] = velocity;
                into[2].samples[sample_index + 1] = velocity;

                // Advance playback by one audio frame.
                state.position += ticks_per_frame;
            }
        }
    };

    /// Envelope generator driven by a gate signal and optional velocity signal.
    pub const ADSR = struct {
        /// Port metadata for the envelope node.
        pub const metadata = Node.Metadata{
            .name = "ADSR",
            .short_name = "adsr",
            .color = .fuschia_pink,
            .has_parameters = true,
            .has_per_voice_state = true,
            .inputs = .{
                .{ .name = "gate", .short_name = "gate", .color = .fuschia_pink },
                .{ .name = "velocity", .short_name = "vel", .color = .fuschia_pink },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .outputs = .{
                .{ .name = "envelope", .short_name = "env", .color = .fuschia_pink },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .input_count = 2,
        };

        /// Curves available for attack, decay, and release transitions.
        pub const Curve = enum {
            /// Constant-rate transition.
            linear,
            /// Slow-starting, fast-ending transition.
            exponential,
            /// Fast-starting, slow-ending transition.
            logarithmic,
        };

        /// Runtime stage of the envelope state machine.
        const Stage = enum {
            /// No gate and no audible envelope level.
            idle,
            /// Rising toward the peak level.
            attack,
            /// Falling toward the sustain level.
            decay,
            /// Holding the sustain level while gated.
            sustain,
            /// Falling toward zero after the gate is released.
            release,
        };

        /// User-controlled envelope timing and level configuration.
        pub const Parameters = struct {
            /// Attack duration in seconds.
            attack: f32 = 0,
            /// Shape of the attack transition.
            attack_curve: Curve = .exponential,
            /// Decay duration in seconds.
            decay: f32 = 0,
            /// Shape of the decay transition.
            decay_curve: Curve = .exponential,
            /// Held level after decay, clamped to 0..1.
            sustain: f32 = 1,
            /// Release duration in seconds.
            release: f32 = 1,
            /// Shape of the release transition.
            release_curve: Curve = .exponential,
        };

        /// Configuration copied at creation time.
        parameters: Parameters,

        /// Current state-machine stage.
        stage: Stage = .idle,
        /// Time spent in the current stage.
        stage_elapsed: f32 = 0,
        /// Level at the beginning of the current stage.
        stage_start_level: f32 = 0,
        /// Current unscaled envelope level.
        level: f32 = 0,
        /// Velocity latched while the gate is held.
        velocity: f32 = 1,

        /// Returns the envelope to its idle defaults while preserving its settings.
        pub fn reset(self: *ADSR, _: u8) void {
            const parameters = self.parameters;
            self.* = .{ .parameters = parameters };
        }

        /// Creates an envelope with an idle runtime state.
        pub fn create(name: []const u8, parameters: Parameters) Node {
            return .{
                .state = .{
                    .adsr = .{ .parameters = parameters },
                },
                .name = name,
                .process = process,
            };
        }

        /// Runs the envelope state machine for one stereo audio block.
        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            // Resolve persistent state and the two control inputs.
            const state = &dsp.processingState(node).adsr;
            const parameters = state.parameters;
            const input_outlets = dsp.nodes.items(.inputs)[node.idx];
            const gate_connection = input_outlets[0];
            const velocity_connection = input_outlets[1];

            // A severed gate means gate-off, allowing the envelope to release safely.
            const gate_buffer = if (gate_connection.isNoop())
                null
            else
                try dsp.getOutput(gate_connection, into[0].sample_count);

            // Resolve optional velocity modulation; unity is the default.
            const velocity_buffer = if (velocity_connection.isNoop())
                null
            else
                try dsp.getOutput(velocity_connection, into[0].sample_count);

            // Clamp the sustain level once because it is constant for the block.
            assert(into[0].sample_count % 2 == 0);
            const frame_count: usize = @intCast(into[0].sample_count / 2);
            const sustain = @max(0.0, @min(1.0, parameters.sustain));
            // Advance the state machine once for each stereo frame.
            for (0..frame_count) |frame| {
                const sample_index = frame * 2;

                const gate = if (gate_buffer) |buffer|
                    buffer.samples[sample_index]
                else
                    0;
                const velocity = if (velocity_buffer) |buffer|
                    buffer.samples[sample_index]
                else
                    1;
                const gate_on = gate >= 0.5;

                // First update the stage transitions from the current gate.
                if (gate_on) {
                    // Velocity is a note property. Latch it while the note is
                    // held so a zero velocity output during a gap does not
                    // cut off the release tail.
                    state.velocity = @max(0.0, @min(1.0, velocity));

                    // A high gate starts the attack, unless the envelope is
                    // already in attack, decay, or sustain.
                    if (state.stage == .idle or state.stage == .release) {
                        state.stage = .attack;
                        state.stage_elapsed = 0;
                        state.stage_start_level = state.level;
                    }
                } else if (state.stage != .idle and state.stage != .release) {
                    // Release starts from the current level, regardless of
                    // which stage was active when the gate fell.
                    state.stage = .release;
                    state.stage_elapsed = 0;
                    state.stage_start_level = state.level;
                }

                // Then advance the active stage by one sample period.
                const f_sample_rate: f32 = @floatFromInt(sample_rate);
                const delta_time = 1.0 / f_sample_rate;

                // Evaluate the level and transition when a stage completes.
                switch (state.stage) {
                    // Silence the envelope while it is idle.
                    .idle => {
                        state.level = 0;
                    },
                    // Rise from the stage start level to the peak.
                    .attack => {
                        if (parameters.attack <= 0) {
                            state.level = 1;
                            state.stage = .decay;
                            state.stage_elapsed = 0;
                            state.stage_start_level = 1;
                        } else {
                            const progress = @min(1.0, state.stage_elapsed / parameters.attack);
                            state.level = interpolate(
                                parameters.attack_curve,
                                state.stage_start_level,
                                1,
                                progress,
                            );
                            state.stage_elapsed += delta_time;
                            if (state.stage_elapsed >= parameters.attack) {
                                state.level = 1;
                                state.stage = .decay;
                                state.stage_elapsed = 0;
                                state.stage_start_level = 1;
                            }
                        }
                    },
                    // Fall from the peak to the configured sustain level.
                    .decay => {
                        if (parameters.decay <= 0) {
                            state.level = sustain;
                            state.stage = .sustain;
                            state.stage_elapsed = 0;
                            state.stage_start_level = state.level;
                        } else {
                            const progress = @min(1.0, state.stage_elapsed / parameters.decay);
                            state.level = interpolate(
                                parameters.decay_curve,
                                1,
                                sustain,
                                progress,
                            );
                            state.stage_elapsed += delta_time;
                            if (state.stage_elapsed >= parameters.decay) {
                                state.level = sustain;
                                state.stage = .sustain;
                                state.stage_elapsed = 0;
                                state.stage_start_level = state.level;
                            }
                        }
                    },
                    // Hold the sustain level until the gate falls.
                    .sustain => {
                        state.level = sustain;
                    },
                    // Fall from the latched level back to silence.
                    .release => {
                        if (parameters.release <= 0) {
                            state.level = 0;
                            state.stage = .idle;
                            state.stage_elapsed = 0;
                            state.stage_start_level = 0;
                        } else {
                            const progress = @min(1.0, state.stage_elapsed / parameters.release);
                            state.level = interpolate(
                                parameters.release_curve,
                                state.stage_start_level,
                                0,
                                progress,
                            );
                            state.stage_elapsed += delta_time;
                            if (state.stage_elapsed >= parameters.release) {
                                state.level = 0;
                                state.stage = .idle;
                                state.stage_elapsed = 0;
                                state.stage_start_level = 0;
                            }
                        }
                    },
                }

                // Apply the latched velocity and duplicate the result to stereo.
                const output = state.level * state.velocity;
                into[0].samples[sample_index] = output;
                into[0].samples[sample_index + 1] = output;
            }
        }

        /// Shapes a normalized transition between two envelope levels.
        fn interpolate(curve: Curve, from: f32, to: f32, progress: f32) f32 {
            // Clamp progress before applying the selected curve.
            const t = @max(0.0, @min(1.0, progress));
            const steepness: f32 = 5;
            // Map linear progress to the requested perceptual response.
            const shaped = switch (curve) {
                .linear => t,
                // Slow at the beginning, fast at the end.
                .exponential => (@exp(steepness * t) - 1) / (@exp(steepness) - 1),
                // Fast at the beginning, slow at the end.
                .logarithmic => (1 - @exp(-steepness * t)) / (1 - @exp(-steepness)),
            };
            // Interpolate the actual envelope level using the shaped progress.
            return from + (to - from) * shaped;
        }
    };

    /// Chamberlin-style state-variable filter with runtime cutoff modulation.
    pub const MultimodeFilter = struct {
        /// Port metadata for the multimode filter node.
        pub const metadata = Node.Metadata{
            .name = "Multimode Filter",
            .short_name = "mmf",
            .color = .havelock_blue,
            .has_parameters = true,
            .has_per_voice_state = true,
            .inputs = .{
                .{ .name = "audio", .short_name = "in", .color = .havelock_blue },
                .{ .name = "cutoff", .short_name = "cut", .unit = "Hz", .color = .havelock_blue },
                .{ .name = "resonance", .short_name = "res", .color = .havelock_blue },
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .outputs = .{
                .{ .name = "audio", .short_name = "out", .color = .havelock_blue, .observer = .waveform },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .input_count = 3,
        };

        /// Output response selected by the filter.
        pub const Type = enum {
            /// Attenuates frequencies below the cutoff.
            high_pass,
            /// Attenuates frequencies above the cutoff.
            low_pass,
            /// Passes a band around the cutoff.
            band_pass,
            /// Rejects a band around the cutoff.
            notch,
        };

        /// User-controlled filter configuration.
        pub const Parameters = struct {
            /// Filter response type.
            type: Type,
            /// Cutoff in hertz when no cutoff input is connected.
            default_cutoff: f32,
            /// Resonance amount when no resonance input is connected.
            default_resonance: f32,
        };

        /// Configuration copied at creation time.
        parameters: Parameters,
        /// Low-pass integrator state for left and right channels.
        low: [2]f32 = .{ 0, 0 },
        /// Band-pass integrator state for left and right channels.
        band: [2]f32 = .{ 0, 0 },

        /// Clears the filter integrators while retaining its response settings.
        pub fn reset(self: *MultimodeFilter, _: u8) void {
            const parameters = self.parameters;
            self.* = .{ .parameters = parameters };
        }

        /// Creates a filter with reset integrator state.
        pub fn create(name: []const u8, parameters: Parameters) Node {
            return .{
                .state = .{
                    .multimode_filter = .{ .parameters = parameters },
                },
                .name = name,
                .process = process,
            };
        }

        /// Filters one interleaved stereo block with optional modulation inputs.
        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            // Resolve persistent filter state and the three possible inputs.
            const state = &dsp.processingState(node).multimode_filter;
            const parameters = state.parameters;
            const input_outlets = dsp.nodes.items(.inputs)[node.idx];

            // A severed audio input leaves the already-cleared output silent.
            if (input_outlets[0].isNoop()) return;

            // Cutoff and resonance are optional.
            const audio_buffer = try dsp.getOutput(
                input_outlets[0],
                into[0].sample_count,
            );
            const cutoff_buffer = if (!input_outlets[1].isNoop())
                try dsp.getOutput(input_outlets[1], into[0].sample_count)
            else
                null;
            const resonance_buffer = if (!input_outlets[2].isNoop())
                try dsp.getOutput(input_outlets[2], into[0].sample_count)
            else
                null;

            // Use the engine rate to convert cutoff to the filter coefficient.
            const f_sample_rate: f32 = @floatFromInt(sample_rate);

            // Update the two-channel filter state one interleaved sample at a time.
            for (0..into[0].sample_count) |sample| {
                const channel = sample % 2;
                const audio = audio_buffer.samples[sample];

                const cutoff = if (cutoff_buffer) |buffer|
                    buffer.samples[sample]
                else
                    parameters.default_cutoff;

                const resonance = if (resonance_buffer) |buffer|
                    buffer.samples[sample]
                else
                    parameters.default_resonance;

                // Clamp modulation inputs to stable ranges before calculating `f`.
                // This is a Chamberlin-style state-variable filter. `f`
                // controls how quickly the filter moves, while `damping`
                // controls the resonance around the cutoff.
                const clamped_cutoff = @max(0.0, @min(f_sample_rate * 0.49, cutoff));
                const f = 2 * @sin(std.math.pi * clamped_cutoff / f_sample_rate);
                const clamped_resonance = @max(0.0, @min(1.0, resonance));
                const resonance_root = @sqrt(@sqrt(clamped_resonance));
                var damping = 2 * (1 - resonance_root);
                if (f > 0)
                    damping = @min(damping, 2 / f - f * 0.5);
                damping = @max(0.001, damping);

                // Integrate the low, high, band, and notch responses.
                const notch = audio - damping * state.band[channel];
                state.low[channel] += f * state.band[channel];
                const high = notch - state.low[channel];
                state.band[channel] += f * high;
                const notch_output = high + state.low[channel];

                // Select the configured response from the updated state.
                into[0].samples[sample] = switch (parameters.type) {
                    .low_pass => state.low[channel],
                    .high_pass => high,
                    .band_pass => state.band[channel],
                    .notch => notch_output,
                };
            }
        }
    };

    /// Mixes a bounded number of delayed copies of a stereo input.
    pub const Delay = struct {
        /// User-controlled base delay, wet level, and number of delayed copies.
        parameters: Parameters,
        /// Interleaved stereo dry-signal history, allocated during initialization.
        dry_history: []f32 = &.{},
        /// Frame slot where the next dry stereo sample is written.
        history_cursor: usize = 0,

        /// Clears delay history while retaining parameters and owned buffer storage.
        pub fn reset(self: *Delay, _: u8) void {
            const parameters = self.parameters;
            const dry_history = self.dry_history;
            self.* = .{ .parameters = parameters, .dry_history = dry_history };
            if (dry_history.len != 0)
                @memset(dry_history, 0);
        }

        /// Maximum delay time supported by one tap, in milliseconds.
        pub const max_delay_ms: f32 = 2_000;
        /// Lowest allowed feedback count.
        pub const min_feedback: u8 = 1;
        /// Highest allowed feedback count.
        pub const max_feedback: u8 = 16;

        /// Port metadata for the delay node.
        pub const metadata = Node.Metadata{
            .name = "Delay",
            .short_name = "dly",
            .color = .desert,
            .has_parameters = true,
            .has_per_voice_state = true,
            .can_link_parameters = false,
            .inputs = .{
                .{ .name = "dry signal", .short_name = "in", .color = .desert },
                .{ .name = "wetness", .short_name = "wet", .color = .desert },
                .{ .name = "delay", .short_name = "dly", .unit = "ms", .color = .desert },
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .outputs = .{
                .{ .name = "output signal", .short_name = "out", .color = .desert, .observer = .meter },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .input_count = 3,
        };

        /// Base settings used when optional wetness or delay inputs are unplugged.
        pub const Parameters = struct {
            /// Base delay in milliseconds.
            delay: f32 = 250,
            /// Dry/wet blend: 0 outputs only dry signal, 1 outputs only delayed copies.
            wetness: f32 = 0.5,
            /// Number of delayed copies, from 1 through 16.
            feedback: u8 = 4,
            /// Multiplier applied to each copy's level to get the next copy's level.
            decay: f32 = 0.5,
        };

        /// Creates a delay node with no allocated audio history yet.
        pub fn create(name: []const u8, parameters: Parameters) Node {
            assert(parametersAreValid(parameters));
            return .{
                .state = .{
                    .delay = .{ .parameters = parameters },
                },
                .name = name,
                .process = process,
                .initialize = initialize,
                .initialize_voice = initialize,
                .deinitialize = deinitialize,
            };
        }

        /// Returns whether parameters can be safely represented and processed.
        pub fn parametersAreValid(parameters: Parameters) bool {
            return std.math.isFinite(parameters.delay) and
                parameters.delay >= 0 and parameters.delay <= max_delay_ms and
                std.math.isFinite(parameters.wetness) and
                parameters.wetness >= 0 and parameters.wetness <= 1 and
                std.math.isFinite(parameters.decay) and
                parameters.decay >= 0 and parameters.decay <= 1 and
                parameters.feedback >= min_feedback and parameters.feedback <= max_feedback;
        }

        /// Allocates enough history for the configured delay range and copy count.
        fn initialize(
            dsp: *DSP,
            node: Index,
            voice: u8,
            allocator: std.mem.Allocator,
        ) std.mem.Allocator.Error!void {
            const state = &dsp.stateForVoice(node, voice).delay;
            try state.ensureHistoryCapacity(allocator, state.parameters);
        }

        /// Releases the delay history allocated during initialization or growth.
        fn deinitialize(dsp: *DSP, node: Index, voice: u8, allocator: std.mem.Allocator) void {
            const state = &dsp.stateForVoice(node, voice).delay;
            if (state.dry_history.len != 0)
                allocator.free(state.dry_history);
            state.dry_history = &.{};
            state.history_cursor = 0;
        }

        /// Grows history when settings require it, preserving the newest samples.
        pub fn ensureHistoryCapacity(
            self: *Delay,
            allocator: std.mem.Allocator,
            parameters: Parameters,
        ) std.mem.Allocator.Error!void {
            assert(parametersAreValid(parameters));

            const sample_rate_f: f32 = @floatFromInt(sample_rate);
            const minimum_delay_ms = 1_000 / sample_rate_f;
            const modulation_limit_ms = @max(
                minimum_delay_ms,
                @min(parameters.delay * 2, max_delay_ms),
            );
            const max_delay_frames: usize = @intFromFloat(@ceil(
                modulation_limit_ms * sample_rate_f / 1_000,
            ));
            const required_frames = max_delay_frames * @as(usize, parameters.feedback) + 1;
            const current_frames = self.dry_history.len / 2;
            if (required_frames <= current_frames) return;

            const next_history = try allocator.alloc(f32, required_frames * 2);
            @memset(next_history, 0);

            // Rebase samples by age so a larger ring preserves the current echo tail.
            if (current_frames != 0) {
                for (1..current_frames + 1) |age| {
                    const previous_frame = (self.history_cursor + current_frames -
                        (age % current_frames)) % current_frames;
                    const next_frame = (required_frames - (age % required_frames)) % required_frames;
                    @memcpy(
                        next_history[next_frame * 2 ..][0..2],
                        self.dry_history[previous_frame * 2 ..][0..2],
                    );
                }
                allocator.free(self.dry_history);
            }

            self.dry_history = next_history;
            self.history_cursor = 0;
        }

        /// Renders a dry/wet blend from the input and its requested delayed copies.
        fn process(dsp: *DSP, node: Index, into: []const *Buffer) ProcessError!void {
            const state = &dsp.processingState(node).delay;
            const parameters = state.parameters;
            const input_outlets = dsp.nodes.items(.inputs)[node.idx];
            if (input_outlets[0].isNoop()) return;

            const output = into[0];
            const dry = try dsp.getOutput(input_outlets[0], output.sample_count);
            const wetness = if (!input_outlets[1].isNoop())
                try dsp.getOutput(input_outlets[1], output.sample_count)
            else
                null;
            const delay = if (!input_outlets[2].isNoop())
                try dsp.getOutput(input_outlets[2], output.sample_count)
            else
                null;

            const frame_capacity = state.dry_history.len / 2;
            assert(frame_capacity != 0);
            assert(output.sample_count % 2 == 0);
            const frame_count: usize = @intCast(output.sample_count / 2);
            const sample_rate_f: f32 = @floatFromInt(sample_rate);
            const minimum_delay_ms = 1_000 / sample_rate_f;
            const modulation_limit_ms = @max(
                minimum_delay_ms,
                @min(parameters.delay * 2, max_delay_ms),
            );
            const repeat_count: usize = @intCast(parameters.feedback);

            for (0..frame_count) |frame| {
                const sample_index = frame * 2;
                const raw_delay_ms = if (delay) |buffer|
                    buffer.samples[sample_index]
                else
                    parameters.delay;
                const requested_delay_ms = if (std.math.isFinite(raw_delay_ms))
                    raw_delay_ms
                else
                    parameters.delay;
                const clamped_delay_ms = @max(
                    minimum_delay_ms,
                    @min(modulation_limit_ms, requested_delay_ms),
                );
                const delay_frames = clamped_delay_ms * sample_rate_f / 1_000;

                // Store the dry frame before reading older frames from the ring.
                @memcpy(
                    state.dry_history[state.history_cursor * 2 ..][0..2],
                    dry.samples[sample_index..][0..2],
                );

                var wet_sample: @Vector(2, f32) = @splat(0);
                var copy_level: f32 = 1;
                for (1..repeat_count + 1) |copy_index| {
                    const age = delay_frames * @as(f32, @floatFromInt(copy_index));
                    const older_age: usize = @intFromFloat(@floor(age));
                    const fraction = age - @as(f32, @floatFromInt(older_age));
                    const newer = state.readStereoHistory(older_age, frame_capacity);
                    const delayed = if (fraction == 0)
                        newer
                    else blk: {
                        const older = state.readStereoHistory(older_age + 1, frame_capacity);
                        break :blk newer + (older - newer) * @as(@Vector(2, f32), @splat(fraction));
                    };
                    wet_sample += delayed * @as(@Vector(2, f32), @splat(copy_level));
                    copy_level *= parameters.decay;
                }

                const raw_wetness: @Vector(2, f32) = if (wetness) |buffer|
                    @bitCast(buffer.samples[sample_index..][0..2].*)
                else
                    @splat(parameters.wetness);
                var finite_wetness: @Vector(2, f32) = undefined;
                inline for (0..2) |channel| {
                    const channel_wetness = raw_wetness[channel];
                    finite_wetness[channel] = if (std.math.isFinite(channel_wetness))
                        channel_wetness
                    else
                        parameters.wetness;
                }
                const wet_level = @max(
                    @as(@Vector(2, f32), @splat(0)),
                    @min(@as(@Vector(2, f32), @splat(1)), finite_wetness),
                );
                const dry_level = @as(@Vector(2, f32), @splat(1)) - wet_level;
                const dry_sample: @Vector(2, f32) = @bitCast(dry.samples[sample_index..][0..2].*);
                output.samples[sample_index..][0..2].* = @bitCast(
                    dry_sample * dry_level + wet_sample * wet_level,
                );

                state.history_cursor = (state.history_cursor + 1) % frame_capacity;
            }
        }

        /// Reads both stored channels at an integer frame age from the cursor.
        fn readStereoHistory(self: *const Delay, age: usize, frame_capacity: usize) @Vector(2, f32) {
            assert(age < frame_capacity);
            const frame = (self.history_cursor + frame_capacity - age % frame_capacity) % frame_capacity;
            return @bitCast(self.dry_history[frame * 2 ..][0..2].*);
        }
    };

    /// Reduces sample rate and bit depth to create a lo-fi effect.
    pub const BitCrusher = struct {
        /// Port metadata for the bit-crusher node.
        pub const metadata = Node.Metadata{
            .name = "Bit Crusher",
            .short_name = "bcr",
            .color = .desert,
            .has_parameters = true,
            .has_per_voice_state = true,
            .inputs = .{
                .{ .name = "audio", .short_name = "in", .color = .desert },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .outputs = .{
                .{ .name = "audio", .short_name = "out", .color = .desert, .observer = .waveform },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
        };

        /// User-controlled reduction settings.
        pub const Parameters = struct {
            /// Target rate at which new stereo frames are captured.
            target_sample_rate: u32 = 8_000,
            /// Number of bits used for quantization.
            bit_depth: u5 = 8,
        };

        /// Configuration copied at creation time.
        parameters: Parameters,
        /// Most recently captured stereo frame.
        last_sample: [2]f32 = .{ 0, 0 },
        /// Number of source frames represented by `last_sample`.
        held_frames: u32 = 0,

        /// Clears the held sample while preserving the reduction settings.
        pub fn reset(self: *BitCrusher, _: u8) void {
            const parameters = self.parameters;
            self.* = .{ .parameters = parameters };
        }

        /// Creates a bit crusher with an empty held frame.
        pub fn create(name: []const u8, parameters: Parameters) Node {
            return .{
                .state = .{
                    .bit_crusher = .{ .parameters = parameters },
                },
                .name = name,
                .process = process,
            };
        }

        /// Captures, quantizes, and holds stereo frames at the reduced settings.
        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            // Derive quantization and frame-hold settings from the configuration.
            const output = into[0];
            const state = &dsp.processingState(node).bit_crusher;
            const parameters = state.parameters;
            const levels: f32 = @floatFromInt((@as(u32, 1) << parameters.bit_depth) - 1);
            const frames_to_hold = sample_rate / parameters.target_sample_rate;

            // A severed source leaves the already-cleared output silent.
            const input = dsp.nodes.items(.inputs)[node.idx][0];
            if (input.isNoop()) return;

            // Resolve the source buffer before processing frames.
            const input_buffer = try dsp.getOutput(input, output.sample_count);

            assert(output.sample_count % 2 == 0);
            const frame_count: usize = @intCast(output.sample_count / 2);
            // Process complete stereo frames so both channels share a hold period.
            for (0..frame_count) |frame| {
                const sample_index = frame * 2;

                // Capture one complete stereo frame at the reduced rate, then
                // hold both channels until the next reduced-rate frame.
                if (state.held_frames == 0) {
                    state.last_sample[0] = input_buffer.samples[sample_index];
                    state.last_sample[1] = input_buffer.samples[sample_index + 1];
                }

                // Normalize, quantize, and map each held channel back to [-1, 1].
                for (0..2) |channel| {
                    const normalized = (state.last_sample[channel] + 1) * 0.5;
                    const quantized = @round(normalized * levels) / levels;
                    output.samples[sample_index + channel] = quantized * 2 - 1;
                }

                // Advance the hold counter and capture a new frame when it expires.
                state.held_frames += 1;
                if (state.held_frames >= frames_to_hold)
                    state.held_frames = 0;
            }
        }
    };

    /// Generates white, pink, or brown stereo noise with amplitude modulation.
    pub const Noise = struct {
        /// Port metadata for the noise node.
        pub const metadata = Node.Metadata{
            .name = "Noise",
            .short_name = "noi",
            .color = .logan,
            .has_parameters = true,
            .has_per_voice_state = true,
            .inputs = .{
                .{ .name = "amplitude", .short_name = "amp", .color = .logan },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
            .outputs = .{
                .{ .name = "noise", .short_name = "out", .color = .logan, .observer = .waveform },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
        };

        /// Available noise colors.
        pub const Type = enum {
            /// Unfiltered random noise.
            white,
            /// High-frequency-weighted noise shaped toward a 1/f spectrum.
            pink,
            /// Integrated low-frequency noise.
            brown,
        };

        /// User-controlled noise configuration.
        pub const Parameters = struct {
            /// Seed used to initialize the deterministic random stream.
            seed: u64,
            /// Noise color.
            type: Type = .white,
            /// Amplitude used when no amplitude input is connected.
            amplitude: f32 = 1,
        };

        /// Configuration copied at creation time.
        parameters: Parameters,
        /// Persistent pseudo-random generator.
        random: std.Random.Xoshiro256,
        /// Per-channel filter state for pink noise.
        pink_state: [2][6]f32 = .{
            .{ 0, 0, 0, 0, 0, 0 },
            .{ 0, 0, 0, 0, 0, 0 },
        },
        /// Per-channel integrator state for brown noise.
        brown_state: [2]f32 = .{ 0, 0 },

        /// Resets random and color-filter history with a voice-specific seed.
        pub fn reset(self: *Noise, voice: u8) void {
            const parameters = self.parameters;
            self.* = .{
                .parameters = parameters,
                .random = std.Random.DefaultPrng.init(parameters.seed +% voice),
            };
        }

        /// Creates a deterministic noise source with reset color-filter state.
        pub fn create(name: []const u8, parameters: Parameters) Node {
            return .{
                .state = .{
                    .noise = .{
                        .parameters = parameters,
                        .random = std.Random.DefaultPrng.init(parameters.seed),
                    },
                },
                .name = name,
                .process = process,
            };
        }

        /// Generates one stereo block and applies optional amplitude modulation.
        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            // Resolve persistent generator/filter state and the optional amplitude input.
            const state = &dsp.processingState(node).noise;
            const parameters = state.parameters;
            const amplitude_connection = dsp.nodes.items(.inputs)[node.idx][0];
            const amplitude_buffer = if (amplitude_connection.isNoop())
                null
            else
                try dsp.getOutput(amplitude_connection, into[0].sample_count);

            // Generate interleaved stereo samples so color state stays channel-local.
            assert(into[0].sample_count % 2 == 0);
            for (0..into[0].sample_count) |sample| {
                // Prefer modulation input; otherwise use the configured amplitude.
                const amplitude = if (amplitude_buffer) |buffer|
                    buffer.samples[sample]
                else
                    parameters.amplitude;

                // Start every color from a shared uniformly distributed sample.
                const white_noise = state.random.random().float(f32) * 2 - 1;
                const channel = sample % 2;
                // Apply the selected color filter, updating only that channel's state.
                const noise = switch (parameters.type) {
                    .white => white_noise,
                    .pink => blk: {
                        // Paul Kellet's lightweight pink-noise filter. The
                        // state is kept per channel because the buffer is
                        // stereo-interleaved.
                        // Run the six-pole pink-noise approximation.
                        var filters = &state.pink_state[channel];
                        filters[0] = 0.99886 * filters[0] + white_noise * 0.0555179;
                        filters[1] = 0.99332 * filters[1] + white_noise * 0.0750759;
                        filters[2] = 0.96900 * filters[2] + white_noise * 0.1538520;
                        filters[3] = 0.86650 * filters[3] + white_noise * 0.3104856;
                        filters[4] = 0.55000 * filters[4] + white_noise * 0.5329522;
                        filters[5] = white_noise * 0.115926;

                        break :blk (filters[0] + filters[1] + filters[2] +
                            filters[3] + filters[4] + filters[5] +
                            white_noise * 0.5362) * 0.11;
                    },
                    .brown => blk: {
                        // A leaky integrator produces the strong low-frequency
                        // emphasis characteristic of brown/red noise.
                        // Integrate and clamp the low-frequency brown-noise signal.
                        state.brown_state[channel] =
                            (state.brown_state[channel] + white_noise * 0.02) / 1.02;
                        const brown = state.brown_state[channel] * 3.5;
                        break :blk @max(-1.0, @min(1.0, brown));
                    },
                };

                // Scale the colored sample and write it to the interleaved buffer.
                into[0].samples[sample] = noise * amplitude;
            }
        }
    };

    pub const MIDI = struct {
        /// One note's controls, held in a stable voice slot until note-off.
        pub const Held = struct {
            /// Pitch converted to frequency in hertz.
            freq: f32 = 0,
            /// Whether the note remains held.
            gate: f32 = 0,
            /// Normalized MIDI velocity for the held note.
            velocity: f32 = 0,
        };

        pub const metadata = Node.Metadata{
            .name = "MIDI",
            .short_name = "midi",
            .color = .carnation,
            .has_parameters = true,
            .can_link_parameters = false,
            .duplicatable = false,
            .output_count = 3,
            .input_count = 0,
            .outputs = .{
                .{ .name = "Frequency", .short_name = "freq", .color = .carnation },
                .{ .name = "Gate", .short_name = "gate", .color = .carnation },
                .{ .name = "Velocity", .short_name = "vel", .color = .carnation },
                .{}, // TODO: CC
                .{}, // TODO: After touch
                .{}, // TODO: Pitch bend (frequency offset)
                .{},
                .{},
            },
        };

        pub const Parameters = struct {
            /// Runtime PortMidi index selected for this MIDI input node.
            device: pm.DeviceId,
        };

        parameters: Parameters,
        /// Opened input stream, absent when the saved device is unavailable.
        stream: ?*pm.MidiStream = null,
        /// Active MIDI notes indexed by the voice slot sent to downstream nodes.
        held: [max_polyphony]Held = @splat(.{}),
        /// Generation in which this node last polled its input stream.
        last_event_generation: u64 = std.math.maxInt(u64),

        /// Clears held notes while keeping the open MIDI input stream.
        pub fn reset(self: *MIDI, _: u8) void {
            const parameters = self.parameters;
            const midi_stream = self.stream;
            self.* = .{ .parameters = parameters, .stream = midi_stream };
        }

        pub fn create(name: []const u8, parameters: Parameters) Node {
            return .{
                .state = .{
                    .midi = .{ .parameters = parameters },
                },
                .name = name,
                .process = process,
                .initialize = initialize,
                .deinitialize = deinitialize,
            };
        }

        fn initialize(dsp: *DSP, node: Index, voice: u8, _: std.mem.Allocator) InitializeError!void {
            const state: *MIDI = &dsp.stateForVoice(node, voice).midi;
            if (state.parameters.device < 0) return;

            // Device indices can become stale between saving and loading a graph.
            if (pm.deviceById(dsp.midi_devices, state.parameters.device) == null) {
                state.parameters.device = pm.NoDevice;
                return;
            }

            var midi_stream: *pm.MidiStream = undefined;
            pm.openInput(
                &midi_stream,
                state.parameters.device,
                block_size,
                null,
                null,
            ) catch |err| {
                if (err == error.InvalidDeviceId) {
                    state.parameters.device = pm.NoDevice;
                    return;
                }
                return err;
            };
            state.stream = midi_stream;
        }

        fn deinitialize(dsp: *DSP, node: Index, voice: u8, _: std.mem.Allocator) void {
            const state: *MIDI = &dsp.stateForVoice(node, voice).midi;
            if (state.stream) |midi_stream| {
                midi_stream.close() catch {};
                state.stream = null;
            }
        }

        fn noteFrequency(note: u7) f32 {
            const concert_a_freq: f32 = 440.0;
            const concert_a_note: f32 = 69.0;
            const semitones_per_octave: f32 = 12.0;

            const note_f: f32 = @floatFromInt(note);
            const semitone_offset = (note_f - concert_a_note) / semitones_per_octave;

            return concert_a_freq * std.math.pow(f32, 2.0, semitone_offset);
        }

        /// Releases the first held voice matching a pitch and records its release velocity.
        fn releaseHeldNote(state: *MIDI, frequency: f32, velocity: f32) void {
            for (&state.held) |*held| {
                if (held.gate == 0 or held.freq != frequency) continue;
                held.gate = 0;
                held.velocity = velocity;
                break;
            }
        }

        fn process(dsp: *DSP, node: Index, into: []const *Buffer) ProcessError!void {
            const state: *MIDI = &dsp.nodes.items(.state)[node.idx].midi;

            // The renderer calls this once per voice. Poll once per block so
            // each voice sees the same note event and held-note snapshot.
            if (state.last_event_generation != dsp.render_generation) {
                state.last_event_generation = dsp.render_generation;
                if (state.parameters.device >= 0) {
                    if (state.stream) |midi_stream| {
                        if (try midi_stream.poll()) {
                            var read = [1]pm.Event{undefined};
                            if (midi_stream.read(read[0..]) > 0) {
                                const msg = midi.Message.init(read[0].message);
                                if (msg == .data) switch (msg.data.command) {
                                    .note_on => |on| {
                                        const frequency = noteFrequency(on.note);
                                        const velocity = @as(f32, @floatFromInt(on.attack_velocity)) / 127;
                                        if (velocity > 0) {
                                            for (&state.held) |*held| {
                                                if (held.gate != 0) continue;
                                                held.* = .{
                                                    .freq = frequency,
                                                    .gate = 1,
                                                    .velocity = velocity,
                                                };
                                                break;
                                            }
                                        } else {
                                            // MIDI commonly encodes note-off as note-on with zero velocity.
                                            releaseHeldNote(state, frequency, velocity);
                                        }
                                    },
                                    .note_off => |off| {
                                        const frequency = noteFrequency(off.note);
                                        const velocity = @as(f32, @floatFromInt(off.release_velocity)) / 127;
                                        releaseHeldNote(state, frequency, velocity);
                                    },
                                    else => {},
                                };
                            }
                        }
                    }
                }
            }

            const held = state.held[dsp.render_voice];
            @memset(into[0].samples[0..into[0].sample_count], held.freq);
            @memset(into[1].samples[0..into[1].sample_count], held.gate);
            @memset(into[2].samples[0..into[2].sample_count], held.velocity);
        }
    };
};

/// Static port metadata for every node kind.
pub const node_metadata = std.EnumArray(Node.Tag, Node.Metadata)
    .init(
    .{
        .add = Node.Add.metadata,
        .adsr = Node.ADSR.metadata,
        .bit_crusher = Node.BitCrusher.metadata,
        .constant = Node.Constant.metadata,
        .duplicate = Node.Duplicate.metadata,
        .input = Node.Input.metadata,
        .keyboard = Node.Keyboard.metadata,
        .mixer = Node.Mixer.metadata,
        .monophonic_sequencer = Node.MonophonicSequencer.metadata,
        .multimode_filter = Node.MultimodeFilter.metadata,
        .multiply = Node.Multiply.metadata,
        .noise = Node.Noise.metadata,
        .noop = Node.Noop.metadata,
        .oscillator = Node.Oscillator.metadata,
        .output = Node.Output.metadata,
        .delay = Node.Delay.metadata,
        .group = Node.Group.metadata,
        .group_input = Node.GroupInput.metadata,
        .group_output = Node.GroupOutput.metadata,
        .midi = Node.MIDI.metadata,
    },
);
