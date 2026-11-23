//! The sidebar, the tab bar shown while it is closed, the header above a
//! session, and the menus they open.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const app_mod = @import("../app/app.zig");
const state = @import("../app/state.zig");
const sessions = @import("../app/sessions.zig");
const format = @import("../app/format.zig");
const t = @import("../design/tokens.zig");
const k = @import("../design/components.zig");
const palette = @import("palette.zig");
const changes = @import("changes.zig");
const settings = @import("settings/settings.zig");
const branches = @import("branches.zig");

const App = app_mod.App;
const Session = state.Session;
const Workspace = state.Workspace;

/// How many sessions a folder lists before "Show more".
const recent = 5;

// ---------------------------------------------------------------------------
// Pieces shared with Home.

/// A session's state as a mark: amber waiting, a spinner running, red
/// stopped; false (nothing drawn) when idle.
pub fn statusMark(c: *ui.Context, st: state.Status) bool {
    switch (st) {
        .waiting => k.dot(c, t.amber_700),
        .running => k.spinner(c, 12),
        .stopped => k.dot(c, t.red_700),
        .idle => return false,
    }
    return true;
}

/// A session's status, counting an error it shows as stopped and an agent
/// starting as running.
pub fn statusOf(s: *const Session) state.Status {
    const st = s.status();
    if (st == .idle and s.err != null) return .stopped;
    if (st == .idle and s.opening) return .running;
    return st;
}

/// One line of text that takes the room left in its row and is cut off
/// where it runs out.
pub fn clipped(c: *ui.Context, text: []const u8, style: ui.TextStyle) void {
    const b = ui.div(c).row().grow().w(0).clip().itemsCenter();
    defer b.end();
    ui.text(c, text, style);
}

/// The first letter of the user's name, in a circle.
pub fn avatar(a: *App, c: *ui.Context) void {
    const b = ui.div(c).w(24).h(24).rounded(12).bg(t.gray_300).center();
    defer b.end();
    const name = userName(a);
    const letter: u8 = if (name.len > 0) std.ascii.toUpper(name[0]) else 'U';
    ui.text(c, c.print("{c}", .{letter}), .{ .size = 11, .weight = .semibold });
}

pub fn userName(a: *App) []const u8 {
    return a.env.get("USERNAME") orelse a.env.get("USER") orelse "You";
}

fn toggleSidebar(a: *App, c: *ui.Context) void {
    if (k.iconButton(c, "panel-left", 16, if (a.sidebar_open) "Hide the sidebar" else "Show the sidebar"))
        a.sidebar_open = !a.sidebar_open;
}

// ---------------------------------------------------------------------------
// The sidebar.

pub fn sidebar(a: *App, c: *ui.Context) void {
    const col = ui.div(c).column().wFull().hFull().px(8).pb(8);
    defer col.end();
    {
        const top = ui.div(c).row().wFull().h(48).pl(8).pr(4).gap(8).itemsCenter();
        defer top.end();
        k.logo(c, 20);
        ui.text(c, "BM Coding Agent", .{ .size = 14, .weight = .semibold });
        ui.spacer(c);
        toggleSidebar(a, c);
    }
    nav(a, c);
    {
        const list = ui.div(c).column().wFull().grow().h(0).scrollY();
        defer list.end();
        for (a.workspaces.items, 0..) |w, wi| group(a, c, w, wi);
        if (a.workspaces.items.len == 0) noWorkspaces(c) else addFolderRow(a, c);
    }
    accountRow(a, c);
}

fn navRow(c: *ui.Context, name: []const u8, label: []const u8, keys: []const u8, on: bool, tint: ui.Color) bool {
    const r = ui.div(c).row().wFull().h(30).px(8).gap(10).itemsCenter().rounded(6).control();
    if (on) _ = r.bg(t.alpha_200);
    _ = r.hover(t.alpha_200);
    k.icon(c, name, .{ .size = 16, .color = tint });
    clipped(c, label, .{ .size = 13 });
    if (keys.len > 0) ui.text(c, keys, .{ .size = 12, .color = t.gray_700 });
    r.end();
    return k.press(r);
}

fn nav(a: *App, c: *ui.Context) void {
    const col = ui.div(c).column().wFull().gap(1).pt(4);
    defer col.end();
    const home = a.page == .session and a.workspace() != null and (if (a.active) |s| s.isEmpty() else true);
    if (navRow(c, "compose", "New session", ui.keys.label("⌘N"), home, t.green_900)) sessions.newSession(a);
    if (navRow(c, "search", "Search", ui.keys.label("⌘K"), a.palette.open, t.blue_900)) palette.toggle(a);
    if (navRow(c, "folder", "Open folder", ui.keys.label("⌘O"), false, t.amber_900)) sessions.openFolder(a);
}

fn noWorkspaces(c: *ui.Context) void {
    const col = ui.div(c).column().wFull().pt(20).px(8).gap(2);
    defer col.end();
    ui.text(c, "No folders yet", .{ .size = 12, .weight = .medium, .color = t.gray_900 });
    ui.text(c, "Sessions show up here once you add a folder.", .{ .size = 12, .color = t.gray_700, .wrap = true });
}

fn addFolderRow(a: *App, c: *ui.Context) void {
    const pad = ui.div(c).column().wFull().pt(16);
    defer pad.end();
    const r = ui.div(c).row().wFull().h(30).px(8).gap(8).itemsCenter().rounded(6).control();
    const hot = r.hovered();
    _ = r.hover(t.alpha_200);
    clipped(c, "Add folder", .{ .size = 13, .color = if (hot) t.gray_1000 else t.gray_700 });
    ui.text(c, ui.keys.label("⌘O"), .{ .size = 12, .color = t.gray_700 });
    r.end();
    if (k.press(r)) sessions.openFolder(a);
}

fn listedCount(w: *const Workspace) usize {
    var n: usize = 0;
    for (w.sessions.items) |s| {
        if (!s.isEmpty()) n += 1;
    }
    return n;
}

/// A folder: its heading (folded or not, with how many sessions it has),
/// then its sessions, indented along a guide line.
fn group(a: *App, c: *ui.Context, w: *Workspace, wi: usize) void {
    c.keyed(w);
    const col = ui.div(c).column().wFull().gap(2).pt(if (wi == 0) 16 else 10);
    defer col.end();
    if (wi > 0) {
        const line = ui.div(c).wFull().px(8).pb(8);
        defer line.end();
        k.hairline(c);
    }
    const total = listedCount(w);
    const current = a.folder == wi;
    {
        const head = ui.div(c).row().wFull().h(34).px(8).gap(8).itemsCenter().rounded(6).control();
        const hi = head.interaction();
        _ = head.hover(t.alpha_100);
        if (hi.hovered) c.cursor = .hand;
        k.icon(c, if (w.collapsed) "chevron-right" else "chevron-down", .{ .size = 12, .color = t.gray_700 });
        k.icon(c, "folder", .{ .size = 15, .color = if (current) t.amber_900 else t.amber_900.alpha(0.55) });
        clipped(c, w.name, .{ .size = 14, .weight = .semibold, .color = t.gray_1000 });
        if (total > 0) ui.text(c, c.print("{d}", .{total}), .{ .size = 12, .weight = .medium, .color = t.gray_700 });
        {
            const plus = ui.div(c).w(22).h(22).center().rounded(5).hover(t.alpha_300).control();
            k.icon(c, "plus", .{ .size = 14, .color = t.gray_900 });
            plus.end();
            ui.tooltip(c, plus.interaction(), "New session in this folder");
            if (k.press(plus)) sessions.newSessionIn(a, w) else if (hi.clicked) w.collapsed = !w.collapsed;
        }
        head.end();
        folderMenu(a, c, w, wi, hi);
    }
    if (w.collapsed) return;
    if (total == 0) {
        const none = ui.div(c).wFull().pl(38).py(4);
        defer none.end();
        ui.text(c, "No sessions yet", .{ .size = 12, .color = t.gray_700 });
        return;
    }
    const shown = if (w.show_all) total else @min(total, recent);
    // The sessions hang from the folder along a guide line.
    const body = ui.div(c).row().wFull().pl(15).itemsStretch();
    defer body.end();
    ui.div(c).w(1).bg(t.alpha_300).end();
    const list = ui.div(c).column().grow().w(0).pl(6).gap(1);
    defer list.end();
    var n: usize = 0;
    for (w.sessions.items) |s| {
        if (s.isEmpty()) continue;
        if (n == shown) break;
        n += 1;
        sessionRow(a, c, s);
    }
    if (total > recent) {
        const r = ui.div(c).row().wFull().h(28).px(8).itemsCenter().rounded(6).control();
        const hot = r.hovered();
        ui.text(c, if (w.show_all) "Show fewer" else c.print("Show {d} more", .{total - recent}), .{ .size = 12, .weight = .medium, .color = if (hot) t.gray_1000 else t.gray_700 });
        r.end();
        if (k.press(r)) w.show_all = !w.show_all;
    }
}

/// Opens a folder where the system shows files.
const reveal_label = switch (@import("builtin").os.tag) {
    .windows => "Reveal in File Explorer",
    .macos => "Reveal in Finder",
    else => "Open in file manager",
};

/// The folder heading's menu: a right click on it.
fn folderMenu(a: *App, c: *ui.Context, w: *Workspace, wi: usize, target: ui.Interaction) void {
    const m = ui.contextMenu(c, &a.menus.folders, target) orelse return;
    defer m.end();
    if (m.item("New session", .{ .icon = "plus", .shortcut = ui.keys.label("⌘N") })) sessions.newSessionIn(a, w);
    if (m.item(reveal_label, .{ .icon = "folder" })) _ = myzig.shell.openPath(w.path);
    if (m.item("Copy path", .{ .icon = "doc.on.doc" })) myzig.clipboard.writeText(w.path);
    m.separator();
    if (m.item("Remove folder", .{ .icon = "trash" })) {
        a.dialog = .{ .remove_folder = wi };
        a.dialog_state.show();
    }
}

fn sessionRow(a: *App, c: *ui.Context, s: *Session) void {
    c.keyed(s);
    const selected = a.page == .session and a.active == s;
    const r = ui.div(c).row().wFull().h(32).px(8).gap(8).itemsCenter().rounded(6).control();
    const it = r.interaction();
    const menu_open = a.menus.row.isOpen() and a.menus.row.owner == it.id;
    if (selected or menu_open) _ = r.bg(t.alpha_300);
    _ = r.hover(t.alpha_200);
    if (it.hovered) c.cursor = .hand;
    // The open session: a bar at its start, its name brighter and bolder.
    ui.div(c).w(3).h(16).rounded(2).bg(if (selected) t.accent else t.accent.alpha(0)).end();
    clipped(c, a.label(s), .{ .size = 14, .weight = if (selected) .medium else .regular, .color = if (selected) t.gray_1000 else t.gray_900 });
    {
        const tail = ui.div(c).row().h(20).gap(6).itemsCenter().justifyEnd();
        defer tail.end();
        // The "…" is always built, and shows on hover: a box that came and
        // went would move the ids after it.
        const show_more = it.hovered or menu_open;
        const b = ui.div(c).w(if (show_more) 20 else 0).h(20).center().rounded(5).control();
        if (menu_open) _ = b.bg(t.alpha_300) else if (show_more) _ = b.hover(t.alpha_300);
        if (show_more) k.icon(c, "ellipsis", .{ .size = 14, .color = t.gray_1000 });
        b.end();
        if (show_more) {
            if (k.press(b) and !menu_open) {
                a.menus.row.openBelow(b.interaction().rect orelse .{});
                a.menus.row.owner = it.id;
                // Owned as of now, or contextMenu takes it for a row gone and closes it.
                a.menus.row.owner_frame = c.frame;
            }
        } else if (!statusMark(c, statusOf(s))) {
            var buf: [32]u8 = undefined;
            ui.text(c, format.ago(&buf, a.now(), s.updated), .{ .size = 12, .color = t.gray_700 });
        }
    }
    r.end();
    if (it.clicked) sessions.select(a, s);
    sessionMenu(a, c, s, &a.menus.row, it);
}

/// A session's menu, from its row (right click or its "…") or its tab.
fn sessionMenu(a: *App, c: *ui.Context, s: *Session, menu: *ui.Menu, target: ui.Interaction) void {
    const m = ui.contextMenu(c, menu, target) orelse return;
    defer m.end();
    sessionItems(a, s, m);
}

fn sessionItems(a: *App, s: *Session, m: *ui.MenuPanel) void {
    if (m.item("Rename", .{ .icon = "pencil" })) startRename(a, s);
    if (m.item("Show changes", .{ .icon = "doc.text", .shortcut = ui.keys.label("⌘\\") })) {
        if (a.active != s) sessions.select(a, s);
        if (a.changes == null) changes.toggle(a);
    }
    if (a.active != s and s.id != null) {
        if (m.item("Open beside", .{ .icon = "rectangle.on.rectangle" })) sessions.openBeside(a, s);
    }
    if (s.id) |id| {
        if (m.item("Copy session id", .{ .icon = "doc.on.doc" })) myzig.clipboard.writeText(id);
    }
    m.separator();
    if (m.item("Archive", .{ .icon = "archive" })) {
        a.dialog = .{ .remove = s };
        a.dialog_state.show();
    }
    if (m.item("Delete", .{ .icon = "trash" })) {
        a.dialog = .{ .delete = s };
        a.dialog_state.show();
    }
}

fn startRename(a: *App, s: *Session) void {
    a.rename.set(a.label(s));
    a.rename.select(0, a.rename.text().len);
    a.dialog = .{ .rename = s };
    a.dialog_state.show();
}

/// Who is using the app, and what the session runs on: opens Settings.
fn accountRow(a: *App, c: *ui.Context) void {
    const r = ui.div(c).row().wFull().h(44).px(8).gap(10).itemsCenter().rounded(8).control();
    if (a.page == .settings) _ = r.bg(t.alpha_200);
    _ = r.hover(t.alpha_200);
    avatar(a, c);
    {
        const col = ui.div(c).column().grow().w(0).clip();
        defer col.end();
        ui.text(c, userName(a), .{ .size = 13 });
        const agent_id = if (a.active) |s| s.agent else a.defaultAgent();
        ui.text(c, a.agentName(agent_id), .{ .size = 12, .color = t.gray_700 });
    }
    k.icon(c, "settings", .{ .size = 16, .color = t.gray_900 });
    r.end();
    if (k.press(r)) settings.open(a);
}

// ---------------------------------------------------------------------------
// The tab bar, in place of the sidebar.

pub fn tabs(a: *App, c: *ui.Context) void {
    const bar = ui.div(c).row().wFull().h(48).pl(12).pr(12).gap(8).itemsCenter();
    defer bar.end();
    toggleSidebar(a, c);
    foldersButton(a, c);
    ui.div(c).w(1).h(16).bg(t.alpha_300).end();
    {
        const strip = ui.div(c).row().grow().w(0).gap(2).itemsCenter().clip();
        defer strip.end();
        const room = c.size.w - 420;
        const fit: usize = @intFromFloat(std.math.clamp(room / 150, 2, 8));
        const open: ?*Session = if (a.page == .session) a.active else null;
        if (a.workspace()) |w| {
            var shown: [8]*Session = undefined;
            var n: usize = 0;
            var kept: ?*Session = null;
            for (w.sessions.items) |s| {
                if (s.isEmpty()) continue;
                if (n < fit) {
                    shown[n] = s;
                    n += 1;
                } else if (open == s) kept = s;
            }
            // The open session keeps a tab, in the last place.
            if (kept) |s| shown[n - 1] = s;
            for (shown[0..n]) |s| tab(a, c, s, open == s);
        }
        const home = if (a.active) |s| s.isEmpty() else true;
        const nb = ui.div(c).w(28).h(28).center().rounded(8).control();
        if (home and a.page == .session) _ = nb.bg(t.alpha_200) else _ = nb.hover(t.alpha_200);
        k.icon(c, "plus", .{ .size = 14, .color = t.gray_900 });
        nb.end();
        ui.tooltip(c, nb.interaction(), "New session");
        if (k.press(nb)) sessions.newSession(a);
    }
    if (k.iconButton(c, "search", 16, "Search")) palette.toggle(a);
    if (k.iconButton(c, "settings", 16, "Settings")) settings.open(a);
    {
        const av = ui.div(c).control();
        avatar(a, c);
        av.end();
        if (k.press(av)) settings.open(a);
    }
}

fn tab(a: *App, c: *ui.Context, s: *Session, on: bool) void {
    c.keyed(s);
    const b = ui.div(c).row().h(32).px(12).gap(8).itemsCenter().rounded(8).maxW(220).minW(64).clip().control();
    if (on) _ = b.bg(t.gray_100).border(t.alpha_300) else _ = b.hover(t.alpha_100);
    _ = statusMark(c, statusOf(s));
    ui.text(c, a.label(s), .{ .size = 13, .color = if (on) t.gray_1000 else t.gray_900, .weight = if (on) .medium else .regular });
    b.end();
    const it = b.interaction();
    if (k.press(b)) sessions.select(a, s);
    sessionMenu(a, c, s, &a.menus.row, it);
}

fn foldersButton(a: *App, c: *ui.Context) void {
    const wi = a.folder orelse 0;
    var elsewhere = false;
    for (a.workspaces.items, 0..) |w, i| {
        if (i != wi and w.sessionStatus() == .waiting) elsewhere = true;
    }
    const b = ui.div(c).row().h(28).px(8).gap(6).itemsCenter().rounded(8).control();
    if (a.menus.folders.isOpen()) _ = b.bg(t.alpha_200);
    _ = b.hover(t.alpha_200);
    {
        const name = ui.div(c).maxW(160).clip();
        ui.text(c, if (a.workspace()) |w| w.name else "No folder", .{ .size = 13, .color = t.gray_900 });
        name.end();
    }
    if (elsewhere) _ = statusMark(c, .waiting);
    k.icon(c, "chevron-down", .{ .size = 12, .color = t.gray_700 });
    b.end();
    const it = b.interaction();
    if (it.hovered) c.cursor = .hand;
    const m = ui.buttonMenu(c, &a.menus.folders, it) orelse return;
    defer m.end();
    for (a.workspaces.items, 0..) |w, i| {
        const st = w.sessionStatus();
        const mark = if (st == .waiting) "  · waiting" else if (st == .running) "  · running" else "";
        if (m.item(c.print("{s}{s}", .{ w.name, mark }), .{ .icon = "folder", .checked = a.folder == i })) sessions.newSessionIn(a, w);
    }
    m.separator();
    if (m.item("Add folder", .{ .icon = "plus", .shortcut = ui.keys.label("⌘O") })) sessions.openFolder(a);
}

// ---------------------------------------------------------------------------
// The header.

fn plainHeader(c: *ui.Context, label: []const u8) void {
    const bar = ui.div(c).row().wFull().h(44).pl(20).pr(10).gap(8).itemsCenter();
    defer bar.end();
    clipped(c, label, .{ .size = 13, .color = t.gray_900 });
}

/// A new session's header: where it starts, and the branch to switch.
fn newHeader(a: *App, c: *ui.Context, w: *Workspace, label: []const u8) void {
    const bar = ui.div(c).row().wFull().h(44).pl(20).pr(10).gap(8).itemsCenter();
    defer bar.end();
    clipped(c, label, .{ .size = 13, .color = t.gray_900 });
    branches.button(a, c, w, .{ .menu = &a.menus.branch, .chars = 32, .height = 28 });
}

pub fn header(a: *App, c: *ui.Context) void {
    if (a.page == .settings) return plainHeader(c, "Settings");
    const w = a.workspace() orelse return plainHeader(c, "Welcome");
    const s = a.active orelse return plainHeader(c, w.name);
    if (s.isEmpty()) return newHeader(a, c, w, c.print("{s} · New session on {s}", .{ w.name, a.agentName(s.agent) }));

    const bar = ui.div(c).row().wFull().h(44).pl(20).pr(10).gap(8).itemsCenter();
    defer bar.end();
    ui.text(c, w.name, .{ .size = 13, .color = t.gray_900 });
    k.icon(c, "chevron-right", .{ .size = 12, .color = t.gray_600 });
    clipped(c, a.label(s), .{ .size = 13, .weight = .medium });
    branches.button(a, c, w, .{ .menu = &a.menus.branch, .chars = 32, .height = 28 });
    if (a.changes == null) changesToggle(a, c, w);
    const more = ui.div(c).w(28).h(28).center().rounded(6).control();
    if (a.menus.header.isOpen()) _ = more.bg(t.alpha_200);
    const hot = more.hovered();
    _ = more.hover(t.alpha_200);
    k.icon(c, "ellipsis", .{ .size = 16, .color = if (hot) t.gray_1000 else t.gray_900 });
    more.end();
    const it = more.interaction();
    if (it.hovered) c.cursor = .hand;
    if (ui.buttonMenu(c, &a.menus.header, it)) |m| {
        defer m.end();
        sessionItems(a, s, m);
    }
}

fn changesToggle(a: *App, c: *ui.Context, w: *Workspace) void {
    var added: usize = 0;
    var removed: usize = 0;
    for (w.status) |ch| {
        added += ch.added;
        removed += ch.removed;
    }
    const b = ui.div(c).row().h(28).px(10).gap(6).itemsCenter().rounded(6).border(t.alpha_400).hover(t.alpha_200).control();
    if (w.status.len == 0) ui.text(c, "No changes", .{ .size = 12, .color = t.gray_900 }) else k.stat(c, added, removed);
    b.end();
    ui.tooltip(c, b.interaction(), "Show the changes panel");
    if (k.press(b)) changes.toggle(a);
}
