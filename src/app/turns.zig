//! Sending a prompt, steering a running turn, the queue, stopping,
//! answering questions, and the snapshots behind "Restore this turn's
//! files".
const std = @import("std");
const app_mod = @import("app.zig");
const state = @import("state.zig");
const rpc = @import("../acp/rpc.zig");
const json = @import("../acp/json.zig");
const git = @import("../host/git.zig");
const jobs = @import("../host/jobs.zig");
const sessions = @import("sessions.zig");

const App = app_mod.App;
const Session = state.Session;

/// Sends the composer's text and attachments: a new turn, or while one
/// runs, steering (fx) or the queue. False when nothing could take it.
pub fn submit(a: *App, text_in: []const u8) bool {
    const s = a.active orelse return false;
    if (!s.live()) return false;
    const text = std.mem.trim(u8, text_in, " \r\n\t");
    const running = s.thread.running();
    if (text.len == 0 and a.attachments.items.len == 0) return !running and sendNext(a, s);
    const images = a.attachments.toOwnedSlice(a.gpa) catch return false;
    // No session yet: the prompt waits for the one it asks the agent for.
    if (s.id == null) {
        s.queue.append(a.gpa, .{ .text = a.gpa.dupe(u8, text) catch return false, .images = images }) catch return false;
        @import("agent.zig").create(a, s);
        a.redraw();
        return true;
    }
    if (!running) return startTurn(a, s, text, images);
    if (images.len == 0 and text.len > 0 and text[0] != '/' and std.mem.eql(u8, s.agent, "fx")) {
        steer(a, s, text);
    } else {
        s.queue.append(a.gpa, .{ .text = a.gpa.dupe(u8, text) catch return false, .images = images }) catch return false;
    }
    a.redraw();
    return true;
}

pub fn sendNext(a: *App, s: *Session) bool {
    if (s.queue.items.len == 0) return false;
    const q = s.queue.orderedRemove(0);
    defer a.gpa.free(q.text);
    return startTurn(a, s, q.text, q.images);
}

const Op = struct {
    a: *App,
    key: u64,
    text: []u8 = &.{},

    fn make(a: *App, s: *Session) *Op {
        const op = a.gpa.create(Op) catch @panic("out of memory");
        op.* = .{ .a = a, .key = s.key };
        return op;
    }

    fn free(op: *Op) void {
        op.a.gpa.free(op.text);
        op.a.gpa.destroy(op);
    }
};

/// fx takes a prompt into a running turn: `_meta.fx.steer`.
fn steer(a: *App, s: *Session, text: []const u8) void {
    const conn = s.conn orelse return;
    const id = s.id orelse return;
    s.steering.append(a.gpa, a.gpa.dupe(u8, text) catch return) catch return;
    const op = Op.make(a, s);
    op.text = a.gpa.dupe(u8, text) catch &.{};
    conn.request("session/prompt", .{
        .sessionId = id,
        .prompt = &[_]struct { type: []const u8 = "text", text: []const u8 }{.{ .text = text }},
        ._meta = .{ .fx = .{ .steer = true } },
    }, .{ .ctx = op, .func = steered });
}

fn steered(ctx: ?*anyopaque, conn: *rpc.Conn, reply: rpc.Reply) void {
    const op: *Op = @ptrCast(@alignCast(ctx.?));
    defer op.free();
    const a = op.a;
    const s = a.byKey(op.key) orelse return;
    if (s.conn != conn) return;
    const absorbed = switch (reply) {
        .gone => return,
        .err => false,
        .ok => |v| !std.mem.eql(u8, json.strOr(json.at(v, &.{ "_meta", "fx" }), "steering", ""), "dropped"),
    };
    var waiting: ?usize = null;
    for (s.steering.items, 0..) |x, i| if (std.mem.eql(u8, x, op.text)) {
        waiting = i;
        break;
    };
    if (waiting) |i| a.gpa.free(s.steering.orderedRemove(i));
    if (!absorbed and waiting != null) {
        s.queue.insert(a.gpa, 0, .{ .text = a.gpa.dupe(u8, op.text) catch return, .images = &.{} }) catch {};
        if (reply == .err and !s.thread.running()) _ = sendNext(a, s);
    }
    a.redraw();
}

/// A prompt beginning `/name` that names a skill on disk becomes an
/// instruction to read and follow it. Agents with commands of their own
/// (Claude Code's `/review`) take theirs as typed.
fn expandSkill(a: *App, s: *Session, text: []const u8) []const u8 {
    if (text.len < 2 or text[0] != '/') return text;
    const rest = text[1..];
    const sp = std.mem.indexOfAny(u8, rest, " \t\n") orelse rest.len;
    const name = rest[0..sp];
    for (s.thread.commands) |c| if (std.mem.eql(u8, c.name, name)) return text;
    const ws = a.workspaceOf(s) orelse return text;
    for (ws.skills) |sk| if (std.mem.eql(u8, sk.name, name)) {
        const args = std.mem.trim(u8, rest[sp..], " \t\n");
        return std.fmt.allocPrint(a.gpa, "Use the `{s}` skill: read {s} first and follow it.\n\n{s}", .{ name, sk.path, args }) catch text;
    };
    return text;
}

/// Sends the prompt of turn `index` again, as a new turn: with `text` in
/// place of its words when given (edited), and its images. The agent keeps
/// what came before; ACP (v1) has no way to take a turn back.
pub fn resend(a: *App, s: *Session, index: usize, text: ?[]const u8) bool {
    if (index >= s.thread.turns.items.len or s.thread.running() or !s.live()) return false;
    const turn = s.thread.turns.items[index];
    var images: std.ArrayList(state.Attachment) = .empty;
    for (turn.images.items) |img| {
        const bytes = a.gpa.dupe(u8, img.bytes) catch continue;
        const name = a.gpa.dupe(u8, "image") catch {
            a.gpa.free(bytes);
            continue;
        };
        images.append(a.gpa, .{ .mime = img.mime, .bytes = bytes, .name = name }) catch {};
    }
    const words = a.gpa.dupe(u8, text orelse turn.prompt.items) catch return false;
    defer a.gpa.free(words);
    const owned = images.toOwnedSlice(a.gpa) catch return false;
    a.to_end = true;
    return startTurn(a, s, std.mem.trim(u8, words, " \r\n\t"), owned);
}

/// Starts editing the prompt of turn `index` in place.
pub fn startEdit(a: *App, s: *Session, index: usize) void {
    if (index >= s.thread.turns.items.len) return;
    endEdit(a);
    a.prompt_edit = .{ .session = s.key, .turn = index, .text = .init(a.gpa, "") };
    // As an edit: the caret at its end, where more is typed.
    a.prompt_edit.?.text.setText(s.thread.turns.items[index].prompt.items);
    a.redraw();
}

pub fn endEdit(a: *App) void {
    if (a.prompt_edit) |*e| e.text.deinit();
    a.prompt_edit = null;
    a.redraw();
}

/// Sends the edited prompt; the edit ends when it went.
pub fn sendEdit(a: *App, s: *Session) void {
    const e = &(a.prompt_edit orelse return);
    const text = e.text.text(a.gpa);
    defer a.gpa.free(text);
    if (std.mem.trim(u8, text, " \r\n\t").len == 0) return;
    if (resend(a, s, e.turn, text)) endEdit(a);
}

fn startTurn(a: *App, s: *Session, text: []const u8, images: []state.Attachment) bool {
    defer {
        for (images) |i| i.deinit(a.gpa);
        a.gpa.free(images);
    }
    const conn = s.conn orelse return false;
    const id = s.id orelse return false;
    if (s.thread.running()) return false;
    const ws = a.workspaceOf(s) orelse return false;
    const prompt = expandSkill(a, s, text);
    defer if (prompt.ptr != text.ptr) a.gpa.free(prompt);

    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    var blocks = std.json.Array.init(ar);
    if (prompt.len > 0) {
        var o: std.json.ObjectMap = .empty;
        o.put(ar, "type", .{ .string = "text" }) catch {};
        o.put(ar, "text", .{ .string = prompt }) catch {};
        blocks.append(.{ .object = o }) catch {};
    }
    for (images) |img| {
        var o: std.json.ObjectMap = .empty;
        const enc = std.base64.standard.Encoder;
        const data = ar.alloc(u8, enc.calcSize(img.bytes.len)) catch continue;
        _ = enc.encode(data, img.bytes);
        o.put(ar, "type", .{ .string = "image" }) catch {};
        o.put(ar, "mimeType", .{ .string = img.mime }) catch {};
        o.put(ar, "data", .{ .string = data }) catch {};
        blocks.append(.{ .object = o }) catch {};
    }

    const turn = s.thread.begin(text, a.now());
    for (images) |img| s.thread.keepImage(turn, img.mime, img.bytes);
    snapshot(a, s, false);
    if (s.tally == null) s.tally = .{ .before = git.cloneChanges(a.gpa, ws.status), .from = s.thread.turns.items.len - 1 };
    if (s.option("model")) |m| a.store.putSession(.{ .id = id, .agent = s.agent, .cwd = ws.path, .model = m.current, .updated = a.now() }) else a.store.putSession(.{ .id = id, .agent = s.agent, .cwd = ws.path, .updated = a.now() });
    if (s.thread.turns.items.len == 1) a.store.putSession(.{ .id = id, .agent = "", .cwd = "", .title = firstLine(text) });
    a.store.save();
    a.settings.clearSkipped(a.gpa);
    s.setError(null);
    s.updated = a.now();

    conn.request("session/prompt", .{ .sessionId = id, .prompt = json.Value{ .array = blocks } }, .{ .ctx = Op.make(a, s), .func = prompted });
    a.to_end = true;
    a.redraw();
    return true;
}

fn firstLine(t: []const u8) []const u8 {
    const line = t[0 .. std.mem.indexOfScalar(u8, t, '\n') orelse t.len];
    return line[0..@min(line.len, 120)];
}

fn prompted(ctx: ?*anyopaque, conn: *rpc.Conn, reply: rpc.Reply) void {
    const op: *Op = @ptrCast(@alignCast(ctx.?));
    defer op.free();
    const a = op.a;
    const s = a.byKey(op.key) orelse return;
    if (s.conn != conn and reply != .gone) return;
    s.stopping = null;
    // Stopped here already: the agent's late answer changes nothing.
    if (!s.thread.running()) return;
    var finished = false;
    switch (reply) {
        .gone => if (s.thread.running()) s.thread.finish(.{ .stop = "cancelled" }, a.now()),
        .err => |e| s.thread.finish(.{ .err = e }, a.now()),
        .ok => |v| {
            const reason = json.strOr(v, "stopReason", "end_turn");
            finished = std.mem.eql(u8, reason, "end_turn");
            s.thread.finish(.{ .stop = reason }, a.now());
        },
    }
    a.notify(a.label(s), if (reply == .err) "Stopped with an error" else "Done");
    s.clearPermission();
    if (a.workspaceOf(s)) |ws| sessions.refreshStatus(a, ws);
    snapshot(a, s, true);
    if (finished) _ = sendNext(a, s);
    if (a.changes != null) @import("../views/changes.zig").refresh(a);
    a.redraw();
}

/// Stops the running turn.
pub fn stop(a: *App) void {
    const s = a.active orelse return;
    stopIn(a, s);
}

/// Asks the agent to stop the turn, and shows it stopping. Asked again,
/// or the agent still at it after `stop_wait` ms, the turn ends here and
/// the agent is put down (`forceStop`).
pub fn stopIn(a: *App, s: *Session) void {
    if (!s.thread.running()) return;
    if (s.stopping != null) return forceStop(a, s);
    const conn = s.conn orelse return forceStop(a, s);
    const id = s.id orelse return;
    s.stopping = a.now();
    if (s.permission != null) @import("agent.zig").answerPermission(a, s, null);
    conn.notify("session/cancel", .{ .sessionId = id });
    s.thread.stopCalls();
    a.redraw();
}

/// How long an agent may take to stop before the app stops it.
pub const stop_wait: i64 = 8000;

/// Ends the turn without the agent: it did not stop when asked. One that
/// can load sessions starts again and loads this one; the turns stay on
/// screen while it does.
pub fn forceStop(a: *App, s: *Session) void {
    s.stopping = null;
    s.clearPermission();
    s.thread.stopCalls();
    s.thread.finish(.{ .stop = "cancelled" }, a.now());
    if (s.conn != null and s.caps.load and s.id != null) {
        if (s.conn) |c| c.stop();
        s.conn = null;
        @import("agent.zig").reload(a, s);
    }
    a.redraw();
}

/// Stops, for good, the turns whose agent did not stop in time.
pub fn tick(a: *App) void {
    const now = a.now();
    for (a.workspaces.items) |w| for (w.sessions.items) |s| if (s.stopping) |at| {
        if (!s.thread.running()) {
            s.stopping = null;
        } else if (now - at > stop_wait) forceStop(a, s);
    };
}

pub fn answerQuestion(a: *App, answer: []const u8) void {
    _ = submit(a, answer);
}

pub fn skipQuestion(a: *App) void {
    const s = a.active orelse return;
    if (s.thread.turns.items.len > 0) s.skipped = s.thread.turns.items.len - 1;
    a.redraw();
}

pub fn toggleTurn(a: *App, index: usize) void {
    const s = a.active orelse return;
    if (s.expanded.remove(index)) return;
    s.expanded.put(a.gpa, index, {}) catch {};
}

pub fn toggleStep(a: *App, s: *Session, turn: usize, step: usize) void {
    const k: u64 = (@as(u64, turn) << 32) | step;
    if (s.open_steps.remove(k)) return;
    s.open_steps.put(a.gpa, k, {}) catch {};
}

pub fn stepOpen(s: *const Session, turn: usize, step: usize) bool {
    return s.open_steps.contains((@as(u64, turn) << 32) | step);
}

pub fn removeQueued(a: *App, s: *Session, i: usize) void {
    if (i >= s.queue.items.len) return;
    s.queue.orderedRemove(i).deinit(a.gpa);
}

// ---------------------------------------------------------------------------
// Snapshots, off the main thread.

const SnapJob = struct {
    a: *App,
    key: u64,
    path: []u8,
    ended: bool,
    tree: ?[]u8 = null,
};

fn snapshot(a: *App, s: *Session, ended: bool) void {
    const ws = a.workspaceOf(s) orelse return;
    const job = a.gpa.create(SnapJob) catch return;
    job.* = .{ .a = a, .key = s.key, .path = a.gpa.dupe(u8, ws.path) catch return a.gpa.destroy(job), .ended = ended };
    jobs.spawn(SnapJob, job, snapWork, snapDone);
}

fn snapWork(j: *SnapJob) void {
    j.tree = git.snapshot(j.a.gpa, j.a.io, j.path);
}

fn snapDone(j: *SnapJob) void {
    const a = j.a;
    defer {
        a.gpa.free(j.path);
        a.gpa.destroy(j);
    }
    const s = a.byKey(j.key) orelse {
        if (j.tree) |t| a.gpa.free(t);
        return;
    };
    const tree = j.tree orelse return s.clearSnap();
    if (!j.ended) {
        s.clearSnap();
        s.snap = .{ .before = tree };
    } else if (s.snap) |*sn| {
        if (sn.after) |x| a.gpa.free(x);
        // A turn that changed nothing has nothing to restore.
        if (std.mem.eql(u8, sn.before, tree)) {
            a.gpa.free(tree);
            s.clearSnap();
        } else sn.after = tree;
    } else a.gpa.free(tree);
    a.redraw();
}

const RestoreJob = struct {
    a: *App,
    key: u64,
    path: []u8,
    before: []u8,
    after: []u8,
    err: ?[]const u8 = null,
};

/// Puts the files the last turn changed back as they were.
pub fn restoreTurn(a: *App) void {
    const s = a.active orelse return;
    const sn = s.snap orelse return;
    const after = sn.after orelse return;
    const ws = a.workspaceOf(s) orelse return;
    const job = a.gpa.create(RestoreJob) catch return;
    job.* = .{
        .a = a,
        .key = s.key,
        .path = a.gpa.dupe(u8, ws.path) catch return,
        .before = a.gpa.dupe(u8, sn.before) catch return,
        .after = a.gpa.dupe(u8, after) catch return,
    };
    jobs.spawn(RestoreJob, job, restoreWork, restoreDone);
}

fn restoreWork(j: *RestoreJob) void {
    j.err = git.restore(j.a.gpa, j.a.io, j.path, j.before, j.after);
}

fn restoreDone(j: *RestoreJob) void {
    const a = j.a;
    defer {
        if (j.err) |e| a.gpa.free(e);
        a.gpa.free(j.path);
        a.gpa.free(j.before);
        a.gpa.free(j.after);
        a.gpa.destroy(j);
    }
    if (a.byKey(j.key)) |s| {
        if (j.err) |e| s.setError(e) else {
            s.clearSnap();
            a.toast("Restored this turn's files");
        }
        if (a.workspaceOf(s)) |ws| sessions.refreshStatus(a, ws);
    }
    if (a.changes != null) @import("../views/changes.zig").refresh(a);
    a.redraw();
}
