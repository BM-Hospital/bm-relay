//! Settings → Storage: what an agent keeps of its sessions on this computer,
//! by project, and freeing it: a project's sessions older than so many
//! days, or all of them; or every project's. A session open in the app
//! stays.
//!
//! Claude Code's files are read and removed here (`claude_files.zig`), off
//! the main thread, each session weighed. Codex and OpenCode keep theirs in
//! databases: the agent itself, started on its own, lists them
//! (`session/list`, every folder's) and deletes them (`session/delete`);
//! their store is weighed as a whole (`agent_stores.zig`).
const std = @import("std");
const app_mod = @import("app.zig");
const sessions = @import("sessions.zig");
const purge = @import("purge.zig");
const agent = @import("agent.zig");
const history = @import("history.zig");
const rpc = @import("../acp/rpc.zig");
const json = @import("../acp/json.zig");
const proto = @import("../acp/proto.zig");
const npx = @import("../host/npx.zig");
const claude_files = @import("../host/claude_files.zig");
const agent_stores = @import("../host/agent_stores.zig");
const jobs = @import("../host/jobs.zig");

const App = app_mod.App;

pub const Kind = enum {
    claude,
    codex,
    opencode,

    pub fn title(k: Kind) []const u8 {
        return switch (k) {
            .claude => "Claude Code",
            .codex => "Codex",
            .opencode => "OpenCode",
        };
    }

    fn store(k: Kind) agent_stores.Kind {
        return switch (k) {
            .codex => .codex,
            else => .opencode,
        };
    }
};

/// A session an agent listed, while it lists.
const Found = struct { id: []const u8, cwd: []const u8, updated: i64 };

pub const State = struct {
    kind: Kind = .claude,
    /// The last scan, in its own arena.
    arena: ?std.heap.ArenaAllocator = null,
    scan: ?claude_files.Scan = null,
    /// The store's folder, as scanned.
    root: []const u8 = "",
    loading: bool = false,
    deleting: bool = false,
    err: ?[]const u8 = null,
    /// Counts scans: one that comes back after another began is dropped.
    gen: u32 = 0,
    /// The deletion the dialog asks about: a project (null: all of them),
    /// sessions older than `days` (0: all), how many and how much.
    plan_project: ?usize = null,
    plan_days: u32 = 0,
    plan_count: usize = 0,
    plan_bytes: u64 = 0,
    /// The project whose "Free space" menu is open.
    menu_for: usize = 0,

    // Codex's and OpenCode's: the agent, started to list and delete.
    conn: ?*rpc.Conn = null,
    ready: bool = false,
    agent: [64]u8 = undefined,
    agent_len: usize = 0,
    /// The scan being made: the sessions listed so far, and the parts not
    /// back yet (the list, the store's weight).
    next: ?std.heap.ArenaAllocator = null,
    found: std.ArrayList(Found) = .empty,
    waiting: u8 = 0,
    pages: u32 = 0,
    weight: agent_stores.Weight = .{},
    /// The sessions it is asked to delete, one at a time; how it went.
    queue: std.ArrayList([]u8) = .empty,
    done: usize = 0,
    failed: usize = 0,
    /// The store's sessions' weight before deleting: the next scan says
    /// what was freed.
    before: ?u64 = null,

    /// Each session's bytes are known: Claude Code's files.
    pub fn sized(s: *const State) bool {
        return s.kind == .claude;
    }

    pub fn agentId(s: *const State) []const u8 {
        return s.agent[0..s.agent_len];
    }

    pub fn deinit(s: *State) void {
        if (s.arena) |*ar| ar.deinit();
        s.arena = null;
        s.scan = null;
        s.root = "";
        if (s.next) |*ar| ar.deinit();
        s.next = null;
        s.found = .empty;
        s.waiting = 0;
    }

    /// Also stops its agent and drops what it was to delete.
    pub fn deinitAll(s: *State, gpa: std.mem.Allocator) void {
        s.deinit();
        if (s.conn) |c| c.stop();
        s.conn = null;
        s.ready = false;
        for (s.queue.items) |id| gpa.free(id);
        s.queue.deinit(gpa);
        s.queue = .empty;
    }
};

/// The agent in Settings that is `kind` (Claude Code, Codex, OpenCode).
pub fn agentFor(a: *App, kind: Kind) ?[]const u8 {
    for (a.store.data.agents) |ag| {
        if (ag.command.len == 0) continue;
        const is = switch (kind) {
            .claude => agent.runsClaudeCode(ag.command),
            .codex => for (ag.command) |arg| {
                if (std.mem.indexOf(u8, arg, "codex") != null) break true;
            } else false,
            .opencode => std.mem.indexOf(u8, std.fs.path.basename(ag.command[0]), "opencode") != null,
        };
        if (is) return ag.id;
    }
    return null;
}

/// Shows `kind`'s store instead.
pub fn choose(a: *App, kind: Kind) void {
    const st = &a.storage;
    if (st.kind == kind or st.deleting) return;
    const gen = st.gen +% 1;
    st.deinitAll(a.gpa);
    st.* = .{ .kind = kind, .gen = gen };
    refresh(a);
}

/// Scans the store again, unless it is being scanned or emptied.
pub fn refresh(a: *App) void {
    const st = &a.storage;
    if (st.loading or st.deleting) return;
    st.loading = true;
    st.err = null;
    st.gen +%= 1;
    defer a.redraw();
    if (st.kind == .claude) {
        const j = a.gpa.create(ScanJob) catch return;
        j.* = .{ .a = a, .gen = st.gen, .arena = .init(a.gpa) };
        jobs.spawn(ScanJob, j, ScanJob.work, ScanJob.done);
        return;
    }
    const id = agentFor(a, st.kind) orelse return failed(a, a.print("{s} is not among the agents in Settings.", .{st.kind.title()}));
    const n = @min(id.len, st.agent.len);
    @memcpy(st.agent[0..n], id[0..n]);
    st.agent_len = n;
    if (st.next) |*ar| ar.deinit();
    st.next = .init(a.gpa);
    st.found = .empty;
    st.pages = 0;
    st.waiting = 2;
    const w = a.gpa.create(WeighJob) catch return;
    w.* = .{ .a = a, .gen = st.gen, .kind = st.kind.store(), .arena = .init(a.gpa) };
    jobs.spawn(WeighJob, w, WeighJob.work, WeighJob.done);
    if (st.conn == null) start(a) else if (st.ready) list(a, null);
}

fn failed(a: *App, why: []const u8) void {
    const st = &a.storage;
    st.loading = false;
    st.err = why;
    if (st.next) |*ar| ar.deinit();
    st.next = null;
    st.waiting = 0;
    a.redraw();
}

const ScanJob = struct {
    a: *App,
    gen: u32,
    arena: std.heap.ArenaAllocator,
    root: []const u8 = "",
    scan: claude_files.Scan = .{},

    fn work(j: *ScanJob) void {
        const ar = j.arena.allocator();
        j.root = claude_files.root(ar, j.a.env) orelse return;
        j.scan = claude_files.scan(ar, j.a.io, j.root);
    }

    fn done(j: *ScanJob) void {
        const a = j.a;
        defer a.gpa.destroy(j);
        const st = &a.storage;
        if (st.gen != j.gen) return j.arena.deinit();
        st.deinit();
        st.arena = j.arena;
        st.scan = j.scan;
        st.root = j.root;
        st.loading = false;
        a.redraw();
    }
};

const WeighJob = struct {
    a: *App,
    gen: u32,
    kind: agent_stores.Kind,
    arena: std.heap.ArenaAllocator,
    weight: agent_stores.Weight = .{},

    fn work(j: *WeighJob) void {
        const ar = j.arena.allocator();
        const base = agent_stores.root(ar, j.a.env, j.kind) orelse return;
        j.weight = agent_stores.weigh(ar, j.a.io, base, j.kind);
    }

    fn done(j: *WeighJob) void {
        const a = j.a;
        defer {
            j.arena.deinit();
            a.gpa.destroy(j);
        }
        const st = &a.storage;
        if (st.gen != j.gen or st.next == null or st.waiting == 0) return;
        st.weight = j.weight;
        st.weight.root = st.next.?.allocator().dupe(u8, j.weight.root) catch "";
        partDone(a);
    }
};

// Codex's and OpenCode's sessions, from the agent.

fn start(a: *App) void {
    const st = &a.storage;
    const prof = a.store.agent(st.agentId()) orelse return failed(a, "There is no such agent in Settings.");
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const argv = npx.direct(arena.allocator(), a.io, a.env, prof.command) orelse prof.command;
    const cwd = a.env.get("USERPROFILE") orelse a.env.get("HOME") orelse ".";
    const conn = rpc.Conn.start(a.gpa, a.io, .{ .argv = argv, .cwd = cwd, .env = a.env }, .{ .ctx = a, .message = message, .exited = exited }) catch |e| {
        return failed(a, agent.startFailed(a, prof.name, argv[0], e));
    };
    st.conn = conn;
    st.ready = false;
    conn.request("initialize", .{
        .protocolVersion = 1,
        .clientCapabilities = .{ .fs = .{ .readTextFile = false, .writeTextFile = false }, .terminal = false },
        .clientInfo = .{ .name = "bm-agent", .title = "BM Coding Agent", .version = agent.version },
    }, .{ .ctx = a, .func = initialized });
}

fn initialized(ctx: ?*anyopaque, conn: *rpc.Conn, reply: rpc.Reply) void {
    const a: *App = @ptrCast(@alignCast(ctx.?));
    const st = &a.storage;
    if (st.conn != conn) return;
    switch (reply) {
        .gone => return,
        .err => |e| return failed(a, a.print("{s}", .{e})),
        .ok => |v| {
            var arena: std.heap.ArenaAllocator = .init(a.gpa);
            defer arena.deinit();
            const caps = proto.parseCapabilities(arena.allocator(), v);
            if (!caps.list or !caps.delete) return failed(a, a.print("This {s} does not list or delete its sessions for other apps: update it.", .{st.kind.title()}));
        },
    }
    st.ready = true;
    if (st.loading) list(a, null);
}

/// Every folder's sessions, a page at a time.
fn list(a: *App, cursor: ?[]const u8) void {
    const st = &a.storage;
    const conn = st.conn orelse return;
    conn.request("session/list", .{ .cursor = cursor }, .{ .ctx = a, .func = listed });
}

fn listed(ctx: ?*anyopaque, conn: *rpc.Conn, reply: rpc.Reply) void {
    const a: *App = @ptrCast(@alignCast(ctx.?));
    const st = &a.storage;
    if (st.conn != conn or st.next == null) return;
    const v = switch (reply) {
        .gone => return,
        .err => |e| return failed(a, a.print("{s}", .{e})),
        .ok => |v| v,
    };
    const ar = st.next.?.allocator();
    for (json.array(v, "sessions")) |x| {
        const id = json.str(x, "sessionId") orelse continue;
        st.found.append(ar, .{
            .id = ar.dupe(u8, id) catch continue,
            .cwd = ar.dupe(u8, json.strOr(x, "cwd", "")) catch "",
            .updated = history.parseIso(json.strOr(x, "updatedAt", "")),
        }) catch {};
    }
    st.pages += 1;
    if (json.str(v, "nextCursor")) |n| if (st.pages < 500) return list(a, n);
    partDone(a);
}

/// One part of the scan is back; with both, the scan is made: the
/// sessions by folder, the most first, each folder's oldest first.
fn partDone(a: *App) void {
    const st = &a.storage;
    st.waiting -|= 1;
    if (st.waiting > 0) return;
    var next = st.next orelse return;
    st.next = null;
    const ar = next.allocator();
    var projects: std.ArrayList(claude_files.Project) = .empty;
    var lists: std.ArrayList(std.ArrayList(claude_files.StoredSession)) = .empty;
    for (st.found.items) |f| {
        const cwd = if (f.cwd.len > 0) f.cwd else "(no folder)";
        const i = for (projects.items, 0..) |p, i| {
            if (std.ascii.eqlIgnoreCase(p.cwd, cwd)) break i;
        } else blk: {
            projects.append(ar, .{ .dir = cwd, .cwd = cwd, .sessions = &.{}, .bytes = 0 }) catch continue;
            lists.append(ar, .empty) catch continue;
            break :blk projects.items.len - 1;
        };
        lists.items[i].append(ar, .{ .id = f.id, .bytes = 0, .modified = f.updated }) catch {};
    }
    for (projects.items, lists.items) |*p, l| {
        std.mem.sort(claude_files.StoredSession, l.items, {}, struct {
            fn lt(_: void, x: claude_files.StoredSession, y: claude_files.StoredSession) bool {
                return x.modified < y.modified;
            }
        }.lt);
        p.sessions = l.items;
    }
    std.mem.sort(claude_files.Project, projects.items, {}, struct {
        fn lt(_: void, x: claude_files.Project, y: claude_files.Project) bool {
            return x.sessions.len > y.sessions.len;
        }
    }.lt);
    if (st.arena) |*old| old.deinit();
    st.arena = next;
    st.scan = .{ .projects = projects.items, .total = st.weight.sessions, .sessions_bytes = st.weight.sessions };
    st.root = st.weight.root;
    st.found = .empty;
    st.loading = false;
    if (st.before) |b| {
        st.before = null;
        var buf: [32]u8 = undefined;
        const n = st.done;
        const freed = b -| st.weight.sessions;
        const what = a.print("Deleted {d} session{s}{s}", .{ n, if (n == 1) "" else "s", if (st.failed > 0) a.print(", {d} kept by {s}", .{ st.failed, st.kind.title() }) else "" });
        a.toast(if (freed > 0) a.print("{s} · {s} freed", .{ what, purge.size(&buf, freed) }) else what);
    }
    a.redraw();
}

/// Its agent asks nothing here: anything it does is answered no.
fn message(_: *anyopaque, conn: *rpc.Conn, msg: rpc.Incoming) void {
    if (msg.id) |id| conn.respondError(id, -32601, "Method not found");
}

fn exited(ctx: *anyopaque, conn: *rpc.Conn, why: []const u8) void {
    const a: *App = @ptrCast(@alignCast(ctx));
    const st = &a.storage;
    if (st.conn != conn) return;
    st.conn = null;
    st.ready = false;
    if (st.loading) failed(a, a.print("{s} stopped: {s}", .{ st.kind.title(), why }));
    if (st.deleting) {
        st.failed += st.queue.items.len;
        for (st.queue.items) |id| a.gpa.free(id);
        st.queue.clearRetainingCapacity();
        deletedAll(a);
    }
}

// Measuring and deleting.

/// Days ago, in milliseconds since 1970.
fn before(a: *App, days: u32) i64 {
    return if (days == 0) std.math.maxInt(i64) else a.now() - @as(i64, days) * 86_400_000;
}

/// Whether the app has session `id` open: it stays.
fn inUse(a: *App, id: []const u8) bool {
    const s = a.byId(id) orelse return false;
    return s.conn != null or s.thread.running();
}

/// How many of project `p`'s sessions (null: every project's) are older
/// than `days` (0: all), and the bytes they take: those it would delete.
pub fn measure(a: *App, p: ?usize, days: u32) struct { count: usize, bytes: u64 } {
    const sc = a.storage.scan orelse return .{ .count = 0, .bytes = 0 };
    const cut = before(a, days);
    var count: usize = 0;
    var bytes: u64 = 0;
    for (sc.projects, 0..) |proj, i| {
        if (p) |only| if (only != i) continue;
        for (proj.sessions) |ses| {
            if (ses.modified >= cut or inUse(a, ses.id)) continue;
            count += 1;
            bytes += ses.bytes;
        }
    }
    return .{ .count = count, .bytes = bytes };
}

/// Asks (the dialog) to delete what `measure` says.
pub fn ask(a: *App, p: ?usize, days: u32) void {
    const m = measure(a, p, days);
    if (m.count == 0) return a.toast("Nothing to delete there");
    const st = &a.storage;
    st.plan_project = p;
    st.plan_days = days;
    st.plan_count = m.count;
    st.plan_bytes = m.bytes;
    a.dialog = .purge_storage;
    a.dialog_state.show();
    a.redraw();
}

/// Deletes what the dialog asked about: the sessions from the agent's
/// store, and from this app; then scans again.
pub fn run(a: *App) void {
    const st = &a.storage;
    const sc = st.scan orelse return;
    if (st.deleting or st.loading) return;
    if (st.kind != .claude and !st.ready) return a.failToast(a.print("{s} stopped: open Storage again.", .{st.kind.title()}));
    const cut = before(a, st.plan_days);
    var ids: std.ArrayList([]u8) = .empty;
    for (sc.projects, 0..) |proj, i| {
        if (st.plan_project) |only| if (only != i) continue;
        for (proj.sessions) |ses| {
            if (ses.modified >= cut or inUse(a, ses.id)) continue;
            ids.append(a.gpa, a.gpa.dupe(u8, ses.id) catch continue) catch {};
        }
    }
    // Out of the app first: none of them is open.
    for (ids.items) |id| {
        if (a.byId(id)) |s| sessions.removeSession(a, s);
        if (a.store.session(id) != null) sessions.deleteArchived(a, id);
    }
    st.deleting = true;
    defer a.redraw();
    if (st.kind == .claude) {
        const j = a.gpa.create(PurgeJob) catch return;
        j.* = .{ .a = a, .ids = ids, .root = a.gpa.dupe(u8, st.root) catch return a.gpa.destroy(j) };
        jobs.spawn(PurgeJob, j, PurgeJob.work, PurgeJob.done);
        return;
    }
    st.queue = ids;
    st.done = 0;
    st.failed = 0;
    st.before = sc.sessions_bytes;
    deleteNext(a);
}

/// Asks the agent to delete the next session queued.
fn deleteNext(a: *App) void {
    const st = &a.storage;
    const conn = st.conn orelse return;
    if (st.queue.items.len == 0) return deletedAll(a);
    const id = st.queue.items[st.queue.items.len - 1];
    conn.request("session/delete", .{ .sessionId = id }, .{ .ctx = a, .func = deletedOne });
}

fn deletedOne(ctx: ?*anyopaque, conn: *rpc.Conn, reply: rpc.Reply) void {
    const a: *App = @ptrCast(@alignCast(ctx.?));
    const st = &a.storage;
    if (st.conn != conn or st.queue.items.len == 0) return;
    switch (reply) {
        .gone => return,
        .err => st.failed += 1,
        .ok => st.done += 1,
    }
    a.gpa.free(st.queue.pop().?);
    a.redraw();
    deleteNext(a);
}

/// The agent deleted what it was asked to: scan again, which says what
/// was freed.
fn deletedAll(a: *App) void {
    const st = &a.storage;
    st.deleting = false;
    if (st.conn == null) {
        st.before = null;
        a.failToast(a.print("{s} stopped: {d} deleted, {d} not", .{ st.kind.title(), st.done, st.failed }));
        return;
    }
    refresh(a);
}

/// The progress of a deletion by the agent: "12 of 58".
pub fn progress(a: *App) ?[]const u8 {
    const st = &a.storage;
    if (!st.deleting or st.kind == .claude) return null;
    const total = st.done + st.failed + st.queue.items.len;
    return a.print("Deleting {d} of {d}…", .{ st.done + st.failed + 1, total });
}

const PurgeJob = struct {
    a: *App,
    root: []u8,
    ids: std.ArrayList([]u8) = .empty,
    freed: u64 = 0,

    fn work(j: *PurgeJob) void {
        var arena: std.heap.ArenaAllocator = .init(j.a.gpa);
        defer arena.deinit();
        for (j.ids.items) |id| {
            j.freed += claude_files.remove(arena.allocator(), j.a.io, j.root, id);
            _ = arena.reset(.retain_capacity);
        }
    }

    fn done(j: *PurgeJob) void {
        const a = j.a;
        defer {
            for (j.ids.items) |id| a.gpa.free(id);
            j.ids.deinit(a.gpa);
            a.gpa.free(j.root);
            a.gpa.destroy(j);
        }
        var buf: [32]u8 = undefined;
        a.toast(a.print("Deleted {d} session{s} · {s} freed", .{ j.ids.items.len, if (j.ids.items.len == 1) "" else "s", purge.size(&buf, j.freed) }));
        a.storage.deleting = false;
        refresh(a);
    }
};
