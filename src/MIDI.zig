const std = @import("std");
const pm = @import("portmidi.zig");

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
