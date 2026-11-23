//! `App`, the one object the window draws: its folders and sessions, the
//! composer's draft, what is open. Its behaviour is spread over the files
//! of `app/` by concern, as functions taking `*App`; what it draws is in
//! `views/`.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const state = @import("state.zig");
const store_mod = @import("../host/store.zig");
const git = @import("../host/git.zig");
const palette = @import("../views/palette.zig");
const changes = @import("../views/changes.zig");
const settings = @import("../views/settings/settings.zig");

pub const Session = state.Session;
pub const Workspace = state.Workspace;
pub const Store = store_mod.Store;

pub const Menus = struct {
    mode: ui.Menu = .{},
    model: ui.Menu = .{},
    thinking: ui.Menu = .{},
    attach: ui.Menu = .{},
    agent: ui.Menu = .{},
    header: ui.Menu = .{},
    /// The branch buttons' menus: the header's and the composer's.
    branch: ui.Menu = .{},
    branch_composer: ui.Menu = .{},
    /// History's choice of agent.
    history_agent: ui.Menu = .{},
    /// Storage's "Free space" menus.
    storage: ui.Menu = .{},
    folders: ui.Menu = .{},
    row: ui.Menu = .{},
    /// The session the row menu is for.
    row_for: ?*Session = null,
    usage: ui.OverlayState = .{},
    mode_pop: ui.OverlayState = .{},
    model_pop: ui.OverlayState = .{},
    thinking_pop: ui.OverlayState = .{},
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    home: []const u8,
    app: *myzig.App,
    window: ?*myzig.Window = null,
    store: Store,

    workspaces: std.ArrayList(*Workspace) = .empty,
    folder: ?usize = null,
    active: ?*Session = null,
    page: state.Page = .session,
    beside: ?*Session = null,
    /// Keys of the sessions opened last, newest first.
    recent: std.ArrayList(u64) = .empty,
    next_key: u64 = 1,

    composer: ui.TextArea,
    attachments: std.ArrayList(state.Attachment) = .empty,
    picker: ?state.Picker = null,
    /// The model menu's filter.
    model_search: ui.TextBuffer = .{},
    /// The model picker: the group it shows ("" until one is picked: the
    /// current model's), the row the arrows are on, only free models.
    model_nav: [128]u8 = undefined,
    model_nav_len: usize = 0,
    model_hi: usize = 0,
    model_free: bool = false,
    /// Just opened: the arrows start on the current model, scrolled to.
    model_seek: bool = false,
    /// What was searched last frame: a new search starts at the top.
    model_q: u64 = 0,

    menus: Menus = .{},
    dialog: ?state.Dialog = null,
    dialog_state: ui.OverlayState = .{},
    rename: ui.TextBuffer = .{},
    /// A prompt being edited in place: its session and turn, and the text.
    prompt_edit: ?state.PromptEdit = null,
    /// The folder's local branches, while a branch menu is open.
    branch_list: ?[][]const u8 = null,
    /// Pictures answers showed, read from files (`pictures.zig`).
    pictures: @import("pictures.zig").Cache = .empty,
    /// Home's History tab: the folder's sessions as its agent lists them.
    history: @import("history.zig").State = .{},
    /// Settings → Storage: what Claude Code keeps on disk.
    storage: @import("storage.zig").State = .{},
    palette: palette.State = .{},
    changes: ?changes.State = null,
    settings: settings.State = .{},
    home_tab: state.HomeTab = .recent,
    toasts: ui.Toasts = .{},

    sidebar_open: bool = true,
    changes_width: f32 = 576,
    /// The sidebar's edge being dragged: saved as it is let go.
    sidebar_dragged: bool = false,
    first_prompt: ?[]u8 = null,
    /// Scroll the transcript to its end on the next frame.
    to_end: bool = false,
    /// Scratch for `print`: messages copied by whoever keeps them.
    print_bufs: [8][1024]u8 = undefined,
    print_at: usize = 0,

    /// Formats into one of a few scratch buffers: for a message that is
    /// copied at once (an error set, a toast, a key looked up).
    pub fn print(a: *App, comptime fmt: []const u8, args: anytype) []const u8 {
        const buf = &a.print_bufs[a.print_at % a.print_bufs.len];
        a.print_at += 1;
        return std.fmt.bufPrint(buf, fmt, args) catch blk: {
            const n = buf.len - 3;
            @memcpy(buf[n..], "...");
            break :blk buf;
        };
    }

    pub fn now(a: *const App) i64 {
        return std.Io.Clock.real.now(a.io).toMilliseconds();
    }

    /// Asks for a frame: something the view shows changed off the
    /// window's events.
    pub fn redraw(a: *App) void {
        if (a.window) |w| w.redraw();
    }

    pub fn newKey(a: *App) u64 {
        defer a.next_key += 1;
        return a.next_key;
    }

    pub fn session(a: *const App) ?*Session {
        return a.active;
    }

    pub fn workspace(a: *const App) ?*Workspace {
        const i = a.folder orelse return null;
        if (i >= a.workspaces.items.len) return null;
        return a.workspaces.items[i];
    }

    pub fn byKey(a: *const App, key: u64) ?*Session {
        for (a.workspaces.items) |w| for (w.sessions.items) |s| if (s.key == key) return s;
        return null;
    }

    pub fn byId(a: *const App, id: []const u8) ?*Session {
        for (a.workspaces.items) |w| for (w.sessions.items) |s| if (s.id) |x| if (std.mem.eql(u8, x, id)) return s;
        return null;
    }

    pub fn workspaceOf(a: *const App, s: *const Session) ?*Workspace {
        for (a.workspaces.items) |w| if (w.indexOf(s) != null) return w;
        return null;
    }

    pub fn workspaceIndex(a: *const App, w: *const Workspace) ?usize {
        for (a.workspaces.items, 0..) |x, i| if (x == w) return i;
        return null;
    }

    /// The sidebar's width, as dragged (`store.sidebar_width`), within bounds.
    pub fn sidebarWidth(a: *const App) f32 {
        return std.math.clamp(a.store.data.sidebar_width, sidebar_min, sidebar_max);
    }

    pub const sidebar_min: f32 = 200;
    pub const sidebar_max: f32 = 480;

    pub fn anyRunning(a: *const App) bool {
        for (a.workspaces.items) |w| for (w.sessions.items) |s| if (s.thread.running()) return true;
        return false;
    }

    pub fn label(a: *const App, s: *const Session) []const u8 {
        return s.label(&a.store);
    }

    /// The agent new sessions use, as set up.
    pub fn defaultAgent(a: *const App) []const u8 {
        if (a.store.agent(a.store.data.agent)) |x| if (!x.off) return x.id;
        for (a.store.data.agents) |x| if (!x.off) return x.id;
        return "claude";
    }

    pub fn agentName(a: *const App, id: []const u8) []const u8 {
        if (a.store.agent(id)) |x| return x.name;
        return id;
    }

    /// Tells the user, when the window is not in front, that a session
    /// finished or waits.
    pub fn notify(a: *App, title: []const u8, body: []const u8) void {
        if (a.store.data.mute) return;
        if (a.window) |w| if (w.isFocused()) return;
        a.app.notify(.{ .id = "bm-agent", .title = title, .body = body }) catch {};
    }

    pub fn toast(a: *App, title: []const u8) void {
        _ = a.toasts.show(title);
        a.redraw();
    }

    pub fn failToast(a: *App, title: []const u8) void {
        _ = a.toasts.failure(title);
        a.redraw();
    }

    pub fn deinit(a: *App) void {
        if (a.prompt_edit) |*e| e.text.deinit();
        if (a.branch_list) |l| @import("../host/git.zig").freeList(a.gpa, l);
        @import("pictures.zig").deinit(a.gpa, &a.pictures);
        a.history.deinit();
        a.storage.deinitAll(a.gpa);
        for (a.workspaces.items) |w| w.destroy();
        a.workspaces.deinit(a.gpa);
        a.recent.deinit(a.gpa);
        for (a.attachments.items) |x| x.deinit(a.gpa);
        a.attachments.deinit(a.gpa);
        a.composer.deinit();
        if (a.changes) |*c| c.deinit(a.gpa);
        a.settings.deinit(a.gpa);
        a.palette.deinit(a.gpa);
        if (a.first_prompt) |p| a.gpa.free(p);
        a.store.deinit();
    }
};

/// A path as it is shown: inside the home folder, with `~`.
pub fn tilde(a: *const App, buf: []u8, path: []const u8) []const u8 {
    if (a.home.len > 0 and path.len > a.home.len and std.ascii.eqlIgnoreCase(path[0..a.home.len], a.home))
        return std.fmt.bufPrint(buf, "~{s}", .{path[a.home.len..]}) catch path;
    return path;
}

test {
    _ = git;
}
