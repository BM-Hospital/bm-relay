//! The pieces every Settings page is made of: the page's title, a card
//! of rows with hairlines between them, a row's title and detail, the
//! button that opens a list of choices, and footnotes.
const std = @import("std");
const ui = @import("myzig").ui;
const t = @import("../../design/tokens.zig");
const comp = @import("../../design/components.zig");

pub fn pageTitle(c: *ui.Context, title: []const u8, detail: []const u8) void {
    const col = ui.div(c).column().wFull().gap(4);
    defer col.end();
    ui.text(c, title, .{ .size = 22, .weight = .medium });
    ui.text(c, detail, .{ .size = 14, .color = t.gray_900, .wrap = true });
}

pub fn sectionTitle(c: *ui.Context, title: []const u8) void {
    const d = ui.div(c).row().wFull().px(2).gap(8).itemsCenter();
    defer d.end();
    ui.text(c, title, .{ .size = 13, .weight = .medium });
}

/// A section's title with something muted beside it and a count at its end.
pub fn countedTitle(c: *ui.Context, title: []const u8, detail: []const u8, count: usize) void {
    const d = ui.div(c).row().wFull().px(2).gap(8).itemsCenter();
    defer d.end();
    ui.text(c, title, .{ .size = 13, .weight = .medium });
    ui.text(c, detail, .{ .size = 12, .mono = true, .color = t.gray_700 });
    ui.spacer(c);
    ui.text(c, c.print("{d}", .{count}), .{ .size = 12, .color = t.gray_700 });
}

/// A card that holds rows, with `sep` between them.
pub fn card(c: *ui.Context) ui.Div {
    return ui.div(c).column().wFull().rounded(12).clip().bg(t.gray_100).border(t.alpha_300);
}

/// The hairline between two rows of a card, `inset` points in from the left.
pub fn sep(c: *ui.Context, inset: f32) void {
    const d = ui.div(c).row().wFull().pl(inset).pr(if (inset <= 16) inset else 0);
    defer d.end();
    ui.div(c).grow().h(1).bg(t.alpha_200).end();
}

/// A row: open it, add `rowText` and its control, then `end`.
pub fn row(c: *ui.Context) ui.Div {
    const r = ui.div(c).row().wFull().gap(12).px(16).py(10).itemsCenter();
    r.c.node(r.index).style.min_height = 60;
    return r;
}

/// A row's title and the line under it, taking the room the control leaves.
pub fn rowText(c: *ui.Context, title: []const u8, detail: []const u8) void {
    const col = ui.div(c).column().grow().gap(1);
    defer col.end();
    ui.text(c, title, .{ .size = 14 });
    if (detail.len > 0) ui.text(c, detail, .{ .size = 13, .color = t.gray_900, .wrap = true });
}

/// A whole row of text alone.
pub fn textRow(c: *ui.Context, title: []const u8, detail: []const u8) void {
    const r = row(c);
    defer r.end();
    rowText(c, title, detail);
}

pub fn footnote(c: *ui.Context, text: []const u8) void {
    const d = ui.div(c).wFull().px(2);
    defer d.end();
    ui.text(c, text, .{ .size = 12, .color = t.gray_700, .wrap = true });
}

/// A note above a page's cards: what is happening, or what went wrong.
pub fn note(c: *ui.Context, text: []const u8, failed: bool) void {
    const d = ui.div(c).row().wFull().gap(10).px(14).py(10).itemsCenter().rounded(10).bg(if (failed) t.red_700.alpha(0.12) else t.gray_100).border(t.alpha_300);
    defer d.end();
    comp.icon(c, if (failed) "alert" else "check", .{ .size = 14, .color = if (failed) t.red_900 else t.gray_900 });
    ui.text(c, text, .{ .size = 13, .color = if (failed) t.red_900 else t.gray_1000, .wrap = true });
}

/// A labelled field of an edit form.
pub fn field(c: *ui.Context, label: []const u8, buf: *ui.TextBuffer, placeholder: []const u8) ui.TextFieldResult {
    const col = ui.div(c).column().wFull().gap(6);
    defer col.end();
    ui.text(c, label, .{ .size = 12, .weight = .medium, .color = t.gray_900 });
    return ui.textField(c, buf, .{ .placeholder = placeholder, .width = .fill, .size = 13 });
}

/// Pill-shaped choices side by side; returns the one pressed this frame.
pub fn segments(c: *ui.Context, labels: []const []const u8, on: usize) ?usize {
    const bar = ui.div(c).row().h(32).p(2).gap(2).rounded(9).bg(t.background_100).border(t.alpha_300);
    defer bar.end();
    var pressed: ?usize = null;
    for (labels, 0..) |l, i| {
        c.keyed(i);
        const seg = ui.div(c).grow().hFull().center().px(10).rounded(7).control();
        if (i == on) _ = seg.bg(t.gray_300);
        ui.text(c, l, .{ .size = 13, .weight = if (i == on) .medium else .regular, .color = if (i == on) t.gray_1000 else t.gray_900 });
        seg.end();
        if (comp.press(seg)) pressed = i;
    }
    return pressed;
}

test {
    std.testing.refAllDecls(@This());
}
