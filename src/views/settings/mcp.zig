//! The MCP servers page: the servers handed to every session the app
//! starts or reopens, as ACP passes them in `session/new`. A server runs
//! as a command (stdio) or is reached at an address (HTTP or SSE).
const std = @import("std");
const ui = @import("myzig").ui;
const App = @import("../../app/app.zig").App;
const t = @import("../../design/tokens.zig");
const comp = @import("../../design/components.zig");
const store_mod = @import("../../host/store.zig");
const rows = @import("rows.zig");

const Mcp = store_mod.Mcp;
const KV = store_mod.KV;

const kinds = [_][]const u8{ "stdio", "http", "sse" };
const kind_labels = [_][]const u8{ "Command (stdio)", "HTTP", "SSE" };

pub fn draw(a: *App, c: *ui.Context) void {
    rows.pageTitle(c, "MCP servers", "Tools from outside the agent, handed to every session the app starts or reopens.");
    const list = a.store.data.mcp;
    {
        const g = ui.div(c).column().wFull().gap(10);
        defer g.end();
        rows.countedTitle(c, "Yours", "", list.len);
        const card = rows.card(c);
        defer card.end();
        if (list.len == 0 and a.settings.mcp_edit == null) rows.textRow(c, "No servers yet", "Add one by its command or its address");
        for (list, 0..) |m, i| {
            c.keyed(i);
            if (i > 0) rows.sep(c, 56);
            if (a.settings.mcp_edit == i) form(a, c, i) else serverRow(a, c, m, i);
        }
        if (a.settings.mcp_edit) |e| if (e >= list.len) {
            if (list.len > 0) rows.sep(c, 16);
            form(a, c, list.len);
        };
    }
    if (a.settings.mcp_edit == null and comp.outlineButton(c, "Add a server", null)) startEdit(a, list.len);
    rows.footnote(c, "A change reaches sessions started or reopened after it. HTTP and SSE servers go only to agents that say they take them.");
}

fn kindIndex(k: []const u8) usize {
    for (kinds, 0..) |x, i| if (std.mem.eql(u8, x, k)) return i;
    return 0;
}

fn serverRow(a: *App, c: *ui.Context, m: Mcp, i: usize) void {
    const r = rows.row(c);
    defer r.end();
    {
        const tile = ui.div(c).w(28).h(28).center().rounded(8).bg(t.gray_200).border(t.alpha_300);
        defer tile.end();
        comp.icon(c, if (std.mem.eql(u8, m.kind, "stdio")) "terminal" else "globe", .{ .size = 14, .color = if (m.off) t.gray_700 else t.gray_900 });
    }
    {
        const col = ui.div(c).column().grow().gap(2);
        defer col.end();
        {
            const line = ui.div(c).row().gap(8).itemsCenter();
            defer line.end();
            ui.text(c, m.name, .{ .size = 14, .color = if (m.off) t.gray_700 else t.gray_1000 });
            comp.pill(c, kind_labels[kindIndex(m.kind)], t.gray_900);
        }
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        ui.text(c, target(arena.allocator(), m), .{ .size = 12, .mono = true, .color = t.gray_900, .wrap = true });
    }
    if (a.settings.mcp_edit == null and comp.textButton(c, "Edit")) startEdit(a, i);
    if (comp.switchOn(c, !m.off)) {
        const copy = a.store.a().dupe(Mcp, a.store.data.mcp) catch return;
        copy[i].off = !copy[i].off;
        a.store.data.mcp = copy;
        a.store.save();
    }
}

/// The command line of a stdio server, or a remote server's address.
fn target(ar: std.mem.Allocator, m: Mcp) []const u8 {
    if (!std.mem.eql(u8, m.kind, "stdio")) return m.url;
    var words: std.ArrayList([]const u8) = .empty;
    words.append(ar, m.command) catch {};
    words.appendSlice(ar, m.args) catch {};
    return store_mod.joinCommand(ar, words.items);
}

fn joinVars(ar: std.mem.Allocator, kvs: []const KV) []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    for (kvs) |kv| words.append(ar, std.fmt.allocPrint(ar, "{s}={s}", .{ kv.key, kv.value }) catch continue) catch {};
    return store_mod.joinCommand(ar, words.items);
}

fn startEdit(a: *App, i: usize) void {
    const s = &a.settings;
    s.mcp_edit = i;
    s.clearNote(a.gpa);
    if (i < a.store.data.mcp.len) {
        const m = a.store.data.mcp[i];
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        s.mcp_name.set(m.name);
        s.mcp_kind = kindIndex(m.kind);
        s.mcp_target.set(target(arena.allocator(), m));
        s.mcp_vars.set(joinVars(arena.allocator(), if (std.mem.eql(u8, m.kind, "stdio")) m.env else m.headers));
    } else {
        s.mcp_name.clear();
        s.mcp_kind = 0;
        s.mcp_target.clear();
        s.mcp_vars.clear();
    }
}

fn form(a: *App, c: *ui.Context, i: usize) void {
    const s = &a.settings;
    const adding = i >= a.store.data.mcp.len;
    const col = ui.div(c).column().wFull().gap(14).p(16);
    defer col.end();
    ui.text(c, if (adding) "New server" else "Edit server", .{ .size = 14, .weight = .medium });
    {
        const r = ui.div(c).row().wFull().gap(12);
        defer r.end();
        {
            const half = ui.div(c).column().grow();
            defer half.end();
            _ = rows.field(c, "Name", &s.mcp_name, "Optional: from the address when empty");
        }
        {
            const kind = ui.div(c).column().gap(6);
            defer kind.end();
            ui.text(c, "Kind", .{ .size = 12, .weight = .medium, .color = t.gray_900 });
            _ = ui.select(c, &s.mcp_kind, &kind_labels, &s.mcp_kind_box, .{ .width = .{ .px = 180 }, .size = 13 });
        }
    }
    const stdio = s.mcp_kind == 0;
    var submitted = rows.field(c, if (stdio) "Command" else "Address", &s.mcp_target, if (stdio) "npx -y @modelcontextprotocol/server-filesystem ." else "https://example.com/mcp").submitted;
    submitted = rows.field(c, if (stdio) "Environment" else "Headers", &s.mcp_vars, if (stdio) "API_KEY=… OTHER=…" else "Authorization=\"Bearer …\"").submitted or submitted;
    rows.footnote(c, "Variables and headers as NAME=value, separated by spaces; quote a value with spaces.");
    const r = ui.div(c).row().wFull().gap(8).itemsCenter();
    defer r.end();
    if (!adding and comp.textButton(c, "Remove")) return remove(a, i);
    ui.spacer(c);
    if (comp.outlineButton(c, "Cancel", null)) {
        s.mcp_edit = null;
        return;
    }
    if (comp.primaryButton(c, "Save", null) or submitted) save(a, i);
}

/// A name for a server from its address or command: "github" for
/// https://api.githubcopilot.com/mcp, "server-filesystem" for its package.
fn nameFor(text: []const u8) []const u8 {
    var s = text;
    if (std.mem.indexOf(u8, s, "://")) |i| {
        s = s[i + 3 ..];
        const end = std.mem.indexOfAny(u8, s, "/:?") orelse s.len;
        var host = s[0..end];
        if (std.mem.startsWith(u8, host, "www.") or std.mem.startsWith(u8, host, "api.") or std.mem.startsWith(u8, host, "mcp.")) host = host[4..];
        const dot = std.mem.indexOfScalar(u8, host, '.') orelse host.len;
        return host[0..dot];
    }
    // The first word after the runner and its flags: the package.
    var words = std.mem.tokenizeAny(u8, s, " \t");
    const runners = [_][]const u8{ "npx", "npx.cmd", "uvx", "node", "python", "python3", "bunx", "pnpm", "dlx", "deno", "run" };
    var last: []const u8 = "server";
    outer: while (words.next()) |w| {
        if (w.len == 0 or w[0] == '-') continue;
        for (runners) |r| if (std.mem.eql(u8, w, r)) continue :outer;
        last = w;
        break;
    }
    var end = last.len;
    while (end > 0 and (last[end - 1] == '/' or last[end - 1] == '\\')) end -= 1;
    last = last[0..end];
    if (std.mem.lastIndexOfAny(u8, last, "/\\")) |i| last = last[i + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, last, '@')) |i| if (i > 0) {
        last = last[0..i];
    };
    return if (last.len > 0) last else "server";
}

fn parseVars(a: *App, ar: std.mem.Allocator, line: []const u8) []const KV {
    var out: std.ArrayList(KV) = .empty;
    for (store_mod.splitCommand(ar, line)) |w| {
        const eq = std.mem.indexOfScalar(u8, w, '=') orelse continue;
        if (eq == 0) continue;
        out.append(a.store.a(), .{ .key = a.store.dupe(w[0..eq]), .value = a.store.dupe(w[eq + 1 ..]) }) catch {};
    }
    return out.items;
}

fn save(a: *App, i: usize) void {
    const s = &a.settings;
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = std.mem.trim(u8, s.mcp_target.text(), " \t");
    if (text.len == 0) return s.setNote(a.gpa, if (s.mcp_kind == 0) "Give the server the command that starts it." else "Give the server its address.", true);
    // An address pasted as a command is an HTTP server.
    var kind = s.mcp_kind;
    if (kind == 0 and (std.mem.startsWith(u8, text, "http://") or std.mem.startsWith(u8, text, "https://"))) kind = 1;
    const name_in = std.mem.trim(u8, s.mcp_name.text(), " \t");
    var m: Mcp = .{ .name = a.store.dupe(if (name_in.len > 0) name_in else nameFor(text)), .kind = kinds[kind] };
    const vars = parseVars(a, ar, s.mcp_vars.text());
    if (kind == 0) {
        const words = store_mod.splitCommand(ar, text);
        if (words.len == 0) return;
        m.command = a.store.dupe(words[0]);
        m.args = a.store.dupeList(words[1..]);
        m.env = vars;
    } else {
        m.url = a.store.dupe(text);
        m.headers = vars;
    }
    for (a.store.data.mcp, 0..) |x, j| if (j != i and std.mem.eql(u8, x.name, m.name))
        return s.setNote(a.gpa, "A server with that name is already here.", true);
    var list: std.ArrayList(Mcp) = .empty;
    list.appendSlice(a.store.a(), a.store.data.mcp) catch return;
    if (i < list.items.len) {
        m.off = list.items[i].off;
        list.items[i] = m;
    } else list.append(a.store.a(), m) catch return;
    a.store.data.mcp = list.items;
    a.store.save();
    s.mcp_edit = null;
    s.setNote(a.gpa, a.print("Saved {s}. New sessions get it.", .{m.name}), false);
}

fn remove(a: *App, i: usize) void {
    var list: std.ArrayList(Mcp) = .empty;
    for (a.store.data.mcp, 0..) |x, j| if (j != i) list.append(a.store.a(), x) catch return;
    a.store.data.mcp = list.items;
    a.store.save();
    a.settings.mcp_edit = null;
}

test "names a server from its address or command" {
    try std.testing.expectEqualStrings("githubcopilot", nameFor("https://api.githubcopilot.com/mcp/"));
    try std.testing.expectEqualStrings("server-filesystem", nameFor("npx -y @modelcontextprotocol/server-filesystem C:/"));
    try std.testing.expectEqualStrings("mcp-server", nameFor("uvx mcp-server@1.2"));
}
