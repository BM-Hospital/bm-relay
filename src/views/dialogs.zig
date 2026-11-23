//! The dialogs: removing a session, renaming it, discarding a file's
//! changes, switching to full access, removing a folder. Whatever sets
//! `a.dialog` opens one (`ask` also shows it); the dialog clears it as it
//! closes. Return confirms, Escape or a press outside cancels.
const std = @import("std");
const ui = @import("myzig").ui;
const app_mod = @import("../app/app.zig");
const state = @import("../app/state.zig");
const sessions = @import("../app/sessions.zig");
const agent = @import("../app/agent.zig");
const git = @import("../host/git.zig");
const t = @import("../design/tokens.zig");
const k = @import("../design/components.zig");
const changes = @import("changes.zig");
const changes_view = @import("changes_view.zig");

const App = app_mod.App;
const Session = state.Session;

/// Opens a dialog.
pub fn ask(a: *App, d: state.Dialog) void {
    a.dialog = d;
    a.dialog_state.show();
    a.redraw();
}

/// Opens the rename dialog on a session, its name in the field.
pub fn startRename(a: *App, s: *Session) void {
    a.rename.set(a.label(s));
    a.page = .session;
    ask(a, .{ .rename = s });
}

pub fn draw(a: *App, c: *ui.Context) void {
    const which = a.dialog orelse {
        if (a.dialog_state.open) a.dialog_state.close();
        return;
    };
    // Set without `ask`: show it now.
    if (!a.dialog_state.open) a.dialog_state.show();
    const d = ui.dialog(c, &a.dialog_state, .{ .width = .{ .px = 400 }, .padding = .all(0), .gap = 0 }) orelse {
        a.dialog = null;
        return;
    };
    const panel = d.panelStyle();
    // A step above the window in the dark, as raised things are; white in the light.
    panel.background = if (t.is_dark) t.gray_100 else t.background_100;
    panel.border = t.alpha_400;
    panel.radius = 12;
    panel.clip = true;
    panel.shadow = t.shadow_modal;
    const opened = a.dialog_state.justOpened(c);
    var confirm = false;
    var cancel = false;
    switch (which) {
        .remove => |s| {
            const head = body(c);
            defer head.end();
            title(c, "Archive this session?");
            note(c, c.print("“{s}” moves to Archived on the home screen. The files it changed are not touched.", .{a.label(s)}));
        },
        .rename => |s| {
            if (opened and a.rename.text().len == 0) a.rename.set(a.label(s));
            const head = body(c).gap(14);
            defer head.end();
            title(c, "Rename session");
            {
                const field = ui.div(c).row().wFull().h(38).px(12).itemsCenter().rounded(10).bg(t.background_200).border(t.accent);
                defer field.end();
                c.next_key = "rename-field";
                const id = c.peekId(null);
                if (opened) c.focus = id;
                if (ui.textField(c, &a.rename, .{ .width = .fill, .bare = true }).submitted) confirm = true;
            }
            ui.text(c, "Only this app shows the new name. The agent keeps its own.", .{ .size = 12, .color = t.gray_700, .wrap = true });
        },
        .discard => |ch| {
            const head = body(c);
            defer head.end();
            const name = if (std.mem.lastIndexOfScalar(u8, ch.path, '/')) |i| ch.path[i + 1 ..] else ch.path;
            title(c, c.print("Discard changes to {s}?", .{name}));
            note(c, if (ch.code == '?') "The new file is deleted. This can't be undone." else "The file goes back to its last commit. This can't be undone.");
            const file = ui.div(c).row().wFull().h(36).px(12).gap(10).itemsCenter().rounded(8).bg(t.background_200).border(t.alpha_200);
            defer file.end();
            changes_view.statusDot(c, ch.code);
            {
                const p = ui.div(c).row().wFull().clip();
                defer p.end();
                ui.text(c, ch.path, .{ .size = 12, .mono = true });
            }
            k.stat(c, ch.added, ch.removed);
        },
        .full_access => {
            const head = body(c);
            defer head.end();
            title(c, "Switch to Full access?");
            note(c, "The agent runs every edit and command in this session without asking. You can switch back at any time.");
        },
        .remove_folder => |i| {
            const head = body(c);
            defer head.end();
            const name = if (i < a.workspaces.items.len) a.workspaces.items[i].name else "this folder";
            title(c, c.print("Remove {s}?", .{name}));
            note(c, "The folder leaves the sidebar and its sessions stop. Nothing on disk is touched; open the folder again to see them.");
        },
        .delete => |s| {
            const head = body(c);
            defer head.end();
            title(c, "Delete this session for good?");
            note(c, deleteNote(a, c, a.label(s), s.agent, s.caps.delete));
        },
        .purge_storage => {
            const head = body(c);
            defer head.end();
            const st = &a.storage;
            var buf: [32]u8 = undefined;
            const where = if (st.plan_project) |i| (if (st.scan) |sc| (if (i < sc.projects.len) sc.projects[i].cwd else "this project") else "this project") else "every project";
            const those = if (st.plan_days == 0) "All the sessions" else c.print("The sessions older than {d} days", .{st.plan_days});
            title(c, c.print("Delete {d} session{s}?", .{ st.plan_count, if (st.plan_count == 1) "" else "s" }));
            const freed = if (st.sized()) c.print(", {s} freed", .{@import("../app/purge.zig").size(&buf, st.plan_bytes)}) else c.print(" ({s} deletes them itself)", .{st.kind.title()});
            note(c, c.print("{s} of {s} are deleted from {s}'s history on disk{s}. Its CLI won't list them again. Sessions open in the app are kept; the files they changed are not touched.", .{ those, where, st.kind.title(), freed }));
        },
        .delete_history => {
            const head = body(c);
            defer head.end();
            title(c, "Delete this session for good?");
            note(c, c.print("“{s}” is deleted from {s}'s own history too: its CLI won't list it again. The files it changed are not touched.", .{ @import("../app/history.zig").doomedTitle(a), a.agentName(a.history.agent) }));
        },
        .delete_saved => |id| {
            const head = body(c);
            defer head.end();
            const rec = a.store.session(id);
            const name = if (rec) |r| (if (r.name.len > 0) r.name else if (r.title.len > 0) r.title else "Untitled session") else "this session";
            title(c, "Delete this session for good?");
            note(c, deleteNote(a, c, name, if (rec) |r| r.agent else "", false));
        },
    }
    // Return confirms everything but the rename field, which has its own.
    if (which != .rename and ui.overlays.takeKey(c, .enter)) confirm = true;
    {
        ui.div(c).wFull().h(1).bg(t.alpha_200).end();
        const foot = ui.div(c).row().wFull().h(64).px(24).itemsCenter().justifyBetween();
        defer foot.end();
        if (k.outlineButton(c, "Cancel", null)) cancel = true;
        const ok = switch (which) {
            .remove => k.dangerButton(c, "Archive"),
            .rename => k.primaryButton(c, "Rename", "⏎"),
            .discard => k.dangerButton(c, "Discard"),
            .full_access => k.primaryButton(c, "Switch", "⏎"),
            .remove_folder => k.dangerButton(c, "Remove folder"),
            .delete, .delete_saved, .delete_history, .purge_storage => k.dangerButton(c, "Delete"),
        };
        if (ok) confirm = true;
    }
    d.end();
    if (confirm) return run(a, which);
    if (cancel) a.dialog_state.close();
    if (!a.dialog_state.open) a.dialog = null;
}

fn run(a: *App, which: state.Dialog) void {
    a.dialog = null;
    a.dialog_state.close();
    switch (which) {
        .remove => |s| if (a.workspaceOf(s) != null) sessions.removeSession(a, s),
        .rename => |s| if (a.workspaceOf(s) != null) sessions.renameSession(a, s, a.rename.text()),
        .discard => |ch| changes.discard(a, ch),
        .full_access => |value| if (a.active) |s| agent.setOption(a, s, "mode", value),
        .remove_folder => |i| sessions.removeFolder(a, i),
        .delete => |s| if (a.workspaceOf(s) != null) sessions.deleteSession(a, s),
        .delete_saved => |id| sessions.purgeArchived(a, id),
        .delete_history => @import("../app/history.zig").deleteDoomed(a),
        .purge_storage => @import("../app/storage.zig").run(a),
    }
    a.redraw();
}

/// What deleting `name` does: its history on disk goes too when its agent
/// is Claude Code (its files) or deletes sessions itself.
fn deleteNote(a: *App, c: *ui.Context, name: []const u8, agent_id: []const u8, can_delete: bool) []const u8 {
    if (@import("../app/purge.zig").removesHistory(a, agent_id, can_delete))
        return c.print("“{s}” is deleted from this app and from {s}'s own history on disk: its CLI won't list it again, and the space it took is freed. The files it changed are not touched.", .{ name, a.agentName(agent_id) });
    return c.print("“{s}” leaves this app for good. The files it changed are not touched; {s} may keep its own copy (delete it from Home's History to ask it to).", .{ name, a.agentName(agent_id) });
}

fn body(c: *ui.Context) ui.Div {
    return ui.div(c).column().wFull().p(24).gap(8);
}

fn title(c: *ui.Context, s: []const u8) void {
    ui.text(c, s, .{ .size = 20, .weight = .semibold, .wrap = true });
}

fn note(c: *ui.Context, s: []const u8) void {
    ui.text(c, s, .{ .size = 14, .color = t.gray_900, .wrap = true, .leading = 1.2 });
}

test {
    _ = git;
}
