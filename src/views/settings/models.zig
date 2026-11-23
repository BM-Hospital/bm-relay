//! The Models page: for each agent, the model, mode and thinking new
//! sessions start on. Choices come from the session open now when it runs
//! that agent, or from the models the agent listed last time.
const std = @import("std");
const ui = @import("myzig").ui;
const App = @import("../../app/app.zig").App;
const t = @import("../../design/tokens.zig");
const comp = @import("../../design/components.zig");
const format = @import("../../app/format.zig");
const rows = @import("rows.zig");

const cats = [_]struct { key: []const u8, title: []const u8, detail: []const u8, what: []const u8 }{
    .{ .key = "model", .title = "Model", .detail = "What new sessions think with", .what = "models" },
    .{ .key = "mode", .title = "Permission mode", .detail = "What a session may do without asking", .what = "modes" },
    .{ .key = "thought_level", .title = "Thinking", .detail = "More thinking is slower and costs more, and catches more", .what = "levels" },
};

const Choices = struct {
    values: []const []const u8 = &.{},
    names: []const []const u8 = &.{},
};

/// The choices of one option of one agent, in `ar`'s memory.
fn choices(a: *App, ar: std.mem.Allocator, agent_id: []const u8, cat: []const u8) Choices {
    if (a.active) |s| if (std.mem.eql(u8, s.agent, agent_id)) if (s.option(cat)) |o| {
        const values = ar.alloc([]const u8, o.choices.len) catch return .{};
        const names = ar.alloc([]const u8, o.choices.len) catch return .{};
        for (o.choices, values, names) |ch, *v, *n| {
            v.* = ch.value;
            n.* = ch.name;
        }
        return .{ .values = values, .names = names };
    };
    if (std.mem.eql(u8, cat, "model")) if (a.store.models(agent_id)) |m| return .{ .values = m.values, .names = m.names };
    return .{};
}

fn nameOf(buf: []u8, ch: Choices, value: []const u8) []const u8 {
    for (ch.values, ch.names) |v, n| if (std.mem.eql(u8, v, value)) return format.modelName(buf, v, n);
    return format.modelName(buf, value, "");
}

pub fn draw(a: *App, c: *ui.Context) void {
    rows.pageTitle(c, "Models", "What each agent starts new sessions on. The composer changes the session open now.");
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    var any = false;
    for (a.store.data.agents, 0..) |ag, ai| {
        if (ag.off) continue;
        any = true;
        c.keyed(ai);
        const g = ui.div(c).column().wFull().gap(10);
        defer g.end();
        {
            const h = ui.div(c).row().wFull().px(2).gap(8).itemsCenter();
            defer h.end();
            ui.text(c, ag.name, .{ .size = 13, .weight = .medium });
            if (std.mem.eql(u8, a.store.data.agent, ag.id)) comp.pill(c, "Default", t.blue_900);
        }
        const card = rows.card(c);
        defer card.end();
        for (cats, 0..) |cat, ci| {
            c.keyed(ci);
            if (ci > 0) rows.sep(c, 16);
            optionRow(a, c, ar, ai, ci, cat.key, cat.title, cat.detail, cat.what);
        }
    }
    if (!any) rows.footnote(c, "Every agent is off. Turn one on in Agents.");
    if (a.active) |s| {
        var buf: [128]u8 = undefined;
        if (s.option("model")) |m| rows.footnote(c, c.print("The session open now runs {s} on {s}.", .{ a.agentName(s.agent), format.modelName(&buf, m.current, nameFromOption(m)) }));
    }
    menu(a, c, ar);
}

fn nameFromOption(o: anytype) []const u8 {
    for (o.choices) |ch| if (std.mem.eql(u8, ch.value, o.current)) return ch.name;
    return "";
}

fn optionRow(a: *App, c: *ui.Context, ar: std.mem.Allocator, ai: usize, ci: usize, key: []const u8, title: []const u8, detail: []const u8, what: []const u8) void {
    const ag = a.store.data.agents[ai];
    const ch = choices(a, ar, ag.id, key);
    const r = rows.row(c);
    defer r.end();
    if (ch.values.len == 0) {
        rows.rowText(c, title, c.print("Open a session on {s} to list its {s}", .{ ag.name, what }));
        return;
    }
    rows.rowText(c, title, detail);
    const chosen = a.store.default(c.print("{s}.{s}", .{ ag.id, key }));
    var buf: [128]u8 = undefined;
    const label = if (chosen) |v| nameOf(&buf, ch, v) else "Agent's default";
    const it = comp.selectButton(c, c.print("{s}", .{label}));
    if (it.clicked) {
        if (a.settings.menu.isOpen() and a.settings.menu_agent == ai and a.settings.menu_cat == ci) {
            a.settings.menu.close();
        } else if (it.rect) |rect| {
            a.settings.menu_agent = ai;
            a.settings.menu_cat = ci;
            a.settings.menu.openBelow(rect);
        }
    }
}

fn menu(a: *App, c: *ui.Context, ar: std.mem.Allocator) void {
    const m = ui.menu(c, &a.settings.menu) orelse return;
    defer m.end();
    const ai = a.settings.menu_agent;
    if (ai >= a.store.data.agents.len) return;
    const ag = a.store.data.agents[ai];
    const key = cats[@min(a.settings.menu_cat, cats.len - 1)].key;
    const store_key = c.print("{s}.{s}", .{ ag.id, key });
    const chosen = a.store.default(store_key);
    const ch = choices(a, ar, ag.id, key);
    if (m.item("Agent's default", .{ .checked = chosen == null })) {
        a.store.setDefault(store_key, null);
        a.store.save();
    }
    m.separator();
    for (ch.values, ch.names) |v, n| {
        var buf: [128]u8 = undefined;
        const on = if (chosen) |x| std.mem.eql(u8, x, v) else false;
        if (m.item(c.print("{s}", .{format.modelName(&buf, v, n)}), .{ .checked = on })) {
            a.store.setDefault(store_key, v);
            a.store.save();
        }
    }
}
