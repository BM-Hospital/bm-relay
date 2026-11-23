//! The window's frame: the sidebar (or the tab bar while it is closed),
//! the main panel with its header and page, the session beside it, the
//! changes panel, and what floats over them. Also the window's shortcuts.
const std = @import("std");
const ui = @import("myzig").ui;
const app_mod = @import("../app/app.zig");
const t = @import("../design/tokens.zig");
const sessions = @import("../app/sessions.zig");
const turns = @import("../app/turns.zig");
const shell = @import("shell.zig");
const home = @import("home.zig");
const thread = @import("thread.zig");
const composer = @import("composer.zig");
const changes = @import("changes.zig");
const palette = @import("palette.zig");
const dialogs = @import("dialogs.zig");
const settings = @import("settings/settings.zig");
const appearance = @import("../app/appearance.zig");

const App = app_mod.App;

pub fn view(a: *App, c: *ui.Context) void {
    appearance.apply(a, c);
    shortcuts(a, c);
    if (a.anyRunning()) c.frameIn(1);
    turns.tick(a);

    const root = ui.div(c).sizeFull().bg(t.background_200);
    defer root.end();
    if (a.sidebar_open) {
        const row = ui.div(c).row().sizeFull();
        defer row.end();
        {
            const side = ui.div(c).w(a.sidebarWidth() - handle_w).hFull().clip();
            defer side.end();
            shell.sidebar(a, c);
        }
        sidebarHandle(a, c);
        panels(a, c, .{ .top = 8, .right = 8, .bottom = 8 });
    } else {
        const col = ui.div(c).column().sizeFull();
        defer col.end();
        shell.tabs(a, c);
        panels(a, c, .{ .left = 8, .right = 8, .bottom = 8 });
    }
    palette.draw(a, c);
    dialogs.draw(a, c);
    _ = ui.toasts(c, &a.toasts);
    escapeStops(a, c);
}

/// Escape stops the running turn from anywhere in the window. Asked last
/// in the frame: a picker, a menu or a dialog that takes it comes first.
fn escapeStops(a: *App, c: *ui.Context) void {
    if (a.dialog != null or a.palette.open or a.picker != null or a.page != .session) return;
    const s = a.active orelse return;
    if (!s.thread.running() or s.permission != null) return;
    if (c.shortcut(.{ .key = ui.Shortcut.escape })) turns.stop(a);
}

fn panel(c: *ui.Context) ui.Div {
    return ui.div(c).column().grow().hFull().rounded(12).clip().bg(t.background_100).border(t.alpha_200).shadow(t.shadow_panel);
}

fn panels(a: *App, c: *ui.Context, pad: ui.Edges) void {
    ui.row(c, .{ .grow = 1, .width = .fill, .height = .fill, .padding = pad, .gap = 8 });
    defer ui.end(c);
    {
        const main = panel(c);
        defer main.end();
        shell.header(a, c);
        page(a, c);
    }
    if (a.page != .session) return;
    if (a.beside) |b| {
        const side = panel(c);
        defer side.end();
        thread.beside(a, c, b);
    }
    if (a.changes != null) {
        resizeHandle(a, c);
        // The session keeps room for its composer.
        const room = c.size.w - (if (a.sidebar_open) a.sidebarWidth() else 0) - 16 - 560;
        const width = std.math.clamp(@min(a.changes_width, room), 320, 960);
        const p = ui.div(c).column().w(width).hFull().rounded(12).clip().bg(t.background_100).border(t.alpha_200).shadow(t.shadow_panel);
        defer p.end();
        changes.draw(a, c);
    }
}

const handle_w: f32 = 6;

/// The sidebar's edge: dragged, it widens or narrows the sidebar, saved
/// as it is let go; a double click sets it back.
fn sidebarHandle(a: *App, c: *ui.Context) void {
    const h = ui.div(c).w(handle_w).hFull().center().control();
    const it = h.interaction();
    // A line shows where to take it.
    ui.div(c).w(if (it.hovered or it.pressed) 2 else 0).hFull().rounded(1).bg(t.accent.alpha(0.7)).end();
    h.end();
    if (it.hovered or it.pressed) c.cursor = .resize_left_right;
    if (it.double_clicked) {
        a.store.data.sidebar_width = 264;
        a.store.save();
        return;
    }
    if (it.pressed) {
        a.store.data.sidebar_width = std.math.clamp(c.input.mouse.x + handle_w / 2, App.sidebar_min, App.sidebar_max);
        a.sidebar_dragged = true;
        c.wants_moves = true;
    } else if (a.sidebar_dragged) {
        a.sidebar_dragged = false;
        a.store.save();
    }
}

/// The edge of the changes panel, dragged to widen it.
fn resizeHandle(a: *App, c: *ui.Context) void {
    const h = ui.div(c).w(6).hFull().control();
    h.end();
    const it = h.interaction();
    if (it.hovered or it.pressed) c.cursor = .resize_left_right;
    if (it.pressed) {
        const right = c.size.w - 8;
        a.changes_width = std.math.clamp(right - c.input.mouse.x, 360, 960);
        c.wants_moves = true;
    }
}

fn page(a: *App, c: *ui.Context) void {
    if (a.page == .settings) return settings.draw(a, c);
    const s = a.active orelse return home.draw(a, c);
    if (s.isEmpty() and s.err == null) return home.draw(a, c);
    if (s.isEmpty()) {
        const col = ui.div(c).column().grow().wFull();
        defer col.end();
        thread.empty(a, c, s);
        composer.draw(a, c);
        return;
    }
    const col = ui.div(c).column().grow().wFull();
    defer col.end();
    thread.draw(a, c, s);
    composer.draw(a, c);
}

fn shortcuts(a: *App, c: *ui.Context) void {
    if (c.shortcut(.{ .key = 'n', .cmd = true })) sessions.newSession(a);
    if (c.shortcut(.{ .key = 'k', .cmd = true })) palette.toggle(a);
    if (c.shortcut(.{ .key = ',', .cmd = true })) settings.open(a);
    if (c.shortcut(.{ .key = '\\', .cmd = true })) changes.toggle(a);
    if (c.shortcut(.{ .key = 'o', .cmd = true })) sessions.openFolder(a);
    if (c.shortcut(.{ .key = 'b', .cmd = true })) a.sidebar_open = !a.sidebar_open;
    if (c.shortcut(.{ .key = '.', .cmd = true })) turns.stop(a);
    if (c.shortcut(.{ .key = '=', .cmd = true }) or c.shortcut(.{ .key = '+', .cmd = true })) appearance.stepTextSize(a, 1);
    if (c.shortcut(.{ .key = '-', .cmd = true })) appearance.stepTextSize(a, -1);
    if (c.shortcut(.{ .key = '0', .cmd = true })) appearance.setTextSize(a, 1);
}
