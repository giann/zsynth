//! Graph-based small DSP
const std = @import("std");
const assert = std.debug.assert;
const a = @import("zaudio");
const Display = @import("Display.zig");
const utils = @import("utils.zig");
const SpmcQueue = utils.SpmcQueue;

/// Module type containing the DSP graph, node definitions, and audio bridge.
const DSP = @This();

pub const sample_rate = 48_000;

/// Maximum number of interleaved stereo samples rendered in one graph block.
pub const block_size = 256;
/// Maximum number of input or output ports exposed by a node.
pub const max_outlets = 8;
/// Number of rendered blocks retained by each node's SampleTap.
pub const sample_tap_capacity = 64;

/// Per-node, audio-thread-safe history of rendered output blocks.
pub const SampleTap = struct {
    /// One rendered block containing every declared output port.
    pub const Block = struct {
        /// Interleaved stereo samples indexed by output port.
        samples: [max_outlets][block_size * 2]f32,
        /// Number of valid interleaved samples in each port.
        sample_count: usize,
        /// Number of declared output ports represented by this block.
        output_count: u8,
    };

    /// Queue type used to publish blocks to independent main-thread readers.
    pub const Queue = SpmcQueue(Block);

    /// Queue descriptor owning its heap-allocated ring storage.
    queue: Queue = undefined,
};

/// Audio engine used to create and control the graph's live sound source.
/// The engine is owned by the application and must outlive this DSP.
engine: *a.Engine,

/// Node whose first output is copied to the audio device.
output: Node.Index = .{ .idx = 1 },
/// Struct-of-arrays storage for all graph nodes.
nodes: std.MultiArrayList(Node) = .empty,
/// Synchronizes graph mutation with the audio callback's graph traversal.
graph_mutex: std.atomic.Mutex = .unlocked,

/// Generation of the currently rendered audio block.
render_generation: u64 = 0,

/// Audio-library data source that requests rendered graph blocks.
graph_data_source: GraphDataSource,

/// Audio-library sound backed by `graph_data_source`.
sound: *a.Sound,

/// Initializes the graph, its live data source, and the audio sound.
pub fn init(self: *DSP, engine: *a.Engine, gpa: std.mem.Allocator) !void {
    // Capture the engine's format so every node renders at the device rate.
    assert(engine.getSampleRate() == sample_rate);

    // Initialize graph-owned fields before creating dependent resources.
    self.* = DSP{
        .engine = engine,
        .graph_data_source = undefined,
        .sound = undefined,
    };

    // Create the stereo pull source consumed by the audio library.
    try self.graph_data_source.init(2);

    // Install the sentinel node first so every default connection is valid.
    _ = try self.addNode(
        gpa,
        Node.Noop.create("noop"),
    );

    // Bind the graph source to a sound, leaving playback stopped for the caller.
    self.sound = try self.engine.createSoundFromDataSource(
        self.graph_data_source.data_source,
        .{},
        null,
    );
}

/// Stops and releases every audio resource owned by the graph.
pub fn deinit(self: *DSP, gpa: std.mem.Allocator) void {
    // Stop playback before releasing the sound and its callback source.
    self.sound.stop() catch {};
    self.lockGraph();
    defer self.unlockGraph();
    self.sound.destroy();
    // Tear down the callback source before freeing graph storage.
    self.graph_data_source.deinit();
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
        self.nodes.items(.sample_tap)[index].queue.deinit(gpa);
        _ = self.nodes.pop();
    }
    self.output = .noop;
    self.render_generation = 0;
}

/// Starts streaming rendered graph audio to the sound device.
pub fn start(self: *DSP) !void {
    try self.sound.start();
}

/// Stops streaming graph audio without destroying the graph.
pub fn stop(self: *DSP) !void {
    try self.sound.stop();
}

/// Reports whether the audio sound is currently playing.
pub fn isPlaying(self: *const DSP) bool {
    return self.sound.isPlaying();
}

pub fn toggle(self: *DSP) !void {
    if (self.sound.isPlaying())
        try self.sound.stop()
    else
        try self.sound.start();
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

    // Validate both ends before replacing the destination connection.
    const source_tag = std.meta.activeTag(self.nodes.items(.state)[source.idx]);
    const source_metadata = node_metadata.get(source_tag);
    const destination_tag = std.meta.activeTag(self.nodes.items(.state)[destination.idx]);
    const destination_metadata = node_metadata.get(destination_tag);
    assert(source_output_port < source_metadata.output_count);
    assert(destination_port < destination_metadata.input_count);

    const inputs = self.nodes.items(.inputs);
    const output_connected = self.nodes.items(.output_connected);
    const previous = inputs[destination.idx][destination_port];

    const replacing_same_connection = !previous.isNoop() and
        previous.node.idx == source.idx and
        previous.output_port == source_output_port;
    assert(replacing_same_connection or !output_connected[source.idx][source_output_port]);

    if (!previous.isNoop()) {
        output_connected[previous.node.idx][previous.output_port] = false;
    }

    inputs[destination.idx][destination_port] = .{
        .node = source,
        .output_port = source_output_port,
    };
    output_connected[source.idx][source_output_port] = true;
}

/// Disconnects the edge feeding one input port.
pub fn disconnectInput(self: *DSP, destination: Node.Index, destination_port: u8) void {
    self.lockGraph();
    defer self.unlockGraph();

    if (destination.idx >= self.nodes.len or destination_port >= max_outlets)
        return;

    const inputs = self.nodes.items(.inputs);
    const output_connected = self.nodes.items(.output_connected);
    const previous = inputs[destination.idx][destination_port];
    if (!previous.isNoop())
        output_connected[previous.node.idx][previous.output_port] = false;
    inputs[destination.idx][destination_port] = .{};
}

/// Disconnects every edge leaving one output port.
pub fn disconnectOutput(self: *DSP, source: Node.Index, source_output_port: u8) void {
    self.lockGraph();
    defer self.unlockGraph();

    if (source.idx >= self.nodes.len or source_output_port >= max_outlets)
        return;

    const inputs = self.nodes.items(.inputs);
    for (inputs) |*node_inputs| {
        for (node_inputs) |*connection| {
            if (!connection.isNoop() and
                connection.node.idx == source.idx and
                connection.output_port == source_output_port)
                connection.* = .{};
        }
    }
    self.nodes.items(.output_connected)[source.idx][source_output_port] = false;
}

/// Removes a node, releases its SampleTap, and repairs graph references.
pub fn remove(self: *DSP, gpa: std.mem.Allocator, node: Node.Index) void {
    self.lockGraph();
    defer self.unlockGraph();

    if (node.isNoop() or node.idx >= self.nodes.len)
        return;

    const last_index = self.nodes.len - 1;
    const removing_output = self.output.idx == node.idx;

    // Unplug every input owned by the removed node.
    const removed_inputs = self.nodes.items(.inputs)[node.idx];
    const output_connected = self.nodes.items(.output_connected);
    for (removed_inputs) |connection| {
        if (!connection.isNoop())
            output_connected[connection.node.idx][connection.output_port] = false;
    }

    // Remove every edge whose source is the node being removed.
    const inputs = self.nodes.items(.inputs);
    for (inputs) |*node_inputs| {
        for (node_inputs) |*connection| {
            if (connection.node.idx == node.idx) {
                connection.* = .{};
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
    }
}

/// Appends a node and returns its index in the graph.
pub fn addNode(self: *DSP, gpa: std.mem.Allocator, node: Node) !Node.Index {
    self.lockGraph();
    defer self.unlockGraph();

    try self.nodes.append(gpa, node);
    errdefer _ = self.nodes.pop();

    const new_index = self.nodes.len - 1;
    self.nodes.items(.sample_tap)[new_index].queue =
        try SampleTap.Queue.initCapacity(gpa, sample_tap_capacity);

    return .{ .idx = new_index };
}

/// Returns a node's SampleTap for immediate main-thread reads.
///
/// The returned pointer must not be retained across graph mutation. The UI
/// stores only the node index and resolves the tap again for each update.
pub fn sampleTap(self: *DSP, node: Node.Index) ?*SampleTap {
    if (node.idx >= self.nodes.len)
        return null;
    return &self.nodes.items(.sample_tap)[node.idx];
}

/// Renders one interleaved stereo block into the audio callback buffer.
fn stream(self: *DSP, into: []f32) !void {
    self.lockGraph();
    defer self.unlockGraph();

    // The callback may request a short block, but never more than one block.
    assert(into.len <= block_size * 2);
    assert(into.len % 2 == 0);

    // A new generation invalidates all node caches from the previous block.
    self.render_generation += 1;
    // Render only the configured output; dependencies are evaluated lazily.
    try self.renderNode(self.output, @intCast(into.len));

    // Copy the completed graph output to the audio library's destination.
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

/// Evaluates one node and all of its dependencies for the requested sample count.
fn renderNode(self: *DSP, node: Node.Index, sample_count: u32) !void {
    const cache = &self.nodes.items(.cache)[node.idx];

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

    // The node recursively requests any connected inputs during processing.
    try self.nodes.items(.process)[node.idx](
        self,
        node,
        outputs[0..],
    );

    // Publish the completed cache only after processing succeeds.
    cache.sample_count = sample_count;
    cache.generation = self.render_generation;

    // Publish a bounded, non-blocking copy after processing completes. The
    // SampleTap copies every declared output port for independent UI readers.
    const source_tag = std.meta.activeTag(self.nodes.items(.state)[node.idx]);
    const output_count = node_metadata.get(source_tag).output_count;
    const sample_tap = &self.nodes.items(.sample_tap)[node.idx];
    var block: SampleTap.Block = .{
        .samples = undefined,
        .sample_count = active_sample_count,
        .output_count = output_count,
    };
    for (0..@intCast(output_count)) |output_port| {
        @memcpy(
            block.samples[output_port][0..active_sample_count],
            outputs[output_port].samples[0..active_sample_count],
        );
    }
    _ = sample_tap.queue.tryPush(block);
}

/// Resolves a connection by rendering its source and returning the requested port.
fn getOutput(
    self: *DSP,
    connection: Node.Connection,
    sample_count: u32,
) !*Buffer {
    // Invalid connections indicate a graph-construction bug.
    assert(!connection.isNoop());
    const source_tag = std.meta.activeTag(self.nodes.items(.state)[connection.node.idx]);
    assert(connection.output_port < node_metadata.get(source_tag).output_count);

    // Rendering is cached, so repeated requests for this source are cheap.
    try self.renderNode(connection.node, sample_count);

    return &self.nodes.items(.cache)[connection.node.idx].outputs[
        @intCast(connection.output_port)
    ];
}

/// Releases the data-source wrapper without freeing the application-owned base.
// Needed because zaudio.DataSource.destroy() assumes zaudio-owned allocation but base is owned on our side
extern fn ma_data_source_uninit(source: *a.DataSource) void;

/// Bridges the pull-based audio callback to the pull-based DSP graph renderer.
const GraphDataSource = struct {
    /// Embedded base required by the audio-library data-source ABI.
    base: a.DataSourceBase,
    /// Opaque data-source handle passed to the audio library.
    data_source: *a.DataSource,
    /// Number of channels exposed to the audio library.
    channels: u32,
    /// Number of frames successfully delivered so far.
    cursor: u64 = 0,

    /// Callback table installed on the audio-library data source.
    const vtable = a.DataSource.VTable{
        .onRead = onRead,
        .onSeek = onSeek,
        .onGetDataFormat = onGetDataFormat,
        .onGetCursor = onGetCursor,
        .onGetLength = onGetLength,
        .onSetLooping = onSetLooping,
        .flags = .{},
    };

    /// Creates the audio-library data source around this wrapper.
    pub fn init(
        self: *GraphDataSource,
        channels: u32,
    ) !void {
        // Reset callback-visible state before handing the wrapper to the library.
        self.* = .{
            .base = undefined,
            .data_source = undefined,
            .channels = channels,
        };

        // Register the static callback table and allocate the opaque handle.
        var config = a.DataSource.Config.init();
        config.vtable = &vtable;

        self.data_source = try a.DataSource.create(config, &self.base);
    }

    /// Uninitializes the audio-library data source.
    pub fn deinit(self: *GraphDataSource) void {
        ma_data_source_uninit(self.data_source);
    }

    /// Recovers the containing wrapper from an audio-library callback handle.
    fn fromDataSource(data_source: *a.DataSource) *GraphDataSource {
        return @fieldParentPtr(
            "base",
            @as(
                *a.DataSourceBase,
                @ptrCast(@alignCast(data_source)),
            ),
        );
    }

    /// Fills the callback buffer by rendering one or more bounded graph blocks.
    fn onRead(
        ds: *a.DataSource,
        frames_out: ?*anyopaque,
        frame_count: u64,
        frames_read: *u64,
    ) callconv(.c) a.Result {
        const self = fromDataSource(ds);
        const dsp: *DSP = @fieldParentPtr("graph_data_source", self);

        // A null destination is a size/query request unsupported by this live source.
        if (frames_out == null)
            return .not_implemented;

        const output: [*]f32 = @ptrCast(@alignCast(frames_out.?));

        // This source is stereo and must fill exactly the requested frame count.
        if (self.channels != 2)
            return .invalid_args;

        // Split large audio-library requests into graph-sized chunks.
        var remaining_frames: usize = @intCast(frame_count);
        var offset_samples: usize = 0;
        while (remaining_frames > 0) {
            // Convert the selected frame count to interleaved sample count.
            const chunk_frames: usize = if (remaining_frames < block_size)
                remaining_frames
            else
                block_size;
            const chunk_samples = chunk_frames * 2;

            // Render directly into the corresponding callback-buffer slice.
            dsp.stream(
                output[offset_samples .. offset_samples + chunk_samples],
            ) catch |err| {
                std.debug.print("dsp.stream error {s}\n", .{@errorName(err)});

                return .generic_error;
            };

            // Advance both counters after a successful chunk.
            remaining_frames -= chunk_frames;
            offset_samples += chunk_samples;
        }

        // Report the complete request only after every chunk succeeded.
        self.cursor += frame_count;
        frames_read.* = frame_count;

        return .success;
    }

    /// Rejects seeking because this data source represents a live graph.
    fn onSeek(
        _: *a.DataSource,
        _: u64,
    ) callconv(.c) a.Result {
        return .not_implemented;
    }

    /// Reports the fixed float32 stereo format and sample rate.
    fn onGetDataFormat(
        ds: *a.DataSource,
        format: ?*a.Format,
        channels: ?*u32,
        data_sample_rate: ?*u32,
        _: ?[*]a.Channel,
        _: usize,
    ) callconv(.c) a.Result {
        const self = fromDataSource(ds);

        // Each optional output is independently supported by the callback ABI.
        if (format) |value| value.* = .float32;
        if (channels) |value| value.* = self.channels;
        if (data_sample_rate) |value| value.* = sample_rate;

        return .success;
    }

    /// Reports the number of frames already produced.
    fn onGetCursor(
        ds: *a.DataSource,
        cursor: ?*u64,
    ) callconv(.c) a.Result {
        const self = fromDataSource(ds);

        if (cursor) |value| value.* = self.cursor;
        return .success;
    }

    /// Reports no finite length because the graph is a live source.
    fn onGetLength(
        _: *a.DataSource,
        _: ?*u64,
    ) callconv(.c) a.Result {
        // Infinite/live source.
        return .not_implemented;
    }

    /// Accepts the looping setting because the live source has no finite loop.
    fn onSetLooping(
        _: *a.DataSource,
        _: a.Bool32,
    ) callconv(.c) a.Result {
        return .success;
    }
};

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
    /// Display name assigned by the graph owner.
    name: []const u8,
    /// Connections feeding each input port.
    inputs: [max_outlets]Connection = @splat(.{}),
    /// Whether each output port is connected to a destination input.
    output_connected: [max_outlets]bool = @splat(false),
    /// Per-generation output cache.
    cache: Cache = .{},
    /// Main-thread-readable history of this node's rendered outputs.
    sample_tap: SampleTap = .{},
    /// Function used to render this node's outputs.
    process: Process,

    /// Static metadata for one node input or output.
    pub const OutletMetadata = struct {
        name: []const u8 = "",
        short_name: []const u8 = "",
        unit: []const u8 = "",
        color: Display.Color = .transparent,
    };

    /// Static port metadata for a node kind.
    pub const Metadata = struct {
        name: []const u8,
        short_name: []const u8,
        color: Display.Color,
        /// Whether the node's outputs are meaningful to inspect as audio levels.
        meterable: bool = true,
        inputs: [max_outlets]OutletMetadata = @splat(.{}),
        outputs: [max_outlets]OutletMetadata = @splat(.{}),
        output_count: u8 = 1,
        input_count: u8 = 1,
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
    };

    /// Error set reserved for node processing failures.
    pub const ProcessError = error{};
    /// Signature implemented by every node's audio-processing function.
    pub const Process = *const fn (
        dsp: *DSP,
        node: Index,
        outputs: []const *Buffer,
    ) ProcessError!void;

    pub const Tag = enum {
        add,
        adsr,
        bit_crusher,
        constant,
        mixer,
        monophonic_sequencer,
        multimode_filter,
        multiply,
        noise,
        noop,
        oscillator,
        output,
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
    };

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

    /// Root node of the graph; forwards its input into the audio engine.
    pub const Output = struct {
        /// Port metadata for the graph output node.
        pub const metadata = Node.Metadata{
            .name = "Output",
            .short_name = "out",
            .color = .persimmon,
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
            .outputs = .{
                .{ .name = "audio", .short_name = "out", .color = .persimmon },
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
                .{},
            },
        };

        /// Creates a graph output node with one input and one output.
        pub fn create(name: []const u8) Node {
            return .{
                .state = .{
                    .output = .{},
                },
                .name = name,
                .process = process,
            };
        }

        /// Copies the connected source buffer into the output buffer.
        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            // Read the one input connection assigned to the output node.
            const input = dsp.nodes.items(.inputs)[node.idx][0];

            // An unconnected output remains silent after the renderer's clear.
            if (input.isNoop()) return;

            // Render the source at the same size, then copy its valid samples.
            const source = try dsp.getOutput(input, into[0].sample_count);
            @memcpy(
                into[0].samples[0..into[0].sample_count],
                source.samples[0..source.sample_count],
            );
        }
    };

    /// Adds all connected input signals sample by sample.
    pub const Add = struct {
        /// Port metadata for the addition node.
        pub const metadata = Node.Metadata{
            .name = "Add",
            .short_name = "add",
            .color = .amber,
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

    /// Multiplies all connected input signals sample by sample.
    pub const Multiply = struct {
        /// Port metadata for the multiplication node.
        pub const metadata = Node.Metadata{
            .name = "Multiply",
            .short_name = "mul",
            .color = .cinnabar,
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
            .meterable = false,
            .color = .golden_rod,
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

    /// Generates a stereo oscillator with optional frequency and amplitude inputs.
    pub const Oscillator = struct {
        /// Port metadata for the oscillator node.
        pub const metadata = Node.Metadata{
            .name = "Oscillator",
            .short_name = "osc",
            .color = .curious_blue,
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
                .{ .name = "audio", .short_name = "out", .color = .curious_blue },
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
        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            // Load graph connections and persistent oscillator state.
            const state = &dsp.nodes.items(.state)[node.idx].oscillator;
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
                .{ .name = "mix", .short_name = "mix", .color = .cerulean },
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
            .meterable = false,
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
            const state = &dsp.nodes.items(.state)[node.idx].monophonic_sequencer;
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
            const state = &dsp.nodes.items(.state)[node.idx].adsr;
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
                .{ .name = "audio", .short_name = "out", .color = .havelock_blue },
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
            const state = &dsp.nodes.items(.state)[node.idx].multimode_filter;
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

    /// Reduces sample rate and bit depth to create a lo-fi effect.
    pub const BitCrusher = struct {
        /// Port metadata for the bit-crusher node.
        pub const metadata = Node.Metadata{
            .name = "Bit Crusher",
            .short_name = "bcr",
            .color = .desert,
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
                .{ .name = "audio", .short_name = "out", .color = .desert },
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
            const state = &dsp.nodes.items(.state)[node.idx].bit_crusher;
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
                .{ .name = "noise", .short_name = "out", .color = .logan },
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
            const state = &dsp.nodes.items(.state)[node.idx].noise;
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
};

/// Static port metadata for every node kind.
pub const node_metadata = std.EnumArray(Node.Tag, Node.Metadata)
    .init(
    .{
        .add = Node.Add.metadata,
        .adsr = Node.ADSR.metadata,
        .bit_crusher = Node.BitCrusher.metadata,
        .constant = Node.Constant.metadata,
        .mixer = Node.Mixer.metadata,
        .monophonic_sequencer = Node.MonophonicSequencer.metadata,
        .multimode_filter = Node.MultimodeFilter.metadata,
        .multiply = Node.Multiply.metadata,
        .noise = Node.Noise.metadata,
        .noop = Node.Noop.metadata,
        .oscillator = Node.Oscillator.metadata,
        .output = Node.Output.metadata,
    },
);
