//! The Behaviour page: instructions added to every new session, whether
//! the app notifies, and what the session open now may do without asking.
const std = @import("std");
const ui = @import("myzig").ui;
const App = @import("../../app/app.zig").App;
const t = @import("../../design/tokens.zig");
const comp = @import("../../design/components.zig");
const rows = @import("rows.zig");
const settings = @import("settings.zig");

pub fn draw(a: *App, c: *ui.Context) void {
    rows.pageTitle(c, "Behaviour", "How new sessions start, and what they may do without asking.");
    general(a, c);
    instructions(a, c);
    allowed(a, c);
}

fn general(a: *App, c: *ui.Context) void {
    const g = ui.div(c).column().wFull().gap(10);
    defer g.end();
    rows.sectionTitle(c, "New sessions");
    const card = rows.card(c);
    defer card.end();
    {
        const r = rows.row(c);
        defer r.end();
        rows.rowText(c, "Notify me", "When a turn needs you or finishes while the window is in the background");
        if (comp.switchOn(c, !a.store.data.mute)) {
            a.store.data.mute = !a.store.data.mute;
            a.store.save();
        }
    }
    rows.sep(c, 16);
    {
        const r = rows.row(c);
        defer r.end();
        rows.rowText(c, "Agent, model, mode and thinking", "Each agent's own, for new sessions");
        if (comp.outlineButton(c, "Models…", null)) settings.openAt(a, .models);
    }
}

fn instructions(a: *App, c: *ui.Context) void {
    const s = &a.settings;
    if (s.instructions == null) s.instructions = ui.TextArea.init(a.gpa, a.store.data.instructions);
    const g = ui.div(c).column().wFull().gap(10);
    defer g.end();
    rows.sectionTitle(c, "Instructions");
    {
        const box = ui.div(c).column().wFull().rounded(12).bg(t.gray_100).border(t.alpha_300).px(6).py(4);
        defer box.end();
        const r = ui.textArea(c, &s.instructions.?, .{
            .placeholder = "For example: reply briefly, and run the tests before you finish",
            .lines = .{ 3, 10 },
            .bare = true,
            .size = 13,
        });
        if (r.changed) {
            const text = s.instructions.?.text(a.gpa);
            defer a.gpa.free(text);
            a.store.data.instructions = a.store.dupe(std.mem.trim(u8, text, " \r\n\t"));
            a.store.save();
        }
    }
    rows.footnote(c, "Added to every new session, after the agent's own instructions. fx takes them as its system prompt; Claude Code appends them to its own.");
}

fn allowed(a: *App, c: *ui.Context) void {
    const g = ui.div(c).column().wFull().gap(10);
    defer g.end();
    rows.sectionTitle(c, "Always allowed in this session");
    const card = rows.card(c);
    {
        defer card.end();
        const grants = if (a.active) |s| s.grants.items else &[_][]u8{};
        if (grants.len == 0) {
            rows.textRow(c, "Nothing is always allowed yet", "Choose Always allow on an approval to add a rule here");
        }
        for (grants, 0..) |rule, i| {
            c.keyed(i);
            if (i > 0) rows.sep(c, 52);
            const r = ui.div(c).row().wFull().h(48).px(16).gap(12).itemsCenter();
            defer r.end();
            {
                const tile = ui.div(c).w(24).h(24).center().rounded(6).bg(t.gray_200);
                defer tile.end();
                ui.text(c, "$", .{ .size = 12, .mono = true, .color = t.gray_900 });
            }
            ui.text(c, rule, .{ .size = 13, .mono = true });
        }
    }
    rows.footnote(c, "Added when you choose Always allow on an approval. The agent keeps them for the session; the composer's permission menu can forget them.");
}
