//! The transcript as a virtual list: a mouse wheel scrolls it up from its
//! end, however long it is.
const std = @import("std");
const ui = @import("myzig").ui;
const t = @import("../design/tokens.zig");
const thread = @import("thread.zig");
const state = @import("../app/state.zig");
const ct = @import("changes_test.zig");
const App = @import("../app/app.zig").App;

const TH = struct {
    a: *App,
    s: *state.Session,
    fn view(h: *TH, c: *ui.Context) void {
        ui.themes.apply(c, t.theme());
        const col = ui.div(c).column().sizeFull().bg(t.background_100);
        defer col.end();
        thread.draw(h.a, c, h.s);
    }
};

test "a long transcript scrolls up from its end by the wheel" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const a = try ct.makeApp(gpa, &env);
    defer ct.freeApp(a);
    const s = state.Session.create(gpa, 1, "x");
    defer s.destroy();
    const answer = "## Done\n\nI changed the report.\n\n```ts\nconst a = 1;\nconst b = 2;\nconst c = 3;\n```\n\n- one\n- two\n- three\n";
    for (0..60) |i| {
        s.thread.apply(.{ .user_text = if (i % 2 == 0) "fix the report" else "and the tests" }, 0);
        s.thread.apply(.{ .text = answer }, 0);
    }
    s.thread.settle(1);
    var h: TH = .{ .a = a, .s = s };
    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&h, TH.view), .{ .width = 900, .height = 600, .theme = t.theme(), .dark = true });
    defer tester.deinit();
    for (0..4) |_| tester.frame();
    var ids = tester.ctx.scroll_limit.iterator();
    var list: u64 = 0;
    var most: f32 = 0;
    while (ids.next()) |e| if (e.value_ptr.* > most) {
        most = e.value_ptr.*;
        list = e.key_ptr.*;
    };
    const end = tester.ctx.scroll.get(list) orelse 0;
    try std.testing.expect(end > 1000);
    tester.moveTo(450, 300);
    for (0..5) |_| tester.wheel(450, 300, 100);
    tester.advance(1);
    for (0..3) |_| tester.frame();
    const now = tester.ctx.scroll.get(list) orelse 0;
    // Five notches of 100 points: the rows above, measured as they come
    // into view, take some of it; the rest moves the view.
    try std.testing.expect(end - now >= 300);
}
