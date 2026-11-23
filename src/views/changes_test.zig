//! The changes panel, the palette and the dialogs, driven offscreen.
const std = @import("std");
const ui = @import("myzig").ui;
const app_mod = @import("../app/app.zig");
const state = @import("../app/state.zig");
const git = @import("../host/git.zig");
const changes = @import("changes.zig");
const palette = @import("palette.zig");
const dialogs = @import("dialogs.zig");
const t = @import("../design/tokens.zig");

const App = app_mod.App;

const Harness = struct {
    a: *App,
    fn view(h: *Harness, c: *ui.Context) void {
        ui.themes.apply(c, t.theme());
        const root = ui.div(c).row().sizeFull().bg(t.background_200).p(8);
        defer root.end();
        const p = ui.div(c).column().w(560).hFull().rounded(12).clip().bg(t.background_100).border(t.alpha_200);
        changes.draw(h.a, c);
        p.end();
        palette.draw(h.a, c);
        dialogs.draw(h.a, c);
    }
};

pub fn makeApp(gpa: std.mem.Allocator, env: *std.process.Environ.Map) !*App {
    const a = try gpa.create(App);
    a.* = .{
        .gpa = gpa,
        .io = std.testing.io,
        .env = env,
        .home = "",
        .app = undefined,
        .store = .init(gpa, std.testing.io, null),
        .composer = .init(gpa, ""),
    };
    a.store.load();
    const w = state.Workspace.create(gpa, "/work/demo");
    try a.workspaces.append(gpa, w);
    a.folder = 0;
    return a;
}

pub fn freeApp(a: *App) void {
    const gpa = a.gpa;
    a.deinit();
    gpa.destroy(a);
}

const sample = [_]git.Change{
    .{ .path = "src/main.zig", .code = 'M', .staged = true, .added = 12, .removed = 3 },
    .{ .path = "src/views/changes.zig", .code = 'M', .staged = false, .added = 40, .removed = 8 },
    .{ .path = "notes.md", .code = '?', .staged = false, .added = 4, .removed = 0 },
};

test "the panel lists staged and unstaged files, and a diff" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const a = try makeApp(gpa, &env);
    defer freeApp(a);
    a.changes = .{ .list = git.cloneChanges(gpa, &sample), .loaded = true };
    var h: Harness = .{ .a = a };
    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&h, Harness.view), .{ .width = 600, .height = 520, .theme = t.theme(), .dark = true });
    defer tester.deinit();
    tester.frame();
    try std.testing.expect(tester.hasText("Staged"));
    try std.testing.expect(tester.hasText("Not staged"));
    try std.testing.expect(tester.hasText("main.zig"));
    try std.testing.expect(tester.hasText("Stage all"));

    // A diff, as opening a file shows it.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    a.changes.?.diff_arena = arena;
    a.changes.?.diff = git.parseUnified(a.changes.?.diff_arena.?.allocator(), "@@ -1,3 +1,4 @@ fn main\n const std = @import(\"std\");\n-pub fn old() void {}\n+pub fn new() void {}\n+\tconst tabbed = 1;\n keep\n");
    a.changes.?.setOpen(gpa, sample[1]);
    tester.frame();
    try std.testing.expect(tester.hasText("Unstage") or tester.hasText("Stage"));
    try std.testing.expect(tester.containsText("pub fn new"));
    arena = undefined;
}

test "the palette filters and the dialogs ask" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const a = try makeApp(gpa, &env);
    defer freeApp(a);
    var h: Harness = .{ .a = a };
    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&h, Harness.view), .{ .width = 760, .height = 560, .theme = t.theme(), .dark = true });
    defer tester.deinit();
    palette.toggle(a);
    tester.frame();
    try std.testing.expect(tester.hasText("New session"));
    try std.testing.expect(tester.hasText("Folders"));
    tester.typeText("sett");
    tester.frame();
    try std.testing.expect(tester.containsText("ings"));
    try std.testing.expect(!tester.hasText("Open folder"));
    tester.key(.escape);
    tester.frame();
    try std.testing.expect(!a.palette.open);

    dialogs.ask(a, .{ .remove_folder = 0 });
    tester.frame();
    try std.testing.expect(tester.hasText("Remove demo?"));
    try std.testing.expect(tester.hasText("Cancel"));
    try tester.clickText("Cancel");
    tester.frame();
    try std.testing.expect(a.dialog == null);
}
