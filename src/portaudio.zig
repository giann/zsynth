//! Small, Zig-oriented bindings for PortAudio's device and stream APIs.
const std = @import("std");

/// Errors returned by PortAudio operations exposed by this module.
pub const Error = error{
    NotInitialized,
    UnanticipatedHostError,
    InvalidChannelCount,
    InvalidSampleRate,
    InvalidDevice,
    InvalidFlag,
    SampleFormatNotSupported,
    BadIODeviceCombination,
    InsufficientMemory,
    BufferTooBig,
    BufferTooSmall,
    NullCallback,
    BadStream,
    TimedOut,
    InternalError,
    DeviceUnavailable,
    IncompatibleHostApiStreamInfo,
    StreamStopped,
    StreamNotStopped,
    InputOverflowed,
    OutputUnderflowed,
    HostApiNotFound,
    InvalidHostApi,
    CannotReadFromCallbackStream,
    CannotWriteToCallbackStream,
    CannotReadFromOutputOnlyStream,
    CannotWriteToInputOnlyStream,
    IncompatibleStreamHostApi,
    BadBufferPointer,
    CannotInitializeRecursively,
};

/// Runtime index used to identify a PortAudio device.
pub const DeviceId = c_int;

/// Sentinel used when no PortAudio device is selected or available.
pub const no_device: DeviceId = -1;

/// Stereo output device collected during PortAudio initialization.
pub const Device = struct {
    /// PortAudio index used to open a stream during this process.
    id: DeviceId,
    /// Host API name copied for display and document identity.
    host_api_name: []u8,
    /// Device name copied for display and document identity.
    name: []u8,
    /// Disambiguated completion label shown in the selected-node editor.
    label: []u8,
    /// Suggested low latency reported by the device.
    low_output_latency: f64,
};

/// Mono or stereo input device that supports the requested sample rate.
pub const InputDevice = struct {
    /// PortAudio index used to open a stream during this process.
    id: DeviceId,
    /// Host API name copied for display and document identity.
    host_api_name: []u8,
    /// Device name copied for display and document identity.
    name: []u8,
    /// Disambiguated completion label shown in the selected-node editor.
    label: []u8,
    /// Number of channels the application will request from this device.
    channel_count: c_int,
    /// Suggested low latency reported by the device.
    low_input_latency: f64,
};

/// Opaque PortAudio stream handle.
pub const Stream = opaque {};

/// Time information supplied to an output callback.
pub const StreamCallbackTimeInfo = extern struct {
    /// Time when the first input sample was captured, if any.
    input_buffer_adc_time: f64,
    /// Current callback invocation time.
    current_time: f64,
    /// Time when the first output sample is expected to be presented.
    output_buffer_dac_time: f64,
};

/// Callback signature used to process interleaved PortAudio stream buffers.
pub const StreamCallback = *const fn (
    ?*const anyopaque,
    ?*anyopaque,
    c_ulong,
    ?*const StreamCallbackTimeInfo,
    c_ulong,
    ?*anyopaque,
) callconv(.c) c_int;

/// PortAudio status values returned by the wrapped C functions.
const PaErrorCode = enum(c_int) {
    not_initialized = -10000,
    unanticipated_host_error = -9999,
    invalid_channel_count = -9998,
    invalid_sample_rate = -9997,
    invalid_device = -9996,
    invalid_flag = -9995,
    sample_format_not_supported = -9994,
    bad_io_device_combination = -9993,
    insufficient_memory = -9992,
    buffer_too_big = -9991,
    buffer_too_small = -9990,
    null_callback = -9989,
    bad_stream = -9988,
    timed_out = -9987,
    internal_error = -9986,
    device_unavailable = -9985,
    incompatible_host_api_stream_info = -9984,
    stream_stopped = -9983,
    stream_not_stopped = -9982,
    input_overflowed = -9981,
    output_underflowed = -9980,
    host_api_not_found = -9979,
    invalid_host_api = -9978,
    cannot_read_from_callback_stream = -9977,
    cannot_write_to_callback_stream = -9976,
    cannot_read_from_output_only_stream = -9975,
    cannot_write_to_input_only_stream = -9974,
    incompatible_stream_host_api = -9973,
    bad_buffer_pointer = -9972,
    cannot_initialize_recursively = -9971,
};

/// C layout for PortAudio's immutable device descriptor.
const PaDeviceInfo = extern struct {
    struct_version: c_int,
    name: ?[*:0]const u8,
    host_api: c_int,
    max_input_channels: c_int,
    max_output_channels: c_int,
    default_low_input_latency: f64,
    default_low_output_latency: f64,
    default_high_input_latency: f64,
    default_high_output_latency: f64,
    default_sample_rate: f64,
};

/// C layout for PortAudio's immutable host API descriptor.
const PaHostApiInfo = extern struct {
    struct_version: c_int,
    type: c_int,
    name: ?[*:0]const u8,
    device_count: c_int,
    default_input_device: DeviceId,
    default_output_device: DeviceId,
};

/// C layout describing an output stream's device and sample format.
const StreamParameters = extern struct {
    device: DeviceId,
    channel_count: c_int,
    sample_format: c_ulong,
    suggested_latency: f64,
    host_api_specific_stream_info: ?*anyopaque,
};

/// Initializes PortAudio before device enumeration or stream operations.
extern fn Pa_Initialize() callconv(.c) c_int;
/// Releases resources acquired by a successful PortAudio initialization.
extern fn Pa_Terminate() callconv(.c) c_int;
/// Returns the number of currently available devices.
extern fn Pa_GetDeviceCount() callconv(.c) c_int;
/// Returns the current system default output device, or `no_device`.
extern fn Pa_GetDefaultOutputDevice() callconv(.c) DeviceId;
/// Returns the current system default input device, or `no_device`.
extern fn Pa_GetDefaultInputDevice() callconv(.c) DeviceId;
/// Returns information for an enumerated device, or null for an invalid index.
extern fn Pa_GetDeviceInfo(device: DeviceId) callconv(.c) ?*const PaDeviceInfo;
/// Returns information for an enumerated host API, or null for an invalid index.
extern fn Pa_GetHostApiInfo(host_api: c_int) callconv(.c) ?*const PaHostApiInfo;
/// Checks whether the requested output format is supported by the device.
extern fn Pa_IsFormatSupported(
    input_parameters: ?*const StreamParameters,
    output_parameters: ?*const StreamParameters,
    sample_rate: f64,
) callconv(.c) c_int;
/// Opens an output stream with the requested callback and format.
extern fn Pa_OpenStream(
    stream: **Stream,
    input_parameters: ?*const StreamParameters,
    output_parameters: ?*const StreamParameters,
    sample_rate: f64,
    frames_per_buffer: c_ulong,
    stream_flags: c_ulong,
    callback: StreamCallback,
    user_data: ?*anyopaque,
) callconv(.c) c_int;
/// Starts an opened stream.
extern fn Pa_StartStream(stream: *Stream) callconv(.c) c_int;
/// Stops an active stream after pending output has drained.
extern fn Pa_StopStream(stream: *Stream) callconv(.c) c_int;
/// Closes a stream and releases its device resources.
extern fn Pa_CloseStream(stream: *Stream) callconv(.c) c_int;
/// Reports whether a stream is currently active.
extern fn Pa_IsStreamActive(stream: *Stream) callconv(.c) c_int;

/// Initializes PortAudio before device enumeration or stream operations.
pub fn init() Error!void {
    try checkError(Pa_Initialize());
}

/// Terminates PortAudio after all application streams and devices are released.
pub fn deinit() Error!void {
    try checkError(Pa_Terminate());
}

/// Returns the default device if it was included in the supported-device list.
pub fn defaultDevice(devices: []const Device) ?DeviceId {
    const id = Pa_GetDefaultOutputDevice();
    if (id < 0) return null;
    for (devices) |device| {
        if (device.id == id) return id;
    }
    return null;
}

/// Returns the supported stereo 48 kHz outputs and owns their copied names.
pub fn enumerateOutputDevices(
    allocator: std.mem.Allocator,
    sample_rate: f64,
) (Error || std.mem.Allocator.Error)![]Device {
    const device_count = Pa_GetDeviceCount();
    if (device_count < 0) return errorFromCode(device_count);

    var devices: std.ArrayList(Device) = .empty;
    errdefer deinitDevices(allocator, devices.items);

    for (0..@intCast(device_count)) |index| {
        const id: DeviceId = @intCast(index);
        const info = Pa_GetDeviceInfo(id) orelse continue;
        if (info.max_output_channels < 2) continue;

        const host_info = Pa_GetHostApiInfo(info.host_api) orelse continue;
        const name_ptr = info.name orelse continue;
        const host_name_ptr = host_info.name orelse continue;
        const parameters = StreamParameters{
            .device = id,
            .channel_count = 2,
            .sample_format = 1,
            .suggested_latency = info.default_low_output_latency,
            .host_api_specific_stream_info = null,
        };
        if (Pa_IsFormatSupported(null, &parameters, sample_rate) != 0)
            continue;

        const name = try allocator.dupe(u8, std.mem.span(name_ptr));
        errdefer allocator.free(name);
        const host_name = try allocator.dupe(u8, std.mem.span(host_name_ptr));
        errdefer allocator.free(host_name);
        const label = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ host_name, name });
        errdefer allocator.free(label);

        try devices.append(allocator, .{
            .id = id,
            .host_api_name = host_name,
            .name = name,
            .label = label,
            .low_output_latency = info.default_low_output_latency,
        });
    }

    return try devices.toOwnedSlice(allocator);
}

/// Returns mono or stereo input devices that support the requested sample rate.
pub fn enumerateInputDevices(
    allocator: std.mem.Allocator,
    sample_rate: f64,
) (Error || std.mem.Allocator.Error)![]InputDevice {
    const device_count = Pa_GetDeviceCount();
    if (device_count < 0) return errorFromCode(device_count);

    var devices: std.ArrayList(InputDevice) = .empty;

    for (0..@intCast(device_count)) |index| {
        const id: DeviceId = @intCast(index);
        const info = Pa_GetDeviceInfo(id) orelse continue;
        if (info.max_input_channels < 1) continue;

        var channel_count: c_int = if (info.max_input_channels >= 2) 2 else 1;
        var parameters = StreamParameters{
            .device = id,
            .channel_count = channel_count,
            .sample_format = 1,
            .suggested_latency = info.default_low_input_latency,
            .host_api_specific_stream_info = null,
        };
        if (Pa_IsFormatSupported(&parameters, null, sample_rate) != 0) {
            if (channel_count == 1) continue;
            channel_count = 1;
            parameters.channel_count = channel_count;
            if (Pa_IsFormatSupported(&parameters, null, sample_rate) != 0)
                continue;
        }

        const host_info = Pa_GetHostApiInfo(info.host_api) orelse continue;
        const name_ptr = info.name orelse continue;
        const host_name_ptr = host_info.name orelse continue;
        appendInputDevice(
            allocator,
            &devices,
            id,
            std.mem.span(host_name_ptr),
            std.mem.span(name_ptr),
            channel_count,
            info.default_low_input_latency,
        ) catch |err| {
            deinitInputDeviceNames(allocator, devices.items);
            devices.deinit(allocator);
            return err;
        };
    }

    return devices.toOwnedSlice(allocator) catch |err| {
        deinitInputDeviceNames(allocator, devices.items);
        devices.deinit(allocator);
        return err;
    };
}

/// Copies one supported input device into the owned enumeration list.
fn appendInputDevice(
    allocator: std.mem.Allocator,
    devices: *std.ArrayList(InputDevice),
    id: DeviceId,
    host_api_name: []const u8,
    name: []const u8,
    channel_count: c_int,
    low_input_latency: f64,
) std.mem.Allocator.Error!void {
    const owned_name = allocator.dupe(u8, name) catch |err| return err;
    const owned_host_name = allocator.dupe(u8, host_api_name) catch |err| {
        allocator.free(owned_name);
        return err;
    };
    const label = std.fmt.allocPrint(allocator, "{s}: {s}", .{ owned_host_name, owned_name }) catch |err| {
        allocator.free(owned_host_name);
        allocator.free(owned_name);
        return err;
    };
    devices.append(allocator, .{
        .id = id,
        .host_api_name = owned_host_name,
        .name = owned_name,
        .label = label,
        .channel_count = channel_count,
        .low_input_latency = low_input_latency,
    }) catch |err| {
        allocator.free(label);
        allocator.free(owned_host_name);
        allocator.free(owned_name);
        return err;
    };
}

/// Frees copied strings without freeing the ArrayList's own item storage.
fn deinitInputDeviceNames(allocator: std.mem.Allocator, devices: []InputDevice) void {
    for (devices) |device| {
        allocator.free(device.host_api_name);
        allocator.free(device.name);
        allocator.free(device.label);
    }
}

/// Frees copied device names produced by `enumerateOutputDevices`.
pub fn deinitDevices(allocator: std.mem.Allocator, devices: []Device) void {
    for (devices) |device| {
        allocator.free(device.host_api_name);
        allocator.free(device.name);
        allocator.free(device.label);
    }
    allocator.free(devices);
}

/// Frees copied device names produced by `enumerateInputDevices`.
pub fn deinitInputDevices(allocator: std.mem.Allocator, devices: []InputDevice) void {
    deinitInputDeviceNames(allocator, devices);
    allocator.free(devices);
}

/// Returns the system default input if supported, or the first supported input.
pub fn defaultInputDevice(devices: []const InputDevice) ?DeviceId {
    const id = Pa_GetDefaultInputDevice();
    if (id >= 0) {
        for (devices) |device|
            if (device.id == id)
                return id;
    }
    return if (devices.len == 0) null else devices[0].id;
}

/// Finds the runtime device ID matching a persisted host API and device name.
pub fn findDevice(
    devices: []const Device,
    host_api_name: []const u8,
    name: []const u8,
) ?DeviceId {
    for (devices) |device| {
        if (std.mem.eql(u8, device.host_api_name, host_api_name) and
            std.mem.eql(u8, device.name, name))
            return device.id;
    }
    return null;
}

/// Returns the descriptor for a current runtime device ID.
pub fn deviceById(devices: []const Device, id: DeviceId) ?*const Device {
    for (devices) |*device| {
        if (device.id == id) return device;
    }
    return null;
}

/// Returns the descriptor for a current runtime input device ID.
pub fn inputDeviceById(devices: []const InputDevice, id: DeviceId) ?*const InputDevice {
    for (devices) |*device| {
        if (device.id == id) return device;
    }
    return null;
}

/// Finds the runtime input ID matching a persisted host API and device name.
pub fn findInputDevice(
    devices: []const InputDevice,
    host_api_name: []const u8,
    name: []const u8,
) ?DeviceId {
    for (devices) |device| {
        if (std.mem.eql(u8, device.host_api_name, host_api_name) and
            std.mem.eql(u8, device.name, name))
            return device.id;
    }
    return null;
}

/// Opens a stopped float32 stereo output stream using PortAudio's variable block size.
pub fn openOutputStream(
    device: *const Device,
    sample_rate: f64,
    callback: StreamCallback,
    user_data: ?*anyopaque,
) Error!*Stream {
    const parameters = StreamParameters{
        .device = device.id,
        .channel_count = 2,
        .sample_format = 1,
        .suggested_latency = device.low_output_latency,
        .host_api_specific_stream_info = null,
    };
    var stream: *Stream = undefined;
    try checkError(Pa_OpenStream(
        &stream,
        null,
        &parameters,
        sample_rate,
        0,
        0,
        callback,
        user_data,
    ));
    return stream;
}

/// Opens a stopped float32 input stream using PortAudio's variable block size.
pub fn openInputStream(
    device: *const InputDevice,
    sample_rate: f64,
    callback: StreamCallback,
    user_data: ?*anyopaque,
) Error!*Stream {
    const parameters = StreamParameters{
        .device = device.id,
        .channel_count = device.channel_count,
        .sample_format = 1,
        .suggested_latency = device.low_input_latency,
        .host_api_specific_stream_info = null,
    };
    var stream: *Stream = undefined;
    try checkError(Pa_OpenStream(
        &stream,
        &parameters,
        null,
        sample_rate,
        0,
        0,
        callback,
        user_data,
    ));
    return stream;
}

/// Starts a stream previously returned by `openOutputStream`.
pub fn startStream(stream: *Stream) Error!void {
    try checkError(Pa_StartStream(stream));
}

/// Stops a running stream and waits for the callback to finish.
pub fn stopStream(stream: *Stream) Error!void {
    try checkError(Pa_StopStream(stream));
}

/// Closes a stream previously returned by `openOutputStream`.
pub fn closeStream(stream: *Stream) Error!void {
    try checkError(Pa_CloseStream(stream));
}

/// Reports whether a stream is currently active.
pub fn isStreamActive(stream: *Stream) Error!bool {
    const active = Pa_IsStreamActive(stream);
    if (active < 0) return errorFromCode(active);
    return active == 1;
}

/// Converts a negative PortAudio status into a Zig error value.
fn checkError(code: c_int) Error!void {
    if (code < 0) return errorFromCode(code);
}

/// Maps a PortAudio error code to the matching Zig error.
fn errorFromCode(code: c_int) Error {
    return switch (@as(PaErrorCode, @fromBackingInt(@intCast(code)))) {
        .not_initialized => error.NotInitialized,
        .unanticipated_host_error => error.UnanticipatedHostError,
        .invalid_channel_count => error.InvalidChannelCount,
        .invalid_sample_rate => error.InvalidSampleRate,
        .invalid_device => error.InvalidDevice,
        .invalid_flag => error.InvalidFlag,
        .sample_format_not_supported => error.SampleFormatNotSupported,
        .bad_io_device_combination => error.BadIODeviceCombination,
        .insufficient_memory => error.InsufficientMemory,
        .buffer_too_big => error.BufferTooBig,
        .buffer_too_small => error.BufferTooSmall,
        .null_callback => error.NullCallback,
        .bad_stream => error.BadStream,
        .timed_out => error.TimedOut,
        .internal_error => error.InternalError,
        .device_unavailable => error.DeviceUnavailable,
        .incompatible_host_api_stream_info => error.IncompatibleHostApiStreamInfo,
        .stream_stopped => error.StreamStopped,
        .stream_not_stopped => error.StreamNotStopped,
        .input_overflowed => error.InputOverflowed,
        .output_underflowed => error.OutputUnderflowed,
        .host_api_not_found => error.HostApiNotFound,
        .invalid_host_api => error.InvalidHostApi,
        .cannot_read_from_callback_stream => error.CannotReadFromCallbackStream,
        .cannot_write_to_callback_stream => error.CannotWriteToCallbackStream,
        .cannot_read_from_output_only_stream => error.CannotReadFromOutputOnlyStream,
        .cannot_write_to_input_only_stream => error.CannotWriteToInputOnlyStream,
        .incompatible_stream_host_api => error.IncompatibleStreamHostApi,
        .bad_buffer_pointer => error.BadBufferPointer,
        .cannot_initialize_recursively => error.CannotInitializeRecursively,
    };
}
