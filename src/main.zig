//! BM Coding Agent: a desktop app for coding agents that speak ACP (Claude Code,
//! Codex, Gemini CLI, fx), drawn by myzig. A port of fx-ui.
//!
//!     zig build run                       open the app
//!     zig build run -- <folder>           open it on a folder
//!     zig build run -- <folder> -p "..."  and send a first prompt
const std = @import("std");
const myzig = @import("myzig");
const app_mod = @import("app/app.zig");
const sessions = @import("app/sessions.zig");
const agent = @import("app/agent.zig");
const git = @import("host/git.zig");
const tokens = @import("design/tokens.zig");
const root = @import("views/root.zig");

const App = app_mod.App;

fn closed(ctx: *anyopaque, _: *myzig.Window) void {
    const a: *App = @ptrCast(@alignCast(ctx));
    if (a.window == null) return;
    agent.stopAll(a);
    a.window = null;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    var folder: ?[]const u8 = null;
    var prompt: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if ((std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--prompt")) and i + 1 < args.len) {
            i += 1;
            prompt = args[i];
        } else if (!std.mem.startsWith(u8, arg, "--myzig")) folder = arg;
    }

    const app = try myzig.App.create(init, .{ .name = "BM Coding Agent", .id = "me.hunghg.bm-agent" });
    defer app.destroy();
    git.init(gpa, init.environ_map);
    defer git.deinit();

    const data_dir = myzig.appPath(gpa, .data, "bm-agent") catch null;
    defer if (data_dir) |d| gpa.free(d);
    // BM_AGENT_STATE names another state file: for trying the app, and tests.
    const store_path = if (init.environ_map.get("BM_AGENT_STATE")) |p| try gpa.dupe(u8, p) else if (data_dir) |d| try std.fs.path.join(gpa, &.{ d, "state.json" }) else null;
    defer if (store_path) |p| gpa.free(p);
    const home = init.environ_map.get("USERPROFILE") orelse init.environ_map.get("HOME") orelse "";

    var a: App = .{
        .gpa = gpa,
        .io = init.io,
        .env = init.environ_map,
        .home = home,
        .app = app,
        .store = .init(gpa, init.io, store_path),
        .composer = .init(gpa, ""),
    };
    defer a.deinit();
    a.store.load();
    // myzig's menus and controls draw the app's icons too.
    myzig.ui.app_icons.* = @import("design/icons.zig").find;
    // The colors before the window opens: its first frame is in them.
    @import("app/appearance.zig").start(&a);
    sessions.loadAll(&a);
    if (prompt) |p| a.first_prompt = try gpa.dupe(u8, p);
    if (folder) |f| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.cwd().realPathFile(init.io, f, &buf) catch 0;
        sessions.openPath(&a, if (n > 0) buf[0..n] else f);
    } else if (a.workspaces.items.len > 0) {
        a.folder = 0;
    }

    a.window = try app.newWindow(.{
        .title = "BM Coding Agent",
        .width = 1280,
        .height = 820,
        .min_width = 860,
        .min_height = 540,
        .theme = tokens.theme(),
        .content = .{ .view = .init(&a, root.view) },
        .on_close = .{ .ctx = &a, .func = closed },
    });
    app.run() catch |e| std.log.err("run: {s}", .{@errorName(e)});
    agent.stopAll(&a);
    a.window = null;
    // Git still reading a folder uses the app's memory: let it finish.
    @import("host/jobs.zig").drain(init.io, 5);
    @import("host/npx.zig").deinit(gpa);
}

test {
    _ = @import("acp/json.zig");
    _ = @import("acp/proto.zig");
    _ = @import("acp/rpc.zig");
    _ = @import("model/transcript.zig");
    _ = @import("model/tools.zig");
    _ = @import("host/git.zig");
    _ = @import("host/store.zig");
    _ = @import("host/pickers.zig");
    _ = @import("host/npx.zig");
    _ = @import("host/claude_files.zig");
    _ = @import("host/agent_stores.zig");
    _ = @import("app/state.zig");
    _ = @import("app/format.zig");
    _ = @import("design/tokens.zig");
    _ = @import("app/appearance.zig");
    _ = @import("app/pictures.zig");
    _ = @import("app/history.zig");
    _ = @import("app/purge.zig");
    _ = @import("app/storage.zig");
    _ = @import("design/components.zig");
    _ = @import("views/changes.zig");
    _ = @import("views/palette.zig");
    _ = @import("views/diff.zig");
    _ = @import("views/dialogs.zig");
    _ = @import("views/changes_test.zig");
    _ = @import("views/timeline.zig");
    _ = @import("views/composer_menus.zig");
    _ = @import("views/timeline_test.zig");
    _ = @import("views/branches.zig");
}
