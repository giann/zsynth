//! The synth editor state and its demonstration DSP graph.

const std = @import("std");
const DSP = @import("DSP.zig");
const StateStack = @import("StateStack.zig");
const ZSynth = @import("ZSynth.zig");
const Renderer = @import("Renderer.zig");

const Self = @This();

/// Runtime owning the display, renderer, and audio engine used by this state.
zsynth: *ZSynth,
/// DSP graph constructed when the editor enters the state stack.
dsp: DSP = undefined,
/// Whether `dsp` currently owns initialized audio resources.
dsp_initialized: bool = false,

/// State-stack callbacks used by the synth editor context.
pub const vtable = StateStack.State.VTable{
    .enter = enter,
    .leave = leave,
    .quit = quit,
    .render = render,
};

/// Initializes the editor DSP graph and writes its initial display text.
fn enter(
    state_stack: *StateStack,
    gpa: std.mem.Allocator,
    state: StateStack.State.Index,
) anyerror!void {
    // Resolve this state index to the concrete editor context.
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;
    // Initialize the DSP against the runtime-owned audio engine.
    try self.dsp.init(self.zsynth.audio_engine, gpa);
    self.dsp_initialized = true;
    // Build and start the simple demonstration graph.
    try simpleDSP(&self.dsp, gpa);
    // Show the editor status after audio is running.
    try self.write(gpa);
}

/// Releases editor resources when the state is temporarily popped.
fn leave(
    state_stack: *StateStack,
    gpa: std.mem.Allocator,
    _: *Renderer,
    state: StateStack.State.Index,
) anyerror!void {
    // Resolve the concrete editor context before releasing its DSP graph.
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;
    self.deinit(gpa);
}

/// Releases editor resources when the application is shutting down.
fn quit(
    state_stack: *StateStack,
    gpa: std.mem.Allocator,
    _: *Renderer,
    state: StateStack.State.Index,
) anyerror!void {
    // Resolve the concrete editor context before releasing its DSP graph.
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;
    self.deinit(gpa);
}

/// Stops and deinitializes the DSP graph exactly once.
fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    // Avoid deinitializing an editor that never completed initialization.
    if (!self.dsp_initialized) return;
    // Release all DSP nodes and mark the graph as inactive.
    self.dsp.deinit(gpa);
    self.dsp_initialized = false;
}

/// Redraws the editor's status text in the runtime-owned display.
fn write(self: *Self, allocator: std.mem.Allocator) !void {
    // Clear the previous frame so the software cursor cannot leave a trail.
    self.zsynth.display.reset();
    // Write the title and current DSP status lines.
    try self.zsynth.display.write(allocator, "ZSYNTH", 2, 2, .black, .amber);
    try self.zsynth.display.write(allocator, "Audio DSP is running", 2, 4, .black, .white);
    try self.zsynth.display.write(allocator, "Close the window to exit", 2, 6, .black, .alto);
}

/// Rebuilds the text display and enqueues the graphic display renderer.
fn render(
    state_stack: *StateStack,
    gpa: std.mem.Allocator,
    state: StateStack.State.Index,
    renderer: *Renderer,
    dt: u64,
) anyerror!void {
    // Resolve the concrete editor context for this frame.
    const self: *Self = &state_stack.stack.items(.context)[state.idx].synth_editor;
    // Redraw text before the runtime overlays the software cursor.
    try self.write(gpa);
    // Submit the graphic display only when that display backend is active.
    if (self.zsynth.display.impl == .graphic)
        try self.zsynth.display.impl.graphic.render(gpa, renderer, dt, false);
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

/// Create a simple DSP with a square waveform, modulation, sequencing, and effects.
fn simpleDSP(dsp: *DSP, allocator: std.mem.Allocator) !void {
    // Create the three pitched voices used by the demo.
    // First voice
    const voice1 = try dsp.addNode(
        allocator,
        DSP.Node.Oscillator.create(
            .{
                .waveform = .square,
                .default_frequency = 440,
                .default_amplitude = 0.5,
            },
        ),
    );

    // Second voice
    const voice2 = try dsp.addNode(
        allocator,
        DSP.Node.Oscillator.create(
            .{
                .waveform = .square,
                .default_frequency = 587.33,
                .default_amplitude = 0.5,
            },
        ),
    );

    // Third voice
    const voice3 = try dsp.addNode(
        allocator,
        DSP.Node.Oscillator.create(
            .{
                .waveform = .triangle,
                .default_frequency = 440,
                .default_amplitude = 0.6,
            },
        ),
    );

    // Create two low-frequency modulators.
    // LFO
    const lfo = try dsp.addNode(
        allocator,
        DSP.Node.Oscillator.create(
            .{
                .waveform = .sine,
                .default_frequency = 5,
                .default_amplitude = 5,
            },
        ),
    );

    // Create the second LFO used as an amplitude modulation source.
    const lfo2 = try dsp.addNode(
        allocator,
        DSP.Node.Oscillator.create(
            .{
                .waveform = .sine,
                .default_frequency = 3,
                .default_amplitude = 3,
            },
        ),
    );

    // Combine the second LFO with the filtered third voice.
    const multiply = try dsp.addNode(
        allocator,
        DSP.Node.Multiply.create(),
    );

    // Create the constant and adder used to offset the first voice's pitch.
    // Emit single 440 value
    const constant = try dsp.addNode(
        allocator,
        DSP.Node.Constant.create(440),
    );

    // Add so LFO modulates voice frequency instead of replace it
    // Add the LFO signal to the base 440 Hz frequency.
    const add = try dsp.addNode(
        allocator,
        DSP.Node.Add.create(),
    );

    // Create the mixer that combines melodic and percussion voices.
    // Mixer for 2 voices
    const mixer = try dsp.addNode(
        allocator,
        DSP.Node.Mixer.create(
            .{
                .gain = 0.3,
                // Both voice at 0.5 gain and first voice 0.5 to the left and second 0.5 to the right
                .gains = [_]f32{ 0.1, 0.1, 0.6, 0.3, 0, 0, 0, 0 },
                .pans = [_]f32{ -0.7, 0.7, 0.0, 0.0, 0, 0, 0, 0 },
            },
        ),
    );

    // Create the melodic sequencer and its shaping effects.
    // Sequencer
    const sequencer = try dsp.addNode(
        allocator,
        DSP.Node.MonophonicSequencer.create(
            .{
                .notes = &sequencer_notes,
            },
        ),
    );

    // Add the filter, envelope, and bit crusher for the third voice.
    // High pass filter
    // Filter the third voice before its second modulation stage.
    const notch_filter = try dsp.addNode(
        allocator,
        DSP.Node.MultimodeFilter.create(
            .{
                .type = .notch,
                .default_cutoff = 400,
                .default_resonance = 0.75,
            },
        ),
    );

    // ADSR
    // Shape the sequenced voice with an envelope.
    const adsr = try dsp.addNode(
        allocator,
        DSP.Node.ADSR.create(
            .{
                .attack = 0.3,
                .attack_curve = .linear,
                .decay = 0.4,
                .sustain = 0.7,
                .release = 0.5,
            },
        ),
    );

    // BitCrusher (to get a 8bit/chip feel)
    // Reduce the mixed signal to give the demo an 8-bit character.
    const crusher = try dsp.addNode(
        allocator,
        DSP.Node.BitCrusher.create(.{}),
    );

    // Create the beat sequencer and noise generator.
    // Sequencer for beat, will be fed into Noise node
    const beat = try dsp.addNode(
        allocator,
        DSP.Node.MonophonicSequencer.create(
            .{
                .notes = &beat_notes,
            },
        ),
    );

    // Noise
    const noise = try dsp.addNode(
        allocator,
        DSP.Node.Noise.create(
            .{
                .seed = 0,
                .type = .pink,
            },
        ),
    );

    // Create the final output node and make it the DSP destination.
    // Final output to audio device
    const output = try dsp.addNode(
        allocator,
        DSP.Node.Output.create(),
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

    try dsp.start();
}
