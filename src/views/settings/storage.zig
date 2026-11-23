//! The Storage page: what an agent (Claude Code, Codex, OpenCode) keeps of
//! its sessions on this computer, the biggest projects first, and buttons
//! that free it (`storage.zig`).
const std = @import("std");
const ui = @import("myzig").ui;
const App = @import("../../app/app.zig").App;
const storage = @import("../../app/storage.zig");
const purge = @import("../../app/purge.zig");
const format = @import("../../app/format.zig");
const t = @import("../../design/tokens.zig");
const comp = @import("../../design/components.zig");
const rows = @import("rows.zig");

const Kind = storage.Kind;

pub fn draw(a: *App, c: *ui.Context) void {
    rows.pageTitle(c, "Storage", "What the agents keep of their sessions on this computer, and freeing it. The files sessions changed are never touched.");
    picker(a, c);
    const st = &a.storage;
    if (st.scan == null and !st.loading and st.err == null) storage.refresh(a);
    if (st.err) |e| {
        rows.note(c, e, true);
        if (comp.outlineButton(c, "Try again", null)) storage.refresh(a);
        return;
    }
    const sc = st.scan orelse return note(c, c.print("Reading {s}'s sessions…", .{st.kind.title()}));
    summary(a, c, sc);
    if (sc.projects.len == 0) return note(c, c.print("{s} keeps no sessions here.", .{st.kind.title()}));
    quick(a, c);
    projects(a, c, sc);
    rows.footnote(c, if (st.sized())
        "Sessions open in the app are kept. Claude Code's files of a session go: its transcript, its subagents', its tool results and file history."
    else
        c.print("Sessions open in the app are kept. {s} deletes them itself, from its database: it reuses the space they took, so its folder may not shrink at once.", .{st.kind.title()}));
}

/// Claude Code, and Codex and OpenCode when they are in Settings.
fn picker(a: *App, c: *ui.Context) void {
    var kinds: [3]Kind = undefined;
    var labels: [3][]const u8 = undefined;
    var n: usize = 0;
    var on: usize = 0;
    for ([_]Kind{ .claude, .codex, .opencode }) |k| {
        if (k != .claude and storage.agentFor(a, k) == null) continue;
        if (k == a.storage.kind) on = n;
        kinds[n] = k;
        labels[n] = k.title();
        n += 1;
    }
    if (n < 2) return;
    const box = ui.div(c).w(360);
    defer box.end();
    if (rows.segments(c, labels[0..n], on)) |i| storage.choose(a, kinds[i]);
}

fn note(c: *ui.Context, text: []const u8) void {
    const d = ui.div(c).wFull().py(24);
    defer d.end();
    ui.text(c, text, .{ .size = 13, .color = t.gray_700 });
}

fn sessionsText(c: *ui.Context, n: usize) []const u8 {
    return c.print("{d} session{s}", .{ n, if (n == 1) "" else "s" });
}

/// "3 sessions · 5.2 MB", or only how many when each one's size is not known.
fn howMuch(a: *App, c: *ui.Context, n: usize, bytes: u64) []const u8 {
    if (!a.storage.sized()) return sessionsText(c, n);
    var buf: [32]u8 = undefined;
    return c.print("{s} · {s}", .{ sessionsText(c, n), purge.size(&buf, bytes) });
}

fn summary(a: *App, c: *ui.Context, sc: anytype) void {
    const st = &a.storage;
    const card = rows.card(c);
    defer card.end();
    const r = rows.row(c);
    defer r.end();
    {
        const tile = ui.div(c).w(36).h(36).center().rounded(9).bg(t.teal_900.alpha(0.12)).border(t.teal_900.alpha(0.25));
        defer tile.end();
        comp.icon(c, "storage", .{ .size = 18, .color = t.teal_900 });
    }
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var n: usize = 0;
    for (sc.projects) |p| n += p.sessions.len;
    if (st.sized())
        rows.rowText(c, c.print("{s} · {s}", .{ st.kind.title(), purge.size(&b1, sc.total) }), c.print("{s} of it is {d} sessions in {d} projects, in {s}", .{ purge.size(&b2, sc.sessions_bytes), n, sc.projects.len, st.root }))
    else
        rows.rowText(c, c.print("{s} · {s} of sessions", .{ st.kind.title(), purge.size(&b1, sc.sessions_bytes) }), c.print("{d} sessions in {d} folders: its session database and transcripts, in {s}", .{ n, sc.projects.len, st.root }));
    if (storage.progress(a)) |p| ui.text(c, p, .{ .size = 12, .color = t.gray_900 });
    if (st.loading or st.deleting) comp.spinner(c, 14) else if (comp.iconButton(c, "arrow.clockwise", 14, "Read it again")) storage.refresh(a);
}

const ages = [_]struct { u32, []const u8 }{ .{ 7, "7 days" }, .{ 30, "30 days" }, .{ 90, "90 days" } };

/// Every project's old sessions, at once.
fn quick(a: *App, c: *ui.Context) void {
    const g = ui.div(c).column().wFull().gap(10);
    defer g.end();
    rows.sectionTitle(c, "Free space in every project");
    const card = rows.card(c);
    defer card.end();
    for (ages, 0..) |age, i| {
        c.keyed(i);
        if (i > 0) rows.sep(c, 16);
        const m = storage.measure(a, null, age[0]);
        const r = rows.row(c);
        defer r.end();
        rows.rowText(c, c.print("Sessions older than {s}", .{age[1]}), if (m.count == 0) "None" else howMuch(a, c, m.count, m.bytes));
        if (m.count > 0 and !a.storage.deleting and !a.storage.loading and comp.outlineButton(c, "Delete…", null)) storage.ask(a, null, age[0]);
    }
}

fn projects(a: *App, c: *ui.Context, sc: anytype) void {
    const sized = a.storage.sized();
    const g = ui.div(c).column().wFull().gap(10);
    defer g.end();
    rows.countedTitle(c, if (sized) "Projects" else "Folders", if (sized) "biggest first" else "most sessions first", sc.projects.len);
    const card = rows.card(c);
    defer card.end();
    const biggest: f32 = @floatFromInt(@max(if (sized) sc.projects[0].bytes else sc.projects[0].sessions.len, 1));
    const now = a.now();
    for (sc.projects, 0..) |p, i| {
        c.keyed(i);
        if (i > 0) rows.sep(c, 16);
        const r = ui.div(c).row().wFull().gap(12).px(16).py(10).itemsCenter();
        defer r.end();
        {
            const col = ui.div(c).column().grow().w(0).gap(4);
            defer col.end();
            {
                const line = ui.div(c).row().wFull().gap(8).itemsCenter();
                defer line.end();
                comp.icon(c, "folder", .{ .size = 14, .color = t.amber_900 });
                const name = std.fs.path.basename(p.cwd);
                ui.text(c, if (name.len > 0) name else p.cwd, .{ .size = 14, .weight = .medium });
                const path = ui.div(c).grow().w(0).clip();
                ui.text(c, p.cwd, .{ .size = 12, .color = t.gray_700 });
                path.end();
            }
            {
                // Its share of the biggest, as a bar.
                const bar = ui.div(c).row().wFull().h(4).rounded(2).bg(t.alpha_200);
                defer bar.end();
                const f = @as(f32, @floatFromInt(if (sized) p.bytes else p.sessions.len)) / biggest;
                ui.div(c).w(@max(4, f * 240)).h(4).rounded(2).bg(t.teal_900).end();
            }
            var b2: [32]u8 = undefined;
            const oldest = p.sessions[0].modified;
            const age = if (oldest > 0) c.print(" · oldest {s}", .{format.ago(&b2, now, oldest)}) else "";
            ui.text(c, c.print("{s}{s}", .{ howMuch(a, c, p.sessions.len, p.bytes), age }), .{ .size = 12, .color = t.gray_900 });
        }
        menu(a, c, i);
    }
}

/// "Free space ▾": a project's sessions older than so many days, or all.
fn menu(a: *App, c: *ui.Context, i: usize) void {
    const st = &a.storage;
    const b = ui.div(c).row().h(30).px(10).gap(6).itemsCenter().rounded(8).border(t.alpha_400).hover(t.alpha_200).control();
    ui.text(c, "Free space", .{ .size = 13 });
    comp.icon(c, "chevron-down", .{ .size = 12, .color = t.gray_700 });
    b.end();
    const it = b.interaction();
    if (it.hovered and c.input.pressed) st.menu_for = i;
    if (st.menu_for != i or st.deleting or st.loading) return;
    const m = ui.buttonMenu(c, &a.menus.storage, it) orelse return;
    defer m.end();
    for (ages ++ [_]struct { u32, []const u8 }{.{ 0, "" }}) |age| {
        const got = storage.measure(a, i, age[0]);
        const what = if (age[0] == 0) "All its sessions" else c.print("Older than {s}", .{age[1]});
        const label = if (got.count == 0) c.print("{s} · none", .{what}) else c.print("{s} · {s}", .{ what, howMuch(a, c, got.count, got.bytes) });
        if (m.item(label, .{ .disabled = got.count == 0, .icon = if (age[0] == 0) "trash" else "" })) storage.ask(a, i, age[0]);
    }
}
