//! The composer: the draft, its images, the `@` and `/` picker above it,
//! what waits (retries, steering, the queue), and the toolbar of attach,
//! mode, model, thinking, usage and send.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const app_mod = @import("../app/app.zig");
const state = @import("../app/state.zig");
const draft = @import("../app/draft.zig");
const turns = @import("../app/turns.zig");
const agent = @import("../app/agent.zig");
const format = @import("../app/format.zig");
const t = @import("../design/tokens.zig");
const comp = @import("../design/components.zig");
const menus = @import("composer_menus.zig");

const App = app_mod.App;
const Session = state.Session;

pub fn draw(a: *App, c: *ui.Context) void {
    const outer = ui.div(c).column().wFull().px(40).pb(20).pt(4).itemsCenter();
    defer outer.end();
    const col = ui.div(c).column().wFull().maxW(t.column).gap(6);
    defer col.end();
    if (a.active) |s| dock(a, c, s);
    c.keyed(@as(u32, 0x9c1c));
    picker(a, c);
    // Keyed: what shows above it (the picker, the queue) must not move the
    // draft's id, which holds the keyboard's focus.
    c.keyed(@as(u32, 0xc0de));
    card(a, c);
}

/// What waits above the composer: a retry, prompts steering the turn,
/// the queue.
fn dock(a: *App, c: *ui.Context, s: *Session) void {
    if (s.thread.recovery == null and s.steering.items.len == 0 and s.queue.items.len == 0) return;
    const d = ui.div(c).column().wFull().px(6);
    defer d.end();
    if (s.thread.recovery) |r| {
        const row = dockRow(c);
        defer row.end();
        comp.spinnerIn(c, 12, t.amber_700);
        ui.text(c, if (r.attempt <= 1) "Retrying" else c.print("Retrying · attempt {d}", .{r.attempt}), .{ .size = 13 });
        ui.text(c, r.message, .{ .size = 13, .color = t.gray_700 });
    }
    for (s.steering.items) |said| {
        const row = dockRow(c);
        defer row.end();
        label(c, "Steering");
        clippedText(c, said);
        comp.spinner(c, 12);
    }
    var remove: ?usize = null;
    for (s.queue.items, 0..) |q, i| {
        c.keyed(i);
        const row = dockRow(c);
        const hot = row.hovered();
        _ = row.hover(t.alpha_100);
        label(c, if (i == 0) "Next" else "Then");
        const line = q.text[0 .. std.mem.indexOfScalar(u8, q.text, '\n') orelse q.text.len];
        clippedText(c, if (line.len > 0) line else "Images");
        if (q.images.len > 0) ui.text(c, if (q.images.len == 1) "1 image" else c.print("{d} images", .{q.images.len}), .{ .size = 12, .color = t.gray_700 });
        {
            const x = ui.div(c).w(20).h(20).center().rounded(5).opacity(if (hot) 1 else 0);
            comp.icon(c, "x", .{ .size = 12, .color = t.gray_900 });
            x.end();
            if (hot and comp.press(x)) remove = i;
        }
        row.end();
    }
    if (remove) |i| turns.removeQueued(a, s, i);
}

fn dockRow(c: *ui.Context) ui.Div {
    return ui.div(c).row().wFull().h(30).px(10).gap(10).itemsCenter().rounded(8);
}

fn label(c: *ui.Context, s: []const u8) void {
    const l = ui.div(c).w(56);
    defer l.end();
    ui.text(c, s, .{ .size = 12, .color = t.gray_700 });
}

fn clippedText(c: *ui.Context, s: []const u8) void {
    const b = ui.div(c).grow().clip();
    defer b.end();
    ui.text(c, s, .{ .size = 13 });
}

/// The list the `@` and `/` triggers open, above the card.
fn picker(a: *App, c: *ui.Context) void {
    const p = a.picker orelse return;
    const list = draft.items(a, c.alloc());
    if (list.len == 0) return;
    const box = ui.div(c).column().wFull().p(6).rounded(12).bg(t.background_100).border(t.alpha_400).shadow(t.shadow_pop);
    defer box.end();
    for (list, 0..) |it, i| {
        c.keyed(i);
        const row = ui.div(c).row().wFull().h(34).px(10).gap(10).itemsCenter().rounded(6).control();
        if (i == p.selected) _ = row.bg(t.alpha_200);
        _ = row.hover(t.alpha_200);
        comp.icon(c, if (p.kind == '/') "bolt" else "file", .{ .size = 14, .color = if (p.kind == '/') t.purple_900 else t.blue_900 });
        {
            // A long name is cut too, its description first.
            const name = ui.div(c).maxW(260).clip();
            defer name.end();
            ui.text(c, it.title, .{ .size = 13, .mono = p.kind == '@' });
        }
        {
            const rest = ui.div(c).grow().w(0).clip();
            defer rest.end();
            ui.text(c, it.detail, .{ .size = 12, .color = t.gray_700 });
        }
        row.end();
        if (comp.press(row)) {
            a.picker.?.selected = i;
            draft.acceptPick(a);
            // The click took the keyboard: give it back to the draft.
            c.focus = a.composer.id;
        }
    }
}

fn card(a: *App, c: *ui.Context) void {
    const s = a.active;
    const box = ui.div(c).column().wFull().gap(8).pt(if (a.attachments.items.len == 0) 12 else 10).px(10).pb(10).rounded(20).bg(t.gray_100.alpha(0.96)).shadow(t.shadow_composer);
    defer box.end();
    attachments(a, c);
    // A box's id follows where it is, and the draft moves: from Home to the
    // session its first prompt starts, below attachments as they come. The
    // keyboard it had moves with it, or Enter, Escape and typing go nowhere.
    const id = c.peekId(null);
    if (a.composer.id != 0 and a.composer.id != id and c.focus == a.composer.id) c.focus = id;
    const focused = c.focus == id;
    _ = box.border(if (focused) t.alpha_300.mix(t.gray_600, 0.4) else t.alpha_400);
    keys(a, c, focused);
    const hint = if (s) |x| (if (x.isEmpty()) "Describe a change. @ to mention files, / for skills" else "Reply, or type @ for files and / for skills") else "Describe a change. @ to mention files, / for skills";
    const r = ui.textArea(c, &a.composer, .{ .lines = .{ 1, 12 }, .placeholder = hint, .bare = true, .size = 14 });
    if (r.changed) draft.updatePicker(a);
    // Nothing else holds the keyboard: the draft takes it.
    if (c.focus == 0 and a.composer.id != 0 and a.dialog == null and !a.palette.open) c.focus = a.composer.id;
    if (box.clicked() and !focused) c.focus = a.composer.id;
    toolbar(a, c, if (box.interaction().rect) |rect| rect.w else 0);
}

/// Enter sends, Shift+Enter breaks the line; the picker takes the arrows,
/// Tab and Escape while it is open; Ctrl+V pastes an image.
fn keys(a: *App, c: *ui.Context, focused: bool) void {
    if (!focused) return;
    const S = ui.Shortcut;
    _ = S;
    if (a.picker != null) {
        if (takeKey(c, .up)) draft.pickerStep(a, -1);
        if (takeKey(c, .down)) draft.pickerStep(a, 1);
        if (takeKey(c, .tab) or takeKey(c, .enter)) draft.acceptPick(a);
        if (takeKey(c, .escape)) a.picker = null;
        return;
    }
    if (takeKey(c, .enter)) {
        const s = a.active;
        const text = draft.text(a);
        defer a.gpa.free(text);
        const empty = std.mem.trim(u8, text, " \r\n\t").len == 0;
        if (empty and a.attachments.items.len == 0) {
            if (s) |x| if (x.permission != null) return agent.answerPermission(a, x, "allow_once");
        }
        send(a, text);
        return;
    }
    // A picture on the clipboard is attached; text pastes as usual.
    if (c.input.shortcut) |sc| if (sc.key == 'v' and (sc.cmd or sc.ctrl) and !sc.shift and !sc.alt) {
        if (draft.pasteImage(a)) _ = c.shortcut(sc);
    };
    if (takeKey(c, .escape)) if (a.active) |s| {
        if (s.permission != null) agent.answerPermission(a, s, "reject_once") else if (s.thread.running()) turns.stop(a);
    };
}

/// Takes a key without modifiers before the draft's editing sees it. On
/// Windows, Up, Down, Tab and Escape come first as a key combination
/// (`input.shortcut`), which the draft takes as its own (moving the caret,
/// letting go) unless it is taken here: they never come as a key then.
pub fn takeKey(c: *ui.Context, k: @typeInfo(@TypeOf(@as(ui.Context, undefined).input.key)).optional.child) bool {
    const in = &c.input;
    if (in.key == k and !in.shift and !in.ctrl and !in.cmd) {
        in.key = null;
        c.changed = true;
        return true;
    }
    const S = ui.Shortcut;
    const code: u21 = switch (k) {
        .up => S.up,
        .down => S.down,
        .tab => S.tab,
        .escape => S.escape,
        .enter => S.enter,
        else => return false,
    };
    const sc = in.shortcut orelse return false;
    if (sc.key != code or sc.shift or sc.ctrl or sc.alt or sc.cmd) return false;
    in.shortcut = null;
    c.shortcut_taken = true;
    c.changed = true;
    return true;
}

fn send(a: *App, text: []const u8) void {
    if (turns.submit(a, text)) draft.clear(a);
}

fn attachments(a: *App, c: *ui.Context) void {
    if (a.attachments.items.len == 0) return;
    const row = ui.div(c).row().gap(8).pb(4);
    defer row.end();
    var remove: ?usize = null;
    for (a.attachments.items, 0..) |img, i| {
        c.keyed(i);
        const shot = ui.div(c).w(56).h(56);
        const hot = shot.hovered();
        _ = ui.image(c, .{ .key = img.name, .bytes = img.bytes, .size = .{ .w = 56, .h = 56 }, .radius = 10 });
        {
            const x = ui.div(c).absolute().offset(40, -6).w(22).h(22).center().rounded(11).bg(t.gray_100).opacity(if (hot) 1 else 0);
            {
                const inner = ui.div(c).w(18).h(18).center().rounded(9).bg(t.gray_1000);
                defer inner.end();
                comp.icon(c, "x", .{ .size = 10, .color = t.background_100 });
            }
            x.end();
            if (hot and comp.press(x)) remove = i;
        }
        shot.end();
    }
    if (remove) |i| draft.removeAttachment(a, i);
}

/// The composer's buttons. `width` is the composer's, last frame: one too
/// narrow for them all leaves the branch out (the header shows it), and
/// what is left of the middle is cut, never the send button.
fn toolbar(a: *App, c: *ui.Context, width: f32) void {
    const s = a.active;
    const roomy = width == 0 or width >= 660;
    const row = ui.div(c).row().wFull().gap(4).itemsCenter();
    defer row.end();
    menus.attach(a, c);
    if (s) |x| if (x.option("mode")) |m| menus.mode(a, c, x, m);
    {
        const mid = ui.div(c).row().grow().w(0).gap(4).itemsCenter().justifyEnd().clip();
        defer mid.end();
        if (s) |x| {
            menus.model(a, c, x);
            if (x.option("thought_level")) |e| menus.thinking(a, c, x, e);
            if (x.isEmpty() and roomy) branch(a, c);
            if (x.thread.usage) |u| if (!x.isEmpty() and u[1] > 0) menus.usage(a, c, u[0], u[1]);
            if (x.opening) comp.spinner(c, 14);
        } else if (roomy) branch(a, c);
    }
    sendButton(a, c);
}

fn branch(a: *App, c: *ui.Context) void {
    const w = a.workspace() orelse return;
    @import("branches.zig").button(a, c, w, .{ .menu = &a.menus.branch_composer, .chars = 22, .height = 32 });
}

fn stopButton(a: *App, c: *ui.Context) void {
    const s = a.active orelse return;
    const b = ui.div(c).w(32).h(32).center().rounded(16).border(t.alpha_400).hover(t.alpha_200).control();
    ui.div(c).w(10).h(10).rounded(2).bg(t.gray_1000).end();
    b.end();
    ui.tooltip(c, b.interaction(), if (s.stopping != null) "Stop now" else "Stop (Esc)");
    if (comp.press(b)) turns.stop(a);
}

fn sendButton(a: *App, c: *ui.Context) void {
    const s = a.active;
    const running = if (s) |x| x.thread.running() else false;
    const drafted = a.composer.len() > 0 or a.attachments.items.len > 0;
    const stop = running and !drafted;
    const ready = if (s) |x| x.live() else false;
    // A draft typed while it runs goes in the queue; stopping stays a press away.
    if (running and drafted) stopButton(a, c);
    const b = ui.div(c).w(32).h(32).center().rounded(16).bg(if (ready or stop) t.accent else t.gray_500).control();
    if (ready or stop) _ = b.hover(t.accent_hover);
    if (stop) ui.div(c).w(10).h(10).rounded(2).bg(t.on_accent).end() else comp.icon(c, "arrow-up", .{ .size = 16, .color = if (ready or stop) t.on_accent else t.background_100 });
    b.end();
    ui.tooltip(c, b.interaction(), if (stop) "Stop (Esc)" else if (ready) "Send (Enter)" else "The agent is starting…");
    if (!comp.press(b)) return;
    if (stop) return turns.stop(a);
    const text = draft.text(a);
    defer a.gpa.free(text);
    send(a, text);
}

test "the model name of an id" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Gpt 5", format.modelName(&buf, "gpt-5", ""));
}
