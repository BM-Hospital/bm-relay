//! BM Relay: a desktop app for coding agents that speak ACP (Claude Code,
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
const crash = @import("host/crash.zig");

/// A panic, a bad memory access, the stack running out: said and logged
/// (`host/crash.zig`) rather than the window just vanishing.
pub const panic = std.debug.FullPanic(crash.panicked);
pub const debug = struct {
    pub fn handleSegfault(addr: ?usize, name: []const u8, ctx: anytype) noreturn {
        crash.faulted(addr, name, ctx);
    }
};

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

    const app = try myzig.App.create(init, .{ .name = "BM Relay", .id = "me.hunghg.bm-relay" });
    defer app.destroy();
    git.init(gpa, init.environ_map);
    defer git.deinit();

    const data_dir = myzig.appPath(gpa, .data, "bm-relay") catch null;
    defer if (data_dir) |d| gpa.free(d);
    if (data_dir) |d| moveOldData(gpa, init.io, d);
    // BM_RELAY_STATE names another state file: for trying the app, and tests.
    const store_path = if (init.environ_map.get("BM_RELAY_STATE")) |p| try gpa.dupe(u8, p) else if (data_dir) |d| try std.fs.path.join(gpa, &.{ d, "state.json" }) else null;
    defer if (store_path) |p| gpa.free(p);
    if (store_path) |p| crash.init(std.fs.path.dirname(p) orelse ".", agent.version);
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
    // The last run crashed: said once, until closed.
    if (crash.takeLast(gpa, init.io)) |text| {
        defer gpa.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        _ = lines.next();
        const what = std.mem.trim(u8, lines.next() orelse "", " \r");
        var buf: [600]u8 = undefined;
        const about = std.fmt.bufPrint(&buf, "{s}{s}Details: {s}.shown", .{ what[0..@min(what.len, 300)], if (what.len > 0) ". " else "", crash.path() }) catch "";
        _ = a.toasts.add(.{ .title = "BM Relay closed unexpectedly last time", .description = about, .kind = .@"error", .timeout = -1 });
    }
    if (prompt) |p| a.first_prompt = try gpa.dupe(u8, p);
    if (folder) |f| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.cwd().realPathFile(init.io, f, &buf) catch 0;
        sessions.openPath(&a, if (n > 0) buf[0..n] else f);
    } else if (a.workspaces.items.len > 0) {
        a.folder = 0;
    }

    a.window = try app.newWindow(.{
        .title = "BM Relay",
        .width = 1280,
        .height = 820,
        .min_width = 860,
        .min_height = 540,
        .theme = tokens.theme(),
        .content = .{ .view = .init(&a, root.view) },
        .on_close = .{ .ctx = &a, .func = closed },
        .on_drop = .of(&a, dropped),
    });
    // Files dragged from other apps reach the composer's drop target.
    if (a.window) |w| myzig.systemDrop(w, &a.dnd, &.{}) catch |e| std.log.warn("drops: {s}", .{@errorName(e)});
    app.run() catch |e| std.log.err("run: {s}", .{@errorName(e)});
    agent.stopAll(&a);
    // The agents' connections are freed as their ends come in.
    @import("acp/rpc.zig").settle(init.io, 1000);
    a.window = null;
    // Git still reading a folder uses the app's memory: let it finish.
    @import("host/jobs.zig").drain(init.io, 5);
    @import("host/npx.zig").deinit(gpa);
}

/// The app was called BM Coding Agent and kept its data in `bm-agent`:
/// that folder becomes `dir` while `dir` has no state yet, so nothing is left
/// behind. `dir` may be there already, empty.
fn moveOldData(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    const state = std.fs.path.join(gpa, &.{ dir, "state.json" }) catch return;
    defer gpa.free(state);
    if (cwd.access(io, state, .{})) |_| return else |_| {}
    const parent = std.fs.path.dirname(dir) orelse return;
    const old = std.fs.path.join(gpa, &.{ parent, "bm-agent" }) catch return;
    defer gpa.free(old);
    cwd.access(io, old, .{}) catch return;
    cwd.deleteDir(io, dir) catch {};
    cwd.rename(old, cwd, dir, io) catch {};
}

/// Files let go on the window where nothing takes them: a folder opens
/// (as Add folder does), files are attached to the draft.
fn dropped(a: *App, _: *myzig.Window, paths: []const []const u8) void {
    for (paths) |p| {
        const st = std.Io.Dir.cwd().statFile(a.io, p, .{}) catch continue;
        if (st.kind == .directory) return sessions.openPath(a, p);
    }
    _ = @import("app/draft.zig").attachFiles(a, paths);
    a.redraw();
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
    _ = @import("host/crash.zig");
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
    _ = @import("views/composer_test.zig");
    _ = @import("views/thread_test.zig");
    _ = @import("views/markdown_test.zig");
    _ = @import("views/branches.zig");
}
