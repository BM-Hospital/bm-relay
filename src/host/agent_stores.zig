//! Where Codex and OpenCode keep their sessions on this computer, and how
//! much of it there is. They delete sessions themselves (`session/delete`);
//! this only weighs their stores, before and after.
const std = @import("std");
const Io = std.Io;
const claude_files = @import("claude_files.zig");

pub const Kind = enum { codex, opencode };

/// A store: its folder, and what its sessions take there. The rest of it
/// (Codex keeps gigabytes of packages) is not weighed: it would take long.
pub const Weight = struct { root: []const u8 = "", sessions: u64 = 0 };

/// The store's folder: `CODEX_HOME` or `.codex` in the home folder; OpenCode's
/// data folder (`XDG_DATA_HOME`, else `.local/share`) `/opencode`.
pub fn root(a: std.mem.Allocator, env: *const std.process.Environ.Map, kind: Kind) ?[]const u8 {
    const home = env.get("USERPROFILE") orelse env.get("HOME");
    return switch (kind) {
        .codex => if (env.get("CODEX_HOME")) |d| a.dupe(u8, d) catch null else std.fs.path.join(a, &.{ home orelse return null, ".codex" }) catch null,
        .opencode => if (env.get("XDG_DATA_HOME")) |d| std.fs.path.join(a, &.{ d, "opencode" }) catch null else std.fs.path.join(a, &.{ home orelse return null, ".local", "share", "opencode" }) catch null,
    };
}

/// The names in a store that are its sessions: their transcripts, their
/// databases (and journals), their snapshots.
fn isSessions(kind: Kind, name: []const u8) bool {
    const prefixes: []const []const u8 = switch (kind) {
        .codex => &.{ "sessions", "archived_sessions", "thread_history_", "state_", "session_index" },
        .opencode => &.{ "opencode.db", "storage", "snapshot", "tool-output" },
    };
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

/// Weighs the store at `base`.
pub fn weigh(a: std.mem.Allocator, io: Io, base: []const u8, kind: Kind) Weight {
    var w: Weight = .{ .root = base };
    var dir = Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch return w;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (!isSessions(kind, e.name)) continue;
        const p = std.fs.path.join(a, &.{ base, e.name }) catch continue;
        w.sessions += claude_files.sizeOf(a, io, p);
    }
    return w;
}

test "a store weighed: its sessions, of all it holds" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "sessions/2026/11");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/2026/11/r.jsonl", .data = "1234" });
    try tmp.dir.writeFile(io, .{ .sub_path = "thread_history_1.sqlite", .data = "123456" });
    try tmp.dir.writeFile(io, .{ .sub_path = "auth.json", .data = "12" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const w = weigh(a, io, base, .codex);
    try std.testing.expectEqual(@as(u64, 10), w.sessions);
}
