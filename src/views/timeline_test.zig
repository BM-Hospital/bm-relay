//! The work log drawn: a long step shows all of itself in its tooltip.
const std = @import("std");
const ui = @import("myzig").ui;
const t = @import("../design/tokens.zig");
const timeline = @import("timeline.zig");
const state = @import("../app/state.zig");
const ct = @import("changes_test.zig");

const TH = struct {
    a: *@import("../app/app.zig").App,
    s: *state.Session,
    fn view(h: *TH, c: *ui.Context) void {
        ui.themes.apply(c, t.theme());
        const col = ui.div(c).column().w(500).hFull().p(16).bg(t.background_100);
        defer col.end();
        const turn = h.s.thread.turns.items[0];
        timeline.draw(h.a, c, h.s, 0, timeline.entries(c.alloc(), h.s, 0, turn.items.items), null);
    }
};

test "a long command's tooltip shows all of it" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const a = try ct.makeApp(gpa, &env);
    defer ct.freeApp(a);
    const s = state.Session.create(gpa, 1, "x");
    defer s.destroy();
    _ = s.thread.begin("go", 0);
    var input: std.json.ObjectMap = .empty;
    try input.put(s.thread.arena.allocator(), "command", .{ .string = "gh api users/someone --jq '{name,login,bio,company,location,blog,public_repos,followers,following,hireable,twitter_username}'" });
    s.thread.apply(.{ .tool_call = .{ .id = "r", .kind = "execute", .status = "completed", .title = "gh", .input = .{ .object = input } } }, 0);
    var h: TH = .{ .a = a, .s = s };
    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&h, TH.view), .{ .width = 520, .height = 300, .theme = t.theme(), .dark = true });
    defer tester.deinit();
    tester.frame();
    const cmd = "gh api users/someone --jq '{name,login,bio,company,location,blog,public_repos,followers,following,hireable,twitter_username}'";
    const cut = cmd[90..96] ++ "\n" ++ cmd[96..100];
    try std.testing.expect(!tester.containsText(cut));
    const r = tester.findText("Ran").?;
    tester.moveTo(r.x + r.w + 60, r.y + r.h / 2);
    tester.advance(1.5);
    tester.frame();
    try std.testing.expect(tester.containsText(cut));
}
