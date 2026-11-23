//! What Claude Code keeps of a session on disk, removed: its transcript in
//! every project folder (`projects/<dir>/<id>.jsonl`), the folder beside it
//! (`<id>/`: subagents' transcripts, tool results), and the folders named
//! for it (`file-history/<id>/`, `session-env/<id>/`). Under
//! `CLAUDE_CONFIG_DIR`, or `.claude` in the home folder. Only names made of
//! the session's id, a UUID, are touched.
const std = @import("std");
const Io = std.Io;

/// Whether `id` is a UUID ("0256f813-7f6b-4e65-8c37-86b450c865ae"): the
/// only names this deletes are made of one.
pub fn isUuid(id: []const u8) bool {
    if (id.len != 36) return false;
    for (id, 0..) |ch, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (dash) {
            if (ch != '-') return false;
        } else if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

/// Claude Code's folder.
pub fn root(a: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]const u8 {
    if (env.get("CLAUDE_CONFIG_DIR")) |d| return a.dupe(u8, d) catch null;
    const home = env.get("USERPROFILE") orelse env.get("HOME") orelse return null;
    return std.fs.path.join(a, &.{ home, ".claude" }) catch null;
}

/// Removes what Claude Code keeps of session `id`; the bytes it took.
pub fn remove(a: std.mem.Allocator, io: Io, base: []const u8, id: []const u8) u64 {
    if (!isUuid(id)) return 0;
    var freed: u64 = 0;
    const cwd = Io.Dir.cwd();
    const projects = std.fs.path.join(a, &.{ base, "projects" }) catch return 0;
    if (cwd.openDir(io, projects, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind != .directory) continue;
            const name = std.fmt.allocPrint(a, "{s}.jsonl", .{id}) catch continue;
            const transcript = std.fs.path.join(a, &.{ projects, e.name, name }) catch continue;
            freed += sizeOf(a, io, transcript);
            cwd.deleteFile(io, transcript) catch {};
            const beside = std.fs.path.join(a, &.{ projects, e.name, id }) catch continue;
            freed += sizeOf(a, io, beside);
            cwd.deleteTree(io, beside) catch {};
        }
    } else |_| {}
    for ([_][]const u8{ "file-history", "session-env" }) |sub| {
        const p = std.fs.path.join(a, &.{ base, sub, id }) catch continue;
        freed += sizeOf(a, io, p);
        cwd.deleteTree(io, p) catch {};
    }
    return freed;
}

/// The bytes a file, or a folder and all in it, takes; 0 when it is not there.
pub fn sizeOf(a: std.mem.Allocator, io: Io, path: []const u8) u64 {
    const cwd = Io.Dir.cwd();
    if (cwd.statFile(io, path, .{})) |st| {
        if (st.kind != .directory) return st.size;
    } else |_| return 0;
    var dir = cwd.openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var total: u64 = 0;
    var w = dir.walk(a) catch return 0;
    defer w.deinit();
    while (w.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        const st = e.dir.statFile(io, e.basename, .{}) catch continue;
        total += st.size;
    }
    return total;
}

test "only a UUID is a name to delete" {
    try std.testing.expect(isUuid("0256f813-7f6b-4e65-8c37-86b450c865ae"));
    try std.testing.expect(!isUuid("../../etc"));
    try std.testing.expect(!isUuid("ses_0256f8137f6b4e658c3786b450c865ae"));
    try std.testing.expect(!isUuid("0256f813-7f6b-4e65-8c37-86b450c865a/"));
}

test "a session's files go, others stay" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = "0256f813-7f6b-4e65-8c37-86b450c865ae";
    const other = "11111111-2222-3333-4444-555555555555";
    try tmp.dir.createDirPath(io, "projects/D--work/" ++ id ++ "/subagents");
    try tmp.dir.writeFile(io, .{ .sub_path = "projects/D--work/" ++ id ++ ".jsonl", .data = "0123456789" });
    try tmp.dir.writeFile(io, .{ .sub_path = "projects/D--work/" ++ id ++ "/subagents/a.jsonl", .data = "abc" });
    try tmp.dir.writeFile(io, .{ .sub_path = "projects/D--work/" ++ other ++ ".jsonl", .data = "keep" });
    try tmp.dir.createDirPath(io, "file-history/" ++ id);
    try tmp.dir.writeFile(io, .{ .sub_path = "file-history/" ++ id ++ "/v1", .data = "12345" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    try std.testing.expectEqual(@as(u64, 18), remove(a, io, base, id));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "projects/D--work/" ++ id ++ ".jsonl", .{}));
    _ = try tmp.dir.statFile(io, "projects/D--work/" ++ other ++ ".jsonl", .{});
    try std.testing.expectEqual(@as(u64, 0), remove(a, io, base, "not-a-uuid"));
}

/// A session in the store: its id, the bytes it takes (its transcript and
/// what is kept for it), and when it was last written (ms).
pub const StoredSession = struct { id: []const u8, bytes: u64, modified: i64 };

/// A project folder of the store (a folder sessions ran in).
pub const Project = struct {
    /// Its name under `projects` ("D--BM-his-web").
    dir: []const u8,
    /// The folder its sessions ran in, as a transcript says; else `dir`.
    cwd: []const u8,
    sessions: []StoredSession,
    bytes: u64,
};

pub const Scan = struct {
    projects: []Project = &.{},
    /// All of the store, sessions and the rest (plugins, caches…).
    total: u64 = 0,
    /// The sessions', of every project.
    sessions_bytes: u64 = 0,
};

/// What the store at `base` holds, biggest project first, each project's
/// sessions oldest first. In `a`'s memory.
pub fn scan(a: std.mem.Allocator, io: Io, base: []const u8) Scan {
    var out: Scan = .{ .total = sizeOf(a, io, base) };
    const cwd = Io.Dir.cwd();
    const projects = std.fs.path.join(a, &.{ base, "projects" }) catch return out;
    var dir = cwd.openDir(io, projects, .{ .iterate = true }) catch return out;
    defer dir.close(io);
    var list: std.ArrayList(Project) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        const pdir = std.fs.path.join(a, &.{ projects, e.name }) catch continue;
        var p: Project = .{ .dir = a.dupe(u8, e.name) catch continue, .cwd = "", .sessions = &.{}, .bytes = 0 };
        var found: std.ArrayList(StoredSession) = .empty;
        var sub = cwd.openDir(io, pdir, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var sit = sub.iterate();
        while (sit.next(io) catch null) |f| {
            if (f.kind != .file or !std.mem.endsWith(u8, f.name, ".jsonl")) continue;
            const id = f.name[0 .. f.name.len - ".jsonl".len];
            if (!isUuid(id)) continue;
            const file = std.fs.path.join(a, &.{ pdir, f.name }) catch continue;
            const st = cwd.statFile(io, file, .{}) catch continue;
            if (p.cwd.len == 0) p.cwd = cwdOf(a, io, file) orelse "";
            var bytes: u64 = st.size;
            bytes += sizeOf(a, io, std.fs.path.join(a, &.{ pdir, id }) catch "");
            for ([_][]const u8{ "file-history", "session-env" }) |kept| bytes += sizeOf(a, io, std.fs.path.join(a, &.{ base, kept, id }) catch "");
            found.append(a, .{
                .id = a.dupe(u8, id) catch continue,
                .bytes = bytes,
                .modified = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_ms)),
            }) catch {};
            p.bytes += bytes;
        }
        if (found.items.len == 0) continue;
        std.mem.sort(StoredSession, found.items, {}, struct {
            fn lt(_: void, x: StoredSession, y: StoredSession) bool {
                return x.modified < y.modified;
            }
        }.lt);
        p.sessions = found.items;
        if (p.cwd.len == 0) p.cwd = p.dir;
        out.sessions_bytes += p.bytes;
        list.append(a, p) catch {};
    }
    std.mem.sort(Project, list.items, {}, struct {
        fn lt(_: void, x: Project, y: Project) bool {
            return x.bytes > y.bytes;
        }
    }.lt);
    out.projects = list.items;
    return out;
}

/// The folder a transcript's session ran in: its first `"cwd"`, near its start.
fn cwdOf(a: std.mem.Allocator, io: Io, path: []const u8) ?[]const u8 {
    var f = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var buf: [32 * 1024]u8 = undefined;
    const n = f.readStreaming(io, &.{&buf}) catch return null;
    const head = buf[0..n];
    const key = "\"cwd\"";
    const at = std.mem.indexOf(u8, head, key) orelse return null;
    // `"cwd":"…"`, spaces allowed around the colon.
    var i = at + key.len;
    while (i < head.len and (head[i] == ' ' or head[i] == ':')) i += 1;
    if (i >= head.len or head[i] != '"') return null;
    i += 1;
    var out: std.ArrayList(u8) = .empty;
    while (i < head.len and head[i] != '"') : (i += 1) {
        if (head[i] == '\\' and i + 1 < head.len) i += 1;
        out.append(a, head[i]) catch return null;
    }
    return if (out.items.len > 0) out.items else null;
}

test "the store scanned: projects, their sessions and folders" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = "0256f813-7f6b-4e65-8c37-86b450c865ae";
    try tmp.dir.createDirPath(io, "projects/D--BM-web/" ++ id);
    try tmp.dir.writeFile(io, .{ .sub_path = "projects/D--BM-web/" ++ id ++ ".jsonl", .data = "{\"type\":\"user\",\"cwd\":\"D:\\\\BM\\\\web\"}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "projects/D--BM-web/" ++ id ++ "/r.txt", .data = "12345" });
    try tmp.dir.writeFile(io, .{ .sub_path = "projects/D--BM-web/notes.txt", .data = "not a session" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const s = scan(a, io, base);
    try std.testing.expectEqual(@as(usize, 1), s.projects.len);
    try std.testing.expectEqualStrings("D:\\BM\\web", s.projects[0].cwd);
    try std.testing.expectEqual(@as(usize, 1), s.projects[0].sessions.len);
    try std.testing.expect(s.projects[0].bytes > 5 and s.total >= s.sessions_bytes);
}
