//! Files onto the composer: dragged from another app (Explorer, Finder),
//! they are attached, an image as itself, another file as a link.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const t = @import("../design/tokens.zig");
const composer = @import("composer.zig");
const draft = @import("../app/draft.zig");
const ct = @import("changes_test.zig");
const App = @import("../app/app.zig").App;

const TH = struct {
    a: *App,
    fn view(h: *TH, c: *ui.Context) void {
        ui.themes.apply(c, t.theme());
        const col = ui.div(c).column().w(760).hFull().justifyEnd().bg(t.background_100);
        defer col.end();
        composer.draw(h.a, c);
    }
};

test "files dragged onto the composer are attached, a folder is not" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const a = try ct.makeApp(gpa, &env);
    defer ct.freeApp(a);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.md", .data = "# Notes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data.csv", .data = "a,b\n1,2\n" });
    try tmp.dir.createDirPath(io, "folder");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", ar);
    const paths = [_][]const u8{
        try std.fs.path.join(ar, &.{ base, "notes.md" }),
        try std.fs.path.join(ar, &.{ base, "data.csv" }),
        try std.fs.path.join(ar, &.{ base, "folder" }),
    };

    var h: TH = .{ .a = a };
    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&h, TH.view), .{ .width = 760, .height = 400, .theme = t.theme(), .dark = true });
    defer tester.deinit();
    tester.frame();
    tester.frame();
    // Over the composer, near the window's bottom: it says it takes them.
    const at: ui.Point = .{ .x = 380, .y = 340 };
    a.dnd.externalEnter(try myzig.transfer.fileData(gpa, &paths), .copy_move, at);
    tester.frame();
    _ = a.dnd.externalOver(at, null);
    tester.frame();
    try std.testing.expect(tester.containsText("Drop to attach the files"));
    _ = a.dnd.externalDrop(at, null, null);
    tester.frame();
    tester.frame();
    try std.testing.expectEqual(@as(usize, 2), a.attachments.items.len);
    try std.testing.expect(a.attachments.items[0].isFile());
    try std.testing.expect(tester.containsText("notes.md"));
    try std.testing.expect(tester.containsText("data.csv"));
    try std.testing.expect(!tester.containsText("Drop to attach the files"));
    // The same file again is not attached twice.
    _ = draft.attachFiles(a, paths[0..1]);
    try std.testing.expectEqual(@as(usize, 2), a.attachments.items.len);
}
