//! PortMidi (https://github.com/PortMidi/portmidi) zig bindings

/// Standard-library support for enumerating and labeling devices.
const std = @import("std");

/// Errors returned by PortMidi operations exposed by this module.
pub const Error = error{
    HostError,
    InvalidDeviceId,
    InsufficientMemory,
    BufferTooSmall,
    BufferOverflow,
    BadPtr,
    BadData,
    InternalError,
    BufferMaxSize,
    NotImplemented,
    InterfaceNotSupported,
    NameConflict,
    DeviceRemoved,
};

/// PortMidi's numeric error codes, used to translate C return values.
const PmError = enum(c_int) {
    pmHostError = -10000,
    pmInvalidDeviceId,
    pmInsufficientMemory,
    pmBufferTooSmall,
    pmBufferOverflow,
    pmBadPtr,
    pmBadData,
    pmInternalError,
    pmBufferMaxSize,
    pmNotImplemented,
    pmInterfaceNotSupported,
    pmNameConflict,
    pmDeviceRemoved,
};

/// Converts a negative PortMidi error code to its corresponding Zig error.
fn makePmError(pm_error: c_int) Error {
    return switch (@as(PmError, @fromBackingInt(@intCast(pm_error)))) {
        .pmHostError => error.HostError,
        .pmInvalidDeviceId => error.InvalidDeviceId,
        .pmInsufficientMemory => error.InsufficientMemory,
        .pmBufferTooSmall => error.BufferTooSmall,
        .pmBufferOverflow => error.BufferOverflow,
        .pmBadPtr => error.BadPtr,
        .pmBadData => error.BadData,
        .pmInternalError => error.InternalError,
        .pmBufferMaxSize => error.BufferMaxSize,
        .pmNotImplemented => error.NotImplemented,
        .pmInterfaceNotSupported => error.InterfaceNotSupported,
        .pmNameConflict => error.NameConflict,
        .pmDeviceRemoved => error.DeviceRemoved,
    };
}

/// PortMidi C entry point that initializes its host APIs and device table.
extern fn Pm_Initialize() callconv(.c) c_int;
/// Initializes PortMidi before querying devices or opening streams.
pub fn init() Error!void {
    const res = Pm_Initialize();
    if (res < 0) {
        return makePmError(res);
    }
}

/// PortMidi C entry point that releases its initialized state.
extern fn Pm_Terminate() callconv(.c) c_int;
/// Terminates PortMidi after its streams have been closed.
pub fn deinit() Error!void {
    const res = Pm_Terminate();
    if (res < 0) {
        return makePmError(res);
    }
}

/// PortMidi C entry point that returns the number of enumerated devices.
extern fn Pm_CountDevices() callconv(.c) DeviceId;
/// Returns the number of PortMidi devices enumerated in the current process.
pub const countDevices = Pm_CountDevices;

/// Process-local index assigned to an enumerated PortMidi device.
pub const DeviceId = c_int;
/// Sentinel device ID used when no MIDI device is available or selected.
pub const NoDevice: DeviceId = -1;
/// C-compatible descriptor for one enumerated PortMidi device.
pub const DeviceInfo = extern struct {
    /// PortMidi device-info structure version.
    struct_version: c_int,
    /// Name of the host API interface used by this device.
    interf: [*:0]const u8,
    /// Device name supplied by the host API.
    name: [*:0]const u8,
    /// Nonzero when the device supports MIDI input.
    input: c_int,
    /// Nonzero when the device supports MIDI output.
    output: c_int,
    /// Nonzero when the device is currently open.
    opened: c_int,
    /// Nonzero when the device was created virtually.
    is_virtual: c_int,
};

/// Cached identity and display label for an available MIDI input device.
pub const Device = struct {
    /// Runtime PortMidi index used when opening the device.
    id: DeviceId,
    /// Host API interface name used to distinguish otherwise identical devices.
    interface_name: []const u8,
    /// Device name reported by PortMidi.
    name: []const u8,
    /// User-facing label combining the interface and device names.
    label: []const u8,
};

/// PortMidi C entry point that returns a device descriptor, if the ID is valid.
extern fn Pm_GetDeviceInfo(id: DeviceId) ?*const DeviceInfo;
/// Returns a descriptor for an enumerated device or `InvalidDeviceId`.
pub fn getDeviceInfo(id: DeviceId) Error!*const DeviceInfo {
    if (Pm_GetDeviceInfo(id)) |info| {
        return info;
    }

    return error.InvalidDeviceId;
}

/// Copies descriptors for all enumerated devices that support MIDI input.
pub fn enumerateInputDevices(allocator: std.mem.Allocator) (Error || std.mem.Allocator.Error)![]Device {
    const device_count = countDevices();
    if (device_count < 0) return error.HostError;

    var devices: std.ArrayList(Device) = .empty;
    errdefer deinitDevices(allocator, devices.items);

    for (0..@intCast(device_count)) |index| {
        const id: DeviceId = @intCast(index);
        const info = getDeviceInfo(id) catch continue;
        if (info.input == 0) continue;

        const interface_name = try allocator.dupe(u8, std.mem.span(info.interf));
        errdefer allocator.free(interface_name);
        const name = try allocator.dupe(u8, std.mem.span(info.name));
        errdefer allocator.free(name);
        const label = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ interface_name, name });
        errdefer allocator.free(label);

        try devices.append(allocator, .{
            .id = id,
            .interface_name = interface_name,
            .name = name,
            .label = label,
        });
    }

    return try devices.toOwnedSlice(allocator);
}

/// Frees the copied strings and device slice returned by `enumerateInputDevices`.
pub fn deinitDevices(allocator: std.mem.Allocator, devices: []Device) void {
    for (devices) |device| {
        allocator.free(device.interface_name);
        allocator.free(device.name);
        allocator.free(device.label);
    }
    allocator.free(devices);
}

/// Returns the first available input device, if PortMidi reported one.
pub fn defaultInputDevice(devices: []const Device) ?DeviceId {
    if (devices.len == 0) return null;
    return devices[0].id;
}

/// Finds a device by its current runtime index.
pub fn deviceById(devices: []const Device, id: DeviceId) ?*const Device {
    for (devices) |*device| {
        if (device.id == id) return device;
    }
    return null;
}

/// Finds the runtime ID matching a persisted interface and device name.
pub fn findDevice(
    devices: []const Device,
    interface_name: []const u8,
    name: []const u8,
) ?DeviceId {
    for (devices) |device| {
        if (std.mem.eql(u8, device.interface_name, interface_name) and
            std.mem.eql(u8, device.name, name))
            return device.id;
    }
    return null;
}

/// Packed PortMidi MIDI-message value containing status and data bytes.
pub const Message = c_int;
/// Extracts the low-byte MIDI status from a packed message.
pub fn messageStatus(msg: Message) c_int {
    return msg & 0xff;
}
/// Extracts the first data byte from a packed MIDI message.
pub fn messageData1(msg: Message) c_int {
    return (msg >> 8) & 0xff;
}
/// Extracts the second data byte from a packed MIDI message.
pub fn messageData2(msg: Message) c_int {
    return (msg >> 16) & 0xff;
}
/// Packs a status byte and two data bytes into a PortMidi message value.
pub fn message(status: c_int, data1: c_int, data2: c_int) Message {
    return ((data2 << 16) & 0xff0000) |
        ((data1 << 8) & 0xff00) |
        (status & 0xff);
}
/// C-compatible input event containing a packed MIDI message and timestamp.
pub const Event = extern struct {
    /// Packed MIDI status and data bytes.
    message: Message,
    /// Event timestamp in PortMidi time units.
    timestamp: Timestamp,
};

/// PortMidi C entry point that closes an open stream.
extern fn Pm_Close(stream: *MidiStream) callconv(.c) c_int;
/// PortMidi C entry point that checks whether a stream has pending input.
extern fn Pm_Poll(stream: *MidiStream) callconv(.c) c_int;
/// PortMidi C entry point that reads pending events from a stream.
extern fn Pm_Read(stream: *MidiStream, buffer: [*]Event, length: c_int) callconv(.c) c_int;
/// Opaque handle to an open PortMidi stream.
pub const MidiStream = opaque {
    /// Closes this stream and releases its PortMidi resources.
    pub fn close(self: *MidiStream) Error!void {
        const res = Pm_Close(self);
        if (res < 0) {
            return makePmError(res);
        }
    }

    /// Reports whether this stream currently has pending input events.
    pub fn poll(self: *MidiStream) Error!bool {
        const res = Pm_Poll(self);
        if (res < 0) {
            return makePmError(res);
        }

        return res == 1;
    }

    /// Reads available events into `buffer` and returns the number read.
    pub fn read(self: *MidiStream, buffer: []Event) u32 {
        const res = Pm_Read(self, buffer.ptr, @intCast(buffer.len));

        return @intCast(if (res > 0) res else 0);
    }
};
/// PortMidi timestamp value, measured in milliseconds by its default clock.
pub const Timestamp = c_int;

/// Callback signature for supplying timestamps to a PortMidi stream.
pub const TimeFn = *const fn (time_info: *anyopaque) callconv(.c) Timestamp;

/// PortMidi C entry point that opens an input stream.
extern fn Pm_OpenInput(
    stream: **MidiStream,
    input_device: DeviceId,
    input_sys_dep_info: ?*anyopaque,
    buffer_size: c_int,
    time_proc: ?TimeFn,
    time_info: ?*anyopaque,
) callconv(.c) c_int;
/// Opens a valid input-capable device and stores its stream handle in `stream`.
pub fn openInput(
    stream: **MidiStream,
    input_device: DeviceId,
    buffer_size: c_int,
    time_proc: ?TimeFn,
    time_info: ?*anyopaque,
) Error!void {
    // PortMidi's C implementation indexes this descriptor before checking the
    // ID, so validate the current device table before crossing the FFI.
    const info = try getDeviceInfo(input_device);
    if (info.input == 0) return error.InvalidDeviceId;

    const res = Pm_OpenInput(
        stream,
        input_device,
        null,
        buffer_size,
        time_proc,
        time_info,
    );
    if (res < 0) {
        return makePmError(res);
    }
}
