const zap = @import("../zap.zig");
const Lock = zap.runtime.Lock;
const nanotime = zap.runtime.Clock.nanotime;

const Bucket = struct {
    lock: Lock = Lock{},
    queue: Queue = Queue{},

    var array = [_]Bucket{Bucket{}} ** 256;

    fn get(address: usize) *Bucket {
        const seed = @truncate(usize, 0x9E3779B97F4A7C15);
        const max = @popCount(usize, ~@as(usize, 0));
        const bits = @ctz(usize, array.len);
        const index = (address *% seed) >> (max - bits);
        return &array[index];
    }
};

// TODO: use red-black tree instead of linear-scan per address in bucket
const Queue = struct {
    root: usize = (Root{ .empty = {} }).pack(),

    const Root = union(enum) {
        empty: void,
        prng: u16,
        waiter: *Waiter,

        fn pack(self: Root) usize {
            return switch (self) {
                .empty => 0,
                .prng => |prng| (@as(usize, prng) << 1) | 1,
                .waiter => |waiter| @ptrToInt(waiter),
            };
        }

        fn unpack(value: usize) Root {
            return switch (@truncate(u1, value)) {
                1 => Root{ .prng = @truncate(u16, value >> 1) },
                0 => switch (value) {
                    0 => .empty,
                    else => Root{ .waiter = @intToPtr(*Waiter, value), },
                },
            };
        }
    };

    fn setRoot(self: *Queue, waiter: ?*Waiter) void {
        var root_waiter: ?*Waiter = null;
        const prng = switch (Root.unpack(self.root)) {
            .empty => @truncate(u16, @ptrToInt(self) >> @alignOf(Waiter)) | 1,
            .prng => |prng| prng,
            .waiter => |w| blk: {
                root_waiter = w;
                break :blk w.prng;
            },
        };

        const pending_waiter = waiter orelse {
            self.root = (Root{ .prng = prng }).pack();
            return;
        };

        pending_waiter.prng = prng;
        pending_waiter.times_out = if (root_waiter) |w| w.times_out else 0;
        self.root = (Root{ .waiter = pending_waiter }).pack();
    }

    fn shouldBeFair(self: *Queue) bool {
        const root_waiter = switch (Root.unpack(self.root)) {
            .empty, .prng => return false,
            .waiter => |waiter| waiter,
        };

        const now = nanotime();
        if (now < root_waiter.times_out)
            return false;
        
        const rand = blk: {
            var x = root_waiter.prng;
            var rand: [2]u16 = undefined;
            for (rand) |*r| { 
                x ^= x << 7;
                x ^= x >> 9;
                x ^= x << 8;
                r.* = x;
            }
            root_waiter.prng = x;
            break :blk @bitCast(u32, rand);
        };

        const timeout = rand % 1_000_000;
        root_waiter.times_out = now + timeout;
        return true;
    }

    fn find(self: *Queue, address: usize, tail: ?*?*Waiter) ?*Waiter {
        var waiter = switch (Root.unpack(self.root)) {
            .empty, .prng => null,
            .waiter => |waiter| waiter,
        };

        if (tail) |t|
            t.* = waiter;

        while (true) {
            const pending_waiter = waiter orelse return null;
            if (pending_waiter.address == address)
                return pending_waiter;

            waiter = pending_waiter.root_next;
            if (tail) |t|
                t.* = pending_waiter;
        }
    }

    fn insert(self: *Queue, address: usize, waiter: *Waiter) void {
        waiter.next = null;
        waiter.tail = waiter;
        waiter.address = address;
        waiter.root_next = null;

        if (self.find(address, &waiter.root_prev)) |head| {
            const tail = head.tail orelse unreachable;
            tail.next = waiter;
            waiter.prev = tail;
            head.tail = waiter;
            return;
        }

        waiter.prev = null;
        if (waiter.root_prev) |root_prev| {
            root_prev.root_next = waiter;
        } else {
            self.setRoot(waiter);
        }
    }

    fn iter(self: *Queue, address: usize) Iter {
        const head = self.find(address, null);

        return Iter{
            .head = head,
            .waiter = head,
            .address = address,
            .queue = self,
        };
    }

    const Iter = struct {
        head: ?*Waiter,
        waiter: ?*Waiter,
        address: usize,
        queue: *Queue,

        fn next(self: *Iter) ?*Waiter {
            const waiter = self.waiter orelse return null;
            self.waiter = waiter.next;
            return waiter;
        }

        fn isEmpty(self: Iter) bool {
            return self.head == null;
        }

        fn remove(self: *Iter, waiter: *Waiter) bool {
            const head = self.head orelse return false;
            if (waiter.tail == null or waiter.address != self.address)
                return false;

            if (waiter.prev) |qprev|
                qprev.next = waiter.next;
            if (waiter.next) |qnext|
                qnext.prev = waiter.prev;
            if (self.waiter == waiter)
                self.waiter = waiter.next;

            if (head == waiter) {
                self.head = waiter.next;
                if (self.head) |new_head| {
                    new_head.tail = waiter.tail;
                    new_head.prng = waiter.prng;
                    new_head.times_out = waiter.times_out;
                    new_head.root_next = waiter.root_next;
                    new_head.root_prev = waiter.root_prev;
                }
            } else if (head.tail == waiter) {
                head.tail = waiter.prev;
            }

            if (self.head == null) {
                if (waiter.root_prev) |root_prev|
                    root_prev.root_next = waiter.root_next;
                if (waiter.root_next) |root_next|
                    root_next.root_prev = waiter.root_prev;
                if (waiter.root_prev == null)
                    self.queue.setRoot(null);
            } else if (self.head != head) {
                if (waiter.root_prev) |root_prev|
                    root_prev.root_next = self.head;
                if (waiter.root_next) |root_next|
                    root_next.root_prev = self.head;
                if (waiter.root_prev == null)
                    self.queue.setRoot(self.head);
            }

            waiter.tail = null;
            return true;
        }
    };
};

const Waiter = struct {
    root_prev: ?*Waiter,
    root_next: ?*Waiter,
    prev: ?*Waiter,
    next: ?*Waiter,
    tail: ?*Waiter,
    token: usize,
    address: usize,
    prng: u16,
    times_out: u64,
    wakeFn: fn(*Waiter) void,

    fn wake(self: *Waiter) void {
        return (self.wakeFn)(self);
    }
};

pub const ParkResult = union(enum){
    unparked: usize,
    timed_out: void,
    invalidated: void,
};

pub fn parkConditionally(
    comptime Event: type,
    address: usize,
    deadline: ?u64,
    context: anytype,
) ParkResult {
    var bucket = Bucket.get(address);
    bucket.lock.acquire();

    const token: usize = context.onValidate() orelse {
        bucket.lock.release();
        return .invalidated;
    };
    
    const Context = @TypeOf(context);
    const EventWaiter = struct {
        event: Event,
        waiter: Waiter,
        bucket_ref: *Bucket,
        context_ref: ?Context,

        pub fn wait(self: *@This()) bool {
            self.bucket_ref.lock.release();
            if (self.context_ref) |ctx|
                ctx.onBeforeWait();
            return true;
        }

        pub fn wake(waiter: *Waiter) void {
            const self = @fieldParentPtr(@This(), "waiter", waiter);
            self.event.notify();
        }
    };

    var event_waiter: EventWaiter = undefined;
    event_waiter.bucket_ref = bucket;
    event_waiter.waiter.wakeFn = EventWaiter.wake;
    event_waiter.event.init();
    defer event_waiter.event.deinit();

    event_waiter.waiter.token = token;
    bucket.queue.insert(address, &event_waiter.waiter);

    event_waiter.context_ref = context;
    if (event_waiter.event.wait(deadline, &event_waiter))
        return .{ .unparked = event_waiter.waiter.token };

    bucket = Bucket.get(address);
    bucket.lock.acquire();

    var iter = bucket.queue.iter(address);
    if (iter.remove(&event_waiter.waiter)) {
        context.onTimeout(token, !iter.isEmpty());
        bucket.lock.release();
        return .timed_out;
    }

    event_waiter.context_ref = null;
    if (event_waiter.event.wait(null, &event_waiter))
        return .{ .unparked = event_waiter.waiter.token };

    unreachable;
}

pub const UnparkResult = struct {
    token: ?usize = null,
    be_fair: bool = false,
    has_more: bool = false,
};

pub fn unparkOne(address: usize, context: anytype) void {
    const bucket = Bucket.get(address);
    bucket.lock.acquire();

    var waiter: ?*Waiter = null;
    var result = UnparkResult{};
    var iter = bucket.queue.iter(address);
    
    if (iter.next()) |pending_waiter| {
        waiter = pending_waiter;
        const be_fair = bucket.queue.shouldBeFair();
        if (!iter.remove(pending_waiter))
            unreachable;

        result = UnparkResult{
            .be_fair = be_fair,
            .has_more = iter.isEmpty(),
            .token = pending_waiter.token,
        };
    }

    const token: usize = context.onUnpark(result);
    bucket.lock.release();

    if (waiter) |pending_waiter| {
        pending_waiter.token = token;
        pending_waiter.wake();
    }
}

pub fn unparkAll(address: usize) void {
    const bucket = Bucket.get(address);
    bucket.lock.acquire();

    var wake_list: ?*Waiter = null;
    var iter = bucket.queue.iter(address);

    while (true) {
        const pending_waiter = iter.next() orelse break;
        if (!iter.remove(pending_waiter))
            unreachable;

        pending_waiter.next = wake_list;
        wake_list = pending_waiter;
    }

    bucket.lock.release();

    while (true) {
        const pending_waiter = wake_list orelse break;
        wake_list = pending_waiter.next;
        pending_waiter.wake();
    }
}