//! The Appearance page: light, dark or as the system is; the accent the
//! app's buttons and marks are drawn in; the size of every text.
const std = @import("std");
const ui = @import("myzig").ui;
const App = @import("../../app/app.zig").App;
const look = @import("../../app/appearance.zig");
const t = @import("../../design/tokens.zig");
const comp = @import("../../design/components.zig");
const rows = @import("rows.zig");

pub fn draw(a: *App, c: *ui.Context) void {
    rows.pageTitle(c, "Appearance", "How the app looks. Changes show at once.");
    choices(a, c);
    sample(c);
}

fn choices(a: *App, c: *ui.Context) void {
    const card = rows.card(c);
    defer card.end();
    {
        const r = rows.row(c);
        defer r.end();
        rows.rowText(c, "Theme", "Light or dark, or as Windows is set");
        const now = look.theme(a);
        const choice = segmented(c, &.{ "System", "Light", "Dark" }, @intFromEnum(now));
        if (choice) |i| if (i != @intFromEnum(now)) look.setTheme(a, @enumFromInt(i));
    }
    rows.sep(c, 16);
    {
        const r = rows.row(c);
        defer r.end();
        rows.rowText(c, "Accent", look.accent(a).name());
        swatches(a, c);
    }
    rows.sep(c, 16);
    {
        const r = rows.row(c);
        defer r.end();
        rows.rowText(c, "Text size", c.print("Every text in the app. {s} and {s} change it, {s} sets it back.", .{ ui.keys.label("⌘="), ui.keys.label("⌘-"), ui.keys.label("⌘0") }));
        var names: [look.sizes.len][]const u8 = undefined;
        for (look.sizes, &names) |s, *n| n.* = s[1];
        if (segmented(c, &names, look.sizeIndex(a))) |i| look.setTextSize(a, look.sizes[i][0]);
    }
}

/// Buttons side by side, one of them chosen: the one pressed, if any.
fn segmented(c: *ui.Context, labels: []const []const u8, chosen: usize) ?usize {
    const bar = ui.div(c).row().p(2).gap(2).rounded(8).bg(t.alpha_100).border(t.alpha_200);
    defer bar.end();
    var pressed: ?usize = null;
    for (labels, 0..) |l, i| {
        c.keyed(i);
        const on = i == chosen;
        const b = ui.div(c).row().h(26).px(10).itemsCenter().rounded(6).control();
        if (on) _ = b.bg(t.background_100).border(t.alpha_300).shadow(t.shadow_panel) else _ = b.hover(t.alpha_200);
        ui.text(c, l, .{ .size = 12, .weight = if (on) .medium else .regular, .color = if (on) t.gray_1000 else t.gray_900 });
        b.end();
        if (comp.press(b)) pressed = i;
    }
    return pressed;
}

/// A dot of each accent, the chosen one ringed.
fn swatches(a: *App, c: *ui.Context) void {
    const row = ui.div(c).row().gap(6).itemsCenter();
    defer row.end();
    const chosen = look.accent(a);
    inline for (@typeInfo(t.Accent).@"enum".field_names) |name| {
        const x = @field(t.Accent, name);
        c.keyed(@intFromEnum(x));
        const on = x == chosen;
        const ring = ui.div(c).w(26).h(26).rounded(13).center().border(if (on) t.gray_1000 else t.gray_1000.alpha(0)).control();
        ui.div(c).w(18).h(18).rounded(9).bg(x.colors(t.is_dark)[0]).border(t.alpha_300).end();
        ring.end();
        ui.tooltip(c, ring.interaction(), x.name());
        if (comp.press(ring) and !on) look.setAccent(a, x);
    }
}

/// What the choices look like together.
fn sample(c: *ui.Context) void {
    const g = ui.div(c).column().wFull().gap(10);
    defer g.end();
    rows.sectionTitle(c, "Preview");
    const box = ui.div(c).column().wFull().gap(12).p(16).rounded(12).bg(t.background_100).border(t.alpha_300);
    defer box.end();
    {
        const r = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer r.end();
        ui.div(c).w(3).h(16).rounded(2).bg(t.accent).end();
        ui.text(c, "The open session", .{ .size = 14, .weight = .medium });
        ui.spacer(c);
        ui.text(c, "2m ago", .{ .size = 12, .color = t.gray_700 });
    }
    ui.text(c, "Answers read in this size, and code in `Cascadia Mono` beside them.", .{ .size = 14, .wrap = true, .leading = 1.45 });
    {
        const r = ui.div(c).row().gap(10).itemsCenter();
        defer r.end();
        _ = comp.primaryButton(c, "Send", "⏎");
        _ = comp.outlineButton(c, "Cancel", null);
        _ = comp.switchOn(c, true);
        comp.stat(c, 12, 3);
    }
}

test {
    std.testing.refAllDecls(@This());
}
