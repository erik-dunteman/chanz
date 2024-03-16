const std = @import("std");

const ChanError = error{
    Closed,
    OutOfMemory,
    NotImplemented,
    DataCorruption,
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
        buf: bufType = [_]?*T{null} ** bufSize,
        closed: bool = false,
        mut: std.Thread.Mutex = std.Thread.Mutex{},
        alloc: std.mem.Allocator = undefined,
        recvQ: std.ArrayList(Receiver) = undefined,
        sendQ: std.ArrayList(Receiver) = undefined,

        // represents a thread waiting on recv
        const Receiver: type = struct {
            mut: std.Thread.Mutex = std.Thread.Mutex{},
            condition: std.Thread.Condition = std.Thread.Condition{},
            data: ?T = null,

            fn putDataAndSignal(self: @This(), data: T) void {
                // invoked by sender thread
                self.data = data;
                self.c.signal();
            }
        };

        // represents a thread waiting on send
        const Sender: type = struct {
            mut: std.Thread.Mutex = std.Thread.Mutex{},
            condition: std.Thread.Condition = std.Thread.Condition{},
            data: T,

            fn getDataAndSignal(self: @This()) T {
                defer self.c.signal();
                return self.data;
            }
        };

        // new impl
        // sender queue
        // receiver queue, containing empty buffer for T

        // cases
        // - no queue
        // sender arrives first, ends up waiting on queue. receiver signals it once it's taken value
        // receiver arrives first, ends up waiting on queue. sender signals it once it's taken value (note senders and receivers both need methods to receive)

        // todo: make sender obj and receiver obj, each with
        // - unique condition signal (maybe could share some mutex?)
        // - data transfer methods

        fn init(alloc: std.mem.Allocator) Self {
            return Self{
                .alloc = alloc,
                .recvQ = std.ArrayList(Receiver).init(alloc),
                .sendQ = std.ArrayList(Receiver).init(alloc),
            };
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

            self.mut.lock();
            errdefer self.mut.unlock();

            // case: receiver already waiting
            // pull receiver (if any) and give it data. Signal receiver that it's done waiting.
            if (self.recvQ.items.len > 0) {
                defer self.mut.unlock();
                var receiver: Receiver = self.recvQ.orderedRemove(0);
                receiver.putDataAndSignal(data);
                return;
            }

            if (self.len() < self.capacity()) {
                defer self.mut.unlock();
                // put T on chan buffer
                // TODO
                return;
            }

            // hold on sender queue. Receivers will signal when they take data.
            var sender: Sender = Sender{ .data = data };

            // prime condition
            sender.mut.lock(); // cond.wait below will unlock it and wait until signal, then relock it
            defer sender.mut.unlock(); // unlocks the relock

            try self.sendQ.append(sender); // make visible to other threads
            self.mut.unlock(); // allow all other threads to proceed. This thread is done reading/writing

            // now just wait for receiver to signal sender
            sender.cond.wait(&sender.mut);
            return;
        }

        fn close(self: *Self) void {
            self.closed = true;
        }

        fn recv(self: *Self) ChanError!T {
            if (self.closed) return ChanError.Closed;

            self.mut.lock();
            errdefer self.mut.unlock();

            // case: value in buffer
            if (self.len() > 0) {
                // TODO
                return ChanError.NotImplemented;
            }

            // case: sender already waiting
            // pull sender and take its data. Signal sender that it's done waiting.
            if (self.sendQ.items.len > 0) {
                defer self.mut.unlock();
                var sender: Sender = self.sendQ.orderedRemove(0);
                const data: T = sender.getDataAndSignal();
                return data;
            }

            // hold on receiver queue. Senders will signal when they take it.
            var receiver: Receiver = Receiver{};

            // prime condition
            receiver.mut.lock();
            defer receiver.mut.unlock();

            try self.recvQ.append(receiver);
            self.mut.unlock();

            // now wait for sender to signal receiver
            receiver.cond.wait(&receiver.mut);
            // sender should have put data in .data
            if (receiver.data) |data| {
                return data;
            } else {
                return ChanError.DataCorruption;
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
