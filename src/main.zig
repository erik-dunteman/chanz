const std = @import("std");

const ChanError = error{
    Closed,
    OutOfMemory,
};

fn Chan(comptime T: type) type {
    return BufferedChan(T, 0);
}

// naive implementation
// sending polls until there's room in buffer, or a receiver listening
// receivers poll for buffer item, or if there's no receiver in chan, then they register themselves as receiver
// note: use of buffer not yet implemented
fn BufferedChan(comptime T: type, comptime bufSize: u8) type {
    return struct {
        const Self = @This();
        const bufType = [bufSize]?*T; // buffer

        alloc: std.mem.Allocator = undefined,
        buf: bufType = [_]?*T{null} ** bufSize,
        closed: bool = false,

        // sync utils
        recvLock: std.Thread.Mutex = std.Thread.Mutex{},
        resvReady: bool = false,
        sendLock: std.Thread.Mutex = std.Thread.Mutex{},
        escrow: ?*T = null, // single item buffer used only for handoff between known sender and receiver

        fn init(alloc: std.mem.Allocator) Self {
            return Self{ .alloc = alloc };
        }

        fn len(self: *Self) u8 {
            var i: u8 = 0;
            for (self.buf) |item| {
                if (item) |_| {
                    i += 1;
                } else {
                    break;
                }
            }
            return i;
        }

        fn capacity(self: *Self) u8 {
            return self.buf.len;
        }

        fn send(self: *Self, data: T) ChanError!void {
            if (self.closed) return ChanError.Closed;
            // acquire send lock (other threads may be contesting for this)
            self.sendLock.lock();
            defer self.sendLock.unlock();
            var item = self.alloc.create(T) catch {
                return ChanError.OutOfMemory;
            };
            item.* = data;

            // await listening receiver (assumes no buffer)
            while (true) : (std.time.sleep(1_000)) {
                if (self.resvReady) {
                    self.escrow = item;
                    // await confirmation that escrow is pulled (it'd become null)
                    while (self.escrow) |_| {
                        std.time.sleep(1_000);
                    }
                    return;
                }
            }
        }

        fn close(self: *Self) void {
            self.closed = true;
        }

        fn recv(self: *Self) ChanError!T {
            if (self.closed) return ChanError.Closed;
            self.recvLock.lock();

            // signal ready for recv, allowing sender to put item in escrow
            self.resvReady = true;
            // await item in escrow
            while (true) {
                if (self.escrow) |item| {
                    // destroy heap allocation and copy value to stack for return
                    defer self.alloc.destroy(item);
                    const copy = item.*;

                    // sender will unlock its mutex once we clear escrow so do that last
                    self.resvReady = false;
                    self.recvLock.unlock();
                    self.escrow = null;

                    return copy;
                }
                std.time.sleep(1_000);
            }
        }
    };
}

pub fn main() !void {
    var c = Chan(u8, 10){};
    std.debug.print("Capacity: {}\n", .{c.capacity()});
    std.debug.print("Len: {}\n", .{c.len()});
}

var mut = std.Thread.Mutex{};
var cond = std.Thread.Condition{};
var predicate = false;
fn consumer(i: u8) void {
    mut.lock(); // don't worry, cond.wait below will unlock it, block until condition signal, and then relock it
    std.debug.print("consumer {d} locked mutex\n", .{i});
    defer {
        mut.unlock(); // so this is a "second" unlock, for the relock on signal
        std.debug.print("consumer {d} unlocked mutex\n", .{i});
    }
    std.debug.print("consumer {d} about to wait\n", .{i});
    cond.wait(&mut);
    std.debug.print("consumer {d} wait broken\n", .{i});
    std.debug.print("consumer {d} after predicate loop\n", .{i});
}
fn producer() void {
    std.time.sleep(1_000_000_000);
    std.debug.print("producer about to signal\n", .{});
    cond.signal();
    std.debug.print("producer signaled\n", .{});
    std.time.sleep(1_000_000_000);
    std.debug.print("producer about to signal\n", .{});
    cond.signal();
    std.debug.print("producer signaled\n", .{});
}

test "condition" {
    std.debug.print("\n", .{});

    const thread1 = try std.Thread.spawn(.{}, consumer, .{1});
    const thread2 = try std.Thread.spawn(.{}, consumer, .{2});
    producer();
    thread1.join();
    thread2.join();
}

test "unbufferedChan" {
    std.debug.print("\n", .{});

    const T = Chan(u8);
    var chan = T.init(std.testing.allocator);

    const thread = struct {
        fn func(c: *T) !void {
            std.time.sleep(2_000_000_000);
            const val = try c.recv();
            std.debug.print("{d} Thread Received {d}\n", .{ std.time.milliTimestamp(), val });
            std.time.sleep(1_000_000_000);
            std.debug.print("{d} Thread Sending {d}\n", .{ std.time.milliTimestamp(), val + 1 });
            try c.send(val + 1);
            std.time.sleep(2_000_000_000);
            std.debug.print("{d} Thread Sending {d}\n", .{ std.time.milliTimestamp(), val + 100 });
            try c.send(val + 100);
            std.debug.print("{d} Thread Exit\n", .{std.time.milliTimestamp()});
        }
    };

    const t = try std.Thread.spawn(.{}, thread.func, .{&chan});
    defer t.join();

    std.time.sleep(1_000_000_000);
    var val: u8 = 10;
    std.debug.print("{d} Main Sending {d}\n", .{ std.time.milliTimestamp(), val });
    try chan.send(val);
    val = try chan.recv();
    std.debug.print("{d} Main Received {d}\n", .{ std.time.milliTimestamp(), val });
    val = try chan.recv();
    std.debug.print("{d} Main Received {d}\n", .{ std.time.milliTimestamp(), val });
}
