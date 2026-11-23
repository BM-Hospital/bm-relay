//! The controls every screen is built from, in fx-ui's look: buttons of
//! four kinds, cards, switches, dots, the line count of a change. Each is
//! immediate: a call draws it and says whether it was pressed.
const std = @import("std");
const ui = @import("myzig").ui;
const t = @import("tokens.zig");
const icons = @import("icons.zig");

pub const icon = icons.draw;

/// The app's logo, as its icon is drawn.
pub const logo_png = @embedFile("logo.png");

pub fn logo(c: *ui.Context, size: f32) void {
    _ = ui.image(c, .{ .key = "app-logo", .bytes = logo_png, .size = .{ .w = size, .h = size }, .radius = 0 });
}

/// A box that acts as a button: the hand over it, and its click.
pub fn press(d: ui.Div) bool {
    const it = d.interaction();
    if (it.hovered) d.c.cursor = .hand;
    return d.clicked();
}

fn button(c: *ui.Context) ui.Div {
    return ui.div(c).row().h(32).px(12).gap(8).itemsCenter().rounded(8).control();
}

fn label(c: *ui.Context, text: []const u8, color: ui.Color) void {
    ui.text(c, text, .{ .size = 13, .weight = .medium, .color = color });
}

fn keys(c: *ui.Context, k: ?[]const u8, color: ui.Color) void {
    if (k) |s| ui.text(c, s, .{ .size = 12, .color = color });
}

pub fn textButton(c: *ui.Context, name: []const u8) bool {
    const b = button(c).px(10);
    const hot = b.hovered();
    _ = b.hover(t.alpha_200);
    defer b.end();
    label(c, name, if (hot) t.gray_1000 else t.gray_900);
    return press(b);
}

pub fn outlineButton(c: *ui.Context, name: []const u8, k: ?[]const u8) bool {
    const b = button(c).border(t.alpha_400).hover(t.alpha_200);
    defer b.end();
    label(c, name, t.gray_1000);
    keys(c, k, t.gray_700);
    return press(b);
}

pub fn primaryButton(c: *ui.Context, name: []const u8, k: ?[]const u8) bool {
    const b = button(c).bg(t.accent).hover(t.accent_hover);
    defer b.end();
    label(c, name, t.on_accent);
    keys(c, k, t.on_accent.alpha(0.6));
    return press(b);
}

pub fn dangerButton(c: *ui.Context, name: []const u8) bool {
    const b = button(c).px(14).bg(t.red_700);
    defer b.end();
    label(c, name, t.white);
    keys(c, "⏎", .{ .r = 1, .g = 1, .b = 1, .a = 0.7 });
    return press(b);
}

/// A square button holding an icon.
pub fn iconButton(c: *ui.Context, name: []const u8, size: f32, tip: ?[]const u8) bool {
    const b = ui.div(c).w(28).h(28).center().rounded(6).control();
    const hot = b.hovered();
    _ = b.hover(t.alpha_200);
    icon(c, name, .{ .size = size, .color = if (hot) t.gray_1000 else t.gray_900 });
    b.end();
    if (tip) |s| ui.tooltip(c, b.interaction(), s);
    return press(b);
}

/// A button that opens a list: its value and an arrow. Returns its
/// interaction, to anchor the list to.
pub fn selectButton(c: *ui.Context, value: []const u8) ui.Interaction {
    const b = ui.div(c).row().h(30).px(10).gap(6).itemsCenter().rounded(8).bg(t.gray_200).border(t.alpha_300).hover(t.gray_300).control();
    ui.text(c, value, .{ .size = 13 });
    icon(c, "chevron-down", .{ .size = 12, .color = t.gray_900 });
    b.end();
    const it = b.interaction();
    if (it.hovered) c.cursor = .hand;
    return it;
}

pub fn card(c: *ui.Context) ui.Div {
    return ui.div(c).column().gap(12).p(14).rounded(12).bg(t.gray_100).border(t.alpha_400);
}

pub fn errorCard(c: *ui.Context, title: []const u8, message: []const u8) void {
    const row = ui.div(c).row().wFull().gap(12).pt(14).pb(14).pl(16).pr(14).rounded(12).bg(t.gray_100).border(t.alpha_400);
    defer row.end();
    {
        const badge = ui.div(c).w(28).h(28).center().rounded(8).bg(t.red_700.alpha(0.14));
        defer badge.end();
        icon(c, "alert", .{ .size = 14, .color = t.red_900 });
    }
    const col = ui.div(c).column().grow().gap(2).pt(3);
    defer col.end();
    ui.text(c, title, .{ .size = 14, .weight = .medium });
    ui.text(c, message, .{ .size = 13, .color = t.gray_900, .wrap = true });
}

/// "+12 −3" in green and red.
pub fn stat(c: *ui.Context, added: usize, removed: usize) void {
    const row = ui.div(c).row().gap(7).itemsCenter();
    defer row.end();
    if (added > 0 or removed == 0) ui.text(c, c.print("+{d}", .{added}), .{ .size = 12, .mono = true, .color = t.green_900 });
    if (removed > 0) ui.text(c, c.print("−{d}", .{removed}), .{ .size = 12, .mono = true, .color = t.red_900 });
}

pub fn dot(c: *ui.Context, color: ui.Color) void {
    ui.div(c).w(7).h(7).rounded(4).bg(color).end();
}

/// A switch: true in the frame it is pressed.
pub fn switchOn(c: *ui.Context, on: bool) bool {
    const s = ui.div(c).row().w(34).h(20).p(2).rounded(10).bg(if (on) t.accent else t.gray_500).control();
    if (on) _ = s.justifyEnd();
    ui.div(c).w(16).h(16).rounded(8).bg(if (on) t.on_accent else t.white).end();
    s.end();
    return press(s);
}

pub fn spinner(c: *ui.Context, size: f32) void {
    ui.spinner(c, .{ .size = size, .color = t.gray_1000 });
}

pub fn spinnerIn(c: *ui.Context, size: f32, color: ui.Color) void {
    ui.spinner(c, .{ .size = size, .color = color });
}

/// A hairline across its parent.
pub fn hairline(c: *ui.Context) void {
    ui.div(c).wFull().h(1).bg(t.alpha_200).end();
}

/// A small rounded label: "Running", "main".
pub fn pill(c: *ui.Context, text: []const u8, color: ui.Color) void {
    const p = ui.div(c).row().px(8).py(2).gap(6).itemsCenter().rounded(10).bg(color.alpha(0.14));
    defer p.end();
    ui.text(c, text, .{ .size = 12, .weight = .medium, .color = color });
}

test {
    std.testing.refAllDecls(@This());
}
