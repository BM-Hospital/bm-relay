//! The About page: the app's name and version, the agent of the session
//! open now, where the app keeps its state, and where it comes from.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const App = @import("../../app/app.zig").App;
const t = @import("../../design/tokens.zig");
const comp = @import("../../design/components.zig");
const agent = @import("../../app/agent.zig");
const rows = @import("rows.zig");

pub fn draw(a: *App, c: *ui.Context) void {
    {
        const head = ui.div(c).row().wFull().gap(16).itemsCenter();
        defer head.end();
        @import("../../design/components.zig").logo(c, 56);
        const col = ui.div(c).column().gap(2);
        defer col.end();
        ui.text(c, "BM Relay", .{ .size = 22, .weight = .medium });
        ui.text(c, c.print("Version {s} · a desktop app for coding agents that speak ACP", .{agent.version}), .{ .size = 14, .color = t.gray_900 });
    }
    session(a, c);
    files(a, c);
    links(c);
}

fn session(a: *App, c: *ui.Context) void {
    const g = ui.div(c).column().wFull().gap(10);
    defer g.end();
    rows.sectionTitle(c, "The agent open now");
    const card = rows.card(c);
    defer card.end();
    const s = a.active orelse {
        rows.textRow(c, "No session is open", "Open one to see which agent runs it");
        return;
    };
    {
        const r = rows.row(c);
        defer r.end();
        const name = if (s.caps.name.len > 0) s.caps.name else a.agentName(s.agent);
        const ver = if (s.caps.version.len > 0) c.print("Version {s}", .{s.caps.version}) else if (s.conn == null) "Not running" else "It did not say its version";
        rows.rowText(c, name, ver);
        comp.pill(c, if (s.conn != null) "Running" else "Stopped", if (s.conn != null) t.green_900 else t.gray_700);
    }
    rows.sep(c, 16);
    {
        var buf: [80]u8 = undefined;
        var fbs: std.Io.Writer = .fixed(&buf);
        const caps = s.caps;
        var first = true;
        inline for (.{ .{ caps.load, "reopens sessions" }, .{ caps.images, "takes images" }, .{ caps.mcp_http, "MCP over HTTP" }, .{ caps.mcp_sse, "MCP over SSE" } }) |x| if (x[0]) {
            fbs.print("{s}{s}", .{ if (first) "" else ", ", x[1] }) catch {};
            first = false;
        };
        rows.textRow(c, "What it can do", if (first) "Nothing beyond prompts" else c.print("{s}", .{fbs.buffered()}));
    }
    if (s.caps.auth.len > 0) {
        rows.sep(c, 16);
        var buf: [160]u8 = undefined;
        var fbs: std.Io.Writer = .fixed(&buf);
        for (s.caps.auth, 0..) |m, i| fbs.print("{s}{s}", .{ if (i == 0) "" else ", ", if (m[1].len > 0) m[1] else m[0] }) catch {};
        rows.textRow(c, "Ways to sign in", c.print("{s} · sign in with the agent's own command line", .{fbs.buffered()}));
    }
}

fn files(a: *App, c: *ui.Context) void {
    const path = a.store.path orelse return;
    const g = ui.div(c).column().wFull().gap(10);
    defer g.end();
    rows.sectionTitle(c, "On this computer");
    const card = rows.card(c);
    defer card.end();
    const r = rows.row(c);
    defer r.end();
    {
        const col = ui.div(c).column().grow().gap(1);
        defer col.end();
        ui.text(c, "State", .{ .size = 14 });
        ui.text(c, path, .{ .size = 12, .mono = true, .color = t.gray_900, .wrap = true });
    }
    if (comp.textButton(c, "Reveal")) myzig.shell.showInFolder(path);
}

fn links(c: *ui.Context) void {
    const g = ui.div(c).column().wFull().gap(10);
    defer g.end();
    rows.sectionTitle(c, "Made with");
    const card = rows.card(c);
    defer card.end();
    const items = [_][3][]const u8{
        .{ "fx-ui", "The app this one is ported from", "https://github.com/zaidmukaddam/fx-ui" },
        .{ "myzig", "Native UI in Zig, drawn on the GPU", "https://github.com/hunghg255/myzig" },
        .{ "Agent Client Protocol", "How the app talks to agents", "https://agentclientprotocol.com" },
    };
    for (items, 0..) |it, i| {
        c.keyed(i);
        if (i > 0) rows.sep(c, 16);
        const r = rows.row(c);
        defer r.end();
        rows.rowText(c, it[0], it[1]);
        if (comp.textButton(c, "Open")) _ = myzig.shell.openUrl(it[2]);
    }
}
