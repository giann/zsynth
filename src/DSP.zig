//! Graph-based small DSP
const std = @import("std");
const a = @import("zaudio");

const DSP = @This();

pub const block_size = 256;
pub const max_outlets = 8;

/// Audio engine, not owned by this
engine: *a.Engine,

/// Sample rate of audio engine (48kHz)
sample_rate: u32,
/// Graph entry point node
output: Node.Index = .{ .idx = 1 },
/// List of audio nodes
nodes: std.MultiArrayList(Node) = .empty,

/// Generation of the currently rendered audio block.
render_generation: u64 = 0,

/// DataSource bound this DSP
graph_data_source: GraphDataSource,

/// zaudio Sound in which the DSP is streaming
sound: *a.Sound,

pub fn init(self: *DSP, engine: *a.Engine, gpa: std.mem.Allocator) !void {
    const sample_rate = engine.getSampleRate();

    self.* = DSP{
        .engine = engine,
        .sample_rate = sample_rate,
        .graph_data_source = undefined,
        .sound = undefined,
    };

    try self.graph_data_source.init(
        2,
        sample_rate,
    );

    // All unplugged stuff point to this thing that does nothing
    _ = try self.addNode(
        gpa,
        Node.Noop.create(),
    );

    self.sound = try self.engine.createSoundFromDataSource(
        self.graph_data_source.data_source,
        .{},
        null,
    );
}

pub fn deinit(self: *DSP, gpa: std.mem.Allocator) void {
    self.sound.stop() catch {};
    self.sound.destroy();
    self.graph_data_source.deinit();
    self.nodes.deinit(gpa);
}

pub fn start(self: *DSP) !void {
    try self.sound.start();
}

pub fn stop(self: *DSP) !void {
    try self.sound.stop();
}

pub fn plug(
    self: *DSP,
    source: Node.Index,
    source_output_port: u8,
    destination: Node.Index,
    destination_port: u8,
) void {
    std.debug.assert(source_output_port < self.nodes.items(.output_count)[source.idx]);
    std.debug.assert(destination_port < max_outlets);

    self.nodes.items(.inputs)[destination.idx][destination_port] = .{
        .node = source,
        .output_port = source_output_port,
    };
}

pub fn addNode(self: *DSP, gpa: std.mem.Allocator, node: Node) !Node.Index {
    try self.nodes.append(gpa, node);

    return .{ .idx = self.nodes.len - 1 };
}

fn stream(self: *DSP, into: []f32) !void {
    std.debug.assert(into.len <= block_size * 2);
    std.debug.assert(into.len % 2 == 0);

    self.render_generation += 1;
    try self.renderNode(self.output, @intCast(into.len));

    const output_buffer = &self.nodes.items(.cache)[self.output.idx].outputs[0];
    @memcpy(into, output_buffer.samples[0..into.len]);
}

fn renderNode(self: *DSP, node: Node.Index, sample_count: u32) !void {
    const cache = &self.nodes.items(.cache)[node.idx];

    if (cache.generation == self.render_generation and
        cache.sample_count == sample_count)
        return;

    const active_sample_count: usize = @intCast(sample_count);
    for (&cache.outputs) |*output| {
        output.sample_count = sample_count;
        @memset(output.samples[0..active_sample_count], 0);
    }

    var outputs: [max_outlets]*Buffer = undefined;
    for (&cache.outputs, 0..) |*output, i| {
        outputs[i] = output;
    }

    try self.nodes.items(.process)[node.idx](
        self,
        node,
        outputs[0..],
    );

    cache.sample_count = sample_count;
    cache.generation = self.render_generation;
}

fn getOutput(
    self: *DSP,
    connection: Node.Connection,
    sample_count: u32,
) !*Buffer {
    std.debug.assert(!connection.isNoop());
    std.debug.assert(connection.output_port < self.nodes.items(.output_count)[connection.node.idx]);

    try self.renderNode(connection.node, sample_count);

    return &self.nodes.items(.cache)[connection.node.idx].outputs[
        @intCast(connection.output_port)
    ];
}

// Needed because zaudio.DataSource.destroy() assumes zaudio-owned allocation but base is owned on our side
extern fn ma_data_source_uninit(source: *a.DataSource) void;

const GraphDataSource = struct {
    base: a.DataSourceBase,
    data_source: *a.DataSource,
    channels: u32,
    sample_rate: u32,
    cursor: u64 = 0,

    const vtable = a.DataSource.VTable{
        .onRead = onRead,
        .onSeek = onSeek,
        .onGetDataFormat = onGetDataFormat,
        .onGetCursor = onGetCursor,
        .onGetLength = onGetLength,
        .onSetLooping = onSetLooping,
        .flags = .{},
    };

    pub fn init(
        self: *GraphDataSource,
        channels: u32,
        sample_rate: u32,
    ) !void {
        self.* = .{
            .base = undefined,
            .data_source = undefined,
            .channels = channels,
            .sample_rate = sample_rate,
        };

        var config = a.DataSource.Config.init();
        config.vtable = &vtable;

        self.data_source = try a.DataSource.create(config, &self.base);
    }

    pub fn deinit(self: *GraphDataSource) void {
        ma_data_source_uninit(self.data_source);
    }

    fn fromDataSource(data_source: *a.DataSource) *GraphDataSource {
        return @fieldParentPtr(
            "base",
            @as(
                *a.DataSourceBase,
                @ptrCast(@alignCast(data_source)),
            ),
        );
    }

    fn onRead(
        ds: *a.DataSource,
        frames_out: ?*anyopaque,
        frame_count: u64,
        frames_read: *u64,
    ) callconv(.c) a.Result {
        const self = fromDataSource(ds);
        const dsp: *DSP = @fieldParentPtr("graph_data_source", self);

        // This source is live and does not support seeking.
        if (frames_out == null)
            return .not_implemented;

        const output: [*]f32 = @ptrCast(@alignCast(frames_out.?));

        // This must fill exactly frame_count frames.
        if (self.channels != 2)
            return .invalid_args;

        var remaining_frames: usize = @intCast(frame_count);
        var offset_samples: usize = 0;
        while (remaining_frames > 0) {
            const chunk_frames: usize = if (remaining_frames < block_size)
                remaining_frames
            else
                block_size;
            const chunk_samples = chunk_frames * 2;

            dsp.stream(
                output[offset_samples .. offset_samples + chunk_samples],
            ) catch |err| {
                std.debug.print("dsp.stream error {s}\n", .{@errorName(err)});

                return .generic_error;
            };

            remaining_frames -= chunk_frames;
            offset_samples += chunk_samples;
        }

        self.cursor += frame_count;
        frames_read.* = frame_count;

        return .success;
    }

    fn onSeek(
        _: *a.DataSource,
        _: u64,
    ) callconv(.c) a.Result {
        return .not_implemented;
    }

    fn onGetDataFormat(
        ds: *a.DataSource,
        format: ?*a.Format,
        channels: ?*u32,
        sample_rate: ?*u32,
        _: ?[*]a.Channel,
        _: usize,
    ) callconv(.c) a.Result {
        const self = fromDataSource(ds);

        if (format) |value| value.* = .float32;
        if (channels) |value| value.* = self.channels;
        if (sample_rate) |value| value.* = self.sample_rate;

        return .success;
    }

    fn onGetCursor(
        ds: *a.DataSource,
        cursor: ?*u64,
    ) callconv(.c) a.Result {
        const self = fromDataSource(ds);

        if (cursor) |value| value.* = self.cursor;
        return .success;
    }

    fn onGetLength(
        _: *a.DataSource,
        _: ?*u64,
    ) callconv(.c) a.Result {
        // Infinite/live source.
        return .not_implemented;
    }

    fn onSetLooping(
        _: *a.DataSource,
        _: a.Bool32,
    ) callconv(.c) a.Result {
        return .success;
    }
};

const Buffer = struct {
    samples: [block_size * 2]f32,
    // Number of valid interleaved f32 samples in `samples`.
    sample_count: u32 = block_size * 2,

    pub fn init(default: f32, sample_count: u32) Buffer {
        var buffer = Buffer{
            .samples = undefined,
            .sample_count = sample_count,
        };

        @memset(buffer.samples[0..], default);

        return buffer;
    }
};

pub const Note = struct {
    pub const RawPitch = u7;

    pub const Accidental = enum(i8) {
        flat = -1,
        natural = 0,
        sharp = 1,
    };

    pub const Pitch = enum(i8) {
        c = 0,
        d = 2,
        e = 4,
        f = 5,
        g = 7,
        a = 9,
        b = 11,

        pub fn pitch(self: Pitch, accidental: Accidental, octave: i16) RawPitch {
            const value = (octave + 1) * 12 +
                @intFromEnum(self) +
                @intFromEnum(accidental);

            std.debug.assert(value >= 0 and value <= 127);

            return @intCast(value);
        }
    };

    /// null means rest
    pitch: ?RawPitch,
    start_tick: u64,
    duration_ticks: u64,
    velocity: f32 = 1,

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

pub const Node = struct {
    pub const Index = struct {
        pub const noop = Index{ .idx = 0 };

        idx: usize,

        pub fn isNoop(self: Index) bool {
            return self.idx == 0;
        }
    };

    pub const Connection = struct {
        node: Index = .noop,
        output_port: u8 = 0,

        pub fn isNoop(self: Connection) bool {
            return self.node.isNoop();
        }
    };

    /// When node has multiple outputs, we compute all of them once, then serve this cache to other ports when requested
    pub const Cache = struct {
        generation: u64 = 0,
        sample_count: u32 = 0,
        outputs: [max_outlets]Buffer = undefined,
    };

    pub const ProcessError = error{};
    pub const Process = *const fn (
        dsp: *DSP,
        node: Index,
        outputs: []const *Buffer,
    ) ProcessError!void;

    pub const State = union(enum) {
        add: Add,
        adsr: ADSR,
        bit_crusher: BitCrusher,
        constant: Constant,
        mixer: Mixer,
        monophonic_sequencer: MonophonicSequencer,
        multimode_filter: MultimodeFilter,
        multiply: Multiply,
        noise: Noise,
        noop: Noop,
        oscillator: Oscillator,
        output: Output,
    };

    state: State,
    output_count: u8 = 1,
    inputs: [max_outlets]Connection = [_]Connection{.{}} ** max_outlets,
    cache: Cache = .{},
    process: Process,

    /// A node that does nothing (any non-initialize input/output of new node point to it)
    pub const Noop = struct {
        pub fn create() Node {
            return .{
                .state = .{ .noop = .{} },
                .process = process,
            };
        }

        fn process(
            _: *DSP,
            _: Index,
            _: []const *Buffer,
        ) ProcessError!void {}
    };

    /// Root node of the graph, forwards its input into the audio engine
    pub const Output = struct {
        pub fn create() Node {
            return .{
                .state = .{
                    .output = .{},
                },
                .process = process,
            };
        }

        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            // Just forward input
            const input = dsp.nodes.items(.inputs)[node.idx][0];

            if (input.isNoop()) return;

            const source = try dsp.getOutput(input, into[0].sample_count);
            @memcpy(
                into[0].samples[0..into[0].sample_count],
                source.samples[0..source.sample_count],
            );
        }
    };

    /// Add inputs
    pub const Add = struct {
        pub fn create() Node {
            return .{
                .state = .{
                    .add = .{},
                },
                .process = process,
            };
        }

        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            const input_outlets = dsp.nodes.items(.inputs)[node.idx];
            const output = into[0];

            // Get data from each input
            var inputs = [_]*Buffer{undefined} ** max_outlets;
            var input_count: usize = 0;
            for (0..inputs.len) |i| {
                const input = input_outlets[i];
                if (input.isNoop()) continue;

                inputs[input_count] = try dsp.getOutput(input, into[0].sample_count);
                input_count += 1;
            }

            // Sum with SIMD
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

            // Sum tail
            while (offset < output.sample_count) : (offset += 1) {
                var sum: f32 = 0;

                for (0..input_count) |i|
                    sum += inputs[i].samples[offset];

                output.samples[offset] = sum;
            }
        }
    };

    /// Multiply inputs
    pub const Multiply = struct {
        pub fn create() Node {
            return .{
                .state = .{
                    .multiply = .{},
                },
                .process = process,
            };
        }

        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            const input_outlets = dsp.nodes.items(.inputs)[node.idx];
            const output = into[0];

            // Get data from each input
            var inputs = [_]*Buffer{undefined} ** max_outlets;
            var input_count: usize = 0;
            for (0..inputs.len) |i| {
                const input = input_outlets[i];
                if (input.isNoop()) continue;

                inputs[input_count] = try dsp.getOutput(input, into[0].sample_count);
                input_count += 1;
            }

            // Multiply with SIMD
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

            // Multiply tail
            while (offset < output.sample_count) : (offset += 1) {
                var result: f32 = 0;

                for (0..input_count) |i|
                    result *= inputs[i].samples[offset];

                output.samples[offset] = result;
            }
        }
    };

    pub const Constant = struct {
        constant: f32 = 0,

        pub fn create(constant: f32) Node {
            return .{
                .state = .{
                    .constant = .{ .constant = constant },
                },
                .process = process,
            };
        }

        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            @memset(
                into[0].samples[0..],
                dsp.nodes.items(.state)[node.idx].constant.constant,
            );
        }
    };

    /// Simple oscillator
    pub const Oscillator = struct {
        pub const Waveform = enum {
            sine,
            sawtooth,
            triangle,
            square,
        };

        const tau: f32 = @floatCast(std.math.tau);

        waveform: Waveform,
        phase: f32 = 0,
        phase_offset: f32 = 0,
        default_frequency: f32,
        default_amplitude: f32,

        pub fn create(oscillator: Oscillator) Node {
            return .{
                .state = .{
                    .oscillator = oscillator,
                },
                .process = process,
            };
        }

        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            const state = &dsp.nodes.items(.state)[node.idx].oscillator;
            const input_outlets = dsp.nodes.items(.inputs)[node.idx];
            const frequency_connection = input_outlets[0];
            const amplitude_connection = input_outlets[1];

            const frequency_buffer: ?*Buffer = if (frequency_connection.isNoop())
                null
            else
                try dsp.getOutput(frequency_connection, into[0].sample_count);
            const amplitude_buffer: ?*Buffer = if (amplitude_connection.isNoop())
                null
            else
                try dsp.getOutput(amplitude_connection, into[0].sample_count);

            const sample_rate: f32 = @floatFromInt(dsp.sample_rate);

            std.debug.assert(into[0].sample_count % 2 == 0);
            const frame_count: usize = @intCast(into[0].sample_count / 2);
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
                const frequency = frequency_input orelse state.default_frequency;
                const amplitude = amplitude_input orelse state.default_amplitude;
                const phase = state.phase + state.phase_offset;
                const phase_in_cycles = phase / tau;
                const normalized_phase: f32 = phase_in_cycles - @floor(phase_in_cycles);

                const unit_sample: f32 = switch (state.waveform) {
                    .sine => @sin(phase),
                    // Ramps from -1 to +1, then jumps back to -1.
                    .sawtooth => 2 * normalized_phase - 1,
                    // Starts at -1, reaches +1 halfway through the cycle.
                    .triangle => 1 - 4 * @abs(normalized_phase - 0.5),
                    // Starts high and changes to low halfway through the cycle.
                    .square => if (normalized_phase < 0.5) 1 else -1,
                };
                const sample = amplitude * unit_sample;

                into[0].samples[sample_index] = sample;
                into[0].samples[sample_index + 1] = sample;

                // Integrate the instantaneous frequency into phase so
                // frequency modulation works correctly across frames.
                state.phase += tau * frequency / sample_rate;

                // Keep phase bounded. This assumes normal oscillator
                // frequencies whose per-frame increment is below tau.
                if (state.phase >= tau)
                    state.phase -= tau;
                if (state.phase < 0)
                    state.phase += tau;
            }
        }
    };

    pub const Mixer = struct {
        gain: f32 = 1,
        gains: [max_outlets]f32 = [_]f32{1} ** max_outlets,
        pans: [max_outlets]f32 = [_]f32{0} ** max_outlets,

        pub fn create(mixer: Mixer) Node {
            return .{
                .state = .{
                    .mixer = mixer,
                },
                .process = process,
            };
        }

        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            const state = &dsp.nodes.items(.state)[node.idx].mixer;
            const input_outlets = dsp.nodes.items(.inputs)[node.idx];
            const output = into[0];

            // Get data from each input
            var inputs = [_]*Buffer{undefined} ** state.gains.len;
            var input_count: usize = 0;
            var left_gains = [_]f32{0} ** max_outlets;
            var right_gains = [_]f32{0} ** max_outlets;
            var mix_gains = [_]f32{0} ** max_outlets;
            for (0..inputs.len) |i| {
                const input = input_outlets[i];
                if (input.isNoop()) continue;

                inputs[input_count] = try dsp.getOutput(input, output.sample_count);

                // Pan input
                const angle = (state.pans[i] + 1) * std.math.pi / 4;
                left_gains[input_count] = @cos(angle);
                right_gains[input_count] = @sin(angle);
                mix_gains[input_count] = state.gains[i];

                input_count += 1;
            }

            std.debug.assert(output.sample_count % 2 == 0);

            // Mix and pan them together with SIMD
            var offset: usize = 0;
            if (std.simd.suggestVectorLength(f32)) |lanes| {
                const V = @Vector(lanes, f32);

                while (offset + lanes <= output.sample_count) : (offset += lanes) {
                    var result: V = @splat(0);

                    for (0..input_count) |i| {
                        // Create an interleaved vector of gains
                        var gains: V = undefined;
                        inline for (0..lanes) |lane|
                            gains[lane] = (if (lane % 2 == 0) left_gains[i] else right_gains[i]) *
                                mix_gains[i];

                        const input: V = @bitCast(inputs[i].samples[offset..][0..lanes].*);

                        result += input * gains;
                    }

                    output.samples[offset..][0..lanes].* = @bitCast(result * @as(V, @splat(state.gain)));
                }
            }

            // Mix and pan together tail
            while (offset < output.sample_count) : (offset += 2) {
                var left: f32 = 0;
                var right: f32 = 0;

                for (0..input_count) |i| {
                    const input = inputs[i];

                    const sample_left = input.samples[offset] * left_gains[i];
                    const sample_right = input.samples[offset + 1] * right_gains[i];

                    // Mix it with the rest
                    left += sample_left * mix_gains[i];
                    right += sample_right * mix_gains[i];
                }

                // Write the mixed signal and apply mixer gain
                output.samples[offset] = left * state.gain;
                output.samples[offset + 1] = right * state.gain;
            }
        }
    };

    pub const MonophonicSequencer = struct {
        /// Amount of ticks for a quater note
        pub const quarter_note_ticks = 960;

        bpm: u8 = 120,
        notes: []const Note,
        /// Current position in ticks
        position: f64 = 0,
        note_index: usize = 0,
        loop: bool = true,
        /// We continue to emit last not frequency with amplitude and gate at 0 in gaps so that ADSR can work
        last_frequency: f32 = 0,

        pub fn create(sequencer: MonophonicSequencer) Node {
            return .{
                .output_count = 3,
                .state = .{
                    .monophonic_sequencer = sequencer,
                },
                .process = process,
            };
        }

        fn ticksToSamples(self: *MonophonicSequencer, ticks: u64, sample_rate: u32) u64 {
            const samples_f64 =
                @as(f64, @floatFromInt(ticks)) *
                60.0 *
                @as(f64, @floatFromInt(sample_rate)) /
                (@as(f64, @floatFromInt(self.bpm)) *
                    @as(f64, @floatFromInt(quarter_note_ticks)));

            return @intFromFloat(@round(samples_f64));
        }

        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            const state = &dsp.nodes.items(.state)[node.idx].monophonic_sequencer;

            const ticks_per_frame: f64 =
                @as(f64, @floatFromInt(state.bpm)) *
                @as(f64, @floatFromInt(quarter_note_ticks)) /
                (60.0 * @as(f64, @floatFromInt(dsp.sample_rate)));

            std.debug.assert(into[0].sample_count % 2 == 0);
            const frame_count: usize = @intCast(into[0].sample_count / 2);

            std.debug.assert(state.notes.len > 0);
            const sequence_end = @as(
                f64,
                @floatFromInt(
                    state.notes[state.notes.len - 1].start_tick +
                        state.notes[state.notes.len - 1].duration_ticks,
                ),
            );

            for (0..frame_count) |frame| {
                const sample_index = frame * 2;

                var frequency: f32 = state.last_frequency;
                var gate: f32 = 0;
                var velocity: f32 = 0;

                // Sequence ended?
                if (state.position >= sequence_end) {
                    if (state.loop) { // Go back to start
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

                // Select current note
                const tick: u64 = @intFromFloat(state.position);
                while (state.note_index < state.notes.len) {
                    const note = state.notes[state.note_index];
                    // If inside note's tick range, select this note
                    if (tick < note.start_tick or
                        tick - note.start_tick < note.duration_ticks)
                        break;
                    state.note_index += 1;
                }

                // If in note, apply frequency, gate and velocity
                if (state.note_index < state.notes.len) {
                    const note = state.notes[state.note_index];
                    if (tick >= note.start_tick and note.pitch != null) {
                        frequency = note.frequency();
                        state.last_frequency = frequency;
                        gate = 1;
                        velocity = note.velocity;
                    }
                } // else it's a gap and values are already at 0

                // Interleave left/right
                into[0].samples[sample_index] = frequency;
                into[0].samples[sample_index + 1] = frequency;
                into[1].samples[sample_index] = gate;
                into[1].samples[sample_index + 1] = gate;
                into[2].samples[sample_index] = velocity;
                into[2].samples[sample_index + 1] = velocity;

                // Advance position in ticks
                state.position += ticks_per_frame;
            }
        }
    };

    pub const ADSR = struct {
        pub const Curve = enum {
            linear,
            exponential,
            logarithmic,
        };

        const Stage = enum {
            idle,
            attack,
            decay,
            sustain,
            release,
        };

        attack: f32 = 0,
        attack_curve: Curve = .exponential,
        decay: f32 = 0,
        decay_curve: Curve = .exponential,
        sustain: f32 = 1,
        release: f32 = 1,
        release_curve: Curve = .exponential,

        // Current state
        stage: Stage = .idle,
        stage_elapsed: f32 = 0,
        stage_start_level: f32 = 0,
        level: f32 = 0,
        velocity: f32 = 1,

        pub fn create(adsr: ADSR) Node {
            return .{
                .state = .{
                    .adsr = adsr,
                },
                .process = process,
            };
        }

        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            const state = &dsp.nodes.items(.state)[node.idx].adsr;
            const input_outlets = dsp.nodes.items(.inputs)[node.idx];
            const gate_connection = input_outlets[0];
            const velocity_connection = input_outlets[1];

            // Gate is required
            std.debug.assert(!gate_connection.isNoop());
            const gate_buffer = try dsp.getOutput(gate_connection, into[0].sample_count);

            // Velocity is optional
            const velocity_buffer = if (velocity_connection.isNoop())
                null
            else
                try dsp.getOutput(velocity_connection, into[0].sample_count);

            std.debug.assert(into[0].sample_count % 2 == 0);
            const frame_count: usize = @intCast(into[0].sample_count / 2);
            const sustain = @max(0.0, @min(1.0, state.sustain));
            for (0..frame_count) |frame| {
                const sample_index = frame * 2;

                const gate = gate_buffer.samples[sample_index];
                const velocity = if (velocity_buffer) |buffer|
                    buffer.samples[sample_index]
                else
                    1;
                const gate_on = gate >= 0.5;

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

                const sample_rate: f32 = @floatFromInt(dsp.sample_rate);
                const delta_time = 1.0 / sample_rate;

                switch (state.stage) {
                    .idle => {
                        state.level = 0;
                    },
                    .attack => {
                        if (state.attack <= 0) {
                            state.level = 1;
                            state.stage = .decay;
                            state.stage_elapsed = 0;
                            state.stage_start_level = 1;
                        } else {
                            const progress = @min(1.0, state.stage_elapsed / state.attack);
                            state.level = interpolate(
                                state.attack_curve,
                                state.stage_start_level,
                                1,
                                progress,
                            );
                            state.stage_elapsed += delta_time;
                            if (state.stage_elapsed >= state.attack) {
                                state.level = 1;
                                state.stage = .decay;
                                state.stage_elapsed = 0;
                                state.stage_start_level = 1;
                            }
                        }
                    },
                    .decay => {
                        if (state.decay <= 0) {
                            state.level = sustain;
                            state.stage = .sustain;
                            state.stage_elapsed = 0;
                            state.stage_start_level = state.level;
                        } else {
                            const progress = @min(1.0, state.stage_elapsed / state.decay);
                            state.level = interpolate(
                                state.decay_curve,
                                1,
                                sustain,
                                progress,
                            );
                            state.stage_elapsed += delta_time;
                            if (state.stage_elapsed >= state.decay) {
                                state.level = sustain;
                                state.stage = .sustain;
                                state.stage_elapsed = 0;
                                state.stage_start_level = state.level;
                            }
                        }
                    },
                    .sustain => {
                        state.level = sustain;
                    },
                    .release => {
                        if (state.release <= 0) {
                            state.level = 0;
                            state.stage = .idle;
                            state.stage_elapsed = 0;
                            state.stage_start_level = 0;
                        } else {
                            const progress = @min(1.0, state.stage_elapsed / state.release);
                            state.level = interpolate(
                                state.release_curve,
                                state.stage_start_level,
                                0,
                                progress,
                            );
                            state.stage_elapsed += delta_time;
                            if (state.stage_elapsed >= state.release) {
                                state.level = 0;
                                state.stage = .idle;
                                state.stage_elapsed = 0;
                                state.stage_start_level = 0;
                            }
                        }
                    },
                }

                const output = state.level * state.velocity;
                into[0].samples[sample_index] = output;
                into[0].samples[sample_index + 1] = output;
            }
        }

        fn interpolate(curve: Curve, from: f32, to: f32, progress: f32) f32 {
            const t = @max(0.0, @min(1.0, progress));
            const steepness: f32 = 5;
            const shaped = switch (curve) {
                .linear => t,
                // Slow at the beginning, fast at the end.
                .exponential => (@exp(steepness * t) - 1) / (@exp(steepness) - 1),
                // Fast at the beginning, slow at the end.
                .logarithmic => (1 - @exp(-steepness * t)) / (1 - @exp(-steepness)),
            };
            return from + (to - from) * shaped;
        }
    };

    pub const MultimodeFilter = struct {
        pub const Type = enum {
            high_pass,
            low_pass,
            band_pass,
            notch,
        };

        type: Type,
        default_cutoff: f32,
        default_resonance: f32,
        low: [2]f32 = .{ 0, 0 },
        band: [2]f32 = .{ 0, 0 },

        pub fn create(filter: MultimodeFilter) Node {
            return .{
                .state = .{
                    .multimode_filter = filter,
                },
                .process = process,
            };
        }

        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            const state = &dsp.nodes.items(.state)[node.idx].multimode_filter;
            const input_outlets = dsp.nodes.items(.inputs)[node.idx];

            std.debug.assert(!input_outlets[0].isNoop());
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

            const sample_rate: f32 = @floatFromInt(dsp.sample_rate);

            for (0..into[0].sample_count) |sample| {
                const channel = sample % 2;
                const audio = audio_buffer.samples[sample];

                const cutoff = if (cutoff_buffer) |buffer|
                    buffer.samples[sample]
                else
                    state.default_cutoff;

                const resonance = if (resonance_buffer) |buffer|
                    buffer.samples[sample]
                else
                    state.default_resonance;

                // This is a Chamberlin-style state-variable filter. `f`
                // controls how quickly the filter moves, while `damping`
                // controls the resonance around the cutoff.
                const clamped_cutoff = @max(0.0, @min(sample_rate * 0.49, cutoff));
                const f = 2 * @sin(std.math.pi * clamped_cutoff / sample_rate);
                const clamped_resonance = @max(0.0, @min(1.0, resonance));
                const resonance_root = @sqrt(@sqrt(clamped_resonance));
                var damping = 2 * (1 - resonance_root);
                if (f > 0)
                    damping = @min(damping, 2 / f - f * 0.5);
                damping = @max(0.001, damping);

                const notch = audio - damping * state.band[channel];
                state.low[channel] += f * state.band[channel];
                const high = notch - state.low[channel];
                state.band[channel] += f * high;
                const notch_output = high + state.low[channel];

                into[0].samples[sample] = switch (state.type) {
                    .low_pass => state.low[channel],
                    .high_pass => high,
                    .band_pass => state.band[channel],
                    .notch => notch_output,
                };
            }
        }
    };

    pub const BitCrusher = struct {
        target_sample_rate: u32 = 8_000,
        bit_depth: u5 = 8,
        last_sample: [2]f32 = .{ 0, 0 },
        held_frames: u32 = 0,

        pub fn create(crusher: BitCrusher) Node {
            return .{
                .state = .{
                    .bit_crusher = crusher,
                },
                .process = process,
            };
        }

        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            const output = into[0];
            const state = &dsp.nodes.items(.state)[node.idx].bit_crusher;
            const levels: f32 = @floatFromInt((@as(u32, 1) << state.bit_depth) - 1);
            const frames_to_hold = dsp.sample_rate / state.target_sample_rate;

            const input = dsp.nodes.items(.inputs)[node.idx][0];
            std.debug.assert(!input.isNoop());
            const input_buffer = try dsp.getOutput(input, output.sample_count);

            std.debug.assert(output.sample_count % 2 == 0);
            const frame_count: usize = @intCast(output.sample_count / 2);
            for (0..frame_count) |frame| {
                const sample_index = frame * 2;

                // Capture one complete stereo frame at the reduced rate, then
                // hold both channels until the next reduced-rate frame.
                if (state.held_frames == 0) {
                    state.last_sample[0] = input_buffer.samples[sample_index];
                    state.last_sample[1] = input_buffer.samples[sample_index + 1];
                }

                for (0..2) |channel| {
                    const normalized = (state.last_sample[channel] + 1) * 0.5;
                    const quantized = @round(normalized * levels) / levels;
                    output.samples[sample_index + channel] = quantized * 2 - 1;
                }

                state.held_frames += 1;
                if (state.held_frames >= frames_to_hold)
                    state.held_frames = 0;
            }
        }
    };

    pub const Noise = struct {
        pub const Type = enum {
            white,
            pink,
            brown,
        };

        pub const Config = struct {
            seed: u64,
            type: Type = .white,
            amplitude: f32 = 1,
        };

        random: std.Random.Xoshiro256,
        default_amplitude: f32,
        pink_state: [2][6]f32 = .{
            .{ 0, 0, 0, 0, 0, 0 },
            .{ 0, 0, 0, 0, 0, 0 },
        },
        brown_state: [2]f32 = .{ 0, 0 },
        type: Type,

        pub fn create(config: Config) Node {
            return .{
                .state = .{
                    .noise = .{
                        .random = std.Random.DefaultPrng.init(config.seed),
                        .default_amplitude = config.amplitude,
                        .type = config.type,
                    },
                },
                .process = process,
            };
        }

        fn process(
            dsp: *DSP,
            node: Index,
            into: []const *Buffer,
        ) ProcessError!void {
            const state = &dsp.nodes.items(.state)[node.idx].noise;
            const amplitude_connection = dsp.nodes.items(.inputs)[node.idx][0];
            const amplitude_buffer = if (amplitude_connection.isNoop())
                null
            else
                try dsp.getOutput(amplitude_connection, into[0].sample_count);

            std.debug.assert(into[0].sample_count % 2 == 0);
            for (0..into[0].sample_count) |sample| {
                const amplitude = if (amplitude_buffer) |buffer|
                    buffer.samples[sample]
                else
                    state.default_amplitude;

                const white_noise = state.random.random().float(f32) * 2 - 1;
                const channel = sample % 2;
                const noise = switch (state.type) {
                    .white => white_noise,
                    .pink => blk: {
                        // Paul Kellet's lightweight pink-noise filter. The
                        // state is kept per channel because the buffer is
                        // stereo-interleaved.
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
                        state.brown_state[channel] =
                            (state.brown_state[channel] + white_noise * 0.02) / 1.02;
                        const brown = state.brown_state[channel] * 3.5;
                        break :blk @max(-1.0, @min(1.0, brown));
                    },
                };

                into[0].samples[sample] = noise * amplitude;
            }
        }
    };
};
