//! Deleting a session for good: from the agent's own store, on disk, not
//! only from this app's list. Claude Code's files are removed here
//! (`claude_files.zig`: its transcript, the subagents' and tool results
//! beside it, its file history); another agent is asked (`session/delete`)
//! when it can be.
const std = @import("std");
const app_mod = @import("app.zig");
const agent = @import("agent.zig");
const rpc = @import("../acp/rpc.zig");
const claude_files = @import("../host/claude_files.zig");
const jobs = @import("../host/jobs.zig");

const App = app_mod.App;

/// Whether the agent `agent_id` is Claude Code, whose files this removes.
pub fn isClaude(a: *App, agent_id: []const u8) bool {
    const prof = a.store.agent(agent_id) orelse return false;
    return agent.runsClaudeCode(prof.command);
}

/// Whether deleting a session of `agent_id` removes its history on disk:
/// Claude Code's always; another's when it takes `session/delete`.
pub fn removesHistory(a: *App, agent_id: []const u8, can_delete: bool) bool {
    return isClaude(a, agent_id) or can_delete;
}

/// Removes Claude Code's files of session `id`, off the main thread; says
/// what it freed.
pub fn claudeFiles(a: *App, id: []const u8) void {
    if (!claude_files.isUuid(id)) return;
    const j = a.gpa.create(Job) catch return;
    j.* = .{ .a = a };
    @memcpy(j.id[0..id.len], id);
    jobs.spawn(Job, j, Job.work, Job.done);
}

const Job = struct {
    a: *App,
    id: [36]u8 = undefined,
    freed: u64 = 0,

    fn work(j: *Job) void {
        var arena: std.heap.ArenaAllocator = .init(j.a.gpa);
        defer arena.deinit();
        const base = claude_files.root(arena.allocator(), j.a.env) orelse return;
        j.freed = claude_files.remove(arena.allocator(), j.a.io, base, &j.id);
    }

    fn done(j: *Job) void {
        const a = j.a;
        defer a.gpa.destroy(j);
        var buf: [32]u8 = undefined;
        a.toast(if (j.freed > 0) a.print("Deleted · {s} freed", .{size(&buf, j.freed)}) else "Deleted");
    }
};

/// Asks the agent on `conn` to delete session `id`, then stops `conn`:
/// the session's own connection, which nothing else uses any more.
pub fn askThenStop(a: *App, conn: *rpc.Conn, id: []const u8) void {
    const op = a.gpa.create(Op) catch return conn.stop();
    op.* = .{ .a = a };
    conn.request("session/delete", .{ .sessionId = id }, .{ .ctx = op, .func = asked });
}

const Op = struct { a: *App };

fn asked(ctx: ?*anyopaque, conn: *rpc.Conn, reply: rpc.Reply) void {
    const op: *Op = @ptrCast(@alignCast(ctx.?));
    const a = op.a;
    a.gpa.destroy(op);
    switch (reply) {
        .gone => return,
        .err => |e| a.failToast(a.print("Its agent kept it: {s}", .{e})),
        .ok => a.toast("Deleted"),
    }
    conn.stop();
}

/// "12.3 MB", "640 KB".
pub fn size(buf: []u8, bytes: u64) []const u8 {
    const b: f64 = @floatFromInt(bytes);
    if (bytes >= 1 << 30) return std.fmt.bufPrint(buf, "{d:.1} GB", .{b / (1 << 30)}) catch "";
    if (bytes >= 1 << 20) return std.fmt.bufPrint(buf, "{d:.1} MB", .{b / (1 << 20)}) catch "";
    if (bytes >= 1 << 10) return std.fmt.bufPrint(buf, "{d} KB", .{bytes >> 10}) catch "";
    return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "";
}

test "sizes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12.5 MB", size(&buf, 12 * (1 << 20) + (1 << 19)));
    try std.testing.expectEqualStrings("640 KB", size(&buf, 640 * 1024));
}
