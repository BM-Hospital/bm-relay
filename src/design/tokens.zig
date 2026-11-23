//! Geist's palettes, dark as fx-ui draws with it and light, an accent the
//! user picks, and the window's theme made from them. Views name colors
//! from here, never by hex: `use` sets them all as the appearance changes.
const std = @import("std");
const ui = @import("myzig").ui;

const C = ui.Color;

fn black(a: u8) C {
    return .{ .r = 0, .g = 0, .b = 0, .a = @as(f32, @floatFromInt(a)) / 255.0 };
}

fn whiteA(a: u8) C {
    return .{ .r = 1, .g = 1, .b = 1, .a = @as(f32, @floatFromInt(a)) / 255.0 };
}

/// Every color a view names: one set for dark, one for light.
pub const Palette = struct {
    background_100: C,
    background_200: C,
    gray_100: C,
    gray_200: C,
    gray_300: C,
    gray_400: C,
    gray_500: C,
    gray_600: C,
    gray_700: C,
    gray_900: C,
    gray_1000: C,
    alpha_100: C,
    alpha_200: C,
    alpha_300: C,
    alpha_400: C,
    amber_700: C,
    amber_900: C,
    red_700: C,
    red_900: C,
    green_700: C,
    green_900: C,
    blue_700: C,
    blue_900: C,
    pink_900: C,
    purple_900: C,
    teal_900: C,
    shadow_panel: ui.Shadow,
    shadow_composer: ui.Shadow,
    shadow_pop: ui.Shadow,
    shadow_modal: ui.Shadow,
};

pub const dark: Palette = .{
    .background_100 = .hex(0x0a0a0a),
    .background_200 = .hex(0x000000),
    .gray_100 = .hex(0x1a1a1a),
    .gray_200 = .hex(0x1f1f1f),
    .gray_300 = .hex(0x292929),
    .gray_400 = .hex(0x2e2e2e),
    .gray_500 = .hex(0x454545),
    .gray_600 = .hex(0x878787),
    .gray_700 = .hex(0x8f8f8f),
    .gray_900 = .hex(0xa1a1a1),
    .gray_1000 = .hex(0xededed),
    .alpha_100 = whiteA(0x0f),
    .alpha_200 = whiteA(0x17),
    .alpha_300 = whiteA(0x21),
    .alpha_400 = whiteA(0x24),
    .amber_700 = .hex(0xffae24),
    .amber_900 = .hex(0xf2a00d),
    .red_700 = .hex(0xe5484d),
    .red_900 = .hex(0xff6166),
    .green_700 = .hex(0x45a557),
    .green_900 = .hex(0x62c073),
    .blue_700 = .hex(0x0070f5),
    .blue_900 = .hex(0x52a8ff),
    .pink_900 = .hex(0xf75f8f),
    .purple_900 = .hex(0xbf7af0),
    .teal_900 = .hex(0x0ac7b4),
    .shadow_panel = .{ .color = black(0x52), .blur = 2, .y = 1 },
    .shadow_composer = .{ .color = black(0x80), .blur = 16, .y = 8 },
    .shadow_pop = .{ .color = black(0x5a), .blur = 14, .y = 8 },
    .shadow_modal = .{ .color = black(0x73), .blur = 24, .y = 16 },
};

pub const light: Palette = .{
    .background_100 = .hex(0xffffff),
    .background_200 = .hex(0xf5f5f5),
    .gray_100 = .hex(0xf2f2f2),
    .gray_200 = .hex(0xebebeb),
    .gray_300 = .hex(0xe6e6e6),
    .gray_400 = .hex(0xdedede),
    .gray_500 = .hex(0xc9c9c9),
    .gray_600 = .hex(0xa8a8a8),
    .gray_700 = .hex(0x7d7d7d),
    .gray_900 = .hex(0x5c5c5c),
    .gray_1000 = .hex(0x171717),
    .alpha_100 = black(0x0a),
    .alpha_200 = black(0x12),
    .alpha_300 = black(0x1a),
    .alpha_400 = black(0x24),
    .amber_700 = .hex(0xf5a524),
    .amber_900 = .hex(0xad5700),
    .red_700 = .hex(0xe5484d),
    .red_900 = .hex(0xcb2a2f),
    .green_700 = .hex(0x45a557),
    .green_900 = .hex(0x297c3b),
    .blue_700 = .hex(0x0070f5),
    .blue_900 = .hex(0x0062d1),
    .pink_900 = .hex(0xc41562),
    .purple_900 = .hex(0x7d00cc),
    .teal_900 = .hex(0x067a6e),
    .shadow_panel = .{ .color = black(0x0f), .blur = 2, .y = 1 },
    .shadow_composer = .{ .color = black(0x1a), .blur = 16, .y = 8 },
    .shadow_pop = .{ .color = black(0x1f), .blur = 14, .y = 8 },
    .shadow_modal = .{ .color = black(0x29), .blur = 24, .y = 16 },
};

/// The color of what the user acts with: the send button, primary
/// buttons, switches, the open session's mark, the focused field.
pub const Accent = enum {
    neutral,
    blue,
    violet,
    green,
    orange,
    pink,

    pub fn name(x: Accent) []const u8 {
        return switch (x) {
            .neutral => "Neutral",
            .blue => "Blue",
            .violet => "Violet",
            .green => "Green",
            .orange => "Orange",
            .pink => "Pink",
        };
    }

    /// Its color, its color under the pointer, and the text on it.
    pub fn colors(x: Accent, in_dark: bool) [3]C {
        const p = if (in_dark) dark else light;
        const on_color: C = .hex(0xffffff);
        return switch (x) {
            .neutral => .{ p.gray_1000, if (in_dark) .hex(0xffffff) else .hex(0x000000), p.background_100 },
            .blue => .{ .hex(0x0a72ef), .hex(0x2b86f5), on_color },
            .violet => .{ .hex(0x8e4ec6), .hex(0x9e62d6), on_color },
            .green => .{ .hex(0x2f9e4f), .hex(0x3aad5c), on_color },
            .orange => .{ .hex(0xe5702a), .hex(0xf0803a), on_color },
            .pink => .{ .hex(0xd6409f), .hex(0xe254ae), on_color },
        };
    }
};

pub var background_100: C = dark.background_100;
pub var background_200: C = dark.background_200;
pub var gray_100: C = dark.gray_100;
pub var gray_200: C = dark.gray_200;
pub var gray_300: C = dark.gray_300;
pub var gray_400: C = dark.gray_400;
pub var gray_500: C = dark.gray_500;
pub var gray_600: C = dark.gray_600;
pub var gray_700: C = dark.gray_700;
pub var gray_900: C = dark.gray_900;
pub var gray_1000: C = dark.gray_1000;
pub var alpha_100: C = dark.alpha_100;
pub var alpha_200: C = dark.alpha_200;
pub var alpha_300: C = dark.alpha_300;
pub var alpha_400: C = dark.alpha_400;
pub var amber_700: C = dark.amber_700;
pub var amber_900: C = dark.amber_900;
pub var red_700: C = dark.red_700;
pub var red_900: C = dark.red_900;
pub var green_700: C = dark.green_700;
pub var green_900: C = dark.green_900;
pub var blue_700: C = dark.blue_700;
pub var blue_900: C = dark.blue_900;
pub var pink_900: C = dark.pink_900;
pub var purple_900: C = dark.purple_900;
pub var teal_900: C = dark.teal_900;
pub var shadow_panel: ui.Shadow = dark.shadow_panel;
pub var shadow_composer: ui.Shadow = dark.shadow_composer;
pub var shadow_pop: ui.Shadow = dark.shadow_pop;
pub var shadow_modal: ui.Shadow = dark.shadow_modal;
pub const white: C = .white;

pub var accent: C = dark.gray_1000;
pub var accent_hover: C = .white;
/// Text and icons on the accent.
pub var on_accent: C = dark.background_100;

/// Whether the colors now are dark's, and the accent they were set with.
pub var is_dark: bool = true;
var current: ?struct { bool, Accent } = null;

/// Sets every color for dark or light and the accent; a no-op when they
/// are already those.
pub fn use(is_dark_now: bool, acc: Accent) void {
    if (current) |cur| if (cur[0] == is_dark_now and cur[1] == acc) return;
    current = .{ is_dark_now, acc };
    is_dark = is_dark_now;
    const p = if (is_dark_now) dark else light;
    inline for (@typeInfo(Palette).@"struct".field_names) |name| @field(@This(), name) = @field(p, name);
    const a = acc.colors(is_dark_now);
    accent = a[0];
    accent_hover = a[1];
    on_accent = a[2];
}

/// `c` as CSS writes it ("#rrggbb"), for SVGs made as text.
pub fn css(buf: []u8, c: C) []const u8 {
    const byte = struct {
        fn f(v: f32) u8 {
            return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
        }
    }.f;
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ byte(c.r), byte(c.g), byte(c.b) }) catch "#888888";
}

/// The reading column of a session, and the sidebar.
pub const column: f32 = 720;
pub const sidebar: f32 = 264;

pub const mono = "Cascadia Mono";

/// The window's theme: the widgets myzig draws (fields, menus, selects,
/// scroll bars) in the same colors.
pub fn theme() ui.Theme {
    var t = if (is_dark) ui.Theme.dark_theme else ui.Theme.light;
    t.background = background_200;
    t.surface = if (is_dark) gray_100 else background_100;
    t.surface_hover = alpha_200;
    t.text = gray_1000;
    t.muted = gray_900;
    t.border = alpha_400;
    t.accent = accent;
    t.accent_hover = accent_hover;
    t.accent_text = on_accent;
    t.ring = gray_600;
    t.track = gray_400;
    t.knob = white;
    t.danger = red_700;
    t.success = green_900;
    t.warning = amber_700;
    t.shadow = shadow_pop.color;
    t.mono_font = mono;
    return t;
}

test "light and dark set every color, and the accent" {
    defer use(true, .neutral);
    use(false, .blue);
    try std.testing.expect(!is_dark);
    try std.testing.expectEqual(light.background_100, background_100);
    try std.testing.expectEqual(light.shadow_modal, shadow_modal);
    try std.testing.expectEqual(Accent.blue.colors(false)[0], accent);
    use(true, .neutral);
    try std.testing.expectEqual(dark.gray_1000, accent);
}
