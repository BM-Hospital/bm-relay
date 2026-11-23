//! How the app looks, as the user sets it in Settings → Appearance: light,
//! dark or as the system is; the accent; the size of every text. Saved in
//! the store, applied at the start of every frame.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const App = @import("app.zig").App;
const t = @import("../design/tokens.zig");

pub const Theme = enum { system, light, dark };

pub fn theme(a: *const App) Theme {
    return std.meta.stringToEnum(Theme, a.store.data.theme) orelse .dark;
}

pub fn accent(a: *const App) t.Accent {
    return std.meta.stringToEnum(t.Accent, a.store.data.accent) orelse .green;
}

/// The text sizes offered, as scales of the designed one.
pub const sizes = [_]struct { f32, []const u8 }{
    .{ 0.9, "Small" },
    .{ 1.0, "Default" },
    .{ 1.1, "Large" },
    .{ 1.25, "Larger" },
    .{ 1.4, "Largest" },
};

/// The offered size nearest the saved one.
pub fn sizeIndex(a: *const App) usize {
    var best: usize = 1;
    for (sizes, 0..) |s, i| {
        if (@abs(s[0] - a.store.data.text_size) < @abs(sizes[best][0] - a.store.data.text_size)) best = i;
    }
    return best;
}

/// At start, before the window opens: the system told what the user chose.
pub fn start(a: *App) void {
    a.app.setAppearance(switch (theme(a)) {
        .system => .system,
        .light => .light,
        .dark => .dark,
    });
    t.use(dark(a), accent(a));
}

/// The frame's colors and text size, as set.
pub fn apply(a: *App, c: *ui.Context) void {
    t.use(dark(a), accent(a));
    ui.themes.apply(c, t.theme());
    c.setZoom(a.store.data.text_size);
}

/// Whether the app shows dark: Windows' App keeps it (read when the system
/// changes), other platforms ask the desktop.
fn dark(a: *const App) bool {
    if (@import("builtin").target.os.tag == .windows) return a.app.dark;
    return myzig.isDark();
}

pub fn setTheme(a: *App, x: Theme) void {
    a.store.data.theme = @tagName(x);
    a.store.save();
    start(a);
    a.redraw();
}

pub fn setAccent(a: *App, x: t.Accent) void {
    a.store.data.accent = @tagName(x);
    a.store.save();
    a.redraw();
}

pub fn setTextSize(a: *App, scale: f32) void {
    a.store.data.text_size = std.math.clamp(scale, sizes[0][0], sizes[sizes.len - 1][0]);
    a.store.save();
    a.redraw();
}

/// One offered size up or down (Ctrl+= and Ctrl+-).
pub fn stepTextSize(a: *App, step: isize) void {
    const i: isize = @intCast(sizeIndex(a));
    const next: usize = @intCast(std.math.clamp(i + step, 0, @as(isize, sizes.len - 1)));
    setTextSize(a, sizes[next][0]);
}
