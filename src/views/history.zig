//! Home's History tab: the folder's sessions as its agent keeps them, the
//! sidebar's and the CLI's alike, newest first. A press opens one.
const std = @import("std");
const ui = @import("myzig").ui;
const app_mod = @import("../app/app.zig");
const state = @import("../app/state.zig");
const history = @import("../app/history.zig");
const format = @import("../app/format.zig");
const t = @import("../design/tokens.zig");
const k = @import("../design/components.zig");
const shell = @import("shell.zig");

const App = app_mod.App;
const Workspace = state.Workspace;

/// The rows; how many it drew (none: the tab's empty note shows).
pub fn rows(a: *App, c: *ui.Context, w: *Workspace) usize {
    const h = &a.history;
    const agent_id = history.pick(a, w);
    if (!h.isFor(w, agent_id) and !h.loading) history.fetch(a, w, false);
    head(a, c, w, agent_id);
    if (h.err) |e| {
        note(c, "The agent could not list its sessions", e);
        return 1;
    }
    if (h.items.items.len == 0) {
        if (h.loading) note(c, c.print("Asking {s}…", .{a.agentName(agent_id)}), "") else note(c, "No sessions yet", c.print("{s} has none in this folder.", .{a.agentName(agent_id)}));
        return 1;
    }
    const now = a.now();
    var opened: ?history.Entry = null;
    var hidden: usize = 0;
    var shown: usize = 0;
    for (h.items.items, 0..) |e, i| {
        const mine = a.byId(e.id);
        // The session this app keeps open for a new prompt: nothing in it.
        if (mine) |m| if (m.isEmpty()) continue;
        if (!h.show_untitled and history.untitled(e.title)) {
            hidden += 1;
            continue;
        }
        shown += 1;
        c.keyed(i);
        const here = mine != null;
        const r = ui.div(c).row().wFull().h(34).px(10).gap(10).itemsCenter().rounded(8).hover(t.alpha_100).control();
        {
            const m = ui.div(c).w(16).h(16).center();
            defer m.end();
            k.icon(c, if (here) "check" else "terminal", .{ .size = 13, .color = if (here) t.green_900 else t.gray_700 });
        }
        shell.clipped(c, if (e.title.len > 0) e.title else "Untitled session", .{ .size = 14 });
        if (here) ui.text(c, "In the sidebar", .{ .size = 12, .color = t.gray_700 });
        {
            const ag = ui.div(c).row().w(56).justifyEnd();
            defer ag.end();
            var buf: [32]u8 = undefined;
            ui.text(c, format.ago(&buf, now, e.updated), .{ .size = 12, .color = t.gray_700 });
        }
        // Delete, while the pointer is on the row: always built (the boxes
        // after keep their ids), as wide as nothing when hidden.
        const show = h.can_delete and r.hovered();
        const x = ui.div(c).w(if (show) 24 else 0).h(24).center().rounded(6).control();
        const xhot = x.hovered();
        if (show) {
            if (xhot) _ = x.bg(t.red_700.alpha(0.15));
            k.icon(c, "x", .{ .size = 14, .color = if (xhot) t.red_900 else t.gray_700 });
        }
        x.end();
        if (show) ui.tooltip(c, x.interaction(), "Delete for good");
        r.end();
        if (show and k.press(x)) history.askDelete(a, e) else if (k.press(r)) opened = e;
    }
    if (hidden > 0 or h.show_untitled) {
        const u = ui.div(c).row().wFull().h(32).px(10).itemsCenter().control();
        const hot = u.hovered();
        ui.text(c, if (h.show_untitled) "Hide untitled sessions" else c.print("Show {d} untitled (most are empty)", .{hidden}), .{ .size = 13, .color = if (hot) t.gray_1000 else t.gray_700 });
        u.end();
        if (k.press(u)) h.show_untitled = !h.show_untitled;
    }
    if (shown == 0 and hidden > 0 and !h.show_untitled) note(c, "No titled sessions", "Those left are untitled: most never had a prompt.");
    if (h.next != null) {
        const more = ui.div(c).row().wFull().h(32).px(10).itemsCenter().control();
        const hot = more.hovered();
        ui.text(c, if (h.loading) "Loading…" else "Load more", .{ .size = 13, .color = if (hot) t.gray_1000 else t.gray_900 });
        more.end();
        if (k.press(more) and !h.loading) history.fetch(a, w, true);
    }
    if (opened) |e| history.open(a, w, e);
    return @max(shown, 1);
}

/// Whose sessions these are, a menu of the agents to list another's, and
/// a button to read the list again.
fn head(a: *App, c: *ui.Context, w: *Workspace, agent_id: []const u8) void {
    const row = ui.div(c).row().wFull().h(34).px(6).gap(8).itemsCenter();
    defer row.end();
    const b = ui.div(c).row().h(28).px(8).gap(6).itemsCenter().rounded(6).control();
    if (a.menus.history_agent.isOpen()) _ = b.bg(t.alpha_200) else _ = b.hover(t.alpha_200);
    k.icon(c, "user", .{ .size = 13, .color = t.blue_900 });
    ui.text(c, a.agentName(agent_id), .{ .size = 13, .weight = .medium });
    k.icon(c, "chevron-down", .{ .size = 12, .color = t.gray_700 });
    b.end();
    const it = b.interaction();
    if (it.hovered) c.cursor = .hand;
    ui.text(c, "sessions in this folder, from this app and its own CLI", .{ .size = 12, .color = t.gray_700 });
    ui.spacer(c);
    if (k.iconButton(c, "arrow.clockwise", 13, "Read the list again")) history.fetch(a, w, false);
    const m = ui.buttonMenu(c, &a.menus.history_agent, it) orelse return;
    defer m.end();
    for (a.store.data.agents) |ag| {
        if (ag.off) continue;
        if (m.item(ag.name, .{ .checked = std.mem.eql(u8, ag.id, agent_id) })) {
            history.choose(a, w, ag.id);
            history.fetch(a, w, false);
        }
    }
}

fn note(c: *ui.Context, title: []const u8, detail: []const u8) void {
    const col = ui.div(c).column().wFull().itemsCenter().gap(6).py(36);
    defer col.end();
    ui.text(c, title, .{ .size = 14 });
    if (detail.len > 0) ui.text(c, detail, .{ .size = 13, .color = t.gray_700, .wrap = true });
}
