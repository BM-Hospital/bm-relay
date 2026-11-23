//! The data the app holds: sessions and the folders they work in, what a
//! session waits on, and the enums for which page, tab or dialog is open.
const std = @import("std");
const ui = @import("myzig").ui;
const json = @import("../acp/json.zig");
const proto = @import("../acp/proto.zig");
const rpc = @import("../acp/rpc.zig");
const transcript = @import("../model/transcript.zig");
const tools = @import("../model/tools.zig");
const git = @import("../host/git.zig");
const pickers = @import("../host/pickers.zig");
const Store = @import("../host/store.zig").Store;

pub const Status = enum { waiting, running, stopped, idle };

/// How many recent sessions keep their agent running.
pub const warm = 6;
pub const max_images = 8;
/// Files (not images) a prompt carries: links the agent reads.
pub const max_files = 20;
pub const max_image_bytes = 3_932_160;

/// An image to send: pasted, dropped or attached.
/// What a prompt carries besides its words: an image (its bytes), or a
/// file (its path: the agent reads it, as ACP's `resource_link`).
pub const Attachment = struct {
    mime: []const u8,
    bytes: []u8,
    name: []u8,
    /// A file's full path; empty for an image.
    path: []u8 = &.{},
    /// A file's size in bytes.
    size: u64 = 0,

    pub fn isFile(at: Attachment) bool {
        return at.path.len > 0;
    }

    pub fn deinit(at: Attachment, gpa: std.mem.Allocator) void {
        gpa.free(at.bytes);
        gpa.free(at.name);
        gpa.free(at.path);
    }
};

/// A prompt edited in place, to send again.
pub const PromptEdit = struct {
    session: u64,
    turn: usize,
    text: ui.TextArea,
};

/// A prompt waiting for the turn before it.
pub const Queued = struct {
    text: []u8,
    images: []Attachment,

    pub fn deinit(q: Queued, gpa: std.mem.Allocator) void {
        gpa.free(q.text);
        for (q.images) |i| i.deinit(gpa);
        gpa.free(q.images);
    }
};

/// A tool call waiting for the user's approval.
pub const Pending = struct {
    arena: std.heap.ArenaAllocator,
    request: json.Value,
    tool: transcript.Tool,
    options: []proto.PermissionOption,
    preview: ?[]git.DiffLine,

    pub fn optionOf(p: *const Pending, kind: []const u8) ?[]const u8 {
        for (p.options) |o| if (std.mem.eql(u8, o.kind, kind)) return o.id;
        return null;
    }
};

pub const Snap = struct {
    before: []u8,
    after: ?[]u8 = null,
};

pub const Tally = struct {
    before: []git.Change,
    from: usize,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    /// The app's own name for it, stable while it is open.
    key: u64,
    /// The agent's id for it, once it has one.
    id: ?[]u8 = null,
    agent: []u8,
    saved_title: ?[]u8 = null,
    updated: i64 = 0,
    /// Its turns have been loaded (or it is new).
    loaded: bool = true,
    /// Its agent is starting or replaying it.
    opening: bool = false,
    thread: transcript.Thread,
    /// The turns the agent replays as a session it already showed loads
    /// again: the old ones stay on screen until the new ones are all in.
    replay: ?transcript.Thread = null,
    /// When the user stopped the running turn (ms), while the agent has
    /// not said it stopped.
    stopping: ?i64 = null,
    options: proto.Options,
    caps_arena: std.heap.ArenaAllocator,
    caps: proto.Capabilities = .{},
    permission: ?*Pending = null,
    expanded: std.AutoHashMapUnmanaged(usize, void) = .empty,
    open_steps: std.AutoHashMapUnmanaged(u64, void) = .empty,
    err: ?[]u8 = null,
    conn: ?*rpc.Conn = null,
    tally: ?Tally = null,
    steering: std.ArrayList([]u8) = .empty,
    queue: std.ArrayList(Queued) = .empty,
    /// The turn whose question the user skipped.
    skipped: ?usize = null,
    grants: std.ArrayList([]u8) = .empty,
    snap: ?Snap = null,
    /// Its turns as a virtual list (`ui.measuredList`): only those in view
    /// are built, however long it is. Beside: as the dimmed one shown there.
    rows: ui.MeasuredListState = .{},
    rows_beside: ui.MeasuredListState = .{},

    pub fn create(gpa: std.mem.Allocator, key: u64, agent: []const u8) *Session {
        const s = gpa.create(Session) catch @panic("out of memory");
        s.* = .{
            .gpa = gpa,
            .key = key,
            .agent = gpa.dupe(u8, agent) catch @panic("out of memory"),
            .thread = .init(gpa),
            .options = .empty(gpa),
            .caps_arena = .init(gpa),
        };
        return s;
    }

    /// The thread updates go to: the replay while one loads.
    pub fn target(s: *Session) *transcript.Thread {
        return if (s.replay) |*r| r else &s.thread;
    }

    /// The replay, done: it becomes the thread.
    pub fn takeReplay(s: *Session) void {
        const r = s.replay orelse return;
        s.replay = null;
        s.thread.deinit();
        s.thread = r;
        // Other turns: their heights are measured anew.
        s.rows.reset();
        s.rows_beside.reset();
    }

    pub fn dropReplay(s: *Session) void {
        if (s.replay) |*r| r.deinit();
        s.replay = null;
    }

    pub fn destroy(s: *Session) void {
        const gpa = s.gpa;
        if (s.conn) |c| c.stop();
        s.clearPermission();
        if (s.id) |x| gpa.free(x);
        gpa.free(s.agent);
        if (s.saved_title) |x| gpa.free(x);
        s.thread.deinit();
        s.dropReplay();
        s.options.deinit();
        s.caps_arena.deinit();
        s.expanded.deinit(gpa);
        s.open_steps.deinit(gpa);
        s.rows.deinit(gpa);
        s.rows_beside.deinit(gpa);
        if (s.err) |e| gpa.free(e);
        s.clearTally();
        for (s.steering.items) |x| gpa.free(x);
        s.steering.deinit(gpa);
        for (s.queue.items) |q| q.deinit(gpa);
        s.queue.deinit(gpa);
        s.clearGrants();
        s.grants.deinit(gpa);
        s.clearSnap();
        gpa.destroy(s);
    }

    pub fn setId(s: *Session, id: []const u8) void {
        if (s.id) |x| s.gpa.free(x);
        s.id = s.gpa.dupe(u8, id) catch null;
    }

    pub fn setAgent(s: *Session, agent: []const u8) void {
        const n = s.gpa.dupe(u8, agent) catch return;
        s.gpa.free(s.agent);
        s.agent = n;
    }

    pub fn setError(s: *Session, msg: ?[]const u8) void {
        if (s.err) |e| s.gpa.free(e);
        s.err = if (msg) |m| s.gpa.dupe(u8, m) catch null else null;
    }

    pub fn setOptions(s: *Session, o: proto.Options) void {
        s.options.deinit();
        s.options = o;
    }

    pub fn clearPermission(s: *Session) void {
        if (s.permission) |p| {
            p.arena.deinit();
            s.gpa.destroy(p);
        }
        s.permission = null;
    }

    pub fn clearTally(s: *Session) void {
        if (s.tally) |t| git.freeChanges(s.gpa, t.before);
        s.tally = null;
    }

    pub fn clearSnap(s: *Session) void {
        if (s.snap) |sn| {
            s.gpa.free(sn.before);
            if (sn.after) |x| s.gpa.free(x);
        }
        s.snap = null;
    }

    pub fn clearGrants(s: *Session) void {
        for (s.grants.items) |g| s.gpa.free(g);
        s.grants.clearRetainingCapacity();
    }

    pub fn option(s: *const Session, key: []const u8) ?*proto.ConfigOption {
        return s.options.find(key);
    }

    /// The name shown for it: the user's, the agent's, or its first prompt.
    pub fn label(s: *const Session, st: *const Store) []const u8 {
        if (s.id) |id| if (st.session(id)) |rec| if (rec.name.len > 0) return rec.name;
        if (s.thread.title) |t| return t;
        if (s.saved_title) |t| if (t.len > 0) return t;
        if (s.thread.turns.items.len > 0) {
            const p = s.thread.turns.items[0].prompt.items;
            if (p.len > 0) return tools.firstLine(p);
        }
        return "New session";
    }

    /// Nothing has been said in it yet.
    pub fn isEmpty(s: *const Session) bool {
        return s.thread.turns.items.len == 0 and s.saved_title == null;
    }

    pub fn status(s: *const Session) Status {
        if (s.permission != null) return .waiting;
        if (s.thread.running()) return .running;
        if (s.thread.last()) |t| if (t.stop != null) return .stopped;
        return .idle;
    }

    /// The question the last turn asks, while nothing else is going on.
    pub fn question(s: *const Session, a: std.mem.Allocator) ?struct { turn: usize, q: tools.Question } {
        const n = s.thread.turns.items.len;
        if (n == 0) return null;
        const t = s.thread.turns.items[n - 1];
        if (t.running() or s.skipped == n - 1 or s.permission != null or s.queue.items.len > 0) return null;
        const q = tools.asked(a, t) orelse return null;
        return .{ .turn = n - 1, .q = q };
    }

    /// Its agent is up and takes prompts. A new session has no id yet:
    /// the agent makes one at its first prompt (`agent.create`).
    pub fn live(s: *const Session) bool {
        return s.conn != null and !s.opening;
    }
};

pub const Workspace = struct {
    gpa: std.mem.Allocator,
    path: []u8,
    name: []const u8,
    branch: ?[]u8 = null,
    sessions: std.ArrayList(*Session) = .empty,
    show_all: bool = false,
    /// Its sessions are folded away in the sidebar.
    collapsed: bool = false,
    /// Skills and files, from the last look at the folder.
    found: std.heap.ArenaAllocator,
    skills: []pickers.Skill = &.{},
    files: []const []const u8 = &.{},
    status: []git.Change = &.{},

    pub fn create(gpa: std.mem.Allocator, path: []const u8) *Workspace {
        const w = gpa.create(Workspace) catch @panic("out of memory");
        const p = gpa.dupe(u8, path) catch @panic("out of memory");
        w.* = .{ .gpa = gpa, .path = p, .name = std.fs.path.basename(p), .found = .init(gpa) };
        if (w.name.len == 0) w.name = p;
        return w;
    }

    pub fn destroy(w: *Workspace) void {
        for (w.sessions.items) |s| s.destroy();
        w.sessions.deinit(w.gpa);
        if (w.branch) |b| w.gpa.free(b);
        git.freeChanges(w.gpa, w.status);
        w.found.deinit();
        w.gpa.free(w.path);
        w.gpa.destroy(w);
    }

    pub fn setStatus(w: *Workspace, list: []git.Change) void {
        git.freeChanges(w.gpa, w.status);
        w.status = list;
    }

    pub fn setBranch(w: *Workspace, b: ?[]u8) void {
        if (w.branch) |x| w.gpa.free(x);
        w.branch = b;
    }

    pub fn sessionStatus(w: *const Workspace) Status {
        var running = false;
        for (w.sessions.items) |s| switch (s.status()) {
            .waiting => return .waiting,
            .running => running = true,
            else => {},
        };
        return if (running) .running else .idle;
    }

    pub fn indexOf(w: *const Workspace, s: *const Session) ?usize {
        for (w.sessions.items, 0..) |x, i| if (x == s) return i;
        return null;
    }
};

pub const Page = enum { session, settings };
pub const HomeTab = enum { recent, running, history, archived };

/// Which popover of the composer is open.
pub const Pop = enum { none, attach, mode, model, thinking, usage, agent };

pub const Picker = struct {
    kind: u8,
    query: []const u8 = "",
    selected: usize = 0,
};

pub const Dialog = union(enum) {
    remove: *Session,
    rename: *Session,
    discard: git.Change,
    full_access: []const u8,
    remove_folder: usize,
    /// Deleting a session for good: from the list, or from Archived (by
    /// its saved id).
    delete: *Session,
    delete_saved: []const u8,
    /// Deleting a session from its agent's own history (History's ✕):
    /// which one, `history.State.doomed` says.
    delete_history,
    /// Freeing Storage: what, `storage.State.plan_*` says.
    purge_storage,
};

test "a session loading again shows its turns until the replay is in" {
    const gpa = std.testing.allocator;
    const s = Session.create(gpa, 1, "claude");
    defer s.destroy();
    _ = s.thread.begin("old", 0);
    s.replay = .init(gpa);
    s.target().apply(.{ .user_text = "replayed" }, 1);
    s.target().apply(.{ .text = "answer" }, 1);
    try std.testing.expectEqualStrings("old", s.thread.turns.items[0].prompt.items);
    s.takeReplay();
    try std.testing.expect(s.replay == null);
    try std.testing.expectEqualStrings("replayed", s.thread.turns.items[0].prompt.items);
    // One dropped (the agent failed) leaves the turns as they were.
    s.replay = .init(gpa);
    s.target().apply(.{ .user_text = "lost" }, 2);
    s.dropReplay();
    try std.testing.expectEqualStrings("replayed", s.thread.turns.items[0].prompt.items);
}

test "a session says where it stands" {
    const gpa = std.testing.allocator;
    const s = Session.create(gpa, 1, "claude");
    defer s.destroy();
    try std.testing.expectEqual(Status.idle, s.status());
    _ = s.thread.begin("go", 0);
    try std.testing.expectEqual(Status.running, s.status());
    s.thread.finish(.{ .err = "the agent exited" }, 1);
    try std.testing.expectEqual(Status.stopped, s.status());
    _ = s.thread.begin("again", 2);
    s.thread.finish(.{ .stop = "end_turn" }, 3);
    try std.testing.expectEqual(Status.idle, s.status());
    _ = ui;
}
