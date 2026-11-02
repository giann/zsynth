//! Various pool data structures
const std = @import("std");
const ZPool = @import("zpool").Pool;

/// Give a new enum type where each case is a power of 2 size from `start_kib` to `max_kib`.
pub fn BucketSize(comptime start_kib: comptime_int, comptime max_kib: comptime_int) type {
    comptime {
        if (start_kib <= 0) {
            @compileError("BucketSize: start_kib must be greater than zero");
        }
        if (max_kib < start_kib) {
            @compileError("BucketSize: max_kib must be >= start_kib");
        }
        if ((start_kib & (start_kib - 1)) != 0) {
            @compileError("BucketSize: start_kib must be a power of two");
        }
        if ((max_kib & (max_kib - 1)) != 0) {
            @compileError("BucketSize: max_kib must be a power of two");
        }
    }

    const start: u64 = @intCast(start_kib);
    const max: u64 = @intCast(max_kib);
    const count = std.math.log2_int(u64, max) - std.math.log2_int(u64, start) + 1;
    const Tag = std.math.IntFittingRange(0, max_kib);

    var names: [count][]const u8 = undefined;
    var vals: [count]Tag = undefined;

    inline for (0..count) |i| {
        const kib: Tag = @intCast(start << @intCast(i));

        names[i] = if (kib < 1024)
            std.fmt.comptimePrint("kb{}", .{kib})
        else
            std.fmt.comptimePrint("mb{}", .{kib / 1024});

        vals[i] = kib;
    }

    return @Enum(
        Tag,
        .exhaustive,
        &names,
        &vals,
    );
}

/// Return the smallest bucket that can contain `size`.
fn getBucketSize(comptime Size: type, size_bytes: usize) Size {
    inline for (std.enums.values(Size)) |bucket| {
        const capacity_bytes =
            @as(usize, @backingInt(bucket)) * 1024;

        if (size_bytes <= capacity_bytes) {
            return bucket;
        }
    }

    @panic("size exceeds the largest bucket");
}

/// Keeps track of reusable resources within the pool
pub fn PoolOfReusables(
    comptime index_bits: u8,
    comptime cycle_bits: u8,
    comptime Resource: type,
    comptime Columns: type,
) type {
    return struct {
        const Self = @This();
        pub const Pool = ZPool(index_bits, cycle_bits, Resource, Columns);
        pub const Handle = struct {
            owner: *Self,
            pool: *Pool,
            handle: Pool.Handle,

            pub fn getColumns(self: @This()) Columns {
                return self.pool.getColumns(self.handle) catch @panic("Invalid handle");
            }

            pub fn release(self: @This(), gpa: std.mem.Allocator) !void {
                try self.owner.release(gpa, self);
            }
        };

        pool: Pool,
        reusables: std.ArrayList(Handle) = .empty,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{
                // zpool.Pool.init() computes typed column pointers before its
                // zero-capacity storage has a backing allocation. The
                // resulting undefined pointer can fail @alignCast on Linux.
                // Start with one slot so all cached pointers refer to valid,
                // correctly aligned storage.
                .pool = Pool.initCapacity(gpa, 1) catch @panic("failed to initialize pool"),
            };
        }

        /// Returns already reusable handle of the resource.
        pub fn getAvailable(self: *Self) ?Handle {
            while (self.reusables.pop()) |reusable| {
                if (self.pool.isLiveHandle(reusable.handle)) {
                    return reusable;
                }
            }

            return null;
        }

        pub fn hasAvailable(self: *Self) bool {
            // Pop avaialable handles that are not live handles
            while (self.reusables.items.len > 0 and
                !self.pool.isLiveHandle(self.reusables.items[self.reusables.items.len - 1].handle))
            {
                _ = self.reusables.pop();
            }

            return self.reusables.items.len > 0;
        }

        /// Add a new item to the pool, considered unavailable right away
        pub fn add(self: *Self, item: Columns) !Handle {
            std.debug.assert(!self.hasAvailable());
            return .{
                .owner = self,
                .pool = &self.pool,
                .handle = try self.pool.add(item),
            };
        }

        /// Mark pool item as available
        pub fn release(self: *Self, gpa: std.mem.Allocator, handle: Handle) !void {
            if (handle.pool.isLiveHandle(handle.handle)) {
                try self.reusables.append(gpa, handle);
            }
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.reusables.deinit(gpa);
            self.pool.deinit();
        }
    };
}

/// Keeps pools of a resource associated with a BucketSize
pub fn BucketedPool(
    comptime start_kib: comptime_int,
    comptime max_kib: comptime_int,
    comptime index_bits: u8,
    comptime cycle_bits: u8,
    comptime Resource: type,
    comptime Columns: type,
) type {
    return struct {
        const Self = @This();

        pub const Size = BucketSize(start_kib, max_kib);
        pub const Pool = PoolOfReusables(
            index_bits,
            cycle_bits,
            Resource,
            Columns,
        );

        buckets: std.EnumArray(Size, Pool),

        pub fn init(gpa: std.mem.Allocator) Self {
            var self = Self{
                .buckets = .initUndefined(),
            };

            inline for (std.enums.values(Size)) |size|
                self.buckets.set(size, .init(gpa));

            return self;
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            inline for (std.enums.values(Size)) |size|
                self.buckets.getPtr(size).deinit(gpa);
        }
    };
}

pub fn MapPool(
    comptime Key: type,
    comptime index_bits: u8,
    comptime cycle_bits: u8,
    comptime Resource: type,
    comptime Columns: type,
) type {
    return struct {
        const Self = @This();

        pub const Pool = PoolOfReusables(
            index_bits,
            cycle_bits,
            Resource,
            Columns,
        );

        pub const empty = Self{};

        map: std.AutoHashMapUnmanaged(Key, Pool) = .empty,

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            var it = self.map.valueIterator();
            while (it.next()) |pool|
                pool.deinit(gpa);

            self.map.deinit(gpa);
        }

        pub fn bucketSizeFor(size_bytes: usize) Pool.Size {
            return getBucketSize(Pool.Size, size_bytes);
        }

        pub fn getAvailable(self: *Self, key: Key) ?Pool.Handle {
            if (self.map.getPtr(key)) |pool| {
                if (pool.getAvailable()) |available| {
                    return available;
                }
            }

            return null;
        }

        pub fn hasAvailable(self: *Self, key: Key) bool {
            if (self.map.getPtr(key)) |pool| {
                return pool.hasAvailable();
            }

            return false;
        }

        pub fn add(self: *Self, key: Key, item: Columns, gpa: std.mem.Allocator) !Pool.Handle {
            const slot = try self.map.getOrPut(gpa, key);

            if (!slot.found_existing) {
                slot.value_ptr.* = .init(gpa);
            }

            const handle = try slot.value_ptr.add(item);

            return handle;
        }
    };
}

pub fn MapBucketedPool(
    comptime Key: type,
    comptime start_kib: comptime_int,
    comptime max_kib: comptime_int,
    comptime index_bits: u8,
    comptime cycle_bits: u8,
    comptime Resource: type,
    comptime Columns: type,
) type {
    return struct {
        const Self = @This();

        pub const Pool = BucketedPool(
            start_kib,
            max_kib,
            index_bits,
            cycle_bits,
            Resource,
            Columns,
        );

        pub const Handle = struct {
            owner: *Pool.Pool,
            handle: Pool.Pool.Handle,

            pub fn getColumns(self: @This()) Columns {
                return self.handle.getColumns();
            }

            pub fn release(self: @This(), gpa: std.mem.Allocator) !void {
                try self.owner.release(gpa, self.handle);
            }
        };

        pub const empty = Self{};

        map: std.AutoHashMapUnmanaged(Key, Pool) = .empty,

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            var it = self.map.valueIterator();
            while (it.next()) |pool|
                pool.deinit(gpa);

            self.map.deinit(gpa);
        }

        pub fn bucketSizeFor(size_bytes: usize) Pool.Size {
            return getBucketSize(Pool.Size, size_bytes);
        }

        pub fn getAvailable(self: *Self, key: Key, size: Pool.Size) ?Handle {
            if (self.map.getPtr(key)) |pool| {
                const bucket = pool.buckets.getPtr(size);
                if (bucket.getAvailable()) |available| {
                    return .{
                        .owner = bucket,
                        .handle = available,
                    };
                }
            }

            return null;
        }

        pub fn hasAvailable(self: *Self, key: Key, size: Pool.Size) bool {
            if (self.map.getPtr(key)) |pool| {
                if (pool.buckets.get(size)) |bucket| {
                    return bucket.hasAvailable();
                }
            }

            return false;
        }

        pub fn add(self: *Self, key: Key, size: Pool.Size, item: Columns, gpa: std.mem.Allocator) !Handle {
            const slot = try self.map.getOrPut(gpa, key);

            if (!slot.found_existing) {
                slot.value_ptr.* = .init(gpa);
            }

            const bucket = slot.value_ptr.buckets.getPtr(size);
            const handle = try bucket.add(item);

            return .{
                .owner = bucket,
                .handle = handle,
            };
        }
    };
}
