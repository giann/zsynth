//! PortMidi (https://github.com/PortMidi/portmidi) zig bindings

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

extern fn Pm_Initialize() callconv(.c) c_int;
pub fn init() Error!void {
    const res = Pm_Initialize();
    if (res < 0) {
        return makePmError(res);
    }
}

extern fn Pm_Terminate() callconv(.c) c_int;
pub fn deinit() Error!void {
    const res = Pm_Terminate();
    if (res < 0) {
        return makePmError(res);
    }
}

extern fn Pm_CountDevices() callconv(.c) DeviceId;
pub const countDevices = Pm_CountDevices;

pub const DeviceId = c_int;
pub const NoDevice: DeviceId = -1;
pub const DeviceInfo = extern struct {
    struct_version: c_int,
    interf: [*:0]const u8,
    name: [*:0]const u8,
    input: bool,
    output: bool,
    opened: bool,
    is_virtual: bool,
};

extern fn Pm_GetDeviceInfo(id: DeviceId) ?*const DeviceInfo;
pub fn getDeviceInfo(id: DeviceId) Error!*const DeviceInfo {
    if (Pm_GetDeviceInfo(id)) |info| {
        return info;
    }

    return error.InvalidDeviceId;
}

pub const Message = c_int;
pub fn messageStatus(msg: Message) c_int {
    return msg & 0xff;
}
pub fn messageData1(msg: Message) c_int {
    return (msg >> 8) & 0xff;
}
pub fn messageData2(msg: Message) c_int {
    return (msg >> 16) & 0xff;
}
pub fn message(status: c_int, data1: c_int, data2: c_int) Message {
    return ((data2 << 16) & 0xff0000) |
        ((data1 << 8) & 0xff00) |
        (status & 0xff);
}
pub const Event = extern struct {
    message: Message,
    timestamp: Timestamp,
};

extern fn Pm_Close(stream: *MidiStream) callconv(.c) c_int;
extern fn Pm_Poll(stream: *MidiStream) callconv(.c) c_int;
extern fn Pm_Read(stream: *MidiStream, buffer: [*]Event, length: c_int) callconv(.c) c_int;
pub const MidiStream = opaque {
    pub fn close(self: *MidiStream) Error!void {
        const res = Pm_Close(self);
        if (res < 0) {
            return makePmError(res);
        }
    }

    pub fn poll(self: *MidiStream) Error!bool {
        const res = Pm_Poll(self);
        if (res < 0) {
            return makePmError(res);
        }

        return res == 1;
    }

    pub fn read(self: *MidiStream, buffer: []Event) u32 {
        const res = Pm_Read(self, buffer.ptr, @intCast(buffer.len));

        return @intCast(if (res > 0) res else 0);
    }
};
pub const Timestamp = c_int;

pub const TimeFn = *const fn (time_info: *anyopaque) callconv(.c) Timestamp;

extern fn Pm_OpenInput(
    stream: **MidiStream,
    input_device: DeviceId,
    input_sys_dep_info: ?*anyopaque,
    buffer_size: c_int,
    time_proc: ?TimeFn,
    time_info: ?*anyopaque,
) callconv(.c) c_int;
pub fn openInput(
    stream: **MidiStream,
    input_device: DeviceId,
    buffer_size: c_int,
    time_proc: ?TimeFn,
    time_info: ?*anyopaque,
) Error!void {
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
