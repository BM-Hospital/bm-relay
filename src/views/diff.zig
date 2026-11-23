//! A diff as a block of numbered lines, added in green and removed in red,
//! as the changes panel and the approval card show it. Lines do not wrap:
//! they are cut at the block's edge.
const std = @import("std");
const ui = @import("myzig").ui;
const git = @import("../host/git.zig");
const t = @import("../design/tokens.zig");

const added_ground: ui.Color = .{ .r = @as(f32, 0x45) / 255.0, .g = @as(f32, 0xa5) / 255.0, .b = @as(f32, 0x57) / 255.0, .a = @as(f32, 0x1f) / 255.0 };
const removed_ground: ui.Color = .{ .r = @as(f32, 0xe5) / 255.0, .g = @as(f32, 0x48) / 255.0, .b = @as(f32, 0x4d) / 255.0, .a = @as(f32, 0x1a) / 255.0 };

/// Draws at most `max` lines of `lines` (all of them when null).
pub fn block(c: *ui.Context, lines: []const git.DiffLine, max: ?usize) void {
    const shown = @min(lines.len, max orelse lines.len);
    const col = ui.div(c).column().wFull().py(6).bg(t.background_200);
    defer col.end();
    for (lines[0..shown]) |l| line(c, l);
}

fn line(c: *ui.Context, l: git.DiffLine) void {
    if (l.kind == .hunk) {
        const row = ui.div(c).row().wFull().h(26).px(14).itemsCenter().clip();
        defer row.end();
        ui.text(c, l.text, .{ .size = 12, .mono = true, .color = t.gray_700 });
        return;
    }
    const ground: ?ui.Color, const tone: ui.Color, const number: ?usize = switch (l.kind) {
        .added => .{ added_ground, t.green_900, l.new },
        .removed => .{ removed_ground, t.red_900, l.old },
        else => .{ null, t.gray_600, l.new },
    };
    const row = ui.div(c).row().wFull().h(22).itemsCenter();
    if (ground) |g| _ = row.bg(g);
    defer row.end();
    {
        const num = ui.div(c).row().w(40).pr(12).justifyEnd();
        defer num.end();
        if (number) |n| ui.text(c, c.print("{d}", .{n}), .{ .size = 12, .mono = true, .color = tone });
    }
    const body = ui.div(c).row().wFull().pr(12).clip();
    defer body.end();
    ui.text(c, if (l.text.len > 0) untab(c.alloc(), l.text) else " ", .{ .size = 12, .mono = true, .color = if (l.kind == .context) t.gray_900 else t.gray_1000 });
}

/// Tabs as four spaces, as the block draws them.
fn untab(a: std.mem.Allocator, s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\t') == null) return s;
    const out = a.alloc(u8, s.len + 3 * std.mem.count(u8, s, "\t")) catch return s;
    var w: usize = 0;
    for (s) |ch| {
        if (ch == '\t') {
            @memcpy(out[w .. w + 4], "    ");
            w += 4;
        } else {
            out[w] = ch;
            w += 1;
        }
    }
    return out[0..w];
}

/// "Show N more lines", under a block cut short.
pub fn moreLines(c: *ui.Context, n: usize) void {
    _ = showMore(c, n);
}

/// "Show N more lines", under a block cut short: true when clicked.
pub fn showMore(c: *ui.Context, n: usize) bool {
    const b = ui.div(c).row().wFull().h(30).center().control();
    const hot = b.hovered();
    ui.text(c, c.print("Show {d} more line{s}", .{ n, if (n == 1) "" else "s" }), .{ .size = 12, .color = if (hot) t.gray_1000 else t.gray_700 });
    b.end();
    if (hot) c.cursor = .hand;
    return b.clicked();
}

test "tabs become four spaces" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a    b", untab(arena.allocator(), "a\tb"));
    try std.testing.expectEqualStrings("ab", untab(arena.allocator(), "ab"));
}
