//! JSON-RPC 2.0 over an agent's standard input and output, one message per
//! line, as ACP speaks it. A thread reads the agent's output and hands each
//! line to the main thread, where everything else happens: requests are
//! written there, replies call back there, and the agent's own messages
//! reach the handler there. Nothing polls and nothing is shared between
//! threads but the lines handed over and the tail of the agent's errors.
const std = @import("std");
const Io = std.Io;
const mainthread = @import("mainthread");
const json = @import("json.zig");
const proc = @import("proc.zig");

pub const Value = json.Value;

/// What a request got back. `gone` means the connection closed first:
/// the callback frees what it holds and does nothing else.
pub const Reply = union(enum) {
    ok: Value,
    err: []const u8,
    gone,
};

pub const Callback = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, conn: *Conn, reply: Reply) void,
};

/// A message the agent sent of its own accord: a notification, or a
/// request when `id` is set (answer it with `respond` or `respondError`).
pub const Incoming = struct {
    method: []const u8,
    params: ?Value,
    id: ?Value,
};

pub const Handler = struct {
    ctx: *anyopaque,
    message: *const fn (ctx: *anyopaque, conn: *Conn, msg: Incoming) void,
    /// The agent's output ended without `stop`: it exited or crashed.
    exited: *const fn (ctx: *anyopaque, conn: *Conn, why: []const u8) void,
};

pub const Conn = struct {
    gpa: std.mem.Allocator,
    io: Io,
    p: proc.Proc,
    handler: Handler,
    pending: std.AutoHashMapUnmanaged(i64, Callback) = .empty,
    next_id: i64 = 0,
    /// The main thread's, the output reader's and the error reader's.
    refs: std.atomic.Value(u32) = .init(3),
    stopped: bool = false,
    /// The last of what the agent wrote to its standard error.
    err_lock: Io.Mutex = .init,
    err_tail: [2048]u8 = undefined,
    err_len: usize = 0,
    /// Anything the app hangs on the connection (its session, say).
    user: ?*anyopaque = null,

    pub fn start(gpa: std.mem.Allocator, io: Io, opts: proc.Options, handler: Handler) !*Conn {
        mainthread.init() catch {};
        const c = try gpa.create(Conn);
        errdefer gpa.destroy(c);
        c.* = .{ .gpa = gpa, .io = io, .p = try proc.spawn(io, opts), .handler = handler };
        _ = live.fetchAdd(1, .acq_rel);
        errdefer _ = live.fetchSub(1, .acq_rel);
        const out = std.Thread.spawn(.{ .stack_size = 1 << 20 }, readLoop, .{c}) catch |e| {
            c.p.kill(io);
            c.p.stdout.close(io);
            if (c.p.stderr) |f| f.close(io);
            return e;
        };
        out.detach();
        if (c.p.stderr) |f| {
            c.p.stderr = null;
            if (std.Thread.spawn(.{ .stack_size = 256 << 10 }, errLoop, .{ c, f })) |t| t.detach() else |_| {
                f.close(io);
                _ = c.refs.fetchSub(1, .acq_rel);
            }
        } else _ = c.refs.fetchSub(1, .acq_rel);
        return c;
    }

    /// Ends the agent. Callbacks still waiting get `gone`, now; the
    /// handler hears nothing more. Main thread.
    pub fn stop(c: *Conn) void {
        if (c.stopped) return;
        c.stopped = true;
        c.p.kill(c.io);
        c.failPending();
        c.release();
    }

    /// What the agent last wrote to its standard error, trimmed.
    pub fn errors(c: *Conn, buf: []u8) []const u8 {
        c.err_lock.lockUncancelable(c.io);
        defer c.err_lock.unlock(c.io);
        const n = @min(buf.len, c.err_len);
        @memcpy(buf[0..n], c.err_tail[c.err_len - n .. c.err_len]);
        return std.mem.trim(u8, buf[0..n], " \r\n\t");
    }

    pub fn request(c: *Conn, method: []const u8, params: anytype, cb: Callback) void {
        if (c.stopped) return cb.func(cb.ctx, c, .gone);
        const id = c.next_id;
        c.next_id += 1;
        c.pending.put(c.gpa, id, cb) catch return cb.func(cb.ctx, c, .{ .err = "Out of memory" });
        c.send(.{ .jsonrpc = "2.0", .id = id, .method = method, .params = params }) catch {
            _ = c.pending.remove(id);
            cb.func(cb.ctx, c, .{ .err = "The agent is not reading its input" });
        };
    }

    pub fn notify(c: *Conn, method: []const u8, params: anytype) void {
        c.send(.{ .jsonrpc = "2.0", .method = method, .params = params }) catch {};
    }

    pub fn respond(c: *Conn, id: Value, result: anytype) void {
        c.send(.{ .jsonrpc = "2.0", .id = id, .result = result }) catch {};
    }

    pub fn respondError(c: *Conn, id: Value, code: i64, message: []const u8) void {
        c.send(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } }) catch {};
    }

    fn send(c: *Conn, msg: anytype) !void {
        const stdin = c.p.stdin orelse return error.Closed;
        var line: Io.Writer.Allocating = .init(c.gpa);
        defer line.deinit();
        try std.json.Stringify.value(msg, .{ .emit_null_optional_fields = false }, &line.writer);
        try line.writer.writeByte('\n');
        try stdin.writeStreamingAll(c.io, line.written());
    }

    fn failPending(c: *Conn) void {
        var it = c.pending.iterator();
        var cbs: std.ArrayList(Callback) = .empty;
        defer cbs.deinit(c.gpa);
        while (it.next()) |e| cbs.append(c.gpa, e.value_ptr.*) catch {};
        c.pending.clearRetainingCapacity();
        for (cbs.items) |cb| cb.func(cb.ctx, c, .gone);
    }

    fn release(c: *Conn) void {
        if (c.refs.fetchSub(1, .acq_rel) != 1) return;
        c.pending.deinit(c.gpa);
        c.gpa.destroy(c);
        _ = live.fetchSub(1, .acq_rel);
    }

    /// One line from the agent, on the main thread.
    fn handleLine(c: *Conn, line: []const u8) void {
        if (c.stopped) return;
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const msg = std.json.parseFromSliceLeaky(Value, arena.allocator(), line, .{}) catch return;
        if (msg != .object) return;
        const method = json.str(msg, "method");
        const id = json.get(msg, "id");
        if (method == null) {
            const n = if (id) |v| (if (v == .integer) v.integer else return) else return;
            const cb = (c.pending.fetchRemove(n) orelse return).value;
            if (json.get(msg, "error")) |e| {
                const text = innerMessage(arena.allocator(), json.str(e, "message") orelse "The request failed");
                const data = json.get(e, "data");
                const detail = if (data) |d| (if (d == .string) d.string else json.stringify(arena.allocator(), d) catch "") else "";
                const why = if (detail.len > 0 and !std.mem.eql(u8, detail, text)) std.fmt.allocPrint(arena.allocator(), "{s}: {s}", .{ text, detail }) catch text else text;
                cb.func(cb.ctx, c, .{ .err = why });
            } else cb.func(cb.ctx, c, .{ .ok = json.get(msg, "result") orelse .null });
            return;
        }
        c.handler.message(c.handler.ctx, c, .{ .method = method.?, .params = json.get(msg, "params"), .id = id });
    }

    fn handleEnd(c: *Conn) void {
        if (!c.stopped) {
            c.stopped = true;
            if (c.p.stdin) |f| f.close(c.io);
            c.p.stdin = null;
            c.failPending();
            var buf: [600]u8 = undefined;
            const tail = c.errors(&buf);
            c.handler.exited(c.handler.ctx, c, if (tail.len > 0) tail else "The agent exited");
            c.p.kill(c.io);
            c.release();
        }
        c.release();
    }
};

/// Agents pass on their provider's errors as JSON inside the message,
/// sometimes JSON inside that: the words are in the innermost "message".
pub fn innerMessage(a: std.mem.Allocator, text: []const u8) []const u8 {
    var cur = text;
    var depth: usize = 0;
    while (depth < 4) : (depth += 1) {
        const at = std.mem.indexOfScalar(u8, cur, '{') orelse return cur;
        const v = std.json.parseFromSliceLeaky(Value, a, cur[at..], .{}) catch return cur;
        cur = json.str(json.get(v, "error"), "message") orelse json.str(v, "message") orelse return cur;
    }
    return cur;
}

test "an error's words, from the JSON around them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const raw = "Internal error: {\"message\":\"{\\\"type\\\":\\\"error\\\",\\\"status\\\":400,\\\"error\\\":{\\\"type\\\":\\\"invalid_request_error\\\",\\\"message\\\":\\\"The model is not supported.\\\"}}\",\"codex_error_info\":\"other\"}";
    try std.testing.expectEqualStrings("The model is not supported.", innerMessage(arena.allocator(), raw));
    try std.testing.expectEqualStrings("plain words", innerMessage(arena.allocator(), "plain words"));
}

const Line = struct {
    c: *Conn,
    bytes: []u8,
    fn run(ctx: ?*anyopaque) callconv(.c) void {
        const l: *Line = @ptrCast(@alignCast(ctx.?));
        defer {
            l.c.gpa.free(l.bytes);
            l.c.gpa.destroy(l);
        }
        l.c.handleLine(l.bytes);
    }
};

fn ended(ctx: ?*anyopaque) callconv(.c) void {
    const c: *Conn = @ptrCast(@alignCast(ctx.?));
    c.handleEnd();
}

/// Connections not freed yet: their agents' ends are still to come.
var live: std.atomic.Value(u32) = .init(0);

/// At quitting, once every agent was stopped: runs the main thread's queue
/// until their connections are freed (their ends are handled there), or
/// `ms` went by. Main thread only.
pub fn settle(io: Io, ms: u32) void {
    if (live.load(.acquire) == 0) return;
    var done: std.atomic.Value(bool) = .init(false);
    const W = struct {
        fn wait(d: *std.atomic.Value(bool), wio: Io, limit: u32) void {
            var waited: u32 = 0;
            while (waited < limit and live.load(.acquire) > 0) : (waited += 10) wio.sleep(.fromMilliseconds(10), .awake) catch break;
            if (!mainthread.post(d, set)) d.store(true, .release);
        }
        fn set(ctx: ?*anyopaque) callconv(.c) void {
            const d: *std.atomic.Value(bool) = @ptrCast(@alignCast(ctx.?));
            d.store(true, .release);
        }
    };
    const t = std.Thread.spawn(.{}, W.wait, .{ &done, io, ms }) catch return;
    mainthread.runUntil(&done);
    t.join();
}

fn readLoop(c: *Conn) void {
    var buf: [64 * 1024]u8 = undefined;
    var r = c.p.stdout.readerStreaming(c.io, &buf);
    var line: Io.Writer.Allocating = .init(c.gpa);
    defer line.deinit();
    while (true) {
        line.clearRetainingCapacity();
        _ = r.interface.streamDelimiter(&line.writer, '\n') catch break;
        r.interface.toss(1);
        const text = std.mem.trim(u8, line.written(), " \r\t");
        if (text.len == 0) continue;
        const l = c.gpa.create(Line) catch continue;
        l.* = .{ .c = c, .bytes = c.gpa.dupe(u8, text) catch {
            c.gpa.destroy(l);
            continue;
        } };
        if (!mainthread.post(l, Line.run)) {
            c.gpa.free(l.bytes);
            c.gpa.destroy(l);
        }
    }
    c.p.stdout.close(c.io);
    if (!mainthread.post(c, ended)) _ = c.refs.fetchSub(1, .acq_rel);
}

fn errLoop(c: *Conn, f: Io.File) void {
    defer c.release();
    defer f.close(c.io);
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = f.readStreaming(c.io, &.{&buf}) catch break;
        if (n == 0) break;
        c.err_lock.lockUncancelable(c.io);
        defer c.err_lock.unlock(c.io);
        const room = c.err_tail.len;
        const take = @min(n, room);
        const chunk = buf[n - take .. n];
        if (c.err_len + take > room) {
            const keep = room - take;
            std.mem.copyForwards(u8, c.err_tail[0..keep], c.err_tail[c.err_len - keep .. c.err_len]);
            c.err_len = keep;
        }
        @memcpy(c.err_tail[c.err_len .. c.err_len + take], chunk);
        c.err_len += take;
    }
}
