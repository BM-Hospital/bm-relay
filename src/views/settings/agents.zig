//! The Agents page, in place of fx-ui's accounts: the ACP agents the app
//! can start, how each is started, which one new sessions use, and the
//! switch that stops offering one.
const std = @import("std");
const ui = @import("myzig").ui;
const App = @import("../../app/app.zig").App;
const t = @import("../../design/tokens.zig");
const comp = @import("../../design/components.zig");
const store_mod = @import("../../host/store.zig");
const rows = @import("rows.zig");

const Agent = store_mod.Agent;

pub fn draw(a: *App, c: *ui.Context) void {
    rows.pageTitle(c, "Agents", "The coding agents that speak ACP, and how to start each one. New sessions use the default.");
    const list = a.store.data.agents;
    {
        const g = ui.div(c).column().wFull().gap(10);
        defer g.end();
        rows.sectionTitle(c, "Agents");
        const card = rows.card(c);
        defer card.end();
        for (list, 0..) |ag, i| {
            c.keyed(i);
            if (i > 0) rows.sep(c, 60);
            if (a.settings.agent_edit == i) form(a, c, i) else agentRow(a, c, ag, i);
        }
        if (a.settings.agent_edit) |e| if (e >= list.len) {
            if (list.len > 0) rows.sep(c, 16);
            form(a, c, list.len);
        };
    }
    {
        const r = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer r.end();
        if (a.settings.agent_edit == null and comp.outlineButton(c, "Add an agent", null)) startEdit(a, list.len);
        ui.spacer(c);
        if (comp.textButton(c, "Reset to defaults")) {
            a.store.setAgents(&store_mod.default_agents);
            if (a.store.agent(a.store.data.agent) == null) a.store.data.agent = "claude";
            a.store.save();
            a.settings.agent_edit = null;
            a.settings.setNote(a.gpa, "The agents are back as the app ships them.", false);
        }
    }
    rows.footnote(c, "Each agent signs in with its own command line, once: run `claude` and sign in for Claude Code, `codex login` for Codex, `gemini` for Gemini CLI; pi uses the providers set up in `pi` itself (`pi auth`), OpenCode those of `opencode auth`. Agents started with npx need Node.js. A change applies to sessions started after it.");
}

fn agentRow(a: *App, c: *ui.Context, ag: Agent, i: usize) void {
    const is_default = std.mem.eql(u8, a.store.data.agent, ag.id);
    const r = rows.row(c);
    defer r.end();
    {
        const tile = ui.div(c).w(28).h(28).center().rounded(8).bg(t.gray_200).border(t.alpha_300);
        defer tile.end();
        const first = if (ag.name.len > 0) ag.name[0..1] else "?";
        ui.text(c, first, .{ .size = 13, .weight = .medium, .color = if (ag.off) t.gray_700 else t.gray_1000 });
    }
    {
        const col = ui.div(c).column().grow().gap(2);
        defer col.end();
        {
            const line = ui.div(c).row().gap(8).itemsCenter();
            defer line.end();
            ui.text(c, ag.name, .{ .size = 14, .color = if (ag.off) t.gray_700 else t.gray_1000 });
            if (is_default) comp.pill(c, "Default", t.blue_900);
            if (ag.off) comp.pill(c, "Off", t.gray_700);
        }
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        ui.text(c, store_mod.joinCommand(arena.allocator(), ag.command), .{ .size = 12, .mono = true, .color = t.gray_900, .wrap = true });
    }
    if (!is_default and !ag.off and comp.textButton(c, "Make default")) {
        a.store.data.agent = a.store.dupe(ag.id);
        a.store.save();
    }
    if (a.settings.agent_edit == null and comp.textButton(c, "Edit")) startEdit(a, i);
    if (comp.switchOn(c, !ag.off)) setOff(a, i, !ag.off);
}

fn startEdit(a: *App, i: usize) void {
    const s = &a.settings;
    s.agent_edit = i;
    s.clearNote(a.gpa);
    if (i < a.store.data.agents.len) {
        const ag = a.store.data.agents[i];
        s.agent_name.set(ag.name);
        s.agent_id.set(ag.id);
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        s.agent_cmd.set(store_mod.joinCommand(arena.allocator(), ag.command));
    } else {
        s.agent_name.clear();
        s.agent_id.clear();
        s.agent_cmd.clear();
    }
}

/// Copies the list into `ar`, to change it and hand it to the store.
fn copy(a: *App, ar: std.mem.Allocator) ?[]Agent {
    return ar.dupe(Agent, a.store.data.agents) catch null;
}

fn setOff(a: *App, i: usize, off: bool) void {
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const list = copy(a, arena.allocator()) orelse return;
    if (i >= list.len) return;
    list[i].off = off;
    a.store.setAgents(list);
    // The default moves to an agent that is on.
    if (off and std.mem.eql(u8, a.store.data.agent, list[i].id)) {
        for (a.store.data.agents) |x| if (!x.off) {
            a.store.data.agent = x.id;
            break;
        };
    }
    a.store.save();
}

fn form(a: *App, c: *ui.Context, i: usize) void {
    const s = &a.settings;
    const adding = i >= a.store.data.agents.len;
    const col = ui.div(c).column().wFull().gap(14).p(16);
    defer col.end();
    ui.text(c, if (adding) "New agent" else "Edit agent", .{ .size = 14, .weight = .medium });
    {
        const r = ui.div(c).row().wFull().gap(12);
        defer r.end();
        {
            const half = ui.div(c).column().grow();
            defer half.end();
            _ = rows.field(c, "Name", &s.agent_name, "My agent");
        }
        if (adding) {
            const half = ui.div(c).column().grow();
            defer half.end();
            _ = rows.field(c, "Id", &s.agent_id, "my-agent");
        }
    }
    const submitted = rows.field(c, "Command", &s.agent_cmd, "my-agent --acp").submitted;
    rows.footnote(c, "The command that starts the agent speaking ACP on its standard input and output. Quote words with spaces.");
    const r = ui.div(c).row().wFull().gap(8).itemsCenter();
    defer r.end();
    if (!adding and a.store.data.agents.len > 1 and comp.textButton(c, "Remove")) return remove(a, i);
    ui.spacer(c);
    if (comp.outlineButton(c, "Cancel", null)) {
        s.agent_edit = null;
        return;
    }
    if (comp.primaryButton(c, "Save", null) or submitted) save(a, i);
}

fn save(a: *App, i: usize) void {
    const s = &a.settings;
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    const name = std.mem.trim(u8, s.agent_name.text(), " \t");
    const words = store_mod.splitCommand(ar, std.mem.trim(u8, s.agent_cmd.text(), " \t"));
    if (words.len == 0) return s.setNote(a.gpa, "Give the agent a command that starts it.", true);
    const list = copy(a, ar) orelse return;
    if (i < list.len) {
        list[i].name = if (name.len > 0) name else list[i].name;
        list[i].command = words;
        a.store.setAgents(list);
    } else {
        const id_raw = std.mem.trim(u8, s.agent_id.text(), " \t");
        const id = std.ascii.allocLowerString(ar, if (id_raw.len > 0) id_raw else name) catch return;
        if (id.len == 0) return s.setNote(a.gpa, "Give the agent a name.", true);
        for (id) |*ch| if (ch.* == ' ' or ch.* == '.') {
            ch.* = '-';
        };
        for (list) |x| if (std.mem.eql(u8, x.id, id)) return s.setNote(a.gpa, "An agent with that id is already here.", true);
        var more: std.ArrayList(Agent) = .empty;
        more.appendSlice(ar, list) catch return;
        more.append(ar, .{ .id = id, .name = if (name.len > 0) name else id, .command = words }) catch return;
        a.store.setAgents(more.items);
    }
    a.store.save();
    s.agent_edit = null;
    s.setNote(a.gpa, "Saved. New sessions start it with this command.", false);
}

fn remove(a: *App, i: usize) void {
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const list = a.store.data.agents;
    if (i >= list.len or list.len < 2) return;
    var kept: std.ArrayList(Agent) = .empty;
    for (list, 0..) |x, j| if (j != i) kept.append(arena.allocator(), x) catch return;
    const gone = list[i].id;
    const was_default = std.mem.eql(u8, a.store.data.agent, gone);
    a.store.setAgents(kept.items);
    if (was_default) a.store.data.agent = a.store.data.agents[0].id;
    a.store.save();
    a.settings.agent_edit = null;
}
