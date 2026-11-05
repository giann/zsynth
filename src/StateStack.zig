//! Provides the small state stack used by the ZSynth runtime.

const std = @import("std");
const Renderer = @import("Renderer.zig");
const sdl = @import("zsdl3");
const SynthEditor = @import("SynthEditor.zig");

const Self = @This();

/// States stored from bottom to top, with the top state receiving input first.
stack: std.MultiArrayList(State) = .empty,

/// Creates an empty stack with room for the initial application states.
pub fn init(gpa: std.mem.Allocator) !Self {
    return .{ .stack = try .initCapacity(gpa, 20) };
}

/// Releases the backing storage while leaving state-owned resources to `quit`.
pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    self.stack.deinit(gpa);
}

/// Returns the index of the top state, or `null` when the stack is empty.
pub fn current(self: Self) ?State.Index {
    if (self.stack.len == 0) return null;
    return .{ .idx = self.stack.len - 1 };
}

/// Reports whether `state` is currently the top state.
pub fn isCurrent(self: Self, state: State.Index) bool {
    return if (self.current()) |current_state|
        current_state.idx == state.idx
    else
        false;
}

/// Return the editor owned by the active state, including editor overlays.
pub fn synthEditor(self: *Self) ?*SynthEditor {
    const state = self.current() orelse return null;
    return switch (self.stack.items(.context)[state.idx]) {
        .synth_editor => |*editor| editor,
        .outlet_connection => |connection| connection.editor,
    };
}

/// Appends a state, enters it, and returns its stack index.
pub fn push(self: *Self, gpa: std.mem.Allocator, new_state: State) State.Error!State.Index {
    // Refuse to grow beyond the fixed capacity reserved by this stack.
    if (self.stack.len >= self.stack.capacity)
        return error.StateStackOverflow;

    // Store the context before invoking callbacks that need to access it.
    try self.stack.append(gpa, new_state);
    const index = State.Index{ .idx = self.stack.len - 1 };
    // Enter the new state after it has a stable index in the stack.
    try self.stack.items(.vtable)[index.idx].enter(self, gpa, index);
    return index;
}

/// Leaves and removes the top state, if one exists.
pub fn pop(self: *Self, gpa: std.mem.Allocator, renderer: *Renderer) State.Error!void {
    // Find the state that will be removed.
    const previous = self.current() orelse return;
    // Let the state release transient resources before removing its context.
    try self.stack.items(.vtable)[previous.idx].leave(self, gpa, renderer, previous);
    // Remove only after the leave callback succeeds.
    _ = self.stack.pop();
}

/// Quits every state from top to bottom and retains the allocated capacity.
pub fn quit(self: *Self, gpa: std.mem.Allocator, renderer: *Renderer) State.Error!void {
    // Walk downward so each state is quit before the stack is cleared.
    var index = self.stack.len;
    while (index > 0) : (index -= 1) {
        try self.stack.items(.vtable)[index - 1].quit(
            self,
            gpa,
            renderer,
            .{ .idx = index - 1 },
        );
    }
    // Keep the allocation available for a possible later start.
    self.stack.clearRetainingCapacity();
}

/// Updates every enabled state from bottom to top.
pub fn update(self: *Self, gpa: std.mem.Allocator, dt: u64) State.Error!void {
    // Cache the column slices used during the ordered traversal.
    const vtables = self.stack.items(.vtable);
    const enabled = self.stack.items(.enabled);
    // Run enabled states in layering order.
    for (vtables, enabled, 0..) |vtable, is_enabled, index| {
        if (is_enabled)
            try vtable.update(self, gpa, .{ .idx = index }, dt);
    }
}

/// Renders every enabled state from bottom to top.
pub fn render(self: *Self, gpa: std.mem.Allocator, renderer: *Renderer, dt: u64) State.Error!void {
    // Cache the columns so rendering does not repeatedly look them up.
    const vtables = self.stack.items(.vtable);
    const enabled = self.stack.items(.enabled);
    // Draw lower states first so upper states can overlay them.
    for (vtables, enabled, 0..) |vtable, is_enabled, index| {
        if (is_enabled)
            try vtable.render(self, gpa, .{ .idx = index }, renderer, dt);
    }
}

/// Sends an input event from the topmost enabled state downward.
pub fn inputEvent(self: *Self, gpa: std.mem.Allocator, event: sdl.Event) State.Error!bool {
    // Traverse in reverse so overlays and the active state get first refusal.
    var index = self.stack.len;
    while (index > 0) : (index -= 1) {
        // Disabled states do not receive input and cannot consume the event.
        if (!self.stack.items(.enabled)[index - 1]) continue;
        // Stop at the first state that reports the event as handled.
        if (try self.stack.items(.vtable)[index - 1].inputEvent(
            self,
            gpa,
            .{ .idx = index - 1 },
            event,
        )) return true;
    }
    return false;
}

/// Dispatches a keyboard event from the topmost enabled state downward.
pub fn keyUpDown(self: *Self, gpa: std.mem.Allocator, event: sdl.KeyboardEvent) State.Error!void {
    var index = self.stack.len;
    while (index > 0) : (index -= 1) {
        if (!self.stack.items(.enabled)[index - 1]) continue;
        if (try self.stack.items(.vtable)[index - 1].keyUpDown(
            self,
            gpa,
            .{ .idx = index - 1 },
            event,
        )) return;
    }
}

/// Dispatches SDL text input from the topmost enabled state downward.
pub fn textInput(self: *Self, gpa: std.mem.Allocator, event: sdl.TextInputEvent) State.Error!void {
    var index = self.stack.len;
    while (index > 0) : (index -= 1) {
        if (!self.stack.items(.enabled)[index - 1]) continue;
        if (try self.stack.items(.vtable)[index - 1].textInput(
            self,
            gpa,
            .{ .idx = index - 1 },
            event,
        )) return;
    }
}

/// Dispatches mouse motion from the topmost enabled state downward.
pub fn mouseMoved(self: *Self, gpa: std.mem.Allocator, event: sdl.MouseMotionEvent) State.Error!void {
    var index = self.stack.len;
    while (index > 0) : (index -= 1) {
        if (!self.stack.items(.enabled)[index - 1]) continue;
        if (try self.stack.items(.vtable)[index - 1].mouseMoved(
            self,
            gpa,
            .{ .idx = index - 1 },
            event,
        )) return;
    }
}

/// Dispatches a mouse-button event from the topmost enabled state downward.
pub fn mouseButton(self: *Self, gpa: std.mem.Allocator, event: sdl.MouseButtonEvent) State.Error!void {
    var index = self.stack.len;
    while (index > 0) : (index -= 1) {
        if (!self.stack.items(.enabled)[index - 1]) continue;
        if (try self.stack.items(.vtable)[index - 1].mouseButton(
            self,
            gpa,
            .{ .idx = index - 1 },
            event,
        )) return;
    }
}

/// A state context and the callbacks that operate on it.
pub const State = struct {
    /// Stable index of a state while it remains in the stack.
    pub const Index = struct {
        /// Zero-based position in the stack.
        idx: usize,
    };

    /// Errors allowed to cross the state lifecycle and input callback boundary.
    pub const Error = error{
        OutOfMemory,
        AudioError,
        SdlError,
        StateStackOverflow,
        InvalidVisualNodeIndex,
        InvalidVisualNodeLayout,
        EmptySynthPath,
        InvalidVisualGraph,
        InvalidNodeParameters,
        UnknownNodeKind,
        MissingNodeParameters,
        UnsupportedSynthSchema,
        InvalidSynthDocument,
        InvalidGraphReference,
        IoError,
    };

    /// State-owned data, selected by `ContextTag`.
    context: Context,
    /// Callback table for the context stored in `context`.
    vtable: *const VTable,
    /// Whether this state participates in update, render, and input dispatch.
    enabled: bool = true,

    /// The context variants supported by this application.
    pub const ContextTag = enum {
        /// The synth editor state.
        synth_editor,
        /// Temporary state used while connecting two DSP outlets.
        outlet_connection,
        command_palette,
    };

    /// Union containing the concrete data for a supported state.
    pub const Context = union(ContextTag) {
        /// The synth editor context.
        synth_editor: SynthEditor,
        /// The active outlet connection context.
        outlet_connection: SynthEditor.OutletConnection,
        command_palette: SynthEditor.CommandPalette,
    };

    /// Lifecycle and dispatch callbacks for a state context.
    pub const VTable = struct {
        /// Default callback for entering a state.
        fn defaultEnter(_: *Self, _: std.mem.Allocator, _: Index) Error!void {}
        /// Default callback for leaving a state.
        fn defaultLeave(_: *Self, _: std.mem.Allocator, _: *Renderer, _: Index) Error!void {}
        /// Default callback for permanently quitting a state.
        fn defaultQuit(_: *Self, _: std.mem.Allocator, _: *Renderer, _: Index) Error!void {}
        /// Default callback for updating a state.
        fn defaultUpdate(_: *Self, _: std.mem.Allocator, _: Index, _: u64) Error!void {}
        /// Default callback for rendering a state.
        fn defaultRender(_: *Self, _: std.mem.Allocator, _: Index, _: *Renderer, _: u64) Error!void {}
        /// Default callback for dispatching an input event.
        fn defaultInputEvent(_: *Self, _: std.mem.Allocator, _: Index, _: sdl.Event) Error!bool {
            return false;
        }
        fn defaultKeyUpDown(_: *Self, _: std.mem.Allocator, _: Index, _: sdl.KeyboardEvent) Error!bool {
            return false;
        }
        /// Default callback for SDL text input.
        fn defaultTextInput(_: *Self, _: std.mem.Allocator, _: Index, _: sdl.TextInputEvent) Error!bool {
            return false;
        }
        fn defaultMouseMoved(_: *Self, _: std.mem.Allocator, _: Index, _: sdl.MouseMotionEvent) Error!bool {
            return false;
        }
        fn defaultMouseButton(_: *Self, _: std.mem.Allocator, _: Index, _: sdl.MouseButtonEvent) Error!bool {
            return false;
        }

        /// Called when the state enters the stack.
        enter: *const fn (*Self, std.mem.Allocator, Index) Error!void = defaultEnter,
        /// Called when the state is temporarily popped.
        leave: *const fn (*Self, std.mem.Allocator, *Renderer, Index) Error!void = defaultLeave,
        /// Called when the state stack is shutting down.
        quit: *const fn (*Self, std.mem.Allocator, *Renderer, Index) Error!void = defaultQuit,
        /// Called once per frame before rendering.
        update: *const fn (*Self, std.mem.Allocator, Index, u64) Error!void = defaultUpdate,
        /// Called once per frame to enqueue rendering work.
        render: *const fn (*Self, std.mem.Allocator, Index, *Renderer, u64) Error!void = defaultRender,
        /// Called for input events from the topmost state downward.
        inputEvent: *const fn (*Self, std.mem.Allocator, Index, sdl.Event) Error!bool = defaultInputEvent,
        /// Called for key-down and key-up events that were not consumed raw.
        keyUpDown: *const fn (*Self, std.mem.Allocator, Index, sdl.KeyboardEvent) Error!bool = defaultKeyUpDown,
        /// Called for SDL text-input events that were not consumed raw.
        textInput: *const fn (*Self, std.mem.Allocator, Index, sdl.TextInputEvent) Error!bool = defaultTextInput,
        /// Called for mouse-motion events that were not consumed raw.
        mouseMoved: *const fn (*Self, std.mem.Allocator, Index, sdl.MouseMotionEvent) Error!bool = defaultMouseMoved,
        /// Called for mouse-button events that were not consumed raw.
        mouseButton: *const fn (*Self, std.mem.Allocator, Index, sdl.MouseButtonEvent) Error!bool = defaultMouseButton,
    };
};
