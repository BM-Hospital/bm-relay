//! The composer's menus: attach, permission mode, model (across agents),
//! thinking, and the context it has used.
const std = @import("std");
const ui = @import("myzig").ui;
const app_mod = @import("../app/app.zig");
const state = @import("../app/state.zig");
const draft = @import("../app/draft.zig");
const agent = @import("../app/agent.zig");
const format = @import("../app/format.zig");
const proto = @import("../acp/proto.zig");
const t = @import("../design/tokens.zig");
const comp = @import("../design/components.zig");

const App = app_mod.App;
const Session = state.Session;

/// A rounded button of the toolbar; `on` while its menu is open.
fn pill(c: *ui.Context, on: bool, border: bool) ui.Div {
    const p = ui.div(c).row().h(32).px(10).gap(6).itemsCenter().rounded(16).control();
    if (border) _ = p.border(t.alpha_400);
    if (on) _ = p.bg(t.alpha_200);
    return p.hover(t.alpha_200);
}

fn panel(p: ui.PopoverPanel, width: f32) void {
    const st = p.style();
    st.background = t.background_100;
    st.border = t.alpha_400;
    st.radius = 12;
    st.shadow = t.shadow_pop;
    st.padding = .all(6);
    st.width = .{ .px = width };
    st.gap = 0;
}

/// A row of a menu: hovered and chosen as menus are.
fn row(c: *ui.Context, on: bool) ui.Div {
    const r = ui.div(c).row().wFull().px(8).py(7).gap(10).itemsCenter().rounded(6).control();
    if (on) _ = r.bg(t.alpha_200);
    return r.hover(t.alpha_200);
}

fn check(c: *ui.Context, on: bool) void {
    if (on) comp.icon(c, "check", .{ .size = 14, .color = t.gray_1000 });
}

pub fn attach(a: *App, c: *ui.Context) void {
    const p = pill(c, a.menus.attach.isOpen(), true).w(32).justifyCenter().px(0);
    comp.icon(c, "plus-lg", .{ .size = 16, .color = t.gray_1000 });
    p.end();
    if (p.interaction().hovered) c.cursor = .hand;
    if (ui.buttonMenu(c, &a.menus.attach, p.interaction())) |m| {
        defer m.end();
        if (m.item("Mention a file", .{ .shortcut = "@" })) draft.mention(a);
        if (m.item("Choose images…", .{})) draft.chooseImages(a);
        if (m.item("Paste image", .{ .shortcut = ui.keys.label("⌘V") })) _ = draft.pasteImage(a);
    }
}

/// What a permission mode lets the agent do, for the modes agents name.
fn modeAbout(value: []const u8, name: []const u8) []const u8 {
    const pairs = [_][2][]const u8{
        .{ "ask", "Every edit and command asks" },
        .{ "default", "Edits and commands ask first" },
        .{ "auto", "A safety review decides instead of you" },
        .{ "acceptEdits", "Edits go through; commands ask" },
        .{ "build", "Edits files and runs commands" },
        .{ "plan", "Plans only: reads, changes nothing" },
        .{ "read-only", "Reads only, changes nothing" },
        .{ "full-access", "Accept all permissions" },
        .{ "bypassPermissions", "Accept all permissions" },
        .{ "dontAsk", "Never asks; denies what isn't allowed" },
    };
    for (pairs) |p| if (std.mem.eql(u8, value, p[0]) or std.ascii.eqlIgnoreCase(name, p[0])) return p[1];
    return "";
}

fn isFullAccess(value: []const u8) bool {
    return std.mem.eql(u8, value, "full-access") or std.mem.eql(u8, value, "bypassPermissions") or std.mem.eql(u8, value, "yolo");
}

/// A mode's color by how much it may do unasked: asking blue, planning
/// purple, editing on its own green, everything red.
pub fn modeColor(value: []const u8) ui.Color {
    const has = struct {
        fn f(v: []const u8, w: []const u8) bool {
            return contains(v, w);
        }
    }.f;
    if (has(value, "full") or has(value, "bypass") or has(value, "yolo") or has(value, "danger")) return t.red_900;
    if (has(value, "plan") or has(value, "read")) return t.purple_900;
    if (has(value, "auto") or has(value, "accept") or has(value, "build") or has(value, "edit")) return t.green_900;
    if (has(value, "ask") or has(value, "default")) return t.blue_900;
    return t.gray_1000;
}

fn choiceName(o: *const proto.ConfigOption) []const u8 {
    for (o.choices) |ch| if (std.mem.eql(u8, ch.value, o.current)) return ch.name;
    return o.current;
}

pub fn mode(a: *App, c: *ui.Context, s: *Session, o: *proto.ConfigOption) void {
    const st = &a.menus.mode_pop;
    const p = pill(c, st.open, true).px(12);
    comp.icon(c, "shield", .{ .size = 14, .color = modeColor(o.current) });
    ui.text(c, choiceName(o), .{ .size = 13 });
    p.end();
    if (comp.press(p)) st.toggle();
    const pop = ui.popover(c, st, p.interaction(), .{ .side = .above, .bare = true, .gap = 8 }) orelse return;
    defer pop.end();
    panel(pop, 340);
    for (o.choices, 0..) |ch, i| {
        c.keyed(i);
        const on = std.mem.eql(u8, ch.value, o.current);
        const r = row(c, on);
        {
            const col = ui.div(c).column().grow();
            defer col.end();
            ui.text(c, ch.name, .{ .size = 13, .weight = .medium });
            const about = if (ch.description.len > 0) ch.description else modeAbout(ch.value, ch.name);
            if (about.len > 0) ui.text(c, about, .{ .size = 12, .color = t.gray_900, .wrap = true });
        }
        check(c, on);
        r.end();
        if (comp.press(r)) {
            st.close();
            if (isFullAccess(ch.value) and !on) {
                a.dialog = .{ .full_access = ch.value };
                a.dialog_state.show();
            } else agent.setOption(a, s, o.id, ch.value);
        }
    }
    if (s.grants.items.len > 0) {
        const g = ui.div(c).column().wFull().pt(8).px(6).pb(6).gap(2);
        defer g.end();
        comp.hairline(c);
        {
            const head = ui.div(c).row().wFull().px(2).py(6).itemsCenter();
            defer head.end();
            ui.text(c, "Allowed in this session", .{ .size = 12, .weight = .medium, .color = t.gray_900 });
            ui.spacer(c);
            const f = ui.div(c).control();
            ui.text(c, "Forget all", .{ .size = 12, .color = if (f.hovered()) t.gray_1000 else t.gray_900 });
            f.end();
            if (comp.press(f)) {
                st.close();
                agent.reload(a, s);
            }
        }
        for (s.grants.items) |gr| ui.text(c, gr, .{ .size = 12, .mono = true });
    }
}

// ---------------------------------------------------------------------------
// Models: the session's agent's own, then the other agents' as last seen.

pub fn model(a: *App, c: *ui.Context, s: *Session) void {
    const st = &a.menus.model_pop;
    const o = s.option("model");
    var buf: [128]u8 = undefined;
    const name = if (o) |m| format.modelName(&buf, m.current, choiceName(m)) else a.agentName(s.agent);
    const p = pill(c, st.open, false).gap(7);
    comp.icon(c, "bolt", .{ .size = 13, .color = t.amber_900 });
    {
        const n = ui.div(c).maxW(180).clip();
        defer n.end();
        ui.text(c, name, .{ .size = 13, .color = t.gray_900 });
    }
    comp.icon(c, "chevron-down", .{ .size = 12, .color = t.gray_900 });
    p.end();
    if (comp.press(p)) {
        st.toggle();
        a.model_search.clear();
    }
    const pop = ui.popover(c, st, p.interaction(), .{ .side = .above, .bare = true, .gap = 8 }) orelse return;
    defer pop.end();
    panel(pop, 360);
    _ = ui.textField(c, &a.model_search, .{ .placeholder = "Search models", .width = .fill });
    const q = a.model_search.text();
    const list = ui.div(c).column().wFull().maxH(380).scrollY().pt(4);
    defer list.end();
    // The session's own agent first.
    group(a, c, s, s.agent, q, st);
    for (a.store.data.agents) |ag| {
        if (ag.off or std.mem.eql(u8, ag.id, s.agent)) continue;
        group(a, c, s, ag.id, q, st);
    }
}

fn group(a: *App, c: *ui.Context, s: *Session, agent_id: []const u8, q: []const u8, st: *ui.OverlayState) void {
    const own = std.mem.eql(u8, agent_id, s.agent);
    const live = if (own) s.option("model") else null;
    const cached = a.store.models(agent_id);
    const n = if (live) |m| m.choices.len else if (cached) |m| m.values.len else 0;
    var shown: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const value = if (live) |m| m.choices[i].value else cached.?.values[i];
        const given = if (live) |m| m.choices[i].name else cached.?.names[i];
        var buf: [128]u8 = undefined;
        const name = format.modelName(&buf, value, given);
        if (q.len > 0 and !contains(name, q) and !contains(value, q)) continue;
        if (shown == 0) heading(c, a.agentName(agent_id), own);
        shown += 1;
        c.keyed(.{ agent_id.ptr, i });
        const on = live != null and std.mem.eql(u8, value, live.?.current);
        const r = row(c, on);
        ui.text(c, name, .{ .size = 13 });
        ui.spacer(c);
        check(c, on);
        r.end();
        if (comp.press(r)) {
            st.close();
            agent.pickModel(a, agent_id, value);
        }
    }
    if (n == 0 and q.len == 0) {
        heading(c, a.agentName(agent_id), own);
        const r = row(c, false);
        ui.text(c, if (own) "The agent offers no model choice" else "Start a session on it to list its models", .{ .size = 12, .color = t.gray_700 });
        r.end();
        if (!own and comp.press(r)) {
            st.close();
            a.store.data.agent = a.store.dupe(agent_id);
            a.store.save();
            if (a.workspaceOf(s)) |w| @import("../app/sessions.zig").newSessionIn(a, w);
        }
    }
}

fn contains(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    return false;
}

fn heading(c: *ui.Context, name: []const u8, own: bool) void {
    const h = ui.div(c).row().wFull().px(8).pt(8).pb(4).gap(6).itemsCenter();
    defer h.end();
    ui.text(c, name, .{ .size = 12, .weight = .medium, .color = t.gray_900 });
    if (own) ui.text(c, "· this session", .{ .size = 12, .color = t.gray_700 });
}

// ---------------------------------------------------------------------------
// Thinking.

pub const Thinking = struct { rank: usize, bars: usize, label: []const u8, about: []const u8 };

/// Levels go by meaning, not by the order the agent lists them.
pub fn thinkingOf(value: []const u8, name: []const u8) Thinking {
    const eq = std.mem.eql;
    if (eq(u8, value, "default") or eq(u8, value, "auto")) return .{ .rank = 0, .bars = 0, .label = "Default", .about = "What the model prefers" };
    if (eq(u8, value, "none") or eq(u8, value, "off")) return .{ .rank = 1, .bars = 0, .label = "Off", .about = "Answers straight away" };
    if (eq(u8, value, "minimal")) return .{ .rank = 2, .bars = 1, .label = "Minimal", .about = "Barely pauses" };
    if (eq(u8, value, "low")) return .{ .rank = 3, .bars = 1, .label = "Low", .about = "A brief think first" };
    if (eq(u8, value, "medium")) return .{ .rank = 4, .bars = 2, .label = "Medium", .about = "For everyday changes" };
    if (eq(u8, value, "high")) return .{ .rank = 5, .bars = 3, .label = "High", .about = "Longer on hard problems" };
    if (eq(u8, value, "xhigh")) return .{ .rank = 6, .bars = 4, .label = "Extra high", .about = "Longer still" };
    if (eq(u8, value, "max")) return .{ .rank = 7, .bars = 4, .label = "Max", .about = "As long as it takes" };
    return .{ .rank = 8, .bars = 0, .label = name, .about = "" };
}

fn bars(c: *ui.Context, lit: usize, on: ui.Color) void {
    const b = ui.div(c).row().w(14).h(14).gap(1.3).itemsEnd().pb(1);
    defer b.end();
    for ([_]f32{ 4, 7, 10, 13 }, 0..) |h, i| ui.div(c).w(2.5).h(h).rounded(0.75).bg(if (i < lit) on else t.gray_500).end();
}

pub fn thinking(a: *App, c: *ui.Context, s: *Session, o: *proto.ConfigOption) void {
    const st = &a.menus.thinking_pop;
    const cur = thinkingOf(o.current, choiceName(o));
    const p = pill(c, st.open, false).gap(7);
    bars(c, cur.bars, t.purple_900);
    ui.text(c, cur.label, .{ .size = 13, .color = t.gray_900 });
    p.end();
    if (comp.press(p)) st.toggle();
    const pop = ui.popover(c, st, p.interaction(), .{ .side = .above, .bare = true, .gap = 8 }) orelse return;
    defer pop.end();
    panel(pop, 300);
    const order = c.alloc().alloc(usize, o.choices.len) catch return;
    for (order, 0..) |*x, i| x.* = i;
    std.mem.sort(usize, order, o.choices, struct {
        fn lt(ch: []const proto.Choice, x: usize, y: usize) bool {
            return thinkingOf(ch[x].value, ch[x].name).rank < thinkingOf(ch[y].value, ch[y].name).rank;
        }
    }.lt);
    for (order) |i| {
        const ch = o.choices[i];
        c.keyed(i);
        const on = std.mem.eql(u8, ch.value, o.current);
        const th = thinkingOf(ch.value, ch.name);
        const r = row(c, on);
        bars(c, th.bars, t.purple_900);
        {
            const l = ui.div(c).w(64);
            defer l.end();
            ui.text(c, th.label, .{ .size = 13 });
        }
        {
            const ab = ui.div(c).grow().clip();
            defer ab.end();
            ui.text(c, if (th.about.len > 0) th.about else ch.description, .{ .size = 12, .color = if (on) t.gray_900 else t.gray_700 });
        }
        check(c, on);
        r.end();
        if (comp.press(r)) {
            st.close();
            agent.setOption(a, s, o.id, ch.value);
        }
    }
}

// ---------------------------------------------------------------------------
// Context used.

fn ring(c: *ui.Context, fraction: f32) void {
    const f = std.math.clamp(fraction, 0.02, 0.999);
    const color = if (f > 0.95) t.red_900 else if (f > 0.8) t.amber_700 else t.teal_900;
    var tb: [8]u8 = undefined;
    const svg = c.print("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"18\" height=\"18\" viewBox=\"0 0 18 18\"><circle cx=\"9\" cy=\"9\" r=\"6.3\" fill=\"none\" stroke=\"{s}\" stroke-width=\"1.8\"/><circle cx=\"9\" cy=\"9\" r=\"6.3\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-dasharray=\"{d:.2} 100\" transform=\"rotate(-90 9 9)\" stroke-linecap=\"round\"/></svg>", .{ t.css(&tb, t.gray_400), f * 2 * std.math.pi * 6.3 });
    _ = ui.svg(c, svg, .{ .width = 18, .height = 18, .color = color, .key = c.print("ring:{d}", .{@as(u32, @intFromFloat(f * 200))}) });
}

pub fn usage(a: *App, c: *ui.Context, used: u64, size: u64) void {
    const st = &a.menus.usage;
    const frac: f32 = @as(f32, @floatFromInt(used)) / @as(f32, @floatFromInt(@max(size, 1)));
    const p = pill(c, st.open, false).w(32).px(0).justifyCenter();
    ring(c, frac);
    p.end();
    if (comp.press(p)) st.toggle();
    const pop = ui.popover(c, st, p.interaction(), .{ .side = .above, .bare = true, .gap = 8 }) orelse return;
    defer pop.end();
    panel(pop, 300);
    const body = ui.div(c).column().wFull().p(8).gap(10);
    defer body.end();
    {
        const head = ui.div(c).row().wFull().itemsCenter();
        defer head.end();
        ui.text(c, "Context", .{ .size = 13, .weight = .medium });
        ui.spacer(c);
        ui.text(c, c.print("{d}%", .{@as(u32, @intFromFloat(@round(frac * 100)))}), .{ .size = 13, .color = if (frac > 0.8) t.amber_700 else t.gray_900 });
    }
    {
        const track = ui.div(c).wFull().h(6).rounded(3).bg(t.gray_400).clip();
        defer track.end();
        const w = (300 - 12 - 16) * std.math.clamp(frac, 0, 1);
        ui.div(c).w(w).h(6).rounded(3).bg(if (frac > 0.8) t.amber_700 else t.gray_1000).end();
    }
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    ui.text(c, c.print("{s} of {s} tokens", .{ format.tokens(&b1, used), format.tokens(&b2, size) }), .{ .size = 12, .color = t.gray_900 });
    if (frac > 0.8) ui.text(c, "The conversation is nearly as long as the model can read. Start a new session soon.", .{ .size = 12, .color = t.gray_700, .wrap = true });
}

test "thinking levels go by meaning, not list order" {
    try std.testing.expectEqual(@as(usize, 4), thinkingOf("xhigh", "xhigh").bars);
    try std.testing.expectEqualStrings("Max", thinkingOf("max", "max").label);
    try std.testing.expectEqual(@as(usize, 8), thinkingOf("ultra", "Ultra").rank);
    try std.testing.expectEqualStrings("Extra high", thinkingOf("xhigh", "xhigh").label);
    try std.testing.expectEqualStrings("Accept all permissions", modeAbout("bypassPermissions", ""));
}
