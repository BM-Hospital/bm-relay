//! What the changes panel draws: its header with the Files and Diff tabs,
//! the staged and unstaged groups, a clean tree, and a file's diff above
//! the other files folded.
const std = @import("std");
const ui = @import("myzig").ui;
const app_mod = @import("../app/app.zig");
const git = @import("../host/git.zig");
const t = @import("../design/tokens.zig");
const k = @import("../design/components.zig");
const changes = @import("changes.zig");
const diff = @import("diff.zig");

const App = app_mod.App;
const State = changes.State;

pub fn draw(a: *App, c: *ui.Context) void {
    if (a.changes == null) return;
    const col = ui.div(c).column().sizeFull();
    defer col.end();
    header(a, c);
    if (a.changes == null) return;
    const st = &a.changes.?;
    ui.scroll(c, .{ .grow = 1, .width = .fill, .padding = .{ .left = 16, .right = 16, .top = 8, .bottom = 16 }, .gap = 20 });
    defer ui.end(c);
    if (st.open) |open| return diffView(a, c, st, open);
    if (st.err) |e| ui.text(c, e, .{ .size = 13, .color = if (st.list.len == 0) t.gray_700 else t.red_900, .wrap = true });
    if (st.list.len == 0) {
        if (st.loaded and st.err == null) clean(a, c, st);
        if (!st.loaded) ui.text(c, "Reading the changes…", .{ .size = 13, .color = t.gray_700 });
        return;
    }
    var staged: usize = 0;
    for (st.list) |ch| {
        if (ch.staged) staged += 1;
    }
    if (staged > 0) group(a, c, st, true);
    if (staged < st.list.len) group(a, c, st, false);
}

fn header(a: *App, c: *ui.Context) void {
    const st = &a.changes.?;
    const row = ui.div(c).row().wFull().h(44).pl(16).pr(10).gap(10).itemsCenter();
    defer row.end();
    ui.text(c, "Changes", .{ .size = 13, .color = t.gray_900 });
    {
        const mid = ui.div(c).row().grow().itemsCenter();
        defer mid.end();
        if (st.list.len == 0) {
            ui.text(c, "Clean", .{ .size = 12, .color = t.gray_700 });
        } else {
            const tot = st.totals();
            k.stat(c, tot[0], tot[1]);
        }
    }
    tabs(a, c, st.open != null);
    if (k.iconButton(c, "x", 14, "Close")) changes.toggle(a);
}

fn segment(c: *ui.Context, label: []const u8, on: bool) bool {
    const b = ui.div(c).row().px(10).hFull().itemsCenter().rounded(6).control();
    if (on) _ = b.bg(t.gray_300);
    const hot = b.hovered();
    ui.text(c, label, .{ .size = 12, .color = if (on or hot) t.gray_1000 else t.gray_900 });
    b.end();
    return k.press(b);
}

fn tabs(a: *App, c: *ui.Context, showing_diff: bool) void {
    const st = &a.changes.?;
    const row = ui.div(c).row().h(28).p(2).rounded(8).bg(t.gray_100).border(t.alpha_300);
    defer row.end();
    if (segment(c, "Files", !showing_diff)) changes.openChange(a, null);
    if (segment(c, "Diff", showing_diff) and st.open == null and st.list.len > 0) changes.openChange(a, st.list[0]);
}

/// A small button inside a row: outlined, or filled for the main one.
fn rowButton(c: *ui.Context, label: []const u8, filled: bool) bool {
    const b = ui.div(c).row().h(26).px(10).itemsCenter().rounded(6).control();
    if (filled) _ = b.bg(t.accent).hover(t.accent_hover) else _ = b.border(t.alpha_400).hover(t.alpha_200);
    ui.text(c, label, .{ .size = 12, .weight = .medium, .color = if (filled) t.on_accent else t.gray_1000 });
    b.end();
    return k.press(b);
}

fn fileCard(c: *ui.Context) ui.Div {
    return ui.div(c).column().wFull().rounded(12).clip().bg(t.gray_100).border(t.alpha_300);
}

pub fn codeColor(code: u8) ui.Color {
    return switch (code) {
        'A' => t.green_700,
        '?' => t.blue_700,
        'D' => t.red_700,
        else => t.amber_700,
    };
}

pub fn statusDot(c: *ui.Context, code: u8) void {
    ui.div(c).w(6).h(6).rounded(3).bg(codeColor(code)).end();
}

/// A file's row: its status, name and folder. The caller adds what
/// follows and ends it.
fn fileRow(c: *ui.Context, ch: git.Change) ui.Div {
    const cut = std.mem.lastIndexOfScalar(u8, ch.path, '/');
    const name = if (cut) |i| ch.path[i + 1 ..] else ch.path;
    const dir = if (cut) |i| ch.path[0..i] else "";
    const fresh = ch.code == '?' or ch.code == 'A';
    const detail = if (fresh) (if (dir.len == 0) "new file" else c.print("{s} · new file", .{dir})) else dir;
    const row = ui.div(c).row().wFull().h(40).px(12).gap(10).itemsCenter();
    statusDot(c, ch.code);
    ui.text(c, name, .{ .size = 13 });
    {
        const d = ui.div(c).row().wFull().clip();
        defer d.end();
        ui.text(c, detail, .{ .size = 12, .color = t.gray_700 });
    }
    return row;
}

fn group(a: *App, c: *ui.Context, st: *State, staged: bool) void {
    const col = ui.div(c).column().wFull().gap(8);
    defer col.end();
    {
        const head = ui.div(c).row().wFull().px(2).itemsCenter();
        defer head.end();
        {
            const l = ui.div(c).row().grow();
            defer l.end();
            ui.text(c, if (staged) "Staged" else "Not staged", .{ .size = 12, .color = t.gray_700 });
        }
        const b = ui.div(c).row().control();
        const hot = b.hovered();
        ui.text(c, if (staged) "Unstage all" else "Stage all", .{ .size = 12, .color = if (hot) t.gray_1000 else t.gray_900 });
        b.end();
        if (k.press(b)) {
            var paths: std.ArrayList([]const u8) = .empty;
            defer paths.deinit(a.gpa);
            for (st.list) |ch| if (ch.staged == staged) paths.append(a.gpa, ch.path) catch {};
            changes.edit(a, if (staged) .unstage else .stage, paths.items, 'M');
        }
    }
    const card = fileCard(c);
    defer card.end();
    var first = true;
    for (st.list) |ch| {
        if (ch.staged != staged) continue;
        if (!first) k.hairline(c);
        first = false;
        ui.key(c, c.print("{s}:{s}", .{ if (staged) "s" else "u", ch.path }));
        if (groupRow(a, c, ch)) |act| switch (act) {
            .open => return changes.openChange(a, ch),
            .stage => return changes.stageToggle(a, ch),
            .discard => return changes.askDiscard(a, ch),
        };
    }
}

const Act = enum { open, stage, discard };

fn groupRow(a: *App, c: *ui.Context, ch: git.Change) ?Act {
    _ = a;
    var act: ?Act = null;
    const row = fileRow(c, ch).hover(t.alpha_100);
    const hot = row.hovered();
    if (hot) {
        if (!ch.staged) {
            const d = ui.div(c).row().px(6).control();
            const dh = d.hovered();
            ui.text(c, "Discard", .{ .size = 12, .color = if (dh) t.red_900 else t.gray_900 });
            d.end();
            if (k.press(d)) act = .discard;
        }
        if (rowButton(c, if (ch.staged) "Unstage" else "Stage", !ch.staged)) act = .stage;
    } else k.stat(c, ch.added, ch.removed);
    row.end();
    if (k.press(row) and act == null) act = .open;
    return act;
}

fn clean(a: *App, c: *ui.Context, st: *State) void {
    const branch = if (a.workspace()) |w| w.branch orelse "HEAD" else "HEAD";
    const col = ui.div(c).column().wFull().itemsCenter().gap(14).pt(80);
    defer col.end();
    {
        const badge = ui.div(c).w(40).h(40).rounded(20).center().bg(t.gray_100).border(t.alpha_300);
        defer badge.end();
        k.icon(c, "check", .{ .size = 18, .color = t.green_900 });
    }
    {
        const words = ui.div(c).column().itemsCenter().gap(4);
        defer words.end();
        ui.text(c, "Nothing to commit", .{ .size = 14, .weight = .medium });
        const line = ui.div(c).row().itemsCenter();
        defer line.end();
        ui.text(c, "The working tree matches ", .{ .size = 13, .color = t.gray_900 });
        ui.text(c, branch, .{ .size = 12, .mono = true, .color = t.gray_900 });
        ui.text(c, ".", .{ .size = 13, .color = t.gray_900 });
    }
    if (st.last_commit) |l| ui.text(c, c.print("Last commit {s}", .{l}), .{ .size = 12, .color = t.gray_700 });
}

fn diffView(a: *App, c: *ui.Context, st: *State, open: git.Change) void {
    if (st.err) |e| ui.text(c, e, .{ .size = 13, .color = t.red_900, .wrap = true });
    const limit: usize = if (st.full) st.diff.len else changes.diff_lines;
    const hidden = st.diff.len -| limit;
    {
        const card = fileCard(c);
        defer card.end();
        {
            const row = fileRow(c, open).pr(8);
            defer row.end();
            {
                const p = ui.div(c).row().pr(6);
                defer p.end();
                k.stat(c, open.added, open.removed);
            }
            if (rowButton(c, if (open.staged) "Unstage" else "Stage", false)) {
                changes.stageToggle(a, open);
                return;
            }
        }
        k.hairline(c);
        diff.block(c, st.diff, limit);
        if (hidden > 0 and diff.showMore(c, hidden)) st.full = true;
    }
    for (st.list) |ch| {
        if (st.isOpen(ch)) continue;
        ui.key(c, c.print("folded:{s}:{s}", .{ if (ch.staged) "s" else "u", ch.path }));
        const card = fileCard(c);
        const row = fileRow(c, ch).hover(t.alpha_100);
        k.stat(c, ch.added, ch.removed);
        k.icon(c, "chevron-down", .{ .size = 12, .color = t.gray_900 });
        row.end();
        card.end();
        if (k.press(row)) return changes.openChange(a, ch);
    }
}
