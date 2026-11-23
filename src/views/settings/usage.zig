//! The Usage page: how full the open session's context is, and the lines
//! each session changed in its folder, as the app counted them. Agents
//! keep their own bills: fx's usage report has no ACP counterpart.
const std = @import("std");
const ui = @import("myzig").ui;
const App = @import("../../app/app.zig").App;
const t = @import("../../design/tokens.zig");
const comp = @import("../../design/components.zig");
const format = @import("../../app/format.zig");
const store_mod = @import("../../host/store.zig");
const rows = @import("rows.zig");

pub fn draw(a: *App, c: *ui.Context) void {
    rows.pageTitle(c, "Usage", "How much of its context the open session holds, and what sessions changed.");
    context(a, c);
    changes(a, c);
}

fn context(a: *App, c: *ui.Context) void {
    const g = ui.div(c).column().wFull().gap(10);
    defer g.end();
    rows.sectionTitle(c, "This session");
    const card = rows.card(c);
    defer card.end();
    const s = a.active orelse {
        rows.textRow(c, "No session is open", "Open one to see how full its context is");
        return;
    };
    {
        const col = ui.div(c).column().wFull().gap(12).px(16).py(14);
        defer col.end();
        const top = ui.div(c).row().wFull().gap(8).itemsCenter();
        {
            defer top.end();
            ui.text(c, "Context", .{ .size = 14 });
            ui.spacer(c);
            if (s.thread.usage) |u| {
                var b1: [32]u8 = undefined;
                var b2: [32]u8 = undefined;
                const pct: f64 = if (u[1] > 0) @as(f64, @floatFromInt(u[0])) * 100 / @as(f64, @floatFromInt(u[1])) else 0;
                ui.text(c, c.print("{s} of {s} tokens · {d:.0}%", .{ format.tokens(&b1, u[0]), format.tokens(&b2, u[1]), pct }), .{ .size = 13, .color = t.gray_900 });
            } else ui.text(c, "The agent has not said yet", .{ .size = 13, .color = t.gray_900 });
        }
        const frac: f64 = if (s.thread.usage) |u| (if (u[1] > 0) @as(f64, @floatFromInt(u[0])) / @as(f64, @floatFromInt(u[1])) else 0) else 0;
        ui.meter(c, frac, .{ .width = .fill, .warning = 0.7, .critical = 0.9 });
    }
    rows.sep(c, 16);
    {
        var tools: usize = 0;
        for (s.thread.turns.items) |turn| tools += turn.toolCount();
        const r = rows.row(c);
        defer r.end();
        rows.rowText(c, a.label(s), c.print("{s} · {d} turn{s} · {d} action{s}", .{
            a.agentName(s.agent),
            s.thread.turns.items.len,
            if (s.thread.turns.items.len == 1) "" else "s",
            tools,
            if (tools == 1) "" else "s",
        }));
        if (s.id) |id| if (a.store.session(id)) |rec| comp.stat(c, rec.added, rec.removed);
    }
}

fn changes(a: *App, c: *ui.Context) void {
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    var list: std.ArrayList(*const store_mod.Saved) = .empty;
    var added: usize = 0;
    var removed: usize = 0;
    for (a.store.data.sessions) |*rec| {
        if (rec.added + rec.removed == 0) continue;
        added += rec.added;
        removed += rec.removed;
        list.append(ar, rec) catch {};
    }
    std.mem.sort(*const store_mod.Saved, list.items, {}, struct {
        fn lt(_: void, x: *const store_mod.Saved, y: *const store_mod.Saved) bool {
            return x.added + x.removed > y.added + y.removed;
        }
    }.lt);
    const g = ui.div(c).column().wFull().gap(10);
    defer g.end();
    {
        const h = ui.div(c).row().wFull().px(2).gap(8).itemsCenter();
        defer h.end();
        ui.text(c, "Lines changed", .{ .size = 13, .weight = .medium });
        ui.spacer(c);
        comp.stat(c, added, removed);
    }
    {
        const card = rows.card(c);
        defer card.end();
        if (list.items.len == 0) rows.textRow(c, "Nothing yet", "Turns that edit files add their lines here");
        const now = a.now();
        for (list.items[0..@min(list.items.len, 20)], 0..) |rec, i| {
            c.keyed(i);
            if (i > 0) rows.sep(c, 16);
            const r = ui.div(c).row().wFull().gap(12).px(16).py(10).itemsCenter();
            defer r.end();
            {
                const col = ui.div(c).column().grow().gap(1);
                defer col.end();
                const name = if (rec.name.len > 0) rec.name else if (rec.title.len > 0) rec.title else "Untitled session";
                ui.text(c, name, .{ .size = 14 });
                var buf: [32]u8 = undefined;
                ui.text(c, c.print("{s} · {s} · {s}", .{ std.fs.path.basename(rec.cwd), a.agentName(rec.agent), format.ago(&buf, now, rec.updated) }), .{ .size = 12, .color = t.gray_700 });
            }
            comp.stat(c, rec.added, rec.removed);
        }
    }
    rows.footnote(c, "Counted from git after each turn: lines a turn added to or took from the files it edited.");
}
