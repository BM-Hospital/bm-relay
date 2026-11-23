//! The icon set: Lucide's (shipped with myzig, `ui.lucide`), under the
//! names the app's views ask for, and the spinner's two parts, drawn here.
//! `find` hands them to myzig (`ui.app_icons`), which draws every icon,
//! the app's and its own widgets', on the pixel grid. A name not here
//! draws myzig's own icon for it: Lucide's for an SF Symbol's name.
const std = @import("std");
const ui = @import("myzig").ui;
const lucide = ui.lucide;

pub const Icon = struct { name: []const u8, svg: []const u8 };

fn doc(comptime width: []const u8, comptime body: []const u8) []const u8 {
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"" ++ width ++ "\">" ++ body ++ "</svg>";
}

pub const all = [_]Icon{
    .{ .name = "panel-left", .svg = lucide.svg("panel-left") },
    .{ .name = "panel-right", .svg = lucide.svg("panel-right") },
    .{ .name = "panel-split", .svg = lucide.svg("columns-2") },
    .{ .name = "compose", .svg = lucide.svg("square-pen") },
    .{ .name = "search", .svg = lucide.svg("search") },
    .{ .name = "star", .svg = lucide.svg("star") },
    .{ .name = "plus", .svg = lucide.svg("plus") },
    .{ .name = "plus-lg", .svg = lucide.svg("plus") },
    .{ .name = "settings", .svg = lucide.svg("settings") },
    .{ .name = "shield", .svg = lucide.svg("shield") },
    .{ .name = "chevron-down", .svg = lucide.svg("chevron-down") },
    .{ .name = "chevron-right", .svg = lucide.svg("chevron-right") },
    .{ .name = "branch", .svg = lucide.svg("git-branch") },
    .{ .name = "arrow-up", .svg = lucide.svg("arrow-up") },
    .{ .name = "check", .svg = lucide.svg("check") },
    .{ .name = "x", .svg = lucide.svg("x") },
    .{ .name = "file", .svg = lucide.svg("file") },
    .{ .name = "folder", .svg = lucide.svg("folder") },
    .{ .name = "lines", .svg = lucide.svg("align-left") },
    .{ .name = "user", .svg = lucide.svg("user") },
    .{ .name = "alert", .svg = lucide.svg("circle-alert") },
    .{ .name = "pencil", .svg = lucide.svg("pencil") },
    .{ .name = "copy", .svg = lucide.svg("copy") },
    .{ .name = "archive", .svg = lucide.svg("archive") },
    .{ .name = "trash", .svg = lucide.svg("trash-2") },
    .{ .name = "terminal", .svg = lucide.svg("terminal") },
    .{ .name = "globe", .svg = lucide.svg("globe") },
    .{ .name = "bolt", .svg = lucide.svg("zap") },
    .{ .name = "ellipsis", .svg = lucide.svg("ellipsis") },
    .{ .name = "square", .svg = lucide.svg("square") },
    .{ .name = "storage", .svg = lucide.svg("hard-drive") },
    .{ .name = "rectangle.on.rectangle", .svg = lucide.svg("columns-2") },
    .{ .name = "spin-track", .svg = doc("2", "<circle cx=\"8\" cy=\"8\" r=\"6\"/>") },
    .{ .name = "spin-arc", .svg = doc("2", "<path d=\"M8 2a6 6 0 0 1 6 6\" stroke-linecap=\"round\"/>") },
};

pub fn find(name: []const u8) ?[]const u8 {
    for (all) |i| if (std.mem.eql(u8, i.name, name)) return i.svg;
    return null;
}

pub const Options = struct { size: f32 = 16, color: ?ui.Color = null, frame: ?f32 = null };

/// Draws the icon `name` in a square box `frame` points wide (its size
/// when null).
pub fn draw(c: *ui.Context, name: []const u8, o: Options) void {
    ui.icon(c, name, .{ .size = o.size, .frame = o.frame, .color = o.color });
}

test "every icon is there" {
    for (all) |i| try std.testing.expect(std.mem.indexOf(u8, i.svg, "<svg") != null);
    try std.testing.expect(find("trash") != null and find("spin-arc") != null and find("nope") == null);
}
