//! Home: what needs you, what is running, recent and archived sessions;
//! the first run, with no folder yet.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("myzig").ui;
const app_mod = @import("../app/app.zig");
const state = @import("../app/state.zig");
const sessions = @import("../app/sessions.zig");
const agent = @import("../app/agent.zig");
const format = @import("../app/format.zig");
const tools = @import("../model/tools.zig");
const git = @import("../host/git.zig");
const store_mod = @import("../host/store.zig");
const t = @import("../design/tokens.zig");
const k = @import("../design/components.zig");
const shell = @import("shell.zig");
const palette = @import("palette.zig");
const dialogs = @import("dialogs.zig");
const composer = @import("composer.zig");
const settings = @import("settings/settings.zig");

const App = app_mod.App;
const Session = state.Session;
const Workspace = state.Workspace;

/// How many rows a list shows.
const rows_max = 6;

pub fn draw(a: *App, c: *ui.Context) void {
    const page = ui.div(c).column().wFull().grow().h(0).scrollY();
    defer page.end();
    const col = ui.div(c).column().wFull().itemsCenter().gap(28).px(40).pt(120).pb(40);
    defer col.end();
    const w = a.workspace() orelse return firstRun(a, c);
    hero(c, c.print("What should we build in {s}?", .{w.name}));
    {
        const box = ui.div(c).column().wFull().maxW(680).gap(10);
        defer box.end();
        const s = a.active;
        if (s != null and s.?.isEmpty() and a.workspaceOf(s.?) == w) {
            composer.draw(a, c);
        } else {
            const row = ui.div(c).row().wFull().gap(12).itemsCenter().justifyCenter();
            defer row.end();
            if (k.primaryButton(c, c.print("New session on {s}", .{a.agentName(a.defaultAgent())}), ui.keys.label("⌘N"))) sessions.newSessionIn(a, w);
        }
    }
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    var archived: std.ArrayList(*const store_mod.Saved) = .empty;
    sessions.archived(a, w, &archived, arena.allocator());
    // The tabs show with nothing in them too: History lists what the agent
    // keeps (from its CLI) before anything was started here.
    lists(a, c, w, archived.items);
}

fn hero(c: *ui.Context, title: []const u8) void {
    const col = ui.div(c).column().itemsCenter().gap(18);
    defer col.end();
    k.logo(c, 64);
    ui.text(c, title, .{ .size = 28, .weight = .medium });
}

/// A small square around a mark, so rows line up.
fn markBox(c: *ui.Context) ui.Div {
    return ui.div(c).w(16).h(16).center();
}

fn bullet(c: *ui.Context) void {
    ui.div(c).w(4).h(4).rounded(2).bg(t.gray_500).end();
}

/// A row of a list: its mark, title, a note and its age. True when clicked.
fn listRow(c: *ui.Context, key: anytype, comptime drawMark: anytype, mark_arg: anytype, title: []const u8, note: anytype, age: []const u8) bool {
    c.keyed(key);
    const r = ui.div(c).row().wFull().h(34).px(10).gap(10).itemsCenter().rounded(8).hover(t.alpha_100).control();
    {
        const m = markBox(c);
        defer m.end();
        drawMark(c, mark_arg);
    }
    shell.clipped(c, title, .{ .size = 14 });
    note.draw(c);
    {
        const ag = ui.div(c).row().w(36).justifyEnd();
        defer ag.end();
        ui.text(c, age, .{ .size = 12, .color = t.gray_700 });
    }
    r.end();
    return k.press(r);
}

fn markStatus(c: *ui.Context, st: state.Status) void {
    if (!shell.statusMark(c, st)) bullet(c);
}

const NoNote = struct {
    fn draw(_: NoNote, _: *ui.Context) void {}
};

const TextNote = struct {
    text: []const u8,
    /// Null: the muted text color of the theme shown.
    color: ?ui.Color = null,
    fn draw(n: TextNote, c: *ui.Context) void {
        const b = ui.div(c).row().maxW(240).clip();
        defer b.end();
        ui.text(c, n.text, .{ .size = 12, .color = n.color orelse t.gray_900 });
    }
};

const StatNote = struct {
    added: usize,
    removed: usize,
    fn draw(n: StatNote, c: *ui.Context) void {
        if (n.added + n.removed > 0) k.stat(c, n.added, n.removed);
    }
};

fn lists(a: *App, c: *ui.Context, w: *Workspace, archived: []const *const store_mod.Saved) void {
    const col = ui.div(c).column().wFull().maxW(680).gap(16);
    defer col.end();
    var live: usize = 0;
    for (w.sessions.items) |s| {
        if (s.permission) |p| approvalCard(a, c, w, s, p);
        if (s.status() == .running) live += 1;
    }
    const list = ui.div(c).column().wFull();
    defer list.end();
    homeTabs(a, c, live);
    if (a.home_tab != .recent) ui.div(c).h(6).end();
    const shown = switch (a.home_tab) {
        .archived => archivedRows(a, c, w, archived),
        .history => @import("history.zig").rows(a, c, w),
        else => sessionRows(a, c, w),
    };
    if (shown == 0) emptyList(c, a.home_tab);
}

fn emptyList(c: *ui.Context, tab: state.HomeTab) void {
    const title, const detail = switch (tab) {
        .running => .{ "Nothing is running", "Sessions that are working show up here." },
        .archived => .{ "Nothing archived", "Sessions you archive from the list are kept here." },
        .history => .{ "No sessions", "The agent lists none in this folder." },
        .recent => .{ "No sessions yet", "Your first prompt starts one." },
    };
    const col = ui.div(c).column().wFull().itemsCenter().gap(6).py(36);
    defer col.end();
    ui.text(c, title, .{ .size = 14 });
    ui.text(c, detail, .{ .size = 13, .color = t.gray_700 });
}

fn homeTabs(a: *App, c: *ui.Context, live: usize) void {
    const row = ui.div(c).row().wFull().h(28).px(2).gap(4).itemsCenter();
    defer row.end();
    tabButton(a, c, "Recent", 0, .recent);
    tabButton(a, c, "Running", live, .running);
    tabButton(a, c, "History", 0, .history);
    tabButton(a, c, "Archived", 0, .archived);
    ui.spacer(c);
    const all = ui.div(c).row().px(6).gap(8).itemsCenter().control();
    const hot = all.hovered();
    const tone = if (hot) t.gray_1000 else t.gray_700;
    ui.text(c, "All sessions", .{ .size = 12, .color = tone });
    ui.text(c, ui.keys.label("⌘K"), .{ .size = 12, .color = tone });
    all.end();
    if (k.press(all)) palette.toggle(a);
}

fn tabButton(a: *App, c: *ui.Context, label: []const u8, count: usize, target: state.HomeTab) void {
    const on = a.home_tab == target;
    const b = ui.div(c).row().h(26).px(8).gap(6).itemsCenter().rounded(6).control();
    if (on) _ = b.bg(t.alpha_200);
    const hot = b.hovered();
    ui.text(c, label, .{ .size = 13, .weight = if (on) .medium else .regular, .color = if (on or hot) t.gray_1000 else t.gray_900 });
    if (count > 0) ui.text(c, c.print("{d}", .{count}), .{ .size = 12, .mono = true, .color = t.gray_700 });
    b.end();
    if (k.press(b)) a.home_tab = target;
}

fn running(s: *const Session) bool {
    return s.status() == .running;
}

fn sessionRows(a: *App, c: *ui.Context, w: *Workspace) usize {
    var picked: [64]*Session = undefined;
    var n: usize = 0;
    // Running first, then the rest, in the folder's order (newest first).
    for ([_]bool{ true, false }) |want_running| {
        for (w.sessions.items) |s| {
            if (n == picked.len) break;
            if (s.isEmpty() or s.status() == .waiting) continue;
            if (running(s) != want_running) continue;
            if (a.home_tab == .running and !running(s)) continue;
            picked[n] = s;
            n += 1;
        }
    }
    const count = @min(n, rows_max);
    const now = a.now();
    const offset = tzOffsetMinutes();
    var heading: ?[]const u8 = null;
    var hbuf: [2][48]u8 = undefined;
    var flip: usize = 0;
    for (picked[0..count]) |s| {
        if (a.home_tab == .recent) {
            const name = if (running(s)) "Today" else format.day(&hbuf[flip], now, s.updated, offset);
            if (heading == null or !std.mem.eql(u8, heading.?, name)) {
                dayHeading(c, name, heading == null);
                heading = name;
                flip ^= 1;
            }
        }
        if (recentRow(a, c, s, now)) {
            sessions.select(a, s);
            return count;
        }
    }
    return count;
}

fn dayHeading(c: *ui.Context, name: []const u8, first: bool) void {
    const b = ui.div(c).row().wFull().h(if (first) 32 else 36).pt(if (first) 10 else 14).px(10).itemsCenter();
    defer b.end();
    ui.text(c, name, .{ .size = 12, .color = t.gray_700 });
}

fn recentRow(a: *App, c: *ui.Context, s: *Session, now: i64) bool {
    const turn = s.thread.last();
    if (turn != null and turn.?.running()) {
        var dbuf: [256]u8 = undefined;
        const secs = @divTrunc(turn.?.elapsed(now), 1000);
        const age = if (secs < 60) "now" else if (secs < 3600) c.print("{d}m", .{@divTrunc(secs, 60)}) else c.print("{d}h", .{@divTrunc(secs, 3600)});
        return listRow(c, s, markStatus, state.Status.running, a.label(s), TextNote{ .text = tools.doing(&dbuf, turn.?) }, age);
    }
    var note: StatNote = .{ .added = 0, .removed = 0 };
    if (s.id) |id| if (a.store.session(id)) |rec| {
        note = .{ .added = rec.added, .removed = rec.removed };
    };
    var buf: [32]u8 = undefined;
    return listRow(c, s, markStatus, shell.statusOf(s), a.label(s), note, format.ago(&buf, now, s.updated));
}

fn archivedRows(a: *App, c: *ui.Context, w: *Workspace, archived: []const *const store_mod.Saved) usize {
    const n = @min(archived.len, rows_max);
    const now = a.now();
    for (archived[0..n]) |rec| {
        var buf: [32]u8 = undefined;
        const title = if (rec.name.len > 0) rec.name else if (rec.title.len > 0) rec.title else "Untitled session";
        switch (archivedRow(c, rec, title, format.ago(&buf, now, rec.updated))) {
            .none => {},
            .restore => {
                sessions.restoreSession(a, w, rec.id);
                return n;
            },
            .delete => dialogs.ask(a, .{ .delete_saved = rec.id }),
        }
    }
    return n;
}

/// An archived session: its title and age, and buttons to restore it or
/// delete it for good.
fn archivedRow(c: *ui.Context, rec: *const store_mod.Saved, title: []const u8, age: []const u8) enum { none, restore, delete } {
    c.keyed(rec);
    const r = ui.div(c).row().wFull().h(34).px(10).gap(10).itemsCenter().rounded(8).hover(t.alpha_100);
    defer r.end();
    {
        const m = markBox(c);
        defer m.end();
        bullet(c);
    }
    shell.clipped(c, title, .{ .size = 14 });
    {
        const ag = ui.div(c).row().w(36).justifyEnd();
        defer ag.end();
        ui.text(c, age, .{ .size = 12, .color = t.gray_700 });
    }
    const restore = ui.div(c).row().h(26).px(10).itemsCenter().rounded(6).border(t.alpha_400).hover(t.alpha_200).control();
    ui.text(c, "Restore", .{ .size = 12, .color = t.gray_1000 });
    restore.end();
    if (k.press(restore)) return .restore;
    if (k.iconButton(c, "trash", 14, "Delete for good")) return .delete;
    return .none;
}

/// A session waiting on an approval, answerable from Home.
fn approvalCard(a: *App, c: *ui.Context, w: *Workspace, s: *Session, p: *state.Pending) void {
    c.keyed(p);
    const card = ui.div(c).row().wFull().gap(10).pl(10).pr(12).py(12).itemsCenter().rounded(12).bg(t.gray_100).border(t.alpha_300).control();
    {
        const m = markBox(c);
        defer m.end();
        _ = shell.statusMark(c, .waiting);
    }
    {
        const col = ui.div(c).column().grow().w(0).gap(2).clip();
        defer col.end();
        ui.text(c, a.label(s), .{ .size = 14, .weight = .medium });
        const line = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer line.end();
        const wants = tools.wants(&p.tool, w.path);
        ui.text(c, wants[0], .{ .size = 13, .color = t.gray_900 });
        shell.clipped(c, wants[1], .{ .size = 12, .mono = true });
        if (p.preview) |lines| {
            const n = git.counts(lines);
            k.stat(c, n[0], n[1]);
        }
    }
    var answered = false;
    {
        const btns = ui.div(c).row().gap(6).itemsCenter();
        defer btns.end();
        if (k.outlineButton(c, "Deny", null)) {
            agent.answerPermission(a, s, "reject_once");
            answered = true;
        }
        if (!answered and p.optionOf("allow_once") != null) {
            if (k.primaryButton(c, if (std.mem.eql(u8, p.tool.kind, "execute")) "Run" else "Allow", null)) {
                agent.answerPermission(a, s, "allow_once");
                answered = true;
            }
        }
    }
    card.end();
    if (!answered and k.press(card)) sessions.select(a, s);
}

// ---------------------------------------------------------------------------
// The first run: no folder yet.

fn firstRun(a: *App, c: *ui.Context) void {
    hero(c, "Welcome to BM Relay");
    ui.text(c, "A desktop app for coding agents that speak ACP: Claude Code, Codex, Gemini CLI, OpenCode, pi and fx.", .{ .size = 13, .color = t.gray_900 });
    const card = ui.div(c).column().wFull().maxW(520).rounded(14).bg(t.gray_100).border(t.alpha_300);
    defer card.end();
    if (step(c, "folder", "Open a folder", "The agent reads, edits and runs inside it", .primary, "Choose…")) sessions.openFolder(a);
    ui.div(c).wFull().h(1).bg(t.alpha_200).end();
    if (step(c, "user", "Set up an agent", c.print("New sessions start on {s}; change it, or add your own, in Settings", .{a.agentName(a.defaultAgent())}), .outline, "Settings")) settings.open(a);
}

fn step(c: *ui.Context, name: []const u8, title: []const u8, detail: []const u8, kind: enum { primary, outline }, button: []const u8) bool {
    const row = ui.div(c).row().wFull().gap(14).px(16).py(16).itemsCenter();
    defer row.end();
    {
        // A tile in its icon's color, faintly: folders amber, agents blue.
        const tone = if (std.mem.eql(u8, name, "folder")) t.amber_900 else t.blue_900;
        const b = ui.div(c).w(32).h(32).center().rounded(8).bg(tone.alpha(0.12)).border(tone.alpha(0.25));
        defer b.end();
        k.icon(c, name, .{ .size = 16, .color = tone });
    }
    {
        const col = ui.div(c).column().grow().gap(2);
        defer col.end();
        ui.text(c, title, .{ .size = 14 });
        ui.text(c, detail, .{ .size = 13, .color = t.gray_900, .wrap = true });
    }
    return switch (kind) {
        .primary => k.primaryButton(c, button, ui.keys.label("⌘O")),
        .outline => k.outlineButton(c, button, null),
    };
}

// ---------------------------------------------------------------------------

/// The local time zone's offset from UTC, in minutes, for day headings.
fn tzOffsetMinutes() i64 {
    if (builtin.os.tag == .windows) {
        var tz: TimeZoneInformation = undefined;
        const r = GetTimeZoneInformation(&tz);
        if (r == 0xFFFFFFFF) return 0;
        const extra: i32 = if (r == 2) tz.DaylightBias else tz.StandardBias;
        return -@as(i64, tz.Bias + extra);
    }
    return 0;
}

const SystemTime = extern struct { a: [8]u16 };
const TimeZoneInformation = extern struct {
    Bias: i32,
    StandardName: [32]u16,
    StandardDate: SystemTime,
    StandardBias: i32,
    DaylightName: [32]u16,
    DaylightDate: SystemTime,
    DaylightBias: i32,
};
extern "kernel32" fn GetTimeZoneInformation(tz: *TimeZoneInformation) callconv(.winapi) u32;
