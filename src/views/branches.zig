//! The folder's branch, and switching it: a button with the branch's name
//! (cut in its middle when long) whose menu lists the local branches, the
//! one last committed to first. A switch is git's (`git switch`), off the
//! main thread; what git refuses, its words say why.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const app_mod = @import("../app/app.zig");
const state = @import("../app/state.zig");
const sessions = @import("../app/sessions.zig");
const format = @import("../app/format.zig");
const git = @import("../host/git.zig");
const jobs = @import("../host/jobs.zig");
const t = @import("../design/tokens.zig");
const comp = @import("../design/components.zig");

const App = app_mod.App;
const Workspace = state.Workspace;

/// Where a button is: its own menu, and how much of a name it shows.
pub const Place = struct { menu: *ui.Menu, chars: usize, height: f32 };

/// The branch button of `w`, and its menu while open.
pub fn button(a: *App, c: *ui.Context, w: *Workspace, place: Place) void {
    const name = w.branch orelse return;
    const b = ui.div(c).row().h(place.height).px(10).gap(6).itemsCenter().rounded(6).clip().control();
    if (place.menu.isOpen()) _ = b.bg(t.alpha_200) else _ = b.hover(t.alpha_200);
    comp.icon(c, "branch", .{ .size = 14, .color = t.purple_900 });
    var buf: [256]u8 = undefined;
    const shown = format.middle(&buf, name, place.chars);
    ui.text(c, shown, .{ .size = 12, .mono = true, .color = t.gray_900 });
    comp.icon(c, "chevron-down", .{ .size = 12, .color = t.gray_700 });
    b.end();
    const it = b.interaction();
    if (it.hovered) c.cursor = .hand;
    if (!place.menu.isOpen()) ui.tooltip(c, it, if (shown.len != name.len) c.print("{s} · Switch branch", .{name}) else "Switch branch");
    const m = ui.buttonMenu(c, place.menu, it) orelse return forget(a);
    defer m.end();
    if (a.branch_list == null) a.branch_list = git.branches(a.gpa, a.io, w.path);
    const busy = running(w);
    if (busy) _ = m.item("A turn is running in this folder", .{ .disabled = true, .icon = "alert" });
    const list = a.branch_list.?;
    const shown_max = @min(list.len, 30);
    for (list[0..shown_max]) |br| {
        const here = std.mem.eql(u8, br, name);
        var lbuf: [256]u8 = undefined;
        const label = c.print("{s}", .{format.middle(&lbuf, br, 44)});
        if (m.item(label, .{ .checked = here, .disabled = busy })) if (!here) switchTo(a, w, br);
    }
    if (list.len > shown_max) _ = m.item(c.print("{d} more: switch with git", .{list.len - shown_max}), .{ .disabled = true });
    m.separator();
    if (m.item("Copy branch name", .{ .icon = "copy" })) {
        myzig.clipboard.writeText(name);
        a.toast("Copied the branch name");
    }
}

/// The list is read again each time a menu opens: branches come and go.
fn forget(a: *App) void {
    if (a.menus.branch.isOpen() or a.menus.branch_composer.isOpen()) return;
    if (a.branch_list) |l| git.freeList(a.gpa, l);
    a.branch_list = null;
}

fn running(w: *const Workspace) bool {
    for (w.sessions.items) |s| if (s.thread.running()) return true;
    return false;
}

const Job = struct {
    a: *App,
    path: []u8,
    name: []u8,
    out: git.Out = .{ .err = "" },

    fn work(j: *Job) void {
        j.out = git.switchTo(j.a.gpa, j.a.io, j.path, j.name);
    }

    fn done(j: *Job) void {
        const a = j.a;
        defer {
            switch (j.out) {
                .ok => |s| a.gpa.free(s),
                .err => |e| if (e.len > 0) a.gpa.free(e),
            }
            a.gpa.free(j.path);
            a.gpa.free(j.name);
            a.gpa.destroy(j);
        }
        switch (j.out) {
            .ok => a.toast(a.print("On {s}", .{j.name})),
            .err => |e| a.failToast(firstLines(a, e)),
        }
        for (a.workspaces.items) |w| if (std.mem.eql(u8, w.path, j.path)) sessions.refreshFolder(a, w);
        if (a.changes != null) @import("changes.zig").refresh(a);
        a.redraw();
    }
};

/// The first lines of what git said: why it would not switch.
fn firstLines(a: *App, text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    const t0 = if (std.mem.startsWith(u8, trimmed, "error: ")) trimmed["error: ".len..] else trimmed;
    var end: usize = t0.len;
    var n: usize = 0;
    for (t0, 0..) |ch, i| if (ch == '\n') {
        n += 1;
        if (n == 3) {
            end = i;
            break;
        }
    };
    return a.print("{s}", .{t0[0..@min(end, 300)]});
}

pub fn switchTo(a: *App, w: *Workspace, name: []const u8) void {
    if (running(w)) return a.failToast("A turn is running in this folder: switch when it ends.");
    const j = a.gpa.create(Job) catch return;
    j.* = .{
        .a = a,
        .path = a.gpa.dupe(u8, w.path) catch return a.gpa.destroy(j),
        .name = a.gpa.dupe(u8, name) catch {
            a.gpa.free(j.path);
            return a.gpa.destroy(j);
        },
    };
    jobs.spawn(Job, j, Job.work, Job.done);
}

test {
    std.testing.refAllDecls(@This());
}
