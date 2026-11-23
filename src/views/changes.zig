//! The changes panel: what git says changed in the folder, each file's
//! diff, staging and discarding. Git runs off the main thread; a read's
//! result is dropped when a newer read started after it. What it draws is
//! in `changes_view.zig`.
const std = @import("std");
const ui = @import("myzig").ui;
const app_mod = @import("../app/app.zig");
const git = @import("../host/git.zig");
const jobs = @import("../host/jobs.zig");
const sessions = @import("../app/sessions.zig");
const view = @import("changes_view.zig");

const App = app_mod.App;

/// Lines of a diff shown before "Show more".
pub const diff_lines = 120;

pub const State = struct {
    /// What changed, in the panel's own memory (`git.freeChanges`).
    list: []git.Change = &.{},
    err: ?[]u8 = null,
    /// The file whose diff shows; its path is the panel's.
    open: ?git.Change = null,
    diff_arena: ?std.heap.ArenaAllocator = null,
    diff: []git.DiffLine = &.{},
    /// The whole diff shows, not its first `diff_lines`.
    full: bool = false,
    last_commit: ?[]u8 = null,
    /// A read has answered since the panel opened.
    loaded: bool = false,
    /// Bumped by each read: older answers are dropped.
    gen: u64 = 0,
    /// The path the discard dialog asks about.
    discard_path: ?[]u8 = null,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        git.freeChanges(gpa, s.list);
        s.list = &.{};
        s.setError(gpa, null);
        s.setOpen(gpa, null);
        if (s.diff_arena) |*ar| ar.deinit();
        s.diff_arena = null;
        s.diff = &.{};
        if (s.last_commit) |l| gpa.free(l);
        s.last_commit = null;
        if (s.discard_path) |p| gpa.free(p);
        s.discard_path = null;
    }

    pub fn setError(s: *State, gpa: std.mem.Allocator, msg: ?[]const u8) void {
        if (s.err) |e| gpa.free(e);
        s.err = if (msg) |m| gpa.dupe(u8, m) catch null else null;
    }

    /// Opens a file's diff (a copy of `c`), or closes it.
    pub fn setOpen(s: *State, gpa: std.mem.Allocator, c: ?git.Change) void {
        const next: ?git.Change = if (c) |x| blk: {
            var o = x;
            o.path = gpa.dupe(u8, x.path) catch break :blk null;
            break :blk o;
        } else null;
        if (s.open) |o| gpa.free(o.path);
        s.open = next;
    }

    pub fn totals(s: *const State) [2]usize {
        var r: [2]usize = .{ 0, 0 };
        for (s.list) |c| {
            r[0] += c.added;
            r[1] += c.removed;
        }
        return r;
    }

    pub fn isOpen(s: *const State, c: git.Change) bool {
        const o = s.open orelse return false;
        return o.staged == c.staged and std.mem.eql(u8, o.path, c.path);
    }
};

/// Opens or closes the panel.
pub fn toggle(a: *App) void {
    if (a.changes) |*c| {
        c.deinit(a.gpa);
        a.changes = null;
    } else {
        a.changes = .{};
        refresh(a);
    }
    a.redraw();
}

/// Shows a file's diff, or the list again.
pub fn openChange(a: *App, c: ?git.Change) void {
    if (a.changes == null) return;
    a.changes.?.setOpen(a.gpa, c);
    a.changes.?.diff = &.{};
    a.changes.?.full = false;
    refresh(a);
}

// ---------------------------------------------------------------------------
// Reading what changed.

const Read = struct {
    a: *App,
    gen: u64,
    path: []u8,
    open: ?git.Change,
    arena: std.heap.ArenaAllocator,
    status: ?[]git.Change = null,
    diff: ?[]git.DiffLine = null,
    diff_err: ?[]const u8 = null,
    last: ?[]u8 = null,
};

/// Reads the folder's changes again, while the panel is open, and the
/// open file's diff; the sidebar's counts follow.
pub fn refresh(a: *App) void {
    if (a.changes == null) return;
    const w = a.workspace() orelse return;
    var st = &a.changes.?;
    st.gen += 1;
    const job = a.gpa.create(Read) catch return;
    job.* = .{
        .a = a,
        .gen = st.gen,
        .path = a.gpa.dupe(u8, w.path) catch return a.gpa.destroy(job),
        .open = null,
        .arena = .init(a.gpa),
    };
    if (st.open) |o| {
        var copy = o;
        copy.path = job.arena.allocator().dupe(u8, o.path) catch o.path;
        job.open = copy;
    }
    jobs.spawn(Read, job, readWork, readDone);
    sessions.refreshStatus(a, w);
}

fn readWork(j: *Read) void {
    const gpa = j.a.gpa;
    const io = j.a.io;
    j.status = git.status(gpa, io, j.path);
    if (j.open) |o| switch (git.fileDiff(j.arena.allocator(), io, j.path, o)) {
        .ok => |lines| j.diff = lines,
        .err => |e| j.diff_err = e,
    };
    j.last = git.lastCommit(gpa, io, j.path);
}

fn readDone(j: *Read) void {
    const a = j.a;
    const gpa = a.gpa;
    defer {
        gpa.free(j.path);
        gpa.destroy(j);
    }
    const st = if (a.changes) |*s| s else null;
    if (st == null or st.?.gen != j.gen) {
        if (j.status) |l| git.freeChanges(gpa, l);
        if (j.last) |l| gpa.free(l);
        j.arena.deinit();
        return;
    }
    const s = st.?;
    s.loaded = true;
    if (j.status) |list| {
        // The open file stays open as the list changes, staged or not.
        if (s.open) |o| {
            var found: ?git.Change = null;
            for (list) |c| if (std.mem.eql(u8, c.path, o.path) and c.staged == o.staged) {
                found = c;
                break;
            };
            if (found == null) for (list) |c| if (std.mem.eql(u8, c.path, o.path)) {
                found = c;
                break;
            };
            s.setOpen(gpa, found);
        }
        git.freeChanges(gpa, s.list);
        s.list = list;
        s.setError(gpa, null);
    } else s.setError(gpa, "This folder is not a git repository, or git is not installed.");
    if (s.diff_arena) |*ar| ar.deinit();
    s.diff_arena = j.arena;
    s.diff = j.diff orelse &.{};
    if (j.diff_err) |e| s.setError(gpa, e);
    if (s.last_commit) |l| gpa.free(l);
    s.last_commit = j.last;
    a.redraw();
}

// ---------------------------------------------------------------------------
// Staging and discarding.

pub const Op = enum { stage, unstage, discard };

const Edit = struct {
    a: *App,
    path: []u8,
    op: Op,
    /// The files staged or unstaged, or the one discarded.
    paths: [][]u8,
    /// What `paths` was allocated as.
    all: [][]u8 = &.{},
    code: u8 = 'M',
    err: ?[]u8 = null,
};

/// Stages, unstages or discards `paths`, then reads the changes again.
pub fn edit(a: *App, op: Op, paths: []const []const u8, code: u8) void {
    const w = a.workspace() orelse return;
    const job = a.gpa.create(Edit) catch return;
    job.* = .{ .a = a, .path = a.gpa.dupe(u8, w.path) catch return a.gpa.destroy(job), .op = op, .paths = &.{}, .code = code };
    const list = a.gpa.alloc([]u8, paths.len) catch {
        a.gpa.free(job.path);
        return a.gpa.destroy(job);
    };
    var n: usize = 0;
    for (paths) |p| {
        list[n] = a.gpa.dupe(u8, p) catch continue;
        n += 1;
    }
    job.paths = list[0..n];
    job.all = list;
    jobs.spawn(Edit, job, editWork, editDone);
}

fn editWork(j: *Edit) void {
    const gpa = j.a.gpa;
    const io = j.a.io;
    for (j.paths) |p| {
        const out = switch (j.op) {
            .stage => git.stage(gpa, io, j.path, p),
            .unstage => git.unstage(gpa, io, j.path, p),
            .discard => git.discard(gpa, io, j.path, .{ .path = p, .code = j.code, .staged = false, .added = 0, .removed = 0 }),
        };
        switch (out) {
            .ok => |s| gpa.free(s),
            .err => |e| {
                if (j.err == null) j.err = gpa.dupe(u8, e) catch null;
                gpa.free(e);
            },
        }
    }
}

fn editDone(j: *Edit) void {
    const a = j.a;
    defer {
        for (j.paths) |p| a.gpa.free(p);
        a.gpa.free(j.all);
        if (j.err) |e| a.gpa.free(e);
        a.gpa.free(j.path);
        a.gpa.destroy(j);
    }
    if (a.changes) |*s| if (j.err) |e| s.setError(a.gpa, e);
    if (j.err != null and a.changes == null) a.failToast(j.err.?);
    refresh(a);
    a.redraw();
}

/// Stages an unstaged change, or unstages a staged one.
pub fn stageToggle(a: *App, c: git.Change) void {
    edit(a, if (c.staged) .unstage else .stage, &.{c.path}, c.code);
}

/// Asks before discarding a change: the dialog holds a copy of it.
pub fn askDiscard(a: *App, c: git.Change) void {
    const s = &(a.changes orelse return);
    if (s.discard_path) |p| a.gpa.free(p);
    s.discard_path = a.gpa.dupe(u8, c.path) catch return;
    var copy = c;
    copy.path = s.discard_path.?;
    a.dialog = .{ .discard = copy };
    a.dialog_state.show();
    a.redraw();
}

/// Discards a change, as the dialog confirmed: its diff closes.
pub fn discard(a: *App, c: git.Change) void {
    if (a.changes) |*s| if (s.open) |o| if (std.mem.eql(u8, o.path, c.path)) {
        s.setOpen(a.gpa, null);
        s.diff = &.{};
    };
    edit(a, .discard, &.{c.path}, c.code);
}

pub fn draw(a: *App, c: *ui.Context) void {
    view.draw(a, c);
}

test "a panel's open file is its own copy" {
    const gpa = std.testing.allocator;
    var s: State = .{};
    defer s.deinit(gpa);
    var path = "src/a.zig".*;
    s.setOpen(gpa, .{ .path = &path, .code = 'M', .staged = false, .added = 1, .removed = 0 });
    path[0] = 'X';
    try std.testing.expectEqualStrings("src/a.zig", s.open.?.path);
    try std.testing.expect(s.isOpen(.{ .path = "src/a.zig", .code = 'M', .staged = false, .added = 0, .removed = 0 }));
    try std.testing.expect(!s.isOpen(.{ .path = "src/a.zig", .code = 'M', .staged = true, .added = 0, .removed = 0 }));
}
