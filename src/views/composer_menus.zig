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
        a.model_nav_len = 0;
        a.model_hi = 0;
        a.model_seek = true;
    }
    const pop = ui.popover(c, st, p.interaction(), .{ .side = .above, .bare = true, .gap = 8 }) orelse return;
    defer pop.end();
    const items = gather(a, c, s);
    const agents = listed(a);
    // One agent: its models in one list. More: the agents beside them.
    const two = agents > 1;
    panel(pop, if (two) 600 else 380);
    const q = a.model_search.text();
    const qh = std.hash.Wyhash.hash(@intFromBool(a.model_free), q);
    if (qh != a.model_q) {
        a.model_q = qh;
        a.model_hi = 0;
        if (q.len > 0) a.model_seek = false;
    }
    var any_free = false;
    for (items) |it| any_free = any_free or it.free;
    // The arrows move along the rows shown; Enter picks: taken before the
    // search field would.
    const keys = @import("composer.zig");
    var moved = false;
    if (keys.takeKey(c, .down)) {
        a.model_hi += 1;
        moved = true;
    }
    if (keys.takeKey(c, .up)) {
        a.model_hi -|= 1;
        moved = true;
    }
    const enter = keys.takeKey(c, .enter);
    {
        const top = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer top.end();
        const f = ui.div(c).grow().w(0);
        // Typing searches as soon as it opens.
        const field = c.peekId(null);
        if (st.justOpened(c)) c.focus = field;
        _ = ui.textField(c, &a.model_search, .{ .placeholder = "Search models", .width = .fill });
        f.end();
        if (any_free or a.model_free) freeToggle(a, c);
    }
    var rows: Rows = .{ .a = a, .c = c, .s = s, .st = st, .enter = enter, .moved = moved };
    if (!two) {
        const list = ui.div(c).column().wFull().maxH(400).scrollY().pt(4);
        rows.list = c.node(list.index).id;
        shown(&rows, items, s.agent, q);
        list.end();
    } else {
        const body = ui.div(c).row().wFull().h(420).gap(6).pt(6);
        defer body.end();
        const key = nav(a, c, s, items, q);
        const list = ui.div(c).column().grow().w(0).hFull().scrollY();
        rows.list = c.node(list.index).id;
        if (std.mem.eql(u8, key, recent_key)) recent(&rows, items, q) else shown(&rows, items, key, q);
        list.end();
    }
    if (rows.count > 0 and a.model_hi >= rows.count) a.model_hi = rows.count - 1;
}

/// More models than this: an agent's are shown under their companies.
const big_list = 24;

/// A model in the picker, of any agent.
const Item = struct {
    agent: []const u8,
    value: []const u8,
    /// Its name, as shown.
    name: []const u8,
    /// Its company's name ("OpenAI"); "" when its id does not say.
    vendor: []const u8,
    /// Its agent has many models: they show under their companies.
    many: bool,
    own: bool,
    on: bool,
    free: bool,
};

/// How many agents the picker lists: those not turned off.
fn listed(a: *App) usize {
    var n: usize = 0;
    for (a.store.data.agents) |ag| {
        if (!ag.off) n += 1;
    }
    return n;
}

/// Every agent's models: the session's agent's (as it offers them), then
/// the others' (as last seen); only free ones when so asked. A big
/// agent's by company, A to Z.
fn gather(a: *App, c: *ui.Context, s: *Session) []Item {
    var out: std.ArrayList(Item) = .empty;
    addAgent(a, c, s, s.agent, &out);
    for (a.store.data.agents) |ag| {
        if (ag.off or std.mem.eql(u8, ag.id, s.agent)) continue;
        addAgent(a, c, s, ag.id, &out);
    }
    return out.items;
}

fn addAgent(a: *App, c: *ui.Context, s: *Session, agent_id: []const u8, out: *std.ArrayList(Item)) void {
    const own = std.mem.eql(u8, agent_id, s.agent);
    const live = if (own) s.option("model") else null;
    const cached = a.store.models(agent_id);
    const n = if (live) |m| m.choices.len else if (cached) |m| m.values.len else 0;
    const many = n > big_list;
    const first = out.items.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const value = if (live) |m| m.choices[i].value else cached.?.values[i];
        const given = if (live) |m| m.choices[i].name else cached.?.names[i];
        const buf = c.alloc().alloc(u8, 128) catch return;
        const name = format.modelName(buf, value, given);
        const free = format.isFree(value, name);
        if (a.model_free and !free) continue;
        const vbuf = c.alloc().alloc(u8, 64) catch return;
        out.append(c.alloc(), .{
            .agent = agent_id,
            .value = value,
            .name = format.withoutFree(name),
            .vendor = format.vendorName(vbuf, format.vendorOf(value)),
            .many = many,
            .own = own,
            .on = live != null and std.mem.eql(u8, value, live.?.current),
            .free = free,
        }) catch {};
    }
    if (many) std.mem.sort(Item, out.items[first..], {}, struct {
        fn lt(_: void, x: Item, y: Item) bool {
            return std.ascii.lessThanIgnoreCase(x.vendor, y.vendor);
        }
    }.lt);
}

/// "Free", on or off: only the models that cost nothing.
fn freeToggle(a: *App, c: *ui.Context) void {
    const b = ui.div(c).row().h(30).px(10).gap(6).itemsCenter().rounded(8).border(if (a.model_free) t.green_900.alpha(0.5) else t.alpha_400).control();
    if (a.model_free) _ = b.bg(t.green_900.alpha(0.12));
    _ = b.hover(t.alpha_200);
    if (a.model_free) comp.icon(c, "check", .{ .size = 12, .color = t.green_900 });
    ui.text(c, "Free", .{ .size = 12, .weight = .medium, .color = if (a.model_free) t.green_900 else t.gray_900 });
    b.end();
    if (comp.press(b)) a.model_free = !a.model_free;
}

/// The rows drawn, counted for the arrows.
const Rows = struct {
    a: *App,
    c: *ui.Context,
    s: *Session,
    st: *ui.OverlayState,
    enter: bool,
    moved: bool,
    list: u64 = 0,
    count: usize = 0,
};

/// A model's row: its name, "free", `tag` (its agent), a check on the
/// current one. Clicked, or Enter on it, picks it.
fn modelRow(r: *Rows, it: Item, tag: ?[]const u8) void {
    const a = r.a;
    const c = r.c;
    const index = r.count;
    r.count += 1;
    c.keyed(.{ it.agent.ptr, it.value.ptr });
    if (a.model_seek and it.on) a.model_hi = index;
    const hi = index == a.model_hi;
    const d = row(c, it.on or hi);
    {
        const n = ui.div(c).grow().w(0).clip();
        defer n.end();
        ui.text(c, it.name, .{ .size = 13 });
    }
    if (it.free) {
        const badge = ui.div(c).px(6).py(1).rounded(4).bg(t.green_900.alpha(0.14));
        ui.text(c, "free", .{ .size = 11, .weight = .medium, .color = t.green_900 });
        badge.end();
    }
    if (tag) |g| ui.text(c, g, .{ .size = 12, .color = t.gray_700 });
    check(c, it.on);
    d.end();
    if (hi and r.moved) _ = reveal(c, r.list, c.node(d.index).id);
    // Opened: scrolled to the current model, once it was laid out.
    if (a.model_seek and it.on and reveal(c, r.list, c.node(d.index).id)) a.model_seek = false;
    if (comp.press(d) or (hi and r.enter)) {
        r.st.close();
        a.store.rememberModel(it.agent, it.value);
        agent.pickModel(a, it.agent, it.value);
    }
}

/// Scrolls the list so row `id` (as last laid out) shows; false when
/// neither was laid out yet.
fn reveal(c: *ui.Context, list: u64, id: u64) bool {
    const view = c.rects.get(list) orelse return false;
    const rect = c.rects.get(id) orelse return false;
    const before = c.scroll.get(list) orelse 0;
    var after = before;
    if (rect.y < view.y) after -= view.y - rect.y;
    if (rect.y + rect.h > view.y + view.h) after += rect.y + rect.h - view.y - view.h;
    if (after != before) {
        c.scroll.put(c.gpa, list, @max(0, after)) catch {};
        c.changed = true;
    }
    return true;
}

fn matches(it: Item, q: []const u8) bool {
    if (q.len == 0) return true;
    return contains(it.name, q) or contains(it.value, q) or contains(it.vendor, q);
}

/// How many of `agent_id`'s models match the search.
fn countOf(items: []const Item, agent_id: []const u8, q: []const u8) usize {
    var n: usize = 0;
    for (items) |it| {
        if (std.mem.eql(u8, it.agent, agent_id) and matches(it, q)) n += 1;
    }
    return n;
}

/// The right side: an agent's models that match, a big one's under their
/// companies.
fn shown(r: *Rows, items: []const Item, agent_id: []const u8, q: []const u8) void {
    const c = r.c;
    var company: ?[]const u8 = null;
    for (items) |it| {
        if (!std.mem.eql(u8, it.agent, agent_id) or !matches(it, q)) continue;
        if (it.many and (company == null or !std.mem.eql(u8, company.?, it.vendor))) {
            company = it.vendor;
            c.keyed(it.value.ptr);
            heading(c, if (it.vendor.len > 0) it.vendor else "Other", false);
        }
        modelRow(r, it, null);
    }
    if (r.count > 0) return;
    if (q.len > 0 or freeOnly(r)) return empty(c, "No model matches");
    noModels(r, agent_id);
}

fn freeOnly(r: *Rows) bool {
    return r.a.model_free;
}

/// Recent: the models picked last, of any agent, that match.
fn recent(r: *Rows, items: []const Item, q: []const u8) void {
    const a = r.a;
    for (a.store.data.recent_models) |k| for (items) |it| if (isRecent(k, it)) {
        if (matches(it, q)) modelRow(r, it, if (it.own) null else a.agentName(it.agent));
        break;
    };
    if (r.count == 0) empty(r.c, "No model matches");
}

fn empty(c: *ui.Context, text: []const u8) void {
    const d = ui.div(c).wFull().px(8).py(12);
    defer d.end();
    ui.text(c, text, .{ .size = 12, .color = t.gray_700 });
}

/// An agent with no models known: a row that starts a session on it.
fn noModels(r: *Rows, agent_id: []const u8) void {
    const a = r.a;
    const c = r.c;
    const own = std.mem.eql(u8, agent_id, r.s.agent);
    const d = row(c, false);
    ui.text(c, if (own) "The agent offers no model choice" else "Start a session on it to list its models", .{ .size = 12, .color = t.gray_700 });
    d.end();
    if (!own and comp.press(d)) {
        r.st.close();
        a.store.data.agent = a.store.dupe(agent_id);
        a.store.save();
        if (a.workspaceOf(r.s)) |w| @import("../app/sessions.zig").newSessionIn(a, w);
    }
}

const recent_key = "\x00recent";

/// The left side: Recent, then the agents (the session's first). A search
/// counts what matches in each, and moves to one with matches when the
/// one shown has none. Returns what is shown.
fn nav(a: *App, c: *ui.Context, s: *Session, items: []const Item, q: []const u8) []const u8 {
    var key: []const u8 = a.model_nav[0..a.model_nav_len];
    var recents: usize = 0;
    for (a.store.data.recent_models) |k| for (items) |it| if (isRecent(k, it)) {
        if (matches(it, q)) recents += 1;
        break;
    };
    const valid = (std.mem.eql(u8, key, recent_key) and recents > 0) or (key.len > 0 and a.store.agent(key) != null);
    if (!valid) {
        setNav(a, s.agent);
        key = s.agent;
    }
    if (q.len > 0 and !std.mem.eql(u8, key, recent_key) and countOf(items, key, q) == 0) {
        // The first agent with matches, the session's first.
        const ids = agentOrder(a, c, s);
        for (ids) |id| if (countOf(items, id, q) > 0) {
            setNav(a, id);
            key = id;
            break;
        };
    }
    const side = ui.div(c).column().w(180).hFull().scrollY().gap(1).pr(6);
    defer side.end();
    if (recents > 0) navEntry(a, c, recent_key, "Recent", recents, "clock", t.blue_900, "");
    for (agentOrder(a, c, s)) |id| {
        c.keyed(id.ptr);
        const n = countOf(items, id, q);
        const known = for (items) |it| {
            if (std.mem.eql(u8, it.agent, id)) break true;
        } else false;
        navEntry(a, c, id, a.agentName(id), n, "user", t.purple_900, if (std.mem.eql(u8, id, s.agent)) "this session" else if (!known and q.len == 0) "no models yet" else "");
    }
    return a.model_nav[0..a.model_nav_len];
}

/// The agents listed: the session's, then the others as in Settings.
fn agentOrder(a: *App, c: *ui.Context, s: *Session) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    out.append(c.alloc(), s.agent) catch {};
    for (a.store.data.agents) |ag| {
        if (ag.off or std.mem.eql(u8, ag.id, s.agent)) continue;
        out.append(c.alloc(), ag.id) catch {};
    }
    return out.items;
}

fn setNav(a: *App, key: []const u8) void {
    const n = @min(key.len, a.model_nav.len);
    @memcpy(a.model_nav[0..n], key[0..n]);
    a.model_nav_len = n;
    a.model_hi = 0;
}

fn isRecent(k: []const u8, it: Item) bool {
    return k.len == it.agent.len + 1 + it.value.len and std.mem.startsWith(u8, k, it.agent) and k[it.agent.len] == '|' and std.mem.endsWith(u8, k, it.value);
}

fn navEntry(a: *App, c: *ui.Context, key: []const u8, label: []const u8, n: usize, icon: []const u8, tint: ui.Color, note: []const u8) void {
    const on = std.mem.eql(u8, a.model_nav[0..a.model_nav_len], key);
    const d = ui.div(c).row().wFull().px(8).py(7).gap(8).itemsCenter().rounded(6).control();
    if (on) _ = d.bg(t.alpha_300);
    _ = d.hover(t.alpha_200);
    comp.icon(c, icon, .{ .size = 13, .color = tint });
    {
        const l = ui.div(c).column().grow().w(0).clip();
        defer l.end();
        ui.text(c, label, .{ .size = 13, .weight = if (on) .medium else .regular, .color = if (on) t.gray_1000 else t.gray_900 });
        if (note.len > 0) ui.text(c, note, .{ .size = 11, .color = t.gray_700 });
    }
    if (n > 0) ui.text(c, c.print("{d}", .{n}), .{ .size = 11, .color = t.gray_700 });
    d.end();
    if (comp.press(d)) {
        setNav(a, key);
        a.model_seek = true;
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
