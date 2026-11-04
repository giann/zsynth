const std = @import("std");
const cache_line = std.atomic.cache_line;

/// We align the producer and consumer to different cache lines to avoid false
/// sharing between them. We Pad the producer and consumer to ensure that they
/// take up a full cache line each.
fn Pad(comptime N: usize, comptime T: type) type {
    const sz = @sizeOf(T);
    const rem = sz % N;
    return [if (rem == 0) 0 else N - rem]u8;
}

const Producer = struct {
    push_cursor: std.atomic.Value(usize) = .{ .raw = 0 },
    _pad: Pad(cache_line, std.atomic.Value(usize)) = undefined,
};

const Consumer = struct {
    pop_cursor: std.atomic.Value(usize) = .{ .raw = 0 },
    _pad: Pad(cache_line, std.atomic.Value(usize)) = undefined,
};

/// A single-producer, single-consumer lock-free queue using a ring buffer.
/// Following the conventions from the Zig standard library.
/// (taken from https://github.com/freref/spsc-queue)
pub fn SpscQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        len: usize,
        mask: usize,

        producer: Producer align(cache_line) = .{},
        consumer: Consumer align(cache_line) = .{},

        pop_cursor_cache: usize = 0,
        push_cursor_cache: usize = 0,

        pub fn initBuffer(buffer: []T) Self {
            std.debug.assert(std.math.isPowerOfTwo(buffer.len));
            return Self{
                .items = buffer,
                .len = buffer.len,
                .mask = buffer.len - 1,
            };
        }

        pub fn initCapacity(allocator: std.mem.Allocator, num: usize) !Self {
            std.debug.assert(std.math.isPowerOfTwo(num));
            const items = try allocator.alloc(T, num);
            return .{
                .items = items,
                .len = items.len,
                .mask = items.len - 1,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.items);
        }

        /// Returns true if the queue is empty.
        pub fn isEmpty(self: *Self) bool {
            const r = self.consumer.pop_cursor.load(.acquire);
            const w = self.producer.push_cursor.load(.acquire);
            return r == w;
        }

        pub fn size(self: *Self) usize {
            const r = self.consumer.pop_cursor.load(.acquire);
            const w = self.producer.push_cursor.load(.acquire);
            return w - r;
        }

        /// Blocking push, spins until there is room in the queue.
        pub fn push(self: *Self, value: T) void {
            const w = self.producer.push_cursor.load(.monotonic);

            // Spin while full (w - r == len)
            while ((w - self.pop_cursor_cache) == self.len) {
                self.pop_cursor_cache = self.consumer.pop_cursor.load(.acquire);
                if ((w - self.pop_cursor_cache) == self.len) {
                    std.atomic.spinLoopHint();
                }
            }

            self.items[w & self.mask] = value;
            self.producer.push_cursor.store(w + 1, .release);
        }

        /// Non-blocking push, returns false if the queue is full.
        pub fn tryPush(self: *Self, value: T) bool {
            const w = self.producer.push_cursor.load(.monotonic);

            if ((w - self.pop_cursor_cache) == self.len) {
                self.pop_cursor_cache = self.consumer.pop_cursor.load(.acquire);
                if ((w - self.pop_cursor_cache) == self.len) return false;
            }

            self.items[w & self.mask] = value;
            self.producer.push_cursor.store(w + 1, .release);
            return true;
        }

        /// Returns a pointer to the front item, or null if the queue is empty.
        pub fn front(self: *Self) ?*T {
            const r = self.consumer.pop_cursor.load(.monotonic);

            if (r == self.push_cursor_cache) {
                self.push_cursor_cache = self.producer.push_cursor.load(.acquire);
                if (self.push_cursor_cache == r) return null;
            }

            return &self.items[r & self.mask];
        }

        /// IMPORTANT: pop must only be called after front() returned non-null.
        /// The consumer is responsible for cleaning up the item if needed.
        pub fn pop(self: *Self) void {
            const r = self.consumer.pop_cursor.load(.monotonic);
            std.debug.assert(self.producer.push_cursor.load(.acquire) != r);

            self.consumer.pop_cursor.store(r + 1, .release);
        }
    };
}

/// A multiple-consumer queue whose storage is supplied by the owning object.
///
/// Readers have independent cursors. A reader claims a slot while it is using
/// it, which prevents the producer from overwriting the value concurrently.
/// Readers that fall behind the retained ring window are silently advanced to
/// the oldest still-retained value.
pub fn SpmcQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        /// One ring slot containing its value and synchronization metadata.
        pub const Slot = struct {
            value: T = undefined,
            sequence: std.atomic.Value(usize) = .{ .raw = 0 },
            readers: std.atomic.Value(usize) = .{ .raw = 0 },
        };

        /// State owned by one independent reader.
        pub const Reader = struct {
            cursor: usize = 0,
            acquired: bool = false,
        };

        /// Highest state bit reserved to exclude readers during a write.
        const writer_bit = @as(usize, 1) << (@bitSizeOf(usize) - 1);

        /// Inline ring storage supplied by the owning SampleTap.
        items: []Slot,
        /// Number of slots in the power-of-two ring.
        len: usize,
        /// Mask used to wrap absolute cursors into the ring.
        mask: usize,
        /// Absolute position immediately after the newest published value.
        push_cursor: std.atomic.Value(usize) = .{ .raw = 0 },

        /// Initializes a queue over caller-owned inline storage.
        pub fn initBuffer(buffer: []Slot) Self {
            std.debug.assert(std.math.isPowerOfTwo(buffer.len));
            std.debug.assert(buffer.len > 1);
            for (buffer) |*slot| {
                slot.sequence.store(0, .monotonic);
                slot.readers.store(0, .monotonic);
            }
            return .{
                .items = buffer,
                .len = buffer.len,
                .mask = buffer.len - 1,
            };
        }

        /// Rebinds the queue to the same logical storage after its owner moves.
        pub fn setBuffer(self: *Self, buffer: []Slot) void {
            std.debug.assert(buffer.len == self.len);
            self.items = buffer;
        }

        /// Creates a reader positioned after the values currently in the queue.
        pub fn reader(self: *const Self) Reader {
            return .{ .cursor = self.push_cursor.load(.acquire) };
        }

        /// Publishes a value without waiting for readers to finish.
        pub fn tryPush(self: *Self, value: T) bool {
            const cursor = self.push_cursor.load(.monotonic);
            const slot = &self.items[cursor & self.mask];

            // Claim the slot for writing. A reader currently copying it makes
            // this block unpublishable, so the real-time producer drops it.
            if (slot.readers.cmpxchgStrong(
                0,
                writer_bit,
                .acquire,
                .monotonic,
            ) != null)
                return false;

            slot.value = value;
            slot.sequence.store(cursor + 1, .release);
            slot.readers.store(0, .release);
            self.push_cursor.store(cursor + 1, .release);
            return true;
        }

        /// Returns the next value for a reader, or null when no value is ready.
        pub fn front(self: *Self, reader_state: *Reader) ?*const T {
            std.debug.assert(!reader_state.acquired);

            while (true) {
                const published = self.push_cursor.load(.acquire);
                const oldest = if (published > self.len) published - self.len else 0;
                if (reader_state.cursor < oldest)
                    reader_state.cursor = oldest;
                if (reader_state.cursor >= published)
                    return null;

                const cursor = reader_state.cursor;
                const slot = &self.items[cursor & self.mask];
                var readers = slot.readers.load(.acquire);
                if ((readers & writer_bit) != 0)
                    continue;

                // Claim the slot before reading its value. The producer uses
                // the writer bit to exclude this claim from an overwrite.
                while (true) {
                    if ((readers & writer_bit) != 0) break;
                    const claimed = slot.readers.cmpxchgWeak(
                        readers,
                        readers + 1,
                        .acquire,
                        .monotonic,
                    );
                    if (claimed == null) {
                        if (slot.sequence.load(.acquire) == cursor + 1) {
                            reader_state.acquired = true;
                            return &slot.value;
                        }
                        _ = slot.readers.fetchSub(1, .release);
                        break;
                    }
                    readers = claimed.?;
                }
            }
        }

        /// Releases the reader's current slot and advances its cursor.
        pub fn pop(self: *Self, reader_state: *Reader) void {
            std.debug.assert(reader_state.acquired);
            const slot = &self.items[reader_state.cursor & self.mask];
            reader_state.acquired = false;
            _ = slot.readers.fetchSub(1, .release);
            reader_state.cursor += 1;
        }
    };
}
