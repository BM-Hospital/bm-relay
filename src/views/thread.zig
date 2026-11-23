//! The transcript: each turn's prompt and images, its work log (live
//! while it runs, folded once it is done), its answer in Markdown with a
//! copy button, the files the last turn changed; the approval, question
//! and error cards; and the session shown beside, dimmed.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const app_mod = @import("../app/app.zig");
const state = @import("../app/state.zig");
const turns = @import("../app/turns.zig");
const agent = @import("../app/agent.zig");
const sessions = @import("../app/sessions.zig");
const format = @import("../app/format.zig");
const transcript = @import("../model/transcript.zig");
const tools = @import("../model/tools.zig");
const git = @import("../host/git.zig");
const t = @import("../design/tokens.zig");
const comp = @import("../design/components.zig");
const timeline = @import("timeline.zig");
const prompts = @import("prompts.zig");
const composer = @import("composer.zig");

const App = app_mod.App;
const Session = state.Session;
const Turn = transcript.Turn;

pub fn draw(a: *App, c: *ui.Context, s: *Session) void {
    c.keyed(.{ @as(u8, 't'), s.key });
    const box = ui.div(c).column().wFull().grow().h(0);
    defer box.end();
    // Scrolled from here (a prompt sent): to the end, following it again.
    if (a.to_end) {
        const id = c.peekId(null);
        c.scroll_follow.put(c.gpa, id, true) catch {};
        _ = c.scroll_seen.remove(id);
        a.to_end = false;
    }
    const list_id = c.peekId(null);
    turnList(a, c, s, &s.rows, false, 40);
    toEndButton(a, c, box, list_id);
}

/// Scrolled up from the end, past a screen: a round arrow at the bottom
/// takes the reader back to the newest message, and to following it.
fn toEndButton(a: *App, c: *ui.Context, box: ui.Div, list_id: u64) void {
    const rect = c.rects.get(c.node(box.index).id) orelse return;
    const offset = c.scroll.get(list_id) orelse return;
    const limit = c.scroll_limit.get(list_id) orelse return;
    if (limit - offset < @max(240, rect.h * 0.6)) return;
    const b = ui.div(c).absolute().offset(rect.w / 2 - 18, rect.h - 52).w(36).h(36).center().rounded(18).bg(t.gray_100).border(t.alpha_400).shadow(t.shadow_pop).hover(t.gray_200).control();
    comp.icon(c, "arrow-down", .{ .size = 16, .color = t.gray_1000 });
    b.end();
    if (b.interaction().hovered) c.cursor = .hand;
    if (comp.press(b)) {
        a.to_end = true;
        a.redraw();
    }
}

/// The turns as a virtual list, the cards after them as its last row: only
/// what is in view is built, so a session of thousands of turns draws as
/// fast as a short one. It follows its end as turns come, until scrolled.
fn turnList(a: *App, c: *ui.Context, s: *Session, rows_state: *ui.MeasuredListState, dimmed: bool, side: f32) void {
    const items = s.thread.turns.items;
    var rows = ui.measuredList(c, rows_state, .{
        .count = items.len + 1,
        .estimate = 320,
        .gap = 20,
        .padding = .{ .top = 24, .bottom = 24, .left = side, .right = side },
        .follow_end = true,
    });
    const ws = a.workspaceOf(s);
    while (rows.next()) |i| {
        const center = ui.div(c).column().wFull().itemsCenter();
        defer center.end();
        const col = ui.div(c).column().wFull().maxW(t.column).gap(20);
        defer col.end();
        if (i == items.len) {
            tail(a, c, s, dimmed);
            continue;
        }
        const turn = items[i];
        c.keyed(turn);
        const last = i + 1 == items.len;
        const files = if (last and !dimmed and ws != null) tools.touched(c.alloc(), turn, ws.?.path, ws.?.status) else &[_]git.Change{};
        drawTurn(a, c, s, i, turn, files);
    }
    rows.end();
}

/// What comes after the turns: loading, the approval and question cards,
/// the error, the restore row.
fn tail(a: *App, c: *ui.Context, s: *Session, dimmed: bool) void {
    const items = s.thread.turns.items;
    if (items.len == 0) {
        if (s.opening) loading(c, "Opening the session…") else if (!s.loaded) loading(c, "Loading…");
    }
    if (dimmed) {
        if (s.permission != null) ui.text(c, "Waiting on your answer. Click to work in this one.", .{ .size = 13, .color = t.amber_700 });
        return;
    }
    if (s.opening and items.len > 0) loading(c, "Loading the session…");
    if (s.permission) |p| prompts.permission(a, c, s, p);
    if (s.question(c.alloc())) |q| prompts.question(a, c, s, q.turn, q.q);
    if (s.err) |e| errorCard(a, c, s, e);
    if (s.snap) |sn| if (sn.after != null and !s.thread.running()) restoreRow(a, c);
}

fn loading(c: *ui.Context, what: []const u8) void {
    const r = ui.div(c).row().gap(8).itemsCenter().h(24);
    defer r.end();
    comp.spinner(c, 14);
    ui.text(c, what, .{ .size = 13, .color = t.gray_700 });
}

fn errorCard(a: *App, c: *ui.Context, s: *Session, e: []const u8) void {
    const wrap = ui.div(c).column().wFull().gap(8);
    defer wrap.end();
    comp.errorCard(c, if (s.conn == null and !s.opening) "The agent stopped" else "Something went wrong", e);
    const row = ui.div(c).row().gap(8).pl(4);
    defer row.end();
    if (s.conn == null and !s.opening) {
        if (comp.textButton(c, "Restart the agent")) agent.reload(a, s);
        if (comp.textButton(c, "Agent settings")) @import("settings/settings.zig").open(a);
    }
    if (comp.textButton(c, "Dismiss")) s.setError(null);
}

fn restoreRow(a: *App, c: *ui.Context) void {
    const r = ui.div(c).row().gap(8).itemsCenter();
    defer r.end();
    if (comp.textButton(c, "Restore this turn's files")) turns.restoreTurn(a);
}

fn drawTurn(a: *App, c: *ui.Context, s: *Session, index: usize, turn: *Turn, files: []const git.Change) void {
    const col = ui.div(c).column().wFull().gap(20);
    defer col.end();
    if (turn.prompt.items.len > 0 or turn.images.items.len > 0 or turn.files.items.len > 0) {
        const editing = if (a.prompt_edit) |e| e.session == s.key and e.turn == index else false;
        if (editing) editBox(a, c, s) else {
            const p = ui.div(c).column().wFull().itemsEnd().gap(4);
            defer p.end();
            const hot = p.hovered();
            if (turn.prompt.items.len > 0) bubble(c, turn.prompt.items);
            if (turn.images.items.len > 0) thumbnails(c, turn);
            if (turn.files.items.len > 0) fileChips(c, turn);
            promptActions(a, c, s, index, turn, hot and a.active == s);
        }
    }
    const work = turn.work();
    var any_work = false;
    for (work) |it| switch (it) {
        .text, .thought => |b| {
            if (std.mem.trim(u8, b.items, " \r\n\t").len > 0) any_work = true;
        },
        .tool => any_work = true,
    };
    if (turn.running()) working(a, c, s, index, turn) else if (any_work) worked(a, c, s, index, turn);
    const answer = turn.answer(c.alloc());
    if (std.mem.trim(u8, answer, " \r\n\t").len > 0) {
        const ans = ui.div(c).column().wFull().gap(14);
        defer ans.end();
        if (turn.md == null) turn.md = ui.Markdown.init(a.gpa);
        const r = ui.markdown(c, answer, .{ .state = &turn.md.?, .streaming = turn.running(), .size = 14, .images = @import("../app/pictures.zig").reader(a, c, s) });
        if (r.link) |url| _ = myzig.shell.openUrl(url);
        if (r.copied != null) a.toast("Copied");
        if (!turn.running()) footer(a, c, s, turn, answer);
    }
    if (files.len > 0) timeline.filesCard(a, c, files);
    if (turn.stop) |why| ui.text(c, why, .{ .size = 13, .color = t.gray_700, .wrap = true });
}

/// Under a prompt, while the pointer is on it: when it was sent, and
/// buttons to send it again, edit it, and copy it. The row keeps its room
/// when hidden: nothing moves as the pointer comes and goes.
fn promptActions(a: *App, c: *ui.Context, s: *Session, index: usize, turn: *Turn, show: bool) void {
    const row = ui.div(c).row().h(26).gap(2).itemsCenter();
    defer row.end();
    if (!show) return;
    if (turn.timed) {
        var buf: [32]u8 = undefined;
        const t0 = ui.div(c).pr(6);
        ui.text(c, format.ago(&buf, a.now(), turn.started), .{ .size = 12, .color = t.gray_700 });
        t0.end();
    }
    const can = !s.thread.running() and s.live();
    if (can and comp.iconButton(c, "arrow.clockwise", 14, "Send again")) _ = turns.resend(a, s, index, null);
    if (can and comp.iconButton(c, "pencil", 14, "Edit and send again")) turns.startEdit(a, s, index);
    if (comp.iconButton(c, "copy", 14, "Copy")) {
        myzig.clipboard.writeText(turn.prompt.items);
        a.toast("Copied the prompt");
    }
}

/// A prompt edited in place: Enter sends it as a new turn, Escape lets go.
fn editBox(a: *App, c: *ui.Context, s: *Session) void {
    const e = &a.prompt_edit.?;
    const col = ui.div(c).column().wFull().itemsEnd().gap(8);
    defer col.end();
    {
        const box = ui.div(c).column().wFull().maxW(560).px(14).py(10).rounded(18).bg(t.gray_200).border(t.alpha_400);
        defer box.end();
        const id = c.peekId(null);
        if (c.focus != id and e.text.id == 0) c.focus = id;
        if (c.focus == id) {
            if (composer.takeKey(c, .escape)) return turns.endEdit(a);
            if (composer.takeKey(c, .enter)) return turns.sendEdit(a, s);
        }
        _ = ui.textArea(c, &e.text, .{ .lines = .{ 1, 12 }, .bare = true, .size = 14 });
    }
    const row = ui.div(c).row().gap(8).itemsCenter();
    defer row.end();
    ui.text(c, "Sent as a new turn; the agent keeps what came before.", .{ .size = 12, .color = t.gray_700 });
    if (comp.outlineButton(c, "Cancel", "Esc")) return turns.endEdit(a);
    if (comp.primaryButton(c, "Send", "⏎")) turns.sendEdit(a, s);
}

fn bubble(c: *ui.Context, prompt: []const u8) void {
    const b = ui.div(c).maxW(520).px(16).py(10).rounded(18).bg(t.gray_200);
    c.node(b.index).style.selectable = true;
    defer b.end();
    // With a link in it: drawn as Markdown that says nothing but the words
    // as typed (`format.plainMarkdown`), so the link opens.
    if (format.hasLink(prompt)) {
        const r = ui.markdown(c, format.plainMarkdown(c.alloc(), prompt), .{ .size = 14 });
        if (r.link) |url| _ = myzig.shell.openUrl(url);
        return;
    }
    ui.text(c, prompt, .{ .size = 14, .wrap = true, .leading = 1.45 });
}

fn thumbnails(c: *ui.Context, turn: *Turn) void {
    const row = ui.div(c).row().gap(8).justifyEnd();
    defer row.end();
    for (turn.images.items, 0..) |img, i| {
        c.keyed(i);
        const box = ui.div(c).w(96).h(72).rounded(10).border(t.alpha_300).clip();
        defer box.end();
        if (!ui.image(c, .{ .key = img.key, .bytes = img.bytes, .size = .{ .w = 96, .h = 72 }, .radius = 10 })) comp.icon(c, "file", .{ .size = 16, .color = t.gray_700 });
    }
}

/// The files the prompt linked, under its words; a click opens one.
fn fileChips(c: *ui.Context, turn: *Turn) void {
    const col = ui.div(c).column().itemsEnd().gap(6);
    defer col.end();
    for (turn.files.items, 0..) |f, i| {
        c.keyed(i);
        const chip = ui.div(c).row().maxW(360).h(34).px(10).gap(8).itemsCenter().rounded(9).bg(t.alpha_100).border(t.alpha_300).hover(t.alpha_200).control();
        comp.icon(c, "paperclip", .{ .size = 13, .color = t.blue_900 });
        {
            const n = ui.div(c).clip();
            defer n.end();
            ui.text(c, f.name, .{ .size = 13 });
        }
        chip.end();
        if (chip.interaction().hovered) c.cursor = .hand;
        if (comp.press(chip)) {
            const shell = @import("myzig").shell;
            _ = if (std.mem.startsWith(u8, f.path, "file:")) shell.openUrl(f.path) else shell.openPath(f.path);
        }
    }
}

fn actionCount(c: *ui.Context, turn: *const Turn) []const u8 {
    const n = turn.toolCount();
    return c.print("{d} action{s}", .{ n, if (n == 1) "" else "s" });
}

fn timed(a: *App, turn: *const Turn) bool {
    return turn.timed and turn.elapsed(a.now()) >= 1000;
}

fn working(a: *App, c: *ui.Context, s: *Session, index: usize, turn: *Turn) void {
    const col = ui.div(c).column().wFull().gap(8);
    defer col.end();
    {
        const head = ui.div(c).row().h(24).gap(8).itemsCenter();
        defer head.end();
        comp.spinner(c, 14);
        var buf: [32]u8 = undefined;
        ui.text(c, if (s.stopping != null) "Stopping…" else if (s.permission != null) "Waiting for you" else "Working", .{ .size = 13 });
        ui.text(c, c.print("{s} · {s}", .{ transcript.duration(&buf, turn.elapsed(a.now())), actionCount(c, turn) }), .{ .size = 13, .color = t.gray_700 });
    }
    const list = timeline.entries(c.alloc(), s, index, turn.work());
    const recent = list[list.len -| 6..];
    if (recent.len > 0) timeline.draw(a, c, s, index, recent, if (s.permission) |p| p.tool.id else null);
    if (s.thread.plan.len > 0) plan(c, s);
}

/// The agent's plan, as Claude Code's to-do list keeps it.
fn plan(c: *ui.Context, s: *Session) void {
    const box = ui.div(c).column().wFull().gap(4).pl(26).pt(4);
    defer box.end();
    for (s.thread.plan, 0..) |e, i| {
        c.keyed(i);
        const row = ui.div(c).row().gap(8).itemsCenter();
        defer row.end();
        const done = std.mem.eql(u8, e.status, "completed");
        const now = std.mem.eql(u8, e.status, "in_progress");
        comp.icon(c, if (done) "check" else if (now) "chevron-right" else "square", .{ .size = 12, .color = if (done) t.green_900 else if (now) t.blue_900 else t.gray_600 });
        ui.text(c, e.content, .{ .size = 13, .color = if (done) t.gray_700 else if (now) t.gray_1000 else t.gray_900 });
    }
}

fn worked(a: *App, c: *ui.Context, s: *Session, index: usize, turn: *Turn) void {
    const open = s.expanded.contains(index);
    const tone = if (open) t.gray_1000 else t.gray_900;
    const col = ui.div(c).column().wFull().gap(8);
    defer col.end();
    {
        const head = ui.div(c).row().h(24).gap(6).itemsCenter().control();
        var buf: [32]u8 = undefined;
        const is_timed = timed(a, turn);
        ui.text(c, if (is_timed) c.print("Worked for {s}", .{transcript.duration(&buf, turn.elapsed(a.now()))}) else c.print("Worked · {s}", .{actionCount(c, turn)}), .{ .size = 13, .color = tone });
        timeline.chevron(c, open, tone);
        if (open and is_timed) ui.text(c, c.print("· {s}", .{actionCount(c, turn)}), .{ .size = 13, .color = t.gray_700 });
        head.end();
        if (comp.press(head)) turns.toggleTurn(a, index);
    }
    if (open) timeline.draw(a, c, s, index, timeline.entries(c.alloc(), s, index, turn.work()), null);
}

fn footer(a: *App, c: *ui.Context, s: *Session, turn: *Turn, answer: []const u8) void {
    const row = ui.div(c).row().h(28).gap(2).itemsCenter();
    defer row.end();
    if (comp.iconButton(c, "copy", 14, "Copy the answer")) {
        myzig.clipboard.writeText(answer);
        a.toast("Copied the answer");
    }
    if (!turn.timed) return;
    var buf: [128]u8 = undefined;
    var dbuf: [32]u8 = undefined;
    const m = if (s.option("model")) |o| format.modelName(&buf, o.current, nameOf(o)) else a.agentName(s.agent);
    const note = if (timed(a, turn)) c.print("{s} · {s}", .{ m, transcript.duration(&dbuf, turn.elapsed(a.now())) }) else m;
    const p = ui.div(c).pl(6);
    defer p.end();
    ui.text(c, note, .{ .size = 12, .color = t.gray_700 });
}

fn nameOf(o: anytype) []const u8 {
    for (o.choices) |ch| if (std.mem.eql(u8, ch.value, o.current)) return ch.name;
    return "";
}

/// A session with nothing said yet: its agent starting, or what failed.
pub fn empty(a: *App, c: *ui.Context, s: *Session) void {
    const box = ui.div(c).column().wFull().grow().px(40).pb(12).itemsCenter().justifyEnd();
    defer box.end();
    const col = ui.div(c).column().wFull().maxW(t.column).gap(16);
    defer col.end();
    if (s.err) |e| errorCard(a, c, s, e) else if (s.opening) loading(c, c.print("Starting {s}…", .{a.agentName(s.agent)}));
}

/// The session beside the active one: dimmed, read only; a click on it
/// swaps the two.
pub fn beside(a: *App, c: *ui.Context, s: *Session) void {
    const col = ui.div(c).column().sizeFull();
    defer col.end();
    {
        const head = ui.div(c).row().wFull().h(44).pl(20).pr(10).gap(8).itemsCenter();
        defer head.end();
        {
            const l = ui.div(c).grow().w(0).clip();
            defer l.end();
            ui.text(c, a.label(s), .{ .size = 13, .color = t.gray_900 });
        }
        if (s.permission != null) comp.dot(c, t.amber_700) else if (s.thread.running()) comp.spinner(c, 12);
        if (comp.iconButton(c, "x", 14, "Close")) sessions.closeBeside(a);
    }
    c.keyed(.{ @as(u8, 'b'), s.key });
    const scroll = ui.div(c).column().wFull().grow().h(0).opacity(0.6).control();
    turnList(a, c, s, &s.rows_beside, true, 24);
    scroll.end();
    const it = scroll.interaction();
    if (it.hovered) c.cursor = .hand;
    if (it.clicked) sessions.swapBeside(a);
}
