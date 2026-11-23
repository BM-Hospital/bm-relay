//! Settings: the frame and its pages (agents, models, behaviour,
//! appearance, MCP servers, skills, usage, about). A list of pages down
//! the left, the chosen page in a reading column on the right. Every
//! change is saved at once.
const std = @import("std");
const ui = @import("myzig").ui;
const App = @import("../../app/app.zig").App;
const t = @import("../../design/tokens.zig");
const comp = @import("../../design/components.zig");
const agents = @import("agents.zig");
const models = @import("models.zig");
const behaviour = @import("behaviour.zig");
const appearance = @import("appearance.zig");
const storage_page = @import("storage.zig");
const mcp = @import("mcp.zig");
const skills = @import("skills.zig");
const usage = @import("usage.zig");
const about = @import("about.zig");

pub const Section = enum { agents, models, behaviour, appearance, mcp, skills, storage, usage, about };

const Tint = enum { blue, amber, green, pink, teal, purple, gray };

const sections = [_]struct { Section, []const u8, []const u8, Tint }{
    .{ .agents, "Agents", "user", .blue },
    .{ .models, "Models", "bolt", .amber },
    .{ .behaviour, "Behaviour", "shield", .green },
    .{ .appearance, "Appearance", "sun.max", .pink },
    .{ .mcp, "MCP servers", "globe", .teal },
    .{ .skills, "Skills", "star", .purple },
    .{ .storage, "Storage", "storage", .teal },
    .{ .usage, "Usage", "lines", .blue },
    .{ .about, "About", "settings", .gray },
};

fn tint(x: Tint) ui.Color {
    return switch (x) {
        .blue => t.blue_900,
        .amber => t.amber_900,
        .green => t.green_900,
        .pink => t.pink_900,
        .teal => t.teal_900,
        .purple => t.purple_900,
        .gray => t.gray_900,
    };
}

pub const State = struct {
    /// Skills the agent said it skipped, from its notices.
    skipped: ?[]u8 = null,
    section: Section = .agents,
    /// What the last change did, or why it failed.
    note: ?[]u8 = null,
    note_failed: bool = false,

    /// The custom instructions, made when Behaviour first shows.
    instructions: ?ui.TextArea = null,

    /// The agent being edited: its index, or the list's length for a new one.
    agent_edit: ?usize = null,
    agent_name: ui.TextBuffer = .{},
    agent_id: ui.TextBuffer = .{},
    agent_cmd: ui.TextBuffer = .{},

    /// The MCP server being edited, as for agents.
    mcp_edit: ?usize = null,
    mcp_kind: usize = 0,
    mcp_kind_box: ui.SelectState = .{},
    mcp_name: ui.TextBuffer = .{},
    mcp_target: ui.TextBuffer = .{},
    mcp_vars: ui.TextBuffer = .{},

    /// The list of choices open on the Models page, and the row it is for.
    menu: ui.Menu = .{},
    menu_agent: usize = 0,
    menu_cat: usize = 0,

    skills_filter: ui.TextBuffer = .{},
    skills_all: bool = false,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.clearSkipped(gpa);
        s.clearNote(gpa);
        if (s.instructions) |*x| x.deinit();
        s.instructions = null;
    }

    pub fn clearSkipped(s: *State, gpa: std.mem.Allocator) void {
        if (s.skipped) |x| gpa.free(x);
        s.skipped = null;
    }

    /// Keeps what fx's notices say about skills it could not load.
    pub fn noteSkillWarnings(s: *State, gpa: std.mem.Allocator, text: []const u8) void {
        if (std.mem.indexOf(u8, text, "skill discovery warning:") == null) return;
        s.clearSkipped(gpa);
        s.skipped = gpa.dupe(u8, text) catch null;
    }

    pub fn setNote(s: *State, gpa: std.mem.Allocator, text: []const u8, failed: bool) void {
        s.clearNote(gpa);
        s.note = gpa.dupe(u8, text) catch null;
        s.note_failed = failed;
    }

    pub fn clearNote(s: *State, gpa: std.mem.Allocator) void {
        if (s.note) |x| gpa.free(x);
        s.note = null;
    }
};

/// Shows Settings.
pub fn open(a: *App) void {
    a.page = .settings;
    a.redraw();
}

/// Shows Settings at one of its pages.
pub fn openAt(a: *App, section: Section) void {
    go(a, section);
    open(a);
}

fn go(a: *App, section: Section) void {
    if (a.settings.section != section) a.settings.clearNote(a.gpa);
    a.settings.section = section;
    a.settings.menu.close();
}

fn back(a: *App) void {
    a.page = .session;
    a.settings.clearNote(a.gpa);
}

pub fn draw(a: *App, c: *ui.Context) void {
    if (!a.settings.menu.isOpen() and a.settings.agent_edit == null and a.settings.mcp_edit == null and
        c.shortcut(.{ .key = ui.Shortcut.escape })) back(a);

    const frame = ui.div(c).row().grow().wFull();
    defer frame.end();
    nav(a, c);
    ui.div(c).w(1).hFull().bg(t.alpha_200).end();
    ui.scroll(c, .{ .grow = 1, .height = .fill });
    defer ui.end(c);
    const center = ui.div(c).row().wFull().justifyCenter().px(40).pt(36).pb(48);
    defer center.end();
    const col = ui.div(c).column().wFull().maxW(640).gap(32);
    defer col.end();
    if (a.settings.note) |n| @import("rows.zig").note(c, n, a.settings.note_failed);
    switch (a.settings.section) {
        .agents => agents.draw(a, c),
        .models => models.draw(a, c),
        .behaviour => behaviour.draw(a, c),
        .appearance => appearance.draw(a, c),
        .storage => storage_page.draw(a, c),
        .mcp => mcp.draw(a, c),
        .skills => skills.draw(a, c),
        .usage => usage.draw(a, c),
        .about => about.draw(a, c),
    }
}

fn nav(a: *App, c: *ui.Context) void {
    const col = ui.div(c).column().w(200).hFull().gap(1).px(10).py(16);
    defer col.end();
    {
        const b = ui.div(c).row().wFull().h(30).px(10).gap(8).itemsCenter().rounded(6).control();
        const hot = b.hovered();
        _ = b.hover(t.alpha_100);
        ui.text(c, "←", .{ .size = 13, .color = if (hot) t.gray_1000 else t.gray_900 });
        ui.text(c, "Back", .{ .size = 13, .color = if (hot) t.gray_1000 else t.gray_900 });
        b.end();
        if (comp.press(b)) back(a);
    }
    ui.div(c).h(10).end();
    {
        const h = ui.div(c).wFull().px(10).pb(6);
        defer h.end();
        ui.text(c, "Settings", .{ .size = 12, .weight = .medium, .color = t.gray_700 });
    }
    for (sections) |s| {
        c.keyed(s[0]);
        const on = a.settings.section == s[0];
        const item = ui.div(c).row().wFull().h(30).px(10).gap(10).itemsCenter().rounded(6).control();
        if (on) _ = item.bg(t.alpha_200) else _ = item.hover(t.alpha_100);
        comp.icon(c, s[2], .{ .size = 14, .color = tint(s[3]) });
        ui.text(c, s[1], .{ .size = 13, .color = if (on) t.gray_1000 else t.gray_900 });
        item.end();
        if (comp.press(item)) go(a, s[0]);
    }
}

test {
    std.testing.refAllDecls(@This());
}
