const std = @import("std");
const pm = @import("portmidi.zig");

/// Maximum number of simultaneous notes published by one MIDI source.
pub const max_polyphony: usize = 8;

/// Atomically published state for one held MIDI note.
pub const Held = struct {
    /// MIDI pitch currently assigned to the voice.
    note: std.atomic.Value(u8) = .{ .raw = 0 },
    /// Whether the voice is currently gated.
    gate: std.atomic.Value(u8) = .{ .raw = 0 },
    /// MIDI velocity normalized to the 0..127 range.
    velocity: std.atomic.Value(u8) = .{ .raw = 0 },
    /// Monotonically increasing note-on generation assigned to this voice.
    trigger: std.atomic.Value(u64) = .{ .raw = 0 },
};

/// A MIDI source's lock-free note snapshot shared with the audio renderer.
pub const Source = struct {
    /// Notes published in stable renderer voice slots.
    held: [max_polyphony]Held = @splat(.{}),

    /// Publishes a note-on in the first free voice slot.
    pub fn noteOn(self: *Source, note: u7, velocity: u7) void {
        if (velocity == 0) {
            self.noteOff(note, 0);
            return;
        }
        for (&self.held) |*held| {
            if (held.gate.load(.acquire) != 0) continue;
            held.note.store(note, .monotonic);
            held.velocity.store(velocity, .monotonic);
            _ = held.trigger.fetchAdd(1, .monotonic);
            held.gate.store(1, .release);
            return;
        }
    }

    /// Releases the first active voice matching a MIDI note.
    pub fn noteOff(self: *Source, note: u7, velocity: u7) void {
        for (&self.held) |*held| {
            if (held.gate.load(.acquire) == 0 or held.note.load(.monotonic) != note)
                continue;
            held.velocity.store(velocity, .monotonic);
            held.gate.store(0, .release);
            return;
        }
    }

    /// Releases every voice published by this source.
    pub fn reset(self: *Source) void {
        for (&self.held) |*held|
            held.gate.store(0, .release);
    }

    /// Reads one renderer voice from this source.
    pub fn snapshot(self: *const Source, voice: u8) Snapshot {
        const held = self.held[voice];
        return .{
            .note = held.note.load(.monotonic),
            .gate = held.gate.load(.acquire),
            .velocity = held.velocity.load(.monotonic),
            .trigger = held.trigger.load(.monotonic),
        };
    }
};

/// One atomically consistent note value consumed by a MIDI node.
pub const Snapshot = struct {
    /// MIDI pitch for the voice.
    note: u8,
    /// Nonzero while the voice is active.
    gate: u8,
    /// MIDI velocity in the 0..127 range.
    velocity: u8,
    /// Note-on generation for the assigned voice.
    trigger: u64,
};

/// Device-indexed MIDI snapshots owned by the synth editor.
pub const SharedState = struct {
    /// Snapshot for the virtual computer-keyboard source.
    virtual: Source = .{},
    /// Snapshots for enumerated physical devices.
    devices: []Device = &.{},
    /// Physical device receiving virtual keyboard input, or `NoDevice`.
    virtual_target: std.atomic.Value(pm.DeviceId) = .{ .raw = pm.NoDevice },

    /// One physical device identity and its shared note snapshot.
    pub const Device = struct {
        /// PortMidi device identifier.
        id: pm.DeviceId,
        /// Notes currently held by this device.
        source: Source = .{},
    };

    /// Returns the shared source for a device ID, including the virtual source.
    pub fn source(self: *const SharedState, device_id: pm.DeviceId) *const Source {
        if (device_id == pm.NoDevice) return &self.virtual;
        for (self.devices) |*device|
            if (device.id == device_id) return &device.source;
        return &empty_source;
    }

    /// Reads the selected device and any virtual input injected into it.
    pub fn snapshot(self: *const SharedState, device_id: pm.DeviceId, voice: u8) Snapshot {
        if (device_id == pm.NoDevice)
            return self.virtual.snapshot(voice);

        const physical = self.source(device_id);
        const virtual_target = self.virtual_target.load(.acquire);
        var physical_active = false;
        for (&physical.held) |*held|
            physical_active = physical_active or held.gate.load(.acquire) != 0;
        var virtual_active = false;
        if (virtual_target == device_id) {
            for (&self.virtual.held) |*held| {
                virtual_active = virtual_active or held.gate.load(.acquire) != 0;
            }
        }

        // Keep the source's stable voice index while it is the only source
        // contributing notes. The ADSR state is indexed by this voice, so
        // compacting released notes here would move a live note onto another
        // envelope and discard its release tail.
        if (!virtual_active)
            return physical.snapshot(voice);
        if (!physical_active)
            return self.virtual.snapshot(voice);

        var active_voice: u8 = 0;
        for (&physical.held, 0..) |*held, index| {
            if (held.gate.load(.acquire) == 0) continue;
            if (active_voice == voice) return physical.snapshot(@intCast(index));
            active_voice += 1;
        }
        if (virtual_target == device_id) {
            for (&self.virtual.held, 0..) |*held, index| {
                if (held.gate.load(.acquire) == 0) continue;
                if (active_voice == voice) return self.virtual.snapshot(@intCast(index));
                active_voice += 1;
            }
        }
        return .{ .note = 0, .gate = 0, .velocity = 0, .trigger = 0 };
    }

    /// Empty source returned when a node refers to an unavailable device.
    const empty_source: Source = .{};
};

pub const Message = union(enum) {
    data: struct {
        channel: u4,
        command: union(enum) {
            note_off: struct {
                note: u7,
                release_velocity: u7,
            },
            note_on: struct {
                note: u7,
                attack_velocity: u7,
            },
            polyphonic_aftertouch: struct {
                note: u7,
                pressure: u7,
            },
            control_change: struct {
                controller: u7,
                value: u7,
            },
            program_change: struct {
                program: u7,
            },
            channel_aftertouch: struct {
                pressure: u7,
            },
            pitch_bend: u14,
        },
    },
    system: struct {
        // TODO
    },

    pub fn init(raw_message: pm.Message) Message {
        const status = pm.messageStatus(raw_message);
        return if (status & 0xf0 == 0)
            .{ .system = .{} }
        else switch (status) {
            0x80...0x8f => .{
                .data = .{
                    .channel = @intCast(status & 0x0f),
                    .command = .{
                        .note_off = .{
                            .note = @intCast(pm.messageData1(raw_message)),
                            .release_velocity = @intCast(pm.messageData2(raw_message)),
                        },
                    },
                },
            },
            0x90...0x9f => .{
                .data = .{
                    .channel = @intCast(status & 0x0f),
                    .command = .{
                        .note_on = .{
                            .note = @intCast(pm.messageData1(raw_message)),
                            .attack_velocity = @intCast(pm.messageData2(raw_message)),
                        },
                    },
                },
            },
            0xa0...0xaf => .{
                .data = .{
                    .channel = @intCast(status & 0x0f),
                    .command = .{
                        .polyphonic_aftertouch = .{
                            .note = @intCast(pm.messageData1(raw_message)),
                            .pressure = @intCast(pm.messageData2(raw_message)),
                        },
                    },
                },
            },
            0xb0...0xbf => .{
                .data = .{
                    .channel = @intCast(status & 0x0f),
                    .command = .{
                        .control_change = .{
                            .controller = @intCast(pm.messageData1(raw_message)),
                            .value = @intCast(pm.messageData2(raw_message)),
                        },
                    },
                },
            },
            0xc0...0xcf => .{
                .data = .{
                    .channel = @intCast(status & 0x0f),
                    .command = .{
                        .program_change = .{
                            .program = @intCast(pm.messageData1(raw_message)),
                        },
                    },
                },
            },
            0xd0...0xdf => .{
                .data = .{
                    .channel = @intCast(status & 0x0f),
                    .command = .{
                        .channel_aftertouch = .{
                            .pressure = @intCast(pm.messageData1(raw_message)),
                        },
                    },
                },
            },
            0xe0...0xef => .{
                .data = .{
                    .channel = @intCast(status & 0x0f),
                    .command = .{
                        .pitch_bend = @intCast(pm.messageData2(raw_message) | pm.messageData1(raw_message)),
                    },
                },
            },
            else => unreachable,
        };
    }
};
