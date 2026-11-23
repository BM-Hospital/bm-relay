//! The Skills page: the skills `/` completes in this folder (from its own
//! and the home folder's `.fx`, `.agents` and `.claude` folders), the
//! commands the agent offers of its own, and skills it said it skipped.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const App = @import("../../app/app.zig").App;
const t = @import("../../design/tokens.zig");
const comp = @import("../../design/components.zig");
const pickers = @import("../../host/pickers.zig");
const rows = @import("rows.zig");

const limit = 40;

pub fn draw(a: *App, c: *ui.Context) void {
    rows.pageTitle(c, "Skills", "Instructions an agent follows when you type / and a skill's name.");
    const ws = a.workspace() orelse {
        rows.footnote(c, "Open a folder to see the skills its sessions can use.");
        return;
    };
    filter(a, c, ws.skills.len);
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    const query = std.mem.trim(u8, a.settings.skills_filter.text(), " \t");

    {
        const names = ar.alloc([]const u8, ws.skills.len) catch return;
        for (ws.skills, names) |s, *n| n.* = s.name;
        var shown: []const usize = undefined;
        if (query.len > 0) shown = pickers.rank(ar, names, query, names.len) else {
            const all = ar.alloc(usize, names.len) catch return;
            for (all, 0..) |*x, i| x.* = i;
            shown = all;
        }
        const g = ui.div(c).column().wFull().gap(10);
        defer g.end();
        rows.countedTitle(c, "In this folder", ws.name, shown.len);
        const card = rows.card(c);
        defer card.end();
        if (shown.len == 0) rows.textRow(c, if (query.len > 0) "No skill matches" else "No skills here yet", if (query.len > 0) "Try fewer letters" else "Add one as <folder>/.claude/skills/<name>/SKILL.md, or in your home folder");
        const n = if (a.settings.skills_all) shown.len else @min(shown.len, limit);
        for (shown[0..n], 0..) |si, i| {
            c.keyed(si);
            if (i > 0) rows.sep(c, 16);
            skillRow(a, c, ws.skills[si]);
        }
        if (n < shown.len) {
            rows.sep(c, 16);
            const more = ui.div(c).wFull().h(40).center().control();
            ui.text(c, c.print("Show {d} more", .{shown.len - n}), .{ .size = 13, .color = if (more.hovered()) t.gray_1000 else t.gray_900 });
            more.end();
            if (comp.press(more)) a.settings.skills_all = true;
        }
    }
    commands(a, c);
    skipped(a, c);
}

fn filter(a: *App, c: *ui.Context, count: usize) void {
    const box = ui.div(c).row().wFull().h(36).px(12).gap(10).itemsCenter().rounded(10).bg(t.gray_100).border(t.alpha_300);
    defer box.end();
    comp.icon(c, "search", .{ .size = 14, .color = t.gray_700 });
    const r = ui.textField(c, &a.settings.skills_filter, .{ .placeholder = c.print("Filter {d} skills", .{count}), .width = .fill, .bare = true, .size = 13 });
    if (r.changed) a.settings.skills_all = false;
}

fn skillRow(a: *App, c: *ui.Context, s: pickers.Skill) void {
    _ = a;
    const r = ui.div(c).row().wFull().gap(12).px(16).py(9).itemsCenter();
    defer r.end();
    {
        const col = ui.div(c).column().grow().gap(1);
        defer col.end();
        ui.text(c, c.print("/{s}", .{s.name}), .{ .size = 13, .mono = true });
        if (s.description.len > 0) ui.text(c, s.description, .{ .size = 13, .color = t.gray_900, .wrap = true });
    }
    if (comp.textButton(c, "Open")) _ = myzig.shell.openPath(s.path);
    if (comp.textButton(c, "Reveal")) myzig.shell.showInFolder(s.path);
}

fn commands(a: *App, c: *ui.Context) void {
    const s = a.active orelse return;
    const list = s.thread.commands;
    if (list.len == 0) return;
    const g = ui.div(c).column().wFull().gap(10);
    defer g.end();
    rows.countedTitle(c, "From the agent", a.agentName(s.agent), list.len);
    const card = rows.card(c);
    defer card.end();
    for (list, 0..) |cmd, i| {
        c.keyed(i);
        if (i > 0) rows.sep(c, 16);
        const r = ui.div(c).column().wFull().gap(1).px(16).py(9);
        defer r.end();
        ui.text(c, c.print("/{s}{s}{s}", .{ cmd.name, if (cmd.hint.len > 0) " " else "", cmd.hint }), .{ .size = 13, .mono = true });
        if (cmd.description.len > 0) ui.text(c, cmd.description, .{ .size = 13, .color = t.gray_900, .wrap = true });
    }
}

fn skipped(a: *App, c: *ui.Context) void {
    const text = a.settings.skipped orelse return;
    const g = ui.div(c).column().wFull().gap(10);
    defer g.end();
    rows.sectionTitle(c, "Skipped");
    {
        const card = rows.card(c);
        defer card.end();
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        var i: usize = 0;
        while (lines.next()) |raw| {
            const l = std.mem.trim(u8, raw, " \r\t");
            const prefix = "skill discovery warning:";
            if (!std.mem.startsWith(u8, l, prefix)) continue;
            c.keyed(i);
            if (i > 0) rows.sep(c, 36);
            i += 1;
            const r = ui.div(c).row().wFull().gap(12).px(16).py(10).itemsCenter();
            defer r.end();
            comp.dot(c, t.amber_700);
            ui.text(c, std.mem.trim(u8, l[prefix.len..], " "), .{ .size = 13, .color = t.gray_900, .wrap = true });
        }
    }
    rows.footnote(c, "The agent could not read these. Fix their SKILL.md front matter and start a new session.");
}
