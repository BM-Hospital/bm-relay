//! A turn's work log: what the agent said on the way, its thoughts, and
//! its steps, like calls folded together, a failure's output under it;
//! and the card of the files a turn changed.
const std = @import("std");
const ui = @import("myzig").ui;
const app_mod = @import("../app/app.zig");
const state = @import("../app/state.zig");
const turns = @import("../app/turns.zig");
const transcript = @import("../model/transcript.zig");
const tools = @import("../model/tools.zig");
const git = @import("../host/git.zig");
const t = @import("../design/tokens.zig");
const comp = @import("../design/components.zig");

const App = app_mod.App;
const Session = state.Session;
const Tool = transcript.Tool;
const Item = transcript.Item;

pub const Entry = union(enum) {
    say: struct { body: []const u8, at: usize },
    thought: struct { body: []const u8, at: usize, open: bool },
    step: struct { tool: *Tool, more: usize, group: ?usize, open: bool },
    output: []const u8,
    /// A subagent's own log, folded under the step that started it.
    agent: struct { tool: *Tool, at: usize, open: bool },
};

fn settled(x: *const Tool) bool {
    return !tools.failed(x) and !tools.live(x) and tools.delegated(x) == null;
}

/// The log's entries, in `ar`'s memory: thoughts in a row join, calls of
/// one kind in a row fold into one step (opened, they list each).
pub fn entries(ar: std.mem.Allocator, s: *const Session, turn: usize, work: []const Item) []Entry {
    var out: std.ArrayList(Entry) = .empty;
    var i: usize = 0;
    while (i < work.len) {
        const at = i;
        switch (work[i]) {
            .text => |body| {
                if (std.mem.trim(u8, body.items, " \r\n\t").len > 0) out.append(ar, .{ .say = .{ .body = body.items, .at = at } }) catch {};
                i += 1;
                continue;
            },
            .thought => |body| {
                const b = std.mem.trim(u8, body.items, " \r\n\t");
                i += 1;
                if (b.len == 0) continue;
                if (out.items.len > 0 and out.items[out.items.len - 1] == .thought) {
                    const last = &out.items[out.items.len - 1].thought;
                    last.body = std.fmt.allocPrint(ar, "{s}\n\n{s}", .{ last.body, b }) catch last.body;
                } else out.append(ar, .{ .thought = .{ .body = b, .at = at, .open = turns.stepOpen(s, turn, at) } }) catch {};
                continue;
            },
            .tool => {},
        }
        const tool = work[i].tool;
        var run: usize = 1;
        if (settled(tool)) {
            while (i + run < work.len and work[i + run] == .tool) {
                const next = work[i + run].tool;
                if (!std.mem.eql(u8, next.kind, tool.kind) or !settled(next)) break;
                run += 1;
            }
        }
        const more = run - 1;
        const is_open = turns.stepOpen(s, turn, at);
        if (more > 0 and is_open) {
            for (work[i .. i + run], 0..) |it, n| out.append(ar, .{ .step = .{ .tool = it.tool, .more = 0, .group = if (n == 0) at else null, .open = true } }) catch {};
            i += run;
            continue;
        }
        i += run;
        out.append(ar, .{ .step = .{ .tool = tool, .more = more, .group = if (more > 0) at else null, .open = false } }) catch {};
        if (tool.children.items.len > 0) out.append(ar, .{ .agent = .{ .tool = tool, .at = at, .open = turns.stepOpen(s, turn, at) } }) catch {};
        const shown: ?[]const u8 = if (tools.failed(tool)) tool.output else tools.report(ar, tool);
        if (shown) |text| if (lastLines(ar, text, 6)) |l| out.append(ar, .{ .output = l }) catch {};
    }
    return out.items;
}

/// The last `n` lines of `text` that hold something.
fn lastLines(ar: std.mem.Allocator, text: []const u8, n: usize) ?[]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (std.mem.trim(u8, l, " \r\t").len > 0) lines.append(ar, std.mem.trimEnd(u8, l, "\r")) catch {};
    if (lines.items.len == 0) return null;
    const from = lines.items.len -| n;
    return std.mem.join(ar, "\n", lines.items[from..]) catch null;
}

fn isStep(list: []const Entry, i: usize) bool {
    if (i >= list.len) return false;
    return list[i] == .step or list[i] == .thought;
}

/// Draws the entries; `asking` is the id of the call waiting for approval.
pub fn draw(a: *App, c: *ui.Context, s: *Session, turn: usize, list: []const Entry, asking: ?[]const u8) void {
    const col = ui.div(c).column().wFull();
    defer col.end();
    for (list, 0..) |e, i| {
        c.keyed(.{ turn, i });
        const above = i > 0 and isStep(list, i - 1);
        const below = isStep(list, i + 1);
        switch (e) {
            .say => |x| say(a, c, s, x.body),
            .thought => |x| thought(a, c, s, turn, x.at, x.body, x.open, above, below and !x.open),
            .output => |body| output(c, body),
            .agent => |x| agent(a, c, s, turn, x.tool, x.at, x.open, asking),
            .step => |x| {
                const waiting = if (asking) |id| std.mem.eql(u8, id, x.tool.id) else false;
                step(a, c, s, turn, x.tool, x.more, x.group, x.open, above, below, waiting);
            },
        }
    }
}

/// The vertical rule of the log, with the step's mark on it.
fn gutterOpen(c: *ui.Context, above: bool) ui.Div {
    const g = ui.div(c).column().w(16).hFull().itemsCenter();
    ui.div(c).w(1).h(8).bg(if (above) t.alpha_300 else t.alpha_300.alpha(0)).end();
    return g;
}

fn gutterClose(c: *ui.Context, g: ui.Div, below: bool) void {
    ui.div(c).w(1).grow().bg(if (below) t.alpha_300 else t.alpha_300.alpha(0)).end();
    g.end();
}

pub fn chevron(c: *ui.Context, open: bool, tone: ui.Color) void {
    comp.icon(c, if (open) "chevron-down" else "chevron-right", .{ .size = 12, .color = tone });
}

fn say(a: *App, c: *ui.Context, s: *Session, body: []const u8) void {
    const d = ui.div(c).wFull().pt(5).pb(7);
    defer d.end();
    const r = ui.markdown(c, std.mem.trim(u8, body, " \r\n\t"), .{ .size = 14, .images = @import("../app/pictures.zig").reader(a, c, s) });
    if (r.link) |url| _ = @import("myzig").shell.openUrl(url);
}

/// A step's whole detail for its tooltip: a long command cut into lines
/// a tooltip can show, and at most so much of it.
fn fullDetail(c: *ui.Context, text: []const u8) ?[]const u8 {
    const t0 = std.mem.trim(u8, text, " \r\n\t");
    if (t0.len <= 60 and std.mem.indexOfScalar(u8, t0, '\n') == null) return null;
    const most = 1200;
    const shown = t0[0..@min(t0.len, most)];
    var out: std.ArrayList(u8) = .empty;
    var col: usize = 0;
    for (shown) |ch| {
        if (ch == '\n') col = 0 else if (col >= 96 and (ch & 0xc0) != 0x80) {
            out.append(c.alloc(), '\n') catch {};
            col = 0;
        }
        out.append(c.alloc(), ch) catch {};
        if (ch != '\n' and (ch & 0xc0) != 0x80) col += 1;
    }
    if (t0.len > most) out.appendSlice(c.alloc(), "…") catch {};
    return out.items;
}

fn thought(a: *App, c: *ui.Context, s: *Session, turn: usize, at: usize, body: []const u8, open: bool, above: bool, below: bool) void {
    const col = ui.div(c).column().wFull();
    defer col.end();
    const row = ui.div(c).row().wFull().h(30).gap(10).control();
    {
        const g = gutterOpen(c, above);
        comp.icon(c, "ellipsis", .{ .size = 14, .color = t.purple_900.alpha(0.8) });
        gutterClose(c, g, below);
    }
    {
        const r = ui.div(c).row().grow().w(0).gap(8).itemsCenter().clip();
        defer r.end();
        ui.text(c, "Thought", .{ .size = 13, .color = t.gray_700 });
        if (!open) ui.text(c, tools.firstLine(body), .{ .size = 13, .color = t.gray_700 });
        chevron(c, open, t.gray_700);
    }
    row.end();
    if (comp.press(row)) turns.toggleStep(a, s, turn, at);
    if (open) {
        const d = ui.div(c).wFull().pl(26).pb(8);
        c.node(d.index).style.selectable = true;
        defer d.end();
        ui.text(c, body, .{ .size = 13, .color = t.gray_700, .wrap = true, .leading = 1.4 });
    }
}

fn output(c: *ui.Context, body: []const u8) void {
    const pad = ui.div(c).wFull().pl(26).pt(2).pb(8);
    defer pad.end();
    const box = ui.div(c).column().wFull().px(12).py(10).rounded(8).bg(t.background_200).border(t.alpha_200).clip();
    c.node(box.index).style.selectable = true;
    defer box.end();
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |l| ui.text(c, l, .{ .size = 12, .mono = true, .color = t.gray_900 });
}

/// Where a subagent's log keeps which of its steps are open: a key of its
/// own, apart from the turns' (`turns.stepOpen`).
fn nested(x: *const Tool) usize {
    return @as(usize, @as(u31, @truncate(@intFromPtr(x) >> 3))) | (1 << 31);
}

/// A subagent's log under its step: folded, how many steps it took and
/// what it does now; open, the log itself in a box.
fn agent(a: *App, c: *ui.Context, s: *Session, turn: usize, x: *Tool, at: usize, open: bool, asking: ?[]const u8) void {
    const live = tools.live(x);
    // A column as wide as the log, not a box that grows into a row: the
    // Markdown inside is measured at its width.
    const body = ui.div(c).column().wFull().pl(20).pb(6);
    defer body.end();
    const head = ui.div(c).row().h(26).px(8).gap(8).itemsCenter().rounded(6).hover(t.alpha_100).control();
    {
        chevron(c, open, t.gray_700);
        const n = x.childCount();
        ui.text(c, c.print("{d} step{s}", .{ n, if (n == 1) "" else "s" }), .{ .size = 12, .weight = .medium, .color = t.gray_900 });
        if (!open) if (x.lastChild()) |last| {
            const words = if (asking != null and std.mem.eql(u8, asking.?, last.id)) tools.awaiting(last) else tools.step(last);
            ui.text(c, "·", .{ .size = 12, .color = t.gray_600 });
            ui.text(c, words[0], .{ .size = 12, .color = if (live) t.gray_1000 else t.gray_700 });
            const d = ui.div(c).maxW(360).clip();
            defer d.end();
            ui.text(c, tools.firstLine(tools.relative(if (a.workspaceOf(s)) |w| w.path else "", words[1])), .{ .size = 12, .mono = true, .color = t.gray_700 });
        };
    }
    head.end();
    if (comp.press(head)) turns.toggleStep(a, s, turn, at);
    if (!open) return;
    const log = ui.div(c).column().wFull().px(8).py(4).rounded(8).bg(t.alpha_100.alpha(0.5)).border(t.alpha_200);
    defer log.end();
    const key = nested(x);
    draw(a, c, s, key, entries(c.alloc(), s, key, x.children.items), asking);
}

fn stepIcon(x: *const Tool) []const u8 {
    if (tools.delegated(x) != null or std.mem.eql(u8, x.name, "subagent") or std.mem.eql(u8, x.name, "subagent_session")) return "user";
    if (std.mem.eql(u8, x.name, "ask_user_question")) return "lines";
    const eq = std.mem.eql;
    if (eq(u8, x.kind, "read")) return "file";
    if (eq(u8, x.kind, "edit")) return "pencil";
    if (eq(u8, x.kind, "search")) return "search";
    if (eq(u8, x.kind, "fetch")) return "globe";
    if (eq(u8, x.kind, "delete")) return "trash";
    if (eq(u8, x.kind, "think")) return "ellipsis";
    return "terminal";
}

/// A step's icon color, by what it does: reading blue, searching purple,
/// editing amber, running green, fetching teal, deleting red, a subagent
/// pink. The words stay gray: color marks the kind, not the text.
pub fn stepColor(x: *const Tool) ui.Color {
    const eq = std.mem.eql;
    if (tools.delegated(x) != null or eq(u8, x.name, "subagent") or eq(u8, x.name, "subagent_session")) return t.pink_900;
    if (eq(u8, x.name, "ask_user_question")) return t.blue_900;
    if (eq(u8, x.kind, "read")) return t.blue_900;
    if (eq(u8, x.kind, "search")) return t.purple_900;
    if (eq(u8, x.kind, "edit") or eq(u8, x.kind, "move")) return t.amber_900;
    if (eq(u8, x.kind, "execute")) return t.green_900;
    if (eq(u8, x.kind, "fetch")) return t.teal_900;
    if (eq(u8, x.kind, "delete")) return t.red_900;
    return t.gray_700;
}

fn step(a: *App, c: *ui.Context, s: *Session, turn: usize, x: *Tool, more: usize, group: ?usize, open: bool, above: bool, below: bool, waiting: bool) void {
    const words = if (waiting) tools.awaiting(x) else tools.step(x);
    const bad = tools.failed(x);
    const now = tools.live(x) and !waiting;
    const tone = if (bad) t.red_900 else if (now) t.gray_1000 else t.gray_700;
    const row = ui.div(c).row().wFull().h(30).gap(10);
    if (group != null) _ = row.control();
    {
        const g = gutterOpen(c, above);
        if (waiting) {
            const d = ui.div(c).w(14).h(14).center();
            defer d.end();
            comp.dot(c, t.amber_700);
        } else if (now) comp.spinner(c, 14) else comp.icon(c, stepIcon(x), .{ .size = 14, .color = if (bad) t.red_900 else if (tools.stopped(x)) t.gray_600 else stepColor(x) });
        gutterClose(c, g, below);
    }
    {
        const r = ui.div(c).row().grow().w(0).gap(8).itemsCenter();
        defer r.end();
        ui.text(c, words[0], .{ .size = 13, .color = tone });
        {
            const d = ui.div(c).grow().w(0).clip();
            const detail = tools.relative(if (a.workspaceOf(s)) |w| w.path else "", words[1]);
            ui.text(c, tools.firstLine(detail), .{ .size = 12, .mono = true, .color = if (now) t.gray_1000 else t.gray_900 });
            d.end();
            // Cut off here: all of it under the pointer.
            if (fullDetail(c, detail)) |full| ui.tooltip(c, d.interaction(), full);
        }
        if (std.mem.eql(u8, x.kind, "edit") and !bad) if (tools.editStat(c.alloc(), x)) |st| comp.stat(c, st[0], st[1]);
        if (more > 0) ui.text(c, c.print("+{d} more", .{more}), .{ .size = 12, .color = t.gray_700 });
        if (group != null) chevron(c, open, t.gray_700);
    }
    row.end();
    if (group) |at| if (comp.press(row)) turns.toggleStep(a, s, turn, at);
}

/// "3 files changed", their lines, and Review, which opens the changes panel.
pub fn filesCard(a: *App, c: *ui.Context, files: []const git.Change) void {
    var added: usize = 0;
    var removed: usize = 0;
    for (files) |f| {
        added += f.added;
        removed += f.removed;
    }
    const card = ui.div(c).column().wFull().rounded(12).border(t.alpha_400).clip();
    defer card.end();
    {
        const head = ui.div(c).row().wFull().h(40).px(14).gap(8).itemsCenter().bg(t.gray_100);
        defer head.end();
        ui.text(c, c.print("{d} file{s} changed", .{ files.len, if (files.len == 1) "" else "s" }), .{ .size = 13, .weight = .medium });
        comp.stat(c, added, removed);
        ui.spacer(c);
        const r = ui.div(c).row().gap(8).itemsCenter().control();
        const hot = r.hovered();
        ui.text(c, "Review", .{ .size = 13, .color = if (hot) t.gray_1000 else t.gray_900 });
        comp.icon(c, "chevron-right", .{ .size = 12, .color = t.gray_900 });
        r.end();
        if (comp.press(r) and a.changes == null) @import("changes.zig").toggle(a);
    }
    for (files, 0..) |f, i| {
        c.keyed(i);
        const row = ui.div(c).column().wFull();
        defer row.end();
        comp.hairline(c);
        const r = ui.div(c).row().wFull().h(36).px(14).gap(10).itemsCenter();
        defer r.end();
        {
            const p = ui.div(c).grow().w(0).clip();
            defer p.end();
            ui.text(c, f.path, .{ .size = 12, .mono = true });
        }
        comp.stat(c, f.added, f.removed);
    }
}

const testing = std.testing;

test "like calls fold and failures stand alone" {
    var th = transcript.Thread.init(testing.allocator);
    defer th.deinit();
    _ = th.begin("go", 0);
    th.apply(.{ .text = "first" }, 0);
    inline for (.{ "a", "b", "c" }) |id| th.apply(.{ .tool_call = .{ .id = id, .kind = "read", .status = "completed" } }, 0);
    th.apply(.{ .tool_call = .{ .id = "d", .kind = "execute", .status = "failed", .output = "a\n\nb\n" } }, 0);
    th.apply(.{ .tool_call = .{ .id = "e", .kind = "execute", .status = "completed" } }, 0);
    const s = state.Session.create(testing.allocator, 1, "x");
    defer s.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = entries(arena.allocator(), s, 0, th.turns.items[0].items.items);
    try testing.expectEqual(@as(usize, 5), list.len);
    try testing.expectEqual(@as(usize, 2), list[1].step.more);
    try testing.expectEqualStrings("a\nb", list[3].output);
    try s.open_steps.put(testing.allocator, 1, {});
    const opened = entries(arena.allocator(), s, 0, th.turns.items[0].items.items);
    try testing.expectEqual(@as(usize, 7), opened.len);
    try testing.expect(opened[1].step.open);
}
