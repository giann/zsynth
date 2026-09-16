const std = @import("std");
const audio = @import("zaudio");
const DSP = @import("DSP.zig");

const gpa = std.heap.c_allocator;

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

pub fn main(process: std.process.Init) !void {
    audio.init(gpa);
    defer audio.deinit();

    var audio_engine_config = audio.Engine.Config.init();
    audio_engine_config.channels = 2;
    audio_engine_config.sample_rate = 48_000;
    const audio_engine = try audio.Engine.create(audio_engine_config);
    defer audio_engine.destroy();

    var dsp: DSP = undefined;
    try dsp.init(audio_engine, gpa);
    defer dsp.deinit(gpa);

    try simpleDSP(&dsp);

    while (true) {
        try process.io.sleep(.fromSeconds(1), .awake);
    }
}

/// Create a simple DSP with a square waveform, modulation, sequencing, and effects.
fn simpleDSP(dsp: *DSP) !void {
    // First voice
    const voice1 = try dsp.addNode(
        gpa,
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
        gpa,
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
        gpa,
        DSP.Node.Oscillator.create(
            .{
                .waveform = .triangle,
                .default_frequency = 440,
                .default_amplitude = 0.6,
            },
        ),
    );

    // LFO
    const lfo = try dsp.addNode(
        gpa,
        DSP.Node.Oscillator.create(
            .{
                .waveform = .sine,
                .default_frequency = 5,
                .default_amplitude = 5,
            },
        ),
    );

    const lfo2 = try dsp.addNode(
        gpa,
        DSP.Node.Oscillator.create(
            .{
                .waveform = .sine,
                .default_frequency = 3,
                .default_amplitude = 3,
            },
        ),
    );

    const multiply = try dsp.addNode(
        gpa,
        DSP.Node.Multiply.create(),
    );

    // Emit single 440 value
    const constant = try dsp.addNode(
        gpa,
        DSP.Node.Constant.create(440),
    );

    // Add so LFO modulates voice frequency instead of replace it
    const add = try dsp.addNode(
        gpa,
        DSP.Node.Add.create(),
    );

    // Mixer for 2 voices
    const mixer = try dsp.addNode(
        gpa,
        DSP.Node.Mixer.create(
            .{
                .gain = 0.3,
                // Both voice at 0.5 gain and first voice 0.5 to the left and second 0.5 to the right
                .gains = [_]f32{ 0.1, 0.1, 0.6, 0.3 } ++ [_]f32{0} ** (DSP.max_outlets - 4),
                .pans = [_]f32{ -0.7, 0.7, 0.0, 0.0 } ++ [_]f32{0} ** (DSP.max_outlets - 4),
            },
        ),
    );

    // Sequencer
    const sequencer = try dsp.addNode(
        gpa,
        DSP.Node.MonophonicSequencer.create(
            .{
                .notes = &sequencer_notes,
            },
        ),
    );

    // High pass filter
    const notch_filter = try dsp.addNode(
        gpa,
        DSP.Node.MultimodeFilter.create(
            .{
                .type = .notch,
                .default_cutoff = 400,
                .default_resonance = 0.75,
            },
        ),
    );

    // ADSR
    const adsr = try dsp.addNode(
        gpa,
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
    const crusher = try dsp.addNode(
        gpa,
        DSP.Node.BitCrusher.create(.{}),
    );

    // Sequencer for beat, will be fed into Noise node
    const beat = try dsp.addNode(
        gpa,
        DSP.Node.MonophonicSequencer.create(
            .{
                .notes = &beat_notes,
            },
        ),
    );

    // Noise
    const noise = try dsp.addNode(
        gpa,
        DSP.Node.Noise.create(
            .{
                .seed = 0,
                .type = .pink,
            },
        ),
    );

    // Final output to audio device
    const output = try dsp.addNode(
        gpa,
        DSP.Node.Output.create(),
    );
    dsp.output = output;

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
