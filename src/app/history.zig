//! A folder's sessions as an agent keeps them (ACP's `session/list`): those
//! started here and those started in the agent's own CLI (`claude`'s
//! `/resume` lists the same). Home's History tab shows them, an agent at a
//! time: it starts that agent on its own to ask (a session of another
//! agent, or none, may be open). One opened joins the sidebar and loads.
const std = @import("std");
const app_mod = @import("app.zig");
const state = @import("state.zig");
const sessions = @import("sessions.zig");
const agent = @import("agent.zig");
const rpc = @import("../acp/rpc.zig");
const json = @import("../acp/json.zig");
const proto = @import("../acp/proto.zig");
const npx = @import("../host/npx.zig");

const App = app_mod.App;
const Session = state.Session;
const Workspace = state.Workspace;

pub const Entry = struct {
    id: []const u8,
    title: []const u8,
    /// Milliseconds on the wall clock; 0 when the agent did not say.
    updated: i64,
};

/// The list for one folder and agent, a page at a time, and the agent
/// process that answers.
pub const State = struct {
    arena: ?std.heap.ArenaAllocator = null,
    path: []const u8 = "",
    agent: []const u8 = "",
    items: std.ArrayList(Entry) = .empty,
    /// Where the next page starts, when there is one.
    next: ?[]const u8 = null,
    loading: bool = false,
    err: ?[]const u8 = null,
    /// Untitled sessions (most never had a prompt) are listed too.
    show_untitled: bool = false,
    /// The agent the user picked for a folder's list (else `pick`'s).
    choice: [64]u8 = undefined,
    choice_len: usize = 0,
    choice_path: [512]u8 = undefined,
    choice_path_len: usize = 0,
    conn: ?*rpc.Conn = null,
    /// The agent answered `initialize`: it takes `session/list`.
    ready: bool = false,
    /// It takes `session/delete` too.
    can_delete: bool = false,
    /// The session a delete was asked for, and its title, while the dialog shows.
    doomed: [160]u8 = undefined,
    doomed_len: usize = 0,
    doomed_title: [160]u8 = undefined,
    doomed_title_len: usize = 0,

    /// Forgets the list and stops its agent; the pick and the toggle stay.
    pub fn deinit(h: *State) void {
        if (h.conn) |c| c.stop();
        if (h.arena) |*ar| ar.deinit();
        const keep = h.*;
        h.* = .{ .show_untitled = keep.show_untitled, .choice = keep.choice, .choice_len = keep.choice_len, .choice_path = keep.choice_path, .choice_path_len = keep.choice_path_len };
    }

    fn a(h: *State) std.mem.Allocator {
        return h.arena.?.allocator();
    }

    /// Whether it lists `w`'s sessions of `agent_id`.
    pub fn isFor(h: *const State, w: *const Workspace, agent_id: []const u8) bool {
        return h.arena != null and std.ascii.eqlIgnoreCase(h.path, w.path) and std.mem.eql(u8, h.agent, agent_id);
    }
};

/// The agent whose sessions the tab lists for `w`: the one picked, else
/// the agent of the folder's last session, else the one new sessions use.
pub fn pick(a: *App, w: *const Workspace) []const u8 {
    const h = &a.history;
    if (h.choice_len > 0 and std.ascii.eqlIgnoreCase(h.choice_path[0..h.choice_path_len], w.path)) return h.choice[0..h.choice_len];
    var best: ?*const Session = null;
    for (w.sessions.items) |s| {
        if (s.id == null) continue;
        if (best == null or s.updated > best.?.updated) best = s;
    }
    if (best) |s| return s.agent;
    return a.defaultAgent();
}

/// Lists another agent's sessions of `w`.
pub fn choose(a: *App, w: *const Workspace, agent_id: []const u8) void {
    const h = &a.history;
    const n = @min(agent_id.len, h.choice.len);
    @memcpy(h.choice[0..n], agent_id[0..n]);
    h.choice_len = n;
    const m = @min(w.path.len, h.choice_path.len);
    @memcpy(h.choice_path[0..m], w.path[0..m]);
    h.choice_path_len = m;
    a.redraw();
}

/// Asks for the first page (`more`: the next one) of `w`'s sessions of
/// the agent `pick` names, starting it when it is not running.
pub fn fetch(a: *App, w: *Workspace, more: bool) void {
    const h = &a.history;
    const agent_id = pick(a, w);
    if (!more or !h.isFor(w, agent_id)) {
        h.deinit();
        h.arena = .init(a.gpa);
        h.path = h.a().dupe(u8, w.path) catch "";
        h.agent = h.a().dupe(u8, agent_id) catch "";
    } else if (h.loading) return;
    h.loading = true;
    h.err = null;
    if (h.conn == null) return start(a, w);
    if (h.ready) list(a, more);
    a.redraw();
}

fn start(a: *App, w: *Workspace) void {
    const h = &a.history;
    const prof = a.store.agent(h.agent) orelse return failed(a, "There is no such agent in Settings.");
    if (prof.command.len == 0) return failed(a, "The agent has no command to start it.");
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const argv = npx.direct(arena.allocator(), a.io, a.env, prof.command) orelse prof.command;
    const conn = rpc.Conn.start(a.gpa, a.io, .{ .argv = argv, .cwd = w.path, .env = a.env }, .{ .ctx = a, .message = message, .exited = exited }) catch |e| {
        return failed(a, agent.startFailed(a, prof.name, argv[0], e));
    };
    h.conn = conn;
    h.ready = false;
    conn.request("initialize", .{
        .protocolVersion = 1,
        .clientCapabilities = .{ .fs = .{ .readTextFile = false, .writeTextFile = false }, .terminal = false },
        .clientInfo = .{ .name = "bm-relay", .title = "BM Relay", .version = agent.version },
    }, .{ .ctx = a, .func = initialized });
    a.redraw();
}

fn failed(a: *App, why: []const u8) void {
    const h = &a.history;
    h.loading = false;
    h.err = if (h.arena != null) h.a().dupe(u8, why) catch why else why;
    a.redraw();
}

fn initialized(ctx: ?*anyopaque, conn: *rpc.Conn, reply: rpc.Reply) void {
    const a: *App = @ptrCast(@alignCast(ctx.?));
    const h = &a.history;
    if (h.conn != conn) return;
    switch (reply) {
        .gone => return,
        .err => |e| return failed(a, e),
        .ok => |v| {
            var arena: std.heap.ArenaAllocator = .init(a.gpa);
            defer arena.deinit();
            const caps = proto.parseCapabilities(arena.allocator(), v);
            if (!caps.list) return failed(a, a.print("{s} does not list its sessions to other apps.", .{a.agentName(h.agent)}));
            h.can_delete = caps.delete;
        },
    }
    h.ready = true;
    list(a, false);
}

fn list(a: *App, more: bool) void {
    const h = &a.history;
    const conn = h.conn orelse return;
    conn.request("session/list", .{ .cwd = h.path, .cursor = if (more) h.next else null }, .{ .ctx = a, .func = listed });
}

/// Its agent asks nothing of the list: anything it does is answered no.
fn message(_: *anyopaque, conn: *rpc.Conn, msg: rpc.Incoming) void {
    if (msg.id) |id| conn.respondError(id, -32601, "Method not found");
}

fn exited(ctx: *anyopaque, conn: *rpc.Conn, why: []const u8) void {
    const a: *App = @ptrCast(@alignCast(ctx));
    const h = &a.history;
    if (h.conn != conn) return;
    h.conn = null;
    h.ready = false;
    if (h.loading) failed(a, why);
}

fn listed(ctx: ?*anyopaque, conn: *rpc.Conn, reply: rpc.Reply) void {
    const a: *App = @ptrCast(@alignCast(ctx.?));
    const h = &a.history;
    if (h.conn != conn or h.arena == null) return;
    h.loading = false;
    defer a.redraw();
    const v = switch (reply) {
        .gone => return,
        .err => |e| return failed(a, e),
        .ok => |v| v,
    };
    for (json.array(v, "sessions")) |x| {
        const id = json.str(x, "sessionId") orelse continue;
        h.items.append(h.a(), .{
            .id = h.a().dupe(u8, id) catch continue,
            .title = h.a().dupe(u8, json.strOr(x, "title", "")) catch "",
            .updated = parseIso(json.strOr(x, "updatedAt", "")),
        }) catch {};
    }
    h.next = if (json.str(v, "nextCursor")) |n| h.a().dupe(u8, n) catch null else null;
}

/// Asks to delete entry `e` (the dialog says what it means first).
pub fn askDelete(a: *App, e: Entry) void {
    const h = &a.history;
    const n = @min(e.id.len, h.doomed.len);
    @memcpy(h.doomed[0..n], e.id[0..n]);
    h.doomed_len = n;
    const title = if (e.title.len > 0) e.title else "Untitled session";
    const m = @min(title.len, h.doomed_title.len);
    @memcpy(h.doomed_title[0..m], title[0..m]);
    h.doomed_title_len = m;
    a.dialog = .delete_history;
    a.dialog_state.show();
    a.redraw();
}

pub fn doomedTitle(a: *const App) []const u8 {
    return a.history.doomed_title[0..a.history.doomed_title_len];
}

/// Deletes the asked-for session from its agent (`session/delete`), and
/// from this app: the sidebar, the saved list.
pub fn deleteDoomed(a: *App) void {
    const purge = @import("purge.zig");
    const h = &a.history;
    const id = h.doomed[0..h.doomed_len];
    // In the sidebar: deleted as from there, the agent's store too.
    if (a.byId(id)) |s| {
        sessions.deleteSession(a, s);
        return drop(h, id);
    }
    if (a.store.session(id) != null) sessions.deleteArchived(a, id);
    // Claude Code's files are removed here: all of them, on disk.
    if (purge.isClaude(a, h.agent)) {
        purge.claudeFiles(a, id);
        return drop(h, id);
    }
    const conn = h.conn orelse return a.failToast("The agent stopped: open History again.");
    const op = a.gpa.create(DeleteOp) catch return;
    op.* = .{ .a = a };
    @memcpy(op.id[0..id.len], id);
    op.len = id.len;
    conn.request("session/delete", .{ .sessionId = id }, .{ .ctx = op, .func = deleted });
}

const DeleteOp = struct { a: *App, id: [160]u8 = undefined, len: usize = 0 };

/// Takes session `id` off the list.
fn drop(h: *State, id: []const u8) void {
    if (h.arena == null) return;
    var i: usize = 0;
    while (i < h.items.items.len) : (i += 1) if (std.mem.eql(u8, h.items.items[i].id, id)) {
        _ = h.items.orderedRemove(i);
        return;
    };
}

fn deleted(ctx: ?*anyopaque, conn: *rpc.Conn, reply: rpc.Reply) void {
    const op: *DeleteOp = @ptrCast(@alignCast(ctx.?));
    const a = op.a;
    defer a.gpa.destroy(op);
    const h = &a.history;
    switch (reply) {
        .gone => return,
        .err => |e| return a.failToast(a.print("Not deleted: {s}", .{e})),
        .ok => {},
    }
    if (h.conn == conn) drop(h, op.id[0..op.len]);
    a.toast("Deleted");
}

/// A title an agent gives a session no prompt has named yet: OpenCode's
/// "New session - 2026-11-23T03:30:29.424Z", an empty one. Such sessions
/// pile up and show nothing.
pub fn untitled(title: []const u8) bool {
    if (title.len == 0) return true;
    const prefix = "New session - ";
    return std.mem.startsWith(u8, title, prefix) and parseIso(title[prefix.len..]) != 0;
}

/// Opens entry `e` of `w`: the sidebar's session when it is there (or
/// archived), else a new one in the sidebar, which loads from the agent.
pub fn open(a: *App, w: *Workspace, e: Entry) void {
    if (a.byId(e.id)) |s| return sessions.select(a, s);
    if (a.store.session(e.id)) |rec| if (rec.hidden) return sessions.restoreSession(a, w, e.id);
    a.store.putSession(.{ .id = e.id, .agent = a.history.agent, .cwd = w.path, .title = e.title, .updated = e.updated });
    a.store.save();
    sessions.listSaved(a, w);
    a.home_tab = .recent;
    if (a.byId(e.id)) |s| sessions.select(a, s);
}

/// "2026-11-23T03:30:38.113Z" in milliseconds since 1970; 0 when unread.
pub fn parseIso(s: []const u8) i64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or s[10] != 'T') return 0;
    const n = struct {
        fn f(t: []const u8) i64 {
            return std.fmt.parseInt(i64, t, 10) catch -1;
        }
    }.f;
    const y = n(s[0..4]);
    const mo = n(s[5..7]);
    const d = n(s[8..10]);
    const hh = n(s[11..13]);
    const mi = n(s[14..16]);
    const ss = n(s[17..19]);
    if (y < 1970 or mo < 1 or mo > 12 or d < 1 or hh < 0 or mi < 0 or ss < 0) return 0;
    // Days from the civil date (Howard Hinnant's algorithm).
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(mo + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return ((days * 24 + hh) * 60 + mi) * 60_000 + ss * 1000;
}

test "untitled sessions" {
    try std.testing.expect(untitled("New session - 2026-11-23T03:30:29.424Z"));
    try std.testing.expect(untitled(""));
    try std.testing.expect(!untitled("Acknowledgment request"));
    try std.testing.expect(!untitled("New session - about the login form"));
}

test "an ISO time in milliseconds" {
    try std.testing.expectEqual(@as(i64, 0), parseIso("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 1_795_000_000_000), parseIso("2026-11-18T11:06:40.000Z"));
    try std.testing.expectEqual(@as(i64, 0), parseIso("yesterday"));
}
