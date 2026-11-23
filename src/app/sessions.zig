//! Folders and the sessions in them: opening a folder, new sessions,
//! selecting, archiving, restoring and renaming them, the split view, and
//! what git says about each folder.
const std = @import("std");
const myzig = @import("myzig");
const app_mod = @import("app.zig");
const state = @import("state.zig");
const agent = @import("agent.zig");
const git = @import("../host/git.zig");
const pickers = @import("../host/pickers.zig");
const jobs = @import("../host/jobs.zig");
const tools = @import("../model/tools.zig");
const store_mod = @import("../host/store.zig");

const App = app_mod.App;
const Session = state.Session;
const Workspace = state.Workspace;

/// Adds the folders the store lists and their sessions, as the app starts.
pub fn loadAll(a: *App) void {
    for (a.store.data.workspaces) |p| {
        var dir = std.Io.Dir.cwd().openDir(a.io, p, .{}) catch continue;
        dir.close(a.io);
        _ = addWorkspace(a, p, false);
    }
}

fn addWorkspace(a: *App, path: []const u8, save: bool) *Workspace {
    for (a.workspaces.items) |w| if (std.ascii.eqlIgnoreCase(w.path, path)) return w;
    const w = Workspace.create(a.gpa, path);
    a.workspaces.append(a.gpa, w) catch {};
    if (save) {
        a.store.addWorkspace(path);
        a.store.save();
    }
    listSaved(a, w);
    refreshFolder(a, w);
    return w;
}

/// The sessions started in this folder, newest first; archived ones too,
/// marked as such by the store.
pub fn listSaved(a: *App, w: *Workspace) void {
    for (a.store.data.sessions) |rec| {
        if (!std.ascii.eqlIgnoreCase(rec.cwd, w.path) or rec.hidden) continue;
        if (a.byId(rec.id) != null) continue;
        const s = Session.create(a.gpa, a.newKey(), rec.agent);
        s.setId(rec.id);
        s.saved_title = a.gpa.dupe(u8, if (rec.title.len > 0) rec.title else "Untitled session") catch null;
        s.updated = rec.updated;
        s.loaded = false;
        w.sessions.append(a.gpa, s) catch {};
    }
    sortSessions(w);
}

fn sortSessions(w: *Workspace) void {
    std.mem.sort(*Session, w.sessions.items, {}, struct {
        fn lt(_: void, x: *Session, y: *Session) bool {
            // Sessions not yet sent anything stay at the top.
            const kx: i64 = if (x.updated == 0) std.math.maxInt(i64) else x.updated;
            const ky: i64 = if (y.updated == 0) std.math.maxInt(i64) else y.updated;
            return kx > ky;
        }
    }.lt);
}

/// The archived sessions of a folder, from the store.
pub fn archived(a: *const App, w: *const Workspace, out: *std.ArrayList(*const store_mod.Saved), gpa: std.mem.Allocator) void {
    for (a.store.data.sessions) |*rec| if (rec.hidden and std.ascii.eqlIgnoreCase(rec.cwd, w.path)) out.append(gpa, rec) catch {};
    std.mem.sort(*const store_mod.Saved, out.items, {}, struct {
        fn lt(_: void, x: *const store_mod.Saved, y: *const store_mod.Saved) bool {
            return x.updated > y.updated;
        }
    }.lt);
}

// ---------------------------------------------------------------------------
// What the folder holds: its branch, skills and files, and what changed.

const FolderJob = struct {
    a: *App,
    w: *Workspace,
    path: []u8,
    home: []const u8,
    arena: std.heap.ArenaAllocator,
    branch: ?[]u8 = null,
    skills: []pickers.Skill = &.{},
    files: []const []const u8 = &.{},
    status: ?[]git.Change = null,
    with_status: bool,
};

fn alive(a: *App, w: *Workspace) bool {
    for (a.workspaces.items) |x| if (x == w) return true;
    return false;
}

fn startFolderJob(a: *App, w: *Workspace, with_status: bool) void {
    const job = a.gpa.create(FolderJob) catch return;
    job.* = .{ .a = a, .w = w, .path = a.gpa.dupe(u8, w.path) catch return a.gpa.destroy(job), .home = a.home, .arena = .init(a.gpa), .with_status = with_status };
    jobs.spawn(FolderJob, job, folderWork, folderDone);
}

/// Looks at a folder again: branch, skills, files.
pub fn refreshFolder(a: *App, w: *Workspace) void {
    startFolderJob(a, w, true);
}

/// What git says changed, and the lines each finished turn moved.
pub fn refreshStatus(a: *App, w: *Workspace) void {
    startFolderJob(a, w, true);
}

fn folderWork(j: *FolderJob) void {
    const gpa = j.a.gpa;
    const io = j.a.io;
    j.branch = git.branch(gpa, io, j.path);
    const ar = j.arena.allocator();
    j.skills = pickers.skills(ar, io, j.path, j.home);
    const files = git.tracked(gpa, io, j.path);
    defer git.freeList(gpa, files);
    if (ar.alloc([]const u8, files.len)) |kept| {
        for (files, kept) |f, *k| k.* = ar.dupe(u8, f) catch "";
        j.files = kept;
    } else |_| {}
    if (j.with_status) j.status = git.status(gpa, io, j.path);
}

fn folderDone(j: *FolderJob) void {
    const a = j.a;
    defer {
        a.gpa.free(j.path);
        a.gpa.destroy(j);
    }
    if (!alive(a, j.w)) {
        if (j.branch) |b| a.gpa.free(b);
        if (j.status) |st| git.freeChanges(a.gpa, st);
        j.arena.deinit();
        return;
    }
    const w = j.w;
    w.setBranch(j.branch);
    w.found.deinit();
    w.found = j.arena;
    w.skills = j.skills;
    w.files = j.files;
    if (j.status) |st| {
        w.setStatus(st);
        tallyTurns(a, w);
    }
    a.redraw();
}

/// Adds what finished turns changed to each session's running count.
fn tallyTurns(a: *App, w: *Workspace) void {
    var dirty = false;
    for (w.sessions.items) |s| {
        if (s.thread.running()) continue;
        const t = s.tally orelse continue;
        const id = s.id orelse {
            s.clearTally();
            continue;
        };
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        const from = @min(t.from, s.thread.turns.items.len);
        const d = tools.delta(arena.allocator(), s.thread.turns.items[from..], w.path, t.before, w.status);
        s.clearTally();
        if (d[0] + d[1] == 0) continue;
        if (a.store.sessionMut(id)) |rec| {
            rec.added += d[0];
            rec.removed += d[1];
            dirty = true;
        }
    }
    if (dirty) a.store.save();
}

// ---------------------------------------------------------------------------
// Folders.

/// Asks for a folder, adds it, and starts a session in it.
pub fn openFolder(a: *App) void {
    const paths = (myzig.dialog.open(a.gpa, .{ .title = "Open a folder", .button = "Open", .files = false, .directories = true }) catch null) orelse return;
    defer myzig.dialog.freePaths(a.gpa, paths);
    if (paths.len == 0) return;
    openPath(a, paths[0]);
}

pub fn openPath(a: *App, path: []const u8) void {
    const w = addWorkspace(a, path, true);
    newSessionIn(a, w);
}

pub fn removeFolder(a: *App, index: usize) void {
    if (index >= a.workspaces.items.len) return;
    const w = a.workspaces.orderedRemove(index);
    for (w.sessions.items) |s| {
        if (a.active == s) a.active = null;
        if (a.beside == s) a.beside = null;
    }
    a.store.removeWorkspace(w.path);
    a.store.save();
    w.destroy();
    if (a.folder) |f| {
        if (f == index) a.folder = if (a.workspaces.items.len > 0) 0 else null else if (f > index) a.folder = f - 1;
    }
    a.dialog = null;
    a.redraw();
}

// ---------------------------------------------------------------------------
// Sessions.

pub fn newSession(a: *App) void {
    if (a.workspace()) |w| return newSessionIn(a, w);
    if (a.workspaces.items.len > 0) return newSessionIn(a, a.workspaces.items[0]);
    openFolder(a);
}

/// Shows the folder's empty session, or starts one on the default agent.
pub fn newSessionIn(a: *App, w: *Workspace) void {
    a.page = .session;
    a.folder = a.workspaceIndex(w);
    for (w.sessions.items) |s| if (s.isEmpty() and std.mem.eql(u8, s.agent, a.defaultAgent())) {
        show(a, s);
        if (s.conn == null and !s.opening and s.err == null) agent.connect(a, s, w, .new);
        return;
    };
    const s = Session.create(a.gpa, a.newKey(), a.defaultAgent());
    w.sessions.insert(a.gpa, 0, s) catch return s.destroy();
    show(a, s);
    agent.connect(a, s, w, .new);
    a.redraw();
}

fn show(a: *App, s: *Session) void {
    a.active = s;
    if (a.workspaceOf(s)) |w| a.folder = a.workspaceIndex(w);
    a.to_end = true;
}

pub fn select(a: *App, s: *Session) void {
    a.recent.insert(a.gpa, 0, s.key) catch {};
    var i: usize = 1;
    while (i < a.recent.items.len) {
        if (a.recent.items[i] == s.key) _ = a.recent.orderedRemove(i) else i += 1;
    }
    if (a.recent.items.len > state.warm) a.recent.shrinkRetainingCapacity(state.warm);
    agent.restIdle(a, .{ a.active, s });
    show(a, s);
    a.page = .session;
    a.picker = null;
    load(a, s);
    if (a.beside == s) a.beside = null;
    if (a.changes != null) @import("../views/changes.zig").refresh(a);
    a.redraw();
}

/// Opens a session listed from before: its agent starts and replays it.
pub fn load(a: *App, s: *Session) void {
    if (s.loaded and (s.conn != null or s.opening or s.err != null)) return;
    if (s.conn != null or s.opening) return;
    const w = a.workspaceOf(s) orelse return;
    s.loaded = true;
    agent.connect(a, s, w, if (s.id != null) .load else .new);
}

/// Archives a session: it leaves the list, and Home's Archived tab holds it.
pub fn removeSession(a: *App, s: *Session) void {
    const w = a.workspaceOf(s) orelse return;
    const i = w.indexOf(s) orelse return;
    if (s.id) |id| {
        if (a.store.sessionMut(id)) |rec| {
            rec.hidden = true;
            if (rec.title.len == 0) rec.title = a.store.dupe(a.label(s));
        }
        a.store.save();
    }
    _ = w.sessions.orderedRemove(i);
    if (a.active == s) a.active = null;
    if (a.beside == s) a.beside = null;
    if (a.menus.row_for == s) a.menus.row_for = null;
    for (a.recent.items, 0..) |k, ri| if (k == s.key) {
        _ = a.recent.orderedRemove(ri);
        break;
    };
    s.destroy();
    a.dialog = null;
    a.redraw();
}

pub fn restoreSession(a: *App, w: *Workspace, id: []const u8) void {
    if (a.store.sessionMut(id)) |rec| rec.hidden = false;
    a.store.save();
    listSaved(a, w);
    a.home_tab = .recent;
    if (a.byId(id)) |s| select(a, s);
}

/// Deletes an archived session for good: from this app, and Claude Code's
/// files of it (`purge.zig`).
pub fn purgeArchived(a: *App, id: []const u8) void {
    const purge = @import("purge.zig");
    const rec = a.store.session(id) orelse return;
    const claude = purge.isClaude(a, rec.agent);
    var buf: [64]u8 = undefined;
    const n = @min(id.len, buf.len);
    @memcpy(buf[0..n], id[0..n]);
    deleteArchived(a, id);
    if (claude) purge.claudeFiles(a, buf[0..n]);
}

/// Forgets an archived session for good (the agent may keep its own copy).
pub fn deleteArchived(a: *App, id: []const u8) void {
    a.store.forgetSession(id);
    a.store.save();
    a.redraw();
}

/// Deletes a listed session for good: its agent stops, and the app
/// forgets it (the agent may keep its own copy).
pub fn deleteSession(a: *App, s: *Session) void {
    const purge = @import("purge.zig");
    var buf: [256]u8 = undefined;
    const id: ?[]const u8 = if (s.id) |x| (if (x.len <= buf.len) blk: {
        @memcpy(buf[0..x.len], x);
        break :blk buf[0..x.len];
    } else null) else null;
    // Gone from the agent's store too: Claude Code's files are removed here;
    // another agent that deletes is asked on the session's own connection,
    // which outlives the session until it answers.
    const claude = purge.isClaude(a, s.agent);
    var ask: ?*@import("../acp/rpc.zig").Conn = null;
    if (!claude and id != null and s.caps.delete and s.conn != null and !s.opening) {
        ask = s.conn;
        s.conn = null;
    }
    removeSession(a, s);
    if (id) |x| {
        deleteArchived(a, x);
        if (claude) purge.claudeFiles(a, x) else if (ask) |c| purge.askThenStop(a, c, x);
    }
}

pub fn renameSession(a: *App, s: *Session, name: []const u8) void {
    if (s.id) |id| {
        const n = std.mem.trim(u8, name, " \t\r\n");
        if (a.store.sessionMut(id)) |rec| rec.name = a.store.dupe(n) else a.store.putSession(.{ .id = id, .agent = s.agent, .cwd = if (a.workspaceOf(s)) |w| w.path else "", .name = n });
        a.store.save();
    }
    a.dialog = null;
    a.redraw();
}

pub fn openBeside(a: *App, s: *Session) void {
    if (a.active == s or s.id == null) return;
    a.beside = s;
    load(a, s);
    a.redraw();
}

pub fn swapBeside(a: *App) void {
    const b = a.beside orelse return;
    a.beside = if (a.active) |cur| (if (cur.isEmpty()) null else cur) else null;
    select(a, b);
}

pub fn closeBeside(a: *App) void {
    a.beside = null;
    a.redraw();
}
