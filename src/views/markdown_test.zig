//! Markdown nested thousands deep (quotes, lists, emphasis) draws: an
//! agent's output can be anything, and such nesting ran out of stack.
const std = @import("std");
const ui = @import("myzig").ui;
const t = @import("../design/tokens.zig");

const TH = struct {
    text: []const u8,
    md: ui.Markdown,
    fn view(h: *TH, c: *ui.Context) void {
        ui.themes.apply(c, t.theme());
        const col = ui.div(c).column().w(500).hFull().p(16).bg(t.background_100);
        defer col.end();
        _ = ui.markdown(c, h.text, .{ .state = &h.md, .size = 14 });
    }
};

fn draw(text: []const u8) !void {
    const gpa = std.testing.allocator;
    var h: TH = .{ .text = text, .md = ui.Markdown.init(gpa) };
    defer h.md.deinit();
    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&h, TH.view), .{ .width = 520, .height = 300, .theme = t.theme(), .dark = true });
    defer tester.deinit();
    tester.frame();
}

test "deeply nested markdown draws" {
    const gpa = std.testing.allocator;
    var quotes: std.ArrayList(u8) = .empty;
    defer quotes.deinit(gpa);
    for (0..5000) |_| try quotes.append(gpa, '>');
    try quotes.appendSlice(gpa, " deep");
    try draw(quotes.items);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    for (0..3000) |i| {
        for (0..i * 2) |_| try list.append(gpa, ' ');
        try list.appendSlice(gpa, "- item\n");
    }
    try draw(list.items);
    var emph: std.ArrayList(u8) = .empty;
    defer emph.deinit(gpa);
    for (0..20000) |_| try emph.appendSlice(gpa, "*[");
    try draw(emph.items);
}
