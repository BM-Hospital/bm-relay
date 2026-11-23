//! The command palette (Ctrl+K): this session's commands, the app's, the
//! folders and the sessions of every folder, ranked as the user types.
//! ↑ and ↓ move, Return runs, Escape or a press outside closes it.
const std = @import("std");
const ui = @import("myzig").ui;
const app_mod = @import("../app/app.zig");
const state = @import("../app/state.zig");
const format = @import("../app/format.zig");
const sessions = @import("../app/sessions.zig");
const turns = @import("../app/turns.zig");
const agent = @import("../app/agent.zig");
const pickers = @import("../host/pickers.zig");
const t = @import("../design/tokens.zig");
const k = @import("../design/components.zig");
const changes = @import("changes.zig");
const dialogs = @import("dialogs.zig");
const settings = @import("settings/settings.zig");

const App = app_mod.App;
const Session = state.Session;

/// Entries shown at most.
const shown = 12;

pub const State = struct {
    open: bool = false,
    overlay: ui.OverlayState = .{},
    query: ui.TextBuffer = .{},
    selected: usize = 0,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        _ = s;
        _ = gpa;
    }
};

pub fn toggle(a: *App) void {
    a.palette.open = !a.palette.open;
    if (a.palette.open) {
        a.palette.query.clear();
        a.palette.selected = 0;
        a.picker = null;
    }
    a.redraw();
}

pub const Command = union(enum) {
    new_session,
    open_folder,
    settings,
    changes,
    sidebar,
    rename,
    remove,
    delete,
    stop,
    restore,
    forget,
    folder: usize,
    open: *Session,
};

pub const Entry = struct {
    group: []const u8,
    icon: []const u8,
    label: []const u8,
    detail: []const u8 = "",
    keys: []const u8 = "",
    command: Command,
};

/// Every entry, before ranking, in `ar`'s memory.
fn entries(a: *App, ar: std.mem.Allocator) []Entry {
    var list: std.ArrayList(Entry) = .empty;
    const add = struct {
        fn f(l: *std.ArrayList(Entry), al: std.mem.Allocator, e: Entry) void {
            l.append(al, e) catch {};
        }
    }.f;
    if (a.active) |s| {
        const running = s.thread.running();
        if (s.id != null and !s.isEmpty()) {
            add(&list, ar, .{ .group = "This session", .icon = "pencil", .label = "Rename this session", .command = .rename });
            add(&list, ar, .{ .group = "This session", .icon = "archive", .label = "Archive this session", .command = .remove });
            add(&list, ar, .{ .group = "This session", .icon = "trash", .label = "Delete this session", .command = .delete });
        }
        if (running) add(&list, ar, .{ .group = "This session", .icon = "x", .label = "Stop the running turn", .keys = "Esc", .command = .stop });
        if (s.snap) |sn| if (sn.after != null and !running)
            add(&list, ar, .{ .group = "This session", .icon = "copy", .label = "Restore this turn's files", .command = .restore });
        if (s.grants.items.len > 0 and !running)
            add(&list, ar, .{ .group = "This session", .icon = "shield", .label = "Forget what this session may do without asking", .command = .forget });
    }
    add(&list, ar, .{ .group = "Commands", .icon = "compose", .label = "New session", .keys = ui.keys.label("⌘N"), .command = .new_session });
    add(&list, ar, .{ .group = "Commands", .icon = "folder", .label = "Open folder", .keys = ui.keys.label("⌘O"), .command = .open_folder });
    add(&list, ar, .{ .group = "Commands", .icon = "panel-split", .label = if (a.changes != null) "Hide changes" else "Show changes", .keys = ui.keys.label("⌘\\"), .command = .changes });
    add(&list, ar, .{ .group = "Commands", .icon = "panel-left", .label = "Toggle the sidebar", .keys = ui.keys.label("⌘B"), .command = .sidebar });
    add(&list, ar, .{ .group = "Commands", .icon = "settings", .label = "Settings", .keys = ui.keys.label("⌘,"), .command = .settings });
    for (a.workspaces.items, 0..) |w, i| {
        var buf: [512]u8 = undefined;
        add(&list, ar, .{ .group = "Folders", .icon = "folder", .label = w.name, .detail = ar.dupe(u8, app_mod.tilde(a, &buf, w.path)) catch "", .command = .{ .folder = i } });
    }
    const now = a.now();
    for (a.workspaces.items) |w| for (w.sessions.items) |s| {
        if (s.id == null or s.isEmpty()) continue;
        var buf: [32]u8 = undefined;
        const when = format.ago(&buf, now, s.updated);
        add(&list, ar, .{
            .group = "Sessions",
            .icon = "lines",
            .label = a.label(s),
            .detail = if (when.len > 0) std.fmt.allocPrint(ar, "{s} · {s}", .{ w.name, when }) catch w.name else w.name,
            .command = .{ .open = s },
        });
    };
    return list.items;
}

/// The entries that match `query`, best first, at most `shown`; all of
/// them in order (to `shown`) for an empty query.
pub fn ranked(ar: std.mem.Allocator, list: []const Entry, query: []const u8) []const Entry {
    const q = std.mem.trim(u8, query, " \t\r\n");
    if (q.len == 0) return list[0..@min(list.len, shown)];
    const labels = ar.alloc([]const u8, list.len) catch return &.{};
    for (list, labels) |e, *l| l.* = e.label;
    const order = pickers.rank(ar, labels, q, shown);
    const out = ar.alloc(Entry, order.len) catch return &.{};
    for (order, out) |i, *o| o.* = list[i];
    return out;
}

fn run(a: *App, e: Entry) void {
    a.palette.open = false;
    a.palette.overlay.close();
    switch (e.command) {
        .new_session => sessions.newSession(a),
        .open_folder => sessions.openFolder(a),
        .settings => settings.open(a),
        .changes => changes.toggle(a),
        .sidebar => a.sidebar_open = !a.sidebar_open,
        .stop => turns.stop(a),
        .restore => turns.restoreTurn(a),
        .forget => if (a.active) |s| agent.reload(a, s),
        .rename => if (a.active) |s| dialogs.startRename(a, s),
        .remove => if (a.active) |s| dialogs.ask(a, .{ .remove = s }),
        .delete => if (a.active) |s| dialogs.ask(a, .{ .delete = s }),
        .folder => |i| if (i < a.workspaces.items.len) sessions.newSessionIn(a, a.workspaces.items[i]),
        .open => |s| if (a.workspaceOf(s) != null) sessions.select(a, s),
    }
    a.redraw();
}

pub fn draw(a: *App, c: *ui.Context) void {
    const p = &a.palette;
    if (p.open and !p.overlay.open) p.overlay.show();
    if (!p.open and p.overlay.open) p.overlay.close();
    const d = ui.dialog(c, &p.overlay, .{ .width = .{ .px = 600 }, .padding = .all(0), .gap = 0, .animated = false }) orelse {
        p.open = false;
        return;
    };
    const top = std.math.clamp(c.size.h * 0.133, 24, 120);
    d.backdropStyle().justify = .start;
    d.backdropStyle().padding = .{ .top = top, .bottom = 24, .left = 24, .right = 24 };
    const panel = d.panelStyle();
    panel.background = t.background_100;
    panel.border = t.alpha_400;
    panel.radius = 12;
    panel.clip = true;
    panel.shadow = t.shadow_modal;
    panel.max_width = @max(0, c.size.w - 48);
    const opened = p.overlay.justOpened(c);
    if (opened) {
        p.query.clear();
        p.selected = 0;
    }
    const ar = c.alloc();
    const list = ranked(ar, entries(a, ar), p.query.text());
    const n = list.len;
    // Taken before the field sees them.
    if (n > 0 and ui.overlays.takeKey(c, .down)) p.selected = (p.selected + 1) % n;
    if (n > 0 and ui.overlays.takeKey(c, .up)) p.selected = (p.selected + n - 1) % n;
    const enter = ui.overlays.takeKey(c, .enter);
    if (p.selected >= n) p.selected = 0;

    var chosen: ?Entry = null;
    var closed = false;
    {
        const head = ui.div(c).row().wFull().h(52).px(16).gap(10).itemsCenter();
        defer head.end();
        k.icon(c, "search", .{ .size = 16, .color = t.gray_900 });
        {
            const f = ui.div(c).row().wFull();
            defer f.end();
            c.next_key = "palette-search";
            const id = c.peekId(null);
            if (opened) c.focus = id;
            if (ui.textField(c, &p.query, .{ .width = .fill, .bare = true, .size = 16, .placeholder = "Search commands and sessions" }).changed) p.selected = 0;
        }
        const esc = ui.div(c).row().h(20).px(6).itemsCenter().rounded(4).bg(t.gray_100).border(t.alpha_400).control();
        ui.text(c, "Esc", .{ .size = 12, .color = t.gray_900 });
        esc.end();
        if (k.press(esc)) closed = true;
    }
    k.hairline(c);
    {
        ui.scroll(c, .{ .width = .fill, .max_height = @max(120, c.size.h - top - 160), .padding = .all(8) });
        defer ui.end(c);
        if (n == 0) {
            const e = ui.div(c).row().wFull().py(22).justifyCenter();
            defer e.end();
            ui.text(c, "Nothing matches", .{ .size = 13, .color = t.gray_700 });
        }
        var last: []const u8 = "";
        for (list, 0..) |e, i| {
            if (!std.mem.eql(u8, e.group, last)) {
                heading(c, e.group, last.len == 0);
                last = e.group;
            }
            ui.keyed(c, i);
            if (row(c, e, i == p.selected, p.query.text())) chosen = e;
        }
    }
    footer(c);
    d.end();
    if (enter and n > 0) chosen = list[p.selected];
    if (chosen) |e| return run(a, e);
    if (closed) {
        p.open = false;
        p.overlay.close();
    }
    if (!p.overlay.open) p.open = false;
}

fn heading(c: *ui.Context, group: []const u8, first: bool) void {
    const h = ui.div(c).row().px(8).pt(if (first) 8 else 12).pb(6);
    defer h.end();
    ui.text(c, group, .{ .size = 12, .weight = .medium, .color = t.gray_900 });
}

/// Where `query` shows in `label`, ignoring case.
pub fn matchAt(label: []const u8, query: []const u8) ?usize {
    const q = std.mem.trim(u8, query, " \t");
    if (q.len == 0 or q.len > label.len) return null;
    var i: usize = 0;
    while (i + q.len <= label.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(label[i .. i + q.len], q)) return i;
    }
    return null;
}

fn row(c: *ui.Context, e: Entry, on: bool, query: []const u8) bool {
    const r = ui.div(c).row().wFull().h(40).px(8).gap(10).itemsCenter().rounded(6).control();
    if (on) _ = r.bg(t.alpha_200) else _ = r.hover(t.alpha_100);
    {
        const mark = ui.div(c).row().w(16).justifyCenter();
        defer mark.end();
        if (e.command == .open) ui.div(c).w(6).h(6).rounded(3).bg(t.gray_500).end() else k.icon(c, e.icon, .{ .size = 16, .color = if (on) t.gray_1000 else t.gray_900 });
    }
    {
        const label = ui.div(c).row().wFull().clip();
        defer label.end();
        const q = std.mem.trim(u8, query, " \t");
        if (matchAt(e.label, q)) |at| {
            if (at > 0) ui.text(c, e.label[0..at], .{ .size = 14 });
            ui.text(c, e.label[at .. at + q.len], .{ .size = 14, .weight = .semibold });
            if (at + q.len < e.label.len) ui.text(c, e.label[at + q.len ..], .{ .size = 14 });
        } else ui.text(c, e.label, .{ .size = 14 });
    }
    const trailing = if (e.keys.len > 0) e.keys else e.detail;
    if (trailing.len > 0) ui.text(c, trailing, .{ .size = 12, .color = t.gray_900 });
    r.end();
    return k.press(r);
}

fn footer(c: *ui.Context) void {
    const f = ui.div(c).row().wFull().h(40).px(16).gap(16).itemsCenter().bg(t.background_200);
    defer f.end();
    ui.text(c, "↑↓ Navigate", .{ .size = 12, .color = t.gray_900 });
    ui.text(c, "⏎ Run", .{ .size = 12, .color = t.gray_900 });
    ui.spacer(c);
    ui.text(c, ui.keys.label("⌘K"), .{ .size = 12, .color = t.gray_700 });
}

test "an empty query keeps the order, a query ranks by label" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = [_]Entry{
        .{ .group = "Commands", .icon = "compose", .label = "New session", .command = .new_session },
        .{ .group = "Commands", .icon = "settings", .label = "Settings", .command = .settings },
        .{ .group = "Commands", .icon = "panel-left", .label = "Toggle the sidebar", .command = .sidebar },
    };
    const all = ranked(arena.allocator(), &list, "  ");
    try std.testing.expectEqual(@as(usize, 3), all.len);
    const r = ranked(arena.allocator(), &list, "set");
    try std.testing.expectEqualStrings("Settings", r[0].label);
    try std.testing.expectEqual(@as(usize, 0), ranked(arena.allocator(), &list, "zzz").len);
    try std.testing.expectEqual(@as(?usize, 4), matchAt("New Session", "sess"));
    try std.testing.expect(matchAt("New", "") == null);
}
