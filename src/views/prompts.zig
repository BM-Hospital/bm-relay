//! The cards that wait on the user: a tool call asking for approval, and
//! a question the agent put with its options.
const std = @import("std");
const ui = @import("myzig").ui;
const app_mod = @import("../app/app.zig");
const state = @import("../app/state.zig");
const agent = @import("../app/agent.zig");
const turns = @import("../app/turns.zig");
const tools = @import("../model/tools.zig");
const git = @import("../host/git.zig");
const t = @import("../design/tokens.zig");
const comp = @import("../design/components.zig");
const diff = @import("diff.zig");

const App = app_mod.App;
const Session = state.Session;

pub fn permission(a: *App, c: *ui.Context, s: *Session, p: *state.Pending) void {
    const cwd = if (a.workspaceOf(s)) |w| w.path else "";
    const detail = tools.relative(cwd, tools.summarize(&p.tool)[1]);
    const command = std.mem.eql(u8, p.tool.kind, "execute");
    const card = comp.card(c).wFull();
    defer card.end();
    {
        const head = ui.div(c).row().wFull().gap(if (command) 8 else 10).px(2).itemsCenter();
        defer head.end();
        comp.dot(c, t.amber_700);
        ui.text(c, tools.question(&p.tool), .{ .size = 14, .weight = .medium });
        ui.spacer(c);
        if (p.tool.title.len > 0 and !std.mem.eql(u8, p.tool.title, detail)) {
            const ti = ui.div(c).maxW(320).clip();
            defer ti.end();
            ui.text(c, p.tool.title, .{ .size = 12, .color = t.gray_700 });
        }
    }
    if (p.preview) |lines| diffPreview(c, detail, lines) else plainPreview(c, detail, command);
    buttons(a, c, s, p, detail, command);
}

fn diffPreview(c: *ui.Context, detail: []const u8, lines: []const git.DiffLine) void {
    const n = git.counts(lines);
    const box = ui.div(c).column().wFull().rounded(8).border(t.alpha_200).clip();
    defer box.end();
    {
        const head = ui.div(c).row().wFull().h(34).px(12).gap(10).itemsCenter().bg(t.gray_200);
        defer head.end();
        {
            const d = ui.div(c).grow().w(0).clip();
            defer d.end();
            ui.text(c, detail, .{ .size = 12, .mono = true });
        }
        comp.stat(c, n[0], n[1]);
    }
    diff.block(c, lines, 40);
    if (lines.len > 40) diff.moreLines(c, lines.len - 40);
}

fn plainPreview(c: *ui.Context, detail: []const u8, command: bool) void {
    const box = ui.div(c).row().wFull().px(12).py(10).rounded(8).bg(t.background_200);
    defer box.end();
    if (command) ui.text(c, "$ ", .{ .size = 13, .mono = true, .color = t.gray_700 });
    const d = ui.div(c).grow();
    defer d.end();
    ui.text(c, if (detail.len > 0) detail else "(no details)", .{ .size = 13, .mono = true, .wrap = true });
}

fn buttons(a: *App, c: *ui.Context, s: *Session, p: *state.Pending, detail: []const u8, command: bool) void {
    const bar = ui.div(c).row().wFull().gap(8).itemsCenter();
    defer bar.end();
    var answer: ?[]const u8 = null;
    if (p.optionOf("allow_always") != null) {
        var words = std.mem.tokenizeAny(u8, detail, " \t\n");
        const w1 = words.next() orelse "";
        const w2 = words.next() orelse "";
        const label = if (command) c.print("Always allow {s}{s}{s}", .{ w1, if (w2.len > 0) " " else "", w2 }) else "Always allow in this session";
        if (comp.textButton(c, label)) answer = "allow_always";
    }
    ui.spacer(c);
    const deny_kind: []const u8 = if (p.optionOf("reject_once") != null) "reject_once" else "reject_always";
    if (comp.outlineButton(c, "Deny", "Esc")) answer = deny_kind;
    if (p.optionOf("allow_once") != null) {
        if (comp.primaryButton(c, if (command) "Run" else "Allow", "⏎")) answer = "allow_once";
    } else if (p.optionOf("allow_always") == null) {
        // An agent whose options are its own: offer them as they are.
        for (p.options) |o| {
            if (std.mem.startsWith(u8, o.kind, "reject")) continue;
            if (comp.outlineButton(c, o.name, null)) answer = o.kind;
        }
    }
    if (answer) |k| agent.answerPermission(a, s, k);
}

pub fn question(a: *App, c: *ui.Context, s: *Session, turn: usize, q: tools.Question) void {
    _ = s;
    const card = comp.card(c).wFull().gap(14).p(16);
    defer card.end();
    {
        const head = ui.div(c).row().wFull().gap(10);
        defer head.end();
        {
            const d = ui.div(c).pt(7);
            defer d.end();
            comp.dot(c, t.amber_700);
        }
        const tx = ui.div(c).grow();
        defer tx.end();
        ui.text(c, q.asks, .{ .size = 14, .weight = .medium, .wrap = true });
    }
    // A number key answers while the composer is empty.
    const typed = a.composer.len() == 0;
    var chosen: ?[]const u8 = null;
    {
        const list = ui.div(c).column().wFull().gap(6);
        defer list.end();
        for (q.options, 0..) |o, i| {
            c.keyed(i);
            if (row(c, i, o, false)) chosen = o;
            if (typed and i < 9 and c.shortcut(.{ .key = @as(u21, '1') + @as(u21, @intCast(i)) })) chosen = o;
        }
        c.keyed(q.options.len);
        if (row(c, q.options.len, "Something else…", true)) c.focus = a.composer.id;
    }
    {
        const foot = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer foot.end();
        ui.text(c, "Press a number, or type an answer below", .{ .size = 12, .color = t.gray_700 });
        ui.spacer(c);
        const skip = ui.div(c).control();
        ui.text(c, "Skip", .{ .size = 13, .weight = .medium, .color = if (skip.hovered()) t.gray_1000 else t.gray_900 });
        skip.end();
        if (comp.press(skip)) {
            if (a.active) |x| x.skipped = turn;
        }
    }
    if (chosen) |o| turns.answerQuestion(a, o);
}

fn row(c: *ui.Context, i: usize, label: []const u8, muted: bool) bool {
    const r = ui.div(c).row().wFull().h(40).px(12).gap(10).itemsCenter().rounded(8).border(t.alpha_300).control().hover(t.alpha_200);
    {
        const n = ui.div(c).w(12);
        defer n.end();
        ui.text(c, c.print("{d}", .{i + 1}), .{ .size = 12, .mono = true, .color = t.gray_700 });
    }
    {
        const d = ui.div(c).grow().w(0).clip();
        defer d.end();
        ui.text(c, label, .{ .size = 13, .color = if (muted) t.gray_700 else t.gray_1000 });
    }
    r.end();
    return comp.press(r);
}
