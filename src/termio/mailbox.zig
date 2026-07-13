const std = @import("std");
const Allocator = std.mem.Allocator;
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");
const termio = @import("../termio.zig");
const BlockingQueue = @import("../datastruct/main.zig").BlockingQueue;

const log = std.log.scoped(.io_writer);

/// A queue used for storing messages that is periodically drained.
/// Typically used by a multi-threaded application. The capacity is
/// hardcoded to a value that empirically has made sense for Ghostty usage
/// but I'm open to changing it with good arguments.
const Queue = BlockingQueue(termio.Message, 64);

/// The location to where write-related messages are sent.
pub const Mailbox = union(enum) {
    // /// Write messages to an unbounded list backed by an allocator.
    // /// This is useful for single-threaded applications where you're not
    // /// afraid of running out of memory. You should be careful that you're
    // /// processing this in a timely manner though since some heavy workloads
    // /// will produce a LOT of messages.
    // ///
    // /// At the time of authoring this, the primary use case for this is
    // /// testing more than anything, but it probably will have a use case
    // /// in libghostty eventually.
    // unbounded: std.ArrayList(termio.Message),

    /// Write messages to a SPSC queue for multi-threaded applications.
    spsc: struct {
        queue: *Queue,
        wakeup: xev.Async,
    },

    /// Init the SPSC writer.
    pub fn initSPSC(alloc: Allocator) !Mailbox {
        var queue = try Queue.create(alloc);
        errdefer queue.destroy(alloc);

        var wakeup = try xev.Async.init();
        errdefer wakeup.deinit();

        return .{ .spsc = .{ .queue = queue, .wakeup = wakeup } };
    }

    pub fn deinit(self: *Mailbox, alloc: Allocator) void {
        switch (self.*) {
            .spsc => |*v| {
                v.queue.destroy(alloc);
                v.wakeup.deinit();
            },
        }
    }

    /// Close the mailbox: all future (and currently blocked) sends drop
    /// their message instead of waiting for space. Called at surface
    /// teardown BEFORE joining the IO thread, because after the IO thread
    /// is asked to stop nobody will ever drain this queue again — a
    /// producer parked in `send`'s slow path would otherwise deadlock the
    /// joining (GUI) thread forever.
    pub fn close(self: *Mailbox) void {
        switch (self.*) {
            .spsc => |*v| v.queue.close(),
        }
    }

    /// Sends the given message without notifying there are messages.
    ///
    /// If the optional mutex is given, it must already be LOCKED. If the
    /// send would block, we'll unlock this mutex, resend the message, and
    /// lock it again. This handles an edge case where queues are full.
    /// This may not apply to all writer types.
    pub fn send(
        self: *Mailbox,
        msg: termio.Message,
        mutex: ?*std.Thread.Mutex,
    ) void {
        switch (self.*) {
            .spsc => |*mb| send: {
                // Try to write to the queue with an instant timeout. This is the
                // fast path because we can queue without a lock.
                if (mb.queue.push(msg, .{ .instant = {} }) > 0) break :send;

                // If we enter this conditional, the queue is full. We wake up
                // the writer thread so that it can process messages to clear up
                // space. However, the writer thread may require the renderer
                // lock so we need to unlock.
                mb.wakeup.notify() catch |err| {
                    log.warn("failed to wake up writer, data will be dropped err={}", .{err});
                    return;
                };

                // Unlock the renderer state so the writer thread can acquire it.
                // Then try to queue our message before continuing. This is a very
                // slow path because we are having a lot of contention for data.
                // But this only gets triggered in certain pathological cases.
                //
                // Note that writes themselves don't require a lock, but there
                // are other messages in the writer queue (resize, focus) that
                // could acquire the lock. This is why we have to release our lock
                // here.
                if (mutex) |m| m.unlock();
                defer if (mutex) |m| m.lock();

                // Bounded timed retries, NEVER a forever wait. Two callers
                // can reach this with a full queue and no hope of a drain:
                // (1) the IO thread itself, when stream processing generates
                // replies (remote backends parse output ON the IO thread, so
                // producer == consumer and waiting can never succeed), and
                // (2) any producer during teardown, after the IO thread has
                // stopped draining. A forever wait wedges that thread — and
                // wedges the GUI thread when Surface.deinit later joins it.
                // Dropping a message after ~50ms of a full queue is strictly
                // better than deadlocking the app; it's also loud so we can
                // find pathological floods.
                var attempts: usize = 0;
                while (attempts < 5) : (attempts += 1) {
                    if (mb.queue.push(msg, .{ .ns = 10 * std.time.ns_per_ms }) > 0) return;
                    if (mb.queue.isClosed()) return;
                }
                log.warn("termio mailbox full for 50ms, dropping message={s}", .{@tagName(msg)});
            },
        }
    }

    /// Notify that there are new messages. This may be a noop depending
    /// on the writer type.
    pub fn notify(self: *Mailbox) void {
        switch (self.*) {
            .spsc => |*v| v.wakeup.notify() catch |err| {
                log.warn("failed to notify writer, data will be dropped err={}", .{err});
            },
        }
    }
};
