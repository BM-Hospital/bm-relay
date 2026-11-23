//! Work off the main thread: `work` runs on a thread of its own, then
//! `done` on the main thread, through myzig's main-thread queue. Nothing
//! polls.
const std = @import("std");
const mainthread = @import("mainthread");

/// Jobs whose work has not finished: the app waits for them as it quits,
/// so none still uses its memory.
var running: std.atomic.Value(u32) = .init(0);

/// Waits, at most `seconds`, for the work of every job to finish.
pub fn drain(io: std.Io, seconds: u32) void {
    var waited: u32 = 0;
    while (running.load(.acquire) > 0 and waited < seconds * 50) : (waited += 1) {
        io.sleep(.fromMilliseconds(20), .awake) catch return;
    }
}

/// Runs `work(job)` on a thread, then `done(job)` on the main thread. The
/// job lives until `done`, which frees it.
pub fn spawn(comptime T: type, job: *T, comptime work: fn (*T) void, comptime done: fn (*T) void) void {
    mainthread.init() catch {};
    const W = struct {
        fn thread(j: *T) void {
            work(j);
            _ = running.fetchSub(1, .release);
            if (!mainthread.post(j, back)) done(j);
        }
        fn back(ctx: ?*anyopaque) callconv(.c) void {
            done(@ptrCast(@alignCast(ctx.?)));
        }
    };
    _ = running.fetchAdd(1, .acquire);
    const th = std.Thread.spawn(.{ .stack_size = 8 << 20 }, W.thread, .{job}) catch {
        _ = running.fetchSub(1, .release);
        work(job);
        done(job);
        return;
    };
    th.detach();
}
