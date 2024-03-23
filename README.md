# chanz
Chanz is a Zig library for creating and using [Go-like channels](https://go.dev/tour/concurrency/2) to send data between threads.

I wrote this as an exercise to get better at Zig comptime and allocators (and because I love Go).

Like in Go, these channels can be used to syncronize threads, because a sender will block until there's a receiver on the other end, and a receiver will block until there's a sender.

### Example:

In the example below, we spawn a thread and immediately subscribe it to the channel with `chan.recv()`, equivalent to Go's `<- c` operator. 

It will block until a value is sent from the main thread with `chan.send()`, equivalent to Go's `c <- val` operator.

```c++
// create channel of u8 type
const T = Chan(u8);
var chan = T.init(std.testing.allocator);
defer chan.deinit();

// spawn thread that immediately waits on channel
const thread = struct {
    fn func(c: *T) !void {
        const val = try c.recv();
        std.debug.print("{d} Thread Received {d}\n", .{ std.time.milliTimestamp(), val });
    }
};

const t = try std.Thread.spawn(.{}, thread.func, .{&chan});
defer t.join();

// let thread wait a bit before sending value
std.time.sleep(1_000_000_000);

var val: u8 = 10;
std.debug.print("{d} Main Sending {d}\n", .{ std.time.milliTimestamp(), val });
try chan.send(val);
```

## Features

### Buffered Chan
Like in Go, channels may be buffered.

This allows senders to dump data into the channel without blocking, until the buffer is full.

```c++
const T = BufferedChan(u16, 3);
var chan = T.init(std.testing.allocator);
defer chan.deinit();
```

### Generic Inner Types
Like in Go, channels may be for any datatype.

Zig comptime generics made this super easy to implement.

You can even make a channel of channels!

```c++
const T = BufferedChan(u8, 3);
const TofT = Chan(T); // chan of chans
var chanOfChan = TofT.init(std.testing.allocator);
defer chanOfChan.deinit();
```

The fact that channel of channels just worked, first try, has officially made me a Zig convert.