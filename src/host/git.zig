//! Git through its command line: the branch, what changed, diffs,
//! staging, and the snapshot and restore behind "Restore this turn's
//! files". Every function blocks: call them off the main thread.
const std = @import("std");
const Io = std.Io;

/// The environment git runs with: the app's, with prompts off. Set once
/// by `init`, then only read.
var env: ?std.process.Environ.Map = null;
var temp_dir: []const u8 = ".";

pub fn init(gpa: std.mem.Allocator, base: *const std.process.Environ.Map) void {
    var m = base.clone(gpa) catch return;
    m.put("GIT_TERMINAL_PROMPT", "0") catch {};
    m.put("GIT_OPTIONAL_LOCKS", "0") catch {};
    m.put("LC_ALL", "C") catch {};
    env = m;
    temp_dir = base.get("TEMP") orelse base.get("TMPDIR") orelse base.get("TMP") orelse "/tmp";
}

pub fn deinit() void {
    if (env) |*m| m.deinit();
    env = null;
}

pub const Change = struct {
    path: []const u8,
    code: u8,
    staged: bool,
    added: usize,
    removed: usize,
};

pub const Line = enum { context, added, removed, hunk };

pub const DiffLine = struct {
    kind: Line,
    old: ?usize = null,
    new: ?usize = null,
    text: []const u8,
};

/// What a command printed, or why it failed.
pub const Out = union(enum) { ok: []u8, err: []const u8 };

fn runEnv(gpa: std.mem.Allocator, io: Io, cwd: []const u8, args: []const []const u8, e: ?*const std.process.Environ.Map) Out {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    argv.appendSlice(gpa, &.{ "git", "-c", "core.quotepath=off", "-c", "color.ui=false" }) catch return .{ .err = gpa.dupe(u8, "Out of memory") catch &.{} };
    argv.appendSlice(gpa, args) catch {};
    const r = std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .environ_map = e,
        .stdout_limit = .limited(64 << 20),
        .create_no_window = true,
    }) catch |er| return .{ .err = std.fmt.allocPrint(gpa, "git: {s}", .{@errorName(er)}) catch &.{} };
    if (r.term.success()) {
        gpa.free(r.stderr);
        return .{ .ok = r.stdout };
    }
    gpa.free(r.stdout);
    const t = std.mem.trim(u8, r.stderr, " \r\n\t");
    const msg = gpa.dupe(u8, if (t.len > 0) t else "git failed") catch &.{};
    gpa.free(r.stderr);
    return .{ .err = msg };
}

pub fn run(gpa: std.mem.Allocator, io: Io, cwd: []const u8, args: []const []const u8) Out {
    return runEnv(gpa, io, cwd, args, if (env) |*m| m else null);
}

fn line(gpa: std.mem.Allocator, io: Io, cwd: []const u8, args: []const []const u8) ?[]u8 {
    switch (run(gpa, io, cwd, args)) {
        .ok => |s| {
            defer gpa.free(s);
            const t = std.mem.trim(u8, s, " \r\n\t");
            if (t.len == 0) return null;
            return gpa.dupe(u8, t) catch null;
        },
        .err => |e| {
            gpa.free(e);
            return null;
        },
    }
}

pub fn branch(gpa: std.mem.Allocator, io: Io, cwd: []const u8) ?[]u8 {
    return line(gpa, io, cwd, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
}

/// The local branches, the one last committed to first. Free with `freeList`.
pub fn branches(gpa: std.mem.Allocator, io: Io, cwd: []const u8) [][]const u8 {
    const out = switch (run(gpa, io, cwd, &.{ "for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads" })) {
        .ok => |s| s,
        .err => |e| {
            gpa.free(e);
            return &.{};
        },
    };
    defer gpa.free(out);
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, out, "\r\n");
    while (it.next()) |b| list.append(gpa, gpa.dupe(u8, b) catch continue) catch {};
    return list.toOwnedSlice(gpa) catch &.{};
}

/// Puts the work tree on branch `name`. git refuses when changes would be
/// lost (its words are the error); changes it can carry over come along.
pub fn switchTo(gpa: std.mem.Allocator, io: Io, cwd: []const u8, name: []const u8) Out {
    return run(gpa, io, cwd, &.{ "switch", name });
}

pub fn lastCommit(gpa: std.mem.Allocator, io: Io, cwd: []const u8) ?[]u8 {
    return line(gpa, io, cwd, &.{ "log", "-1", "--format=%h · %cr" });
}

/// The files git tracks or would (not ignored), one per entry.
pub fn tracked(gpa: std.mem.Allocator, io: Io, cwd: []const u8) [][]const u8 {
    const out = switch (run(gpa, io, cwd, &.{ "ls-files", "-z", "--cached", "--others", "--exclude-standard" })) {
        .ok => |s| s,
        .err => |e| {
            gpa.free(e);
            return &.{};
        },
    };
    defer gpa.free(out);
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, out, 0);
    while (it.next()) |p| list.append(gpa, gpa.dupe(u8, p) catch continue) catch {};
    return list.toOwnedSlice(gpa) catch &.{};
}

pub fn freeList(gpa: std.mem.Allocator, list: []const []const u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

// ---------------------------------------------------------------------------
// Snapshots: the whole work tree as a git tree, written through an index
// of its own so that the user's staging is never touched.

fn scratchIndex(gpa: std.mem.Allocator, io: Io) ![]u8 {
    const now = std.Io.Clock.real.now(io).toMicroseconds();
    return std.fmt.allocPrint(gpa, "{s}{c}bm-relay-index-{d}", .{ temp_dir, std.fs.path.sep, now });
}

fn aside(gpa: std.mem.Allocator, io: Io, cwd: []const u8, index: []const u8, args: []const []const u8) Out {
    const base = if (env) |*m| m else return .{ .err = gpa.dupe(u8, "git is not set up") catch &.{} };
    var m = base.clone(gpa) catch return .{ .err = gpa.dupe(u8, "Out of memory") catch &.{} };
    defer m.deinit();
    m.put("GIT_INDEX_FILE", index) catch {};
    return runEnv(gpa, io, cwd, args, &m);
}

fn sameDir(io: Io, a: []const u8, b: []const u8) bool {
    var ba: [std.fs.max_path_bytes]u8 = undefined;
    var bb: [std.fs.max_path_bytes]u8 = undefined;
    const ra = std.Io.Dir.cwd().realPathFile(io, a, &ba) catch return false;
    const rb = std.Io.Dir.cwd().realPathFile(io, b, &bb) catch return false;
    return std.ascii.eqlIgnoreCase(ba[0..ra], bb[0..rb]);
}

/// The work tree as a tree id, or null outside the top of a repository.
pub fn snapshot(gpa: std.mem.Allocator, io: Io, cwd: []const u8) ?[]u8 {
    const root = line(gpa, io, cwd, &.{ "rev-parse", "--show-toplevel" }) orelse return null;
    defer gpa.free(root);
    if (!sameDir(io, root, cwd)) return null;
    const index = scratchIndex(gpa, io) catch return null;
    defer {
        std.Io.Dir.cwd().deleteFile(io, index) catch {};
        gpa.free(index);
    }
    switch (aside(gpa, io, cwd, index, &.{ "read-tree", "HEAD" })) {
        .ok => |s| gpa.free(s),
        .err => |e| gpa.free(e),
    }
    switch (aside(gpa, io, cwd, index, &.{ "add", "-A" })) {
        .ok => |s| gpa.free(s),
        .err => |e| {
            gpa.free(e);
            return null;
        },
    }
    return switch (aside(gpa, io, cwd, index, &.{"write-tree"})) {
        .ok => |s| blk: {
            defer gpa.free(s);
            break :blk gpa.dupe(u8, std.mem.trim(u8, s, " \r\n\t")) catch null;
        },
        .err => |e| blk: {
            gpa.free(e);
            break :blk null;
        },
    };
}

/// Puts the files a turn changed back as they were before it: those it
/// made are deleted, the rest checked out from `before`. Refuses when the
/// tree is no longer as the turn left it. Returns an error message, or null.
pub fn restore(gpa: std.mem.Allocator, io: Io, cwd: []const u8, before: []const u8, after: []const u8) ?[]const u8 {
    const now = snapshot(gpa, io, cwd);
    defer if (now) |n| gpa.free(n);
    if (now == null or !std.mem.eql(u8, now.?, after))
        return gpa.dupe(u8, "Files have changed since this turn ended, so nothing was restored.") catch null;
    const listed = switch (run(gpa, io, cwd, &.{ "diff", "--name-status", "--no-renames", "-z", before, after })) {
        .ok => |s| s,
        .err => |e| return e,
    };
    defer gpa.free(listed);
    var created: std.ArrayList([]const u8) = .empty;
    defer created.deinit(gpa);
    var changed: std.ArrayList([]const u8) = .empty;
    defer changed.deinit(gpa);
    var fields = std.mem.tokenizeScalar(u8, listed, 0);
    while (fields.next()) |code| {
        const path = fields.next() orelse break;
        if (std.mem.eql(u8, code, "A")) created.append(gpa, path) catch {} else changed.append(gpa, path) catch {};
    }
    if (changed.items.len > 0) {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        args.appendSlice(gpa, &.{ "checkout", before, "--" }) catch {};
        args.appendSlice(gpa, changed.items) catch {};
        const index = scratchIndex(gpa, io) catch return null;
        defer {
            std.Io.Dir.cwd().deleteFile(io, index) catch {};
            gpa.free(index);
        }
        switch (aside(gpa, io, cwd, index, args.items)) {
            .ok => |s| gpa.free(s),
            .err => |e| return e,
        }
    }
    var dir = std.Io.Dir.cwd().openDir(io, cwd, .{}) catch return gpa.dupe(u8, "Could not open the folder") catch null;
    defer dir.close(io);
    for (created.items) |p| dir.deleteFile(io, p) catch |e| return std.fmt.allocPrint(gpa, "{s}: {s}", .{ p, @errorName(e) }) catch null;
    return null;
}

// ---------------------------------------------------------------------------
// Status and diffs.

const Count = struct { path: []const u8, added: usize, removed: usize };

/// `git diff --numstat -z`: a rename is three fields, an empty path then
/// the old and the new.
fn parseNumstat(a: std.mem.Allocator, text: []const u8) []Count {
    var out: std.ArrayList(Count) = .empty;
    var fields = std.mem.splitScalar(u8, text, 0);
    while (fields.next()) |record| {
        var parts = std.mem.splitScalar(u8, record, '\t');
        const added = parts.next() orelse continue;
        const removed = parts.next() orelse continue;
        var path = parts.rest();
        if (path.len == 0) {
            _ = fields.next();
            path = fields.next() orelse "";
        }
        out.append(a, .{ .path = path, .added = std.fmt.parseInt(usize, added, 10) catch 0, .removed = std.fmt.parseInt(usize, removed, 10) catch 0 }) catch {};
    }
    return out.items;
}

fn countOf(list: []const Count, path: []const u8) [2]usize {
    for (list) |c| if (std.mem.eql(u8, c.path, path)) return .{ c.added, c.removed };
    return .{ 0, 0 };
}

/// What changed in the work tree: staged, unstaged and untracked, with
/// the lines added and removed. Paths are in `gpa`'s memory; free with
/// `freeChanges`.
pub fn status(gpa: std.mem.Allocator, io: Io, cwd: []const u8) ?[]Change {
    const porcelain = switch (run(gpa, io, cwd, &.{ "status", "--porcelain=v1", "-uall" })) {
        .ok => |s| s,
        .err => |e| {
            gpa.free(e);
            return null;
        },
    };
    defer gpa.free(porcelain);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    const staged = numstat(aa, io, cwd, true);
    const unstaged = numstat(aa, io, cwd, false);
    var dir = std.Io.Dir.cwd().openDir(io, cwd, .{}) catch null;
    defer if (dir) |*d| d.close(io);
    var out: std.ArrayList(Change) = .empty;
    var lines = std.mem.splitScalar(u8, porcelain, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (l.len < 4) continue;
        const x = l[0];
        const y = l[1];
        var path = l[3..];
        if (std.mem.lastIndexOf(u8, path, " -> ")) |i| path = path[i + 4 ..];
        path = unquote(aa, path);
        if (x == '?') {
            const n = if (dir) |d| lineCount(aa, io, d, path) else 0;
            out.append(gpa, .{ .path = gpa.dupe(u8, path) catch continue, .code = '?', .staged = false, .added = n, .removed = 0 }) catch {};
            continue;
        }
        if (x != ' ') {
            const c = countOf(staged, path);
            out.append(gpa, .{ .path = gpa.dupe(u8, path) catch continue, .code = x, .staged = true, .added = c[0], .removed = c[1] }) catch {};
        }
        if (y != ' ') {
            const c = countOf(unstaged, path);
            out.append(gpa, .{ .path = gpa.dupe(u8, path) catch continue, .code = y, .staged = false, .added = c[0], .removed = c[1] }) catch {};
        }
    }
    return out.toOwnedSlice(gpa) catch null;
}

fn unquote(a: std.mem.Allocator, p: []const u8) []const u8 {
    if (p.len < 2 or p[0] != '"' or p[p.len - 1] != '"') return p;
    return std.zig.string_literal.parseAlloc(a, p) catch p[1 .. p.len - 1];
}

fn numstat(a: std.mem.Allocator, io: Io, cwd: []const u8, cached: bool) []Count {
    const args: []const []const u8 = if (cached) &.{ "diff", "--cached", "--numstat", "-z" } else &.{ "diff", "--numstat", "-z" };
    return switch (run(a, io, cwd, args)) {
        .ok => |s| parseNumstat(a, s),
        .err => &.{},
    };
}

fn lineCount(a: std.mem.Allocator, io: Io, dir: std.Io.Dir, path: []const u8) usize {
    const text = dir.readFileAlloc(io, path, a, .limited(16 << 20)) catch return 0;
    if (text.len == 0) return 0;
    var n = std.mem.count(u8, text, "\n");
    if (text[text.len - 1] != '\n') n += 1;
    return n;
}

pub fn freeChanges(gpa: std.mem.Allocator, list: []const Change) void {
    for (list) |c| gpa.free(c.path);
    gpa.free(list);
}

pub fn cloneChanges(gpa: std.mem.Allocator, list: []const Change) []Change {
    const out = gpa.alloc(Change, list.len) catch return &.{};
    for (list, out) |c, *o| {
        o.* = c;
        o.path = gpa.dupe(u8, c.path) catch "";
    }
    return out;
}

/// The diff of one change, in `a`'s memory.
pub fn fileDiff(a: std.mem.Allocator, io: Io, cwd: []const u8, c: Change) union(enum) { ok: []DiffLine, err: []const u8 } {
    if (c.code == '?') {
        var dir = std.Io.Dir.cwd().openDir(io, cwd, .{}) catch return .{ .err = "Could not open the folder" };
        defer dir.close(io);
        const body = dir.readFileAlloc(io, c.path, a, .limited(4 << 20)) catch |e| return .{ .err = @errorName(e) };
        return .{ .ok = lineDiff(a, "", body, null) };
    }
    const args: []const []const u8 = if (c.staged) &.{ "diff", "--cached", "--", c.path } else &.{ "diff", "--", c.path };
    return switch (run(a, io, cwd, args)) {
        .ok => |s| .{ .ok = parseUnified(a, s) },
        .err => |e| .{ .err = e },
    };
}

pub fn parseUnified(a: std.mem.Allocator, text: []const u8) []DiffLine {
    var old: usize = 0;
    var new: usize = 0;
    var out: std.ArrayList(DiffLine) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, l, "@@ ")) {
            var parts = std.mem.tokenizeScalar(u8, l[3..], ' ');
            old = hunkStart(parts.next());
            new = hunkStart(parts.next());
            out.append(a, .{ .kind = .hunk, .text = l }) catch {};
        } else if (out.items.len == 0) {
            continue;
        } else if (l.len > 0 and l[0] == '+') {
            out.append(a, .{ .kind = .added, .new = new, .text = l[1..] }) catch {};
            new += 1;
        } else if (l.len > 0 and l[0] == '-') {
            out.append(a, .{ .kind = .removed, .old = old, .text = l[1..] }) catch {};
            old += 1;
        } else if (l.len > 0 and l[0] == ' ') {
            out.append(a, .{ .kind = .context, .old = old, .new = new, .text = l[1..] }) catch {};
            old += 1;
            new += 1;
        }
    }
    return out.items;
}

fn hunkStart(s: ?[]const u8) usize {
    const t = s orelse return 1;
    if (t.len < 2) return 1;
    var it = std.mem.splitScalar(u8, t[1..], ',');
    return std.fmt.parseInt(usize, it.first(), 10) catch 1;
}

pub fn stage(gpa: std.mem.Allocator, io: Io, cwd: []const u8, path: []const u8) Out {
    return run(gpa, io, cwd, &.{ "add", "--", path });
}

pub fn unstage(gpa: std.mem.Allocator, io: Io, cwd: []const u8, path: []const u8) Out {
    return run(gpa, io, cwd, &.{ "restore", "--staged", "--", path });
}

pub fn discard(gpa: std.mem.Allocator, io: Io, cwd: []const u8, c: Change) Out {
    if (c.code == '?') {
        var dir = std.Io.Dir.cwd().openDir(io, cwd, .{}) catch return .{ .err = gpa.dupe(u8, "Could not open the folder") catch &.{} };
        defer dir.close(io);
        dir.deleteFile(io, c.path) catch |e| return .{ .err = gpa.dupe(u8, @errorName(e)) catch &.{} };
        return .{ .ok = &.{} };
    }
    return run(gpa, io, cwd, &.{ "restore", "--", c.path });
}

pub fn counts(lines: []const DiffLine) [2]usize {
    var r: [2]usize = .{ 0, 0 };
    for (lines) |l| switch (l.kind) {
        .added => r[0] += 1,
        .removed => r[1] += 1,
        else => {},
    };
    return r;
}

/// A line diff of two texts by their longest common subsequence, with
/// `context` lines kept around each change (all of them when null).
pub fn lineDiff(a: std.mem.Allocator, old: []const u8, new: []const u8, context: ?usize) []DiffLine {
    const xs = splitLines(a, old);
    const ys = splitLines(a, new);
    const n = xs.len;
    const m = ys.len;
    // Too large to compare line by line: show the new text whole.
    if (n * m > 4_000_000) {
        var out: std.ArrayList(DiffLine) = .empty;
        for (xs, 0..) |x, i| out.append(a, .{ .kind = .removed, .old = i + 1, .text = x }) catch {};
        for (ys, 0..) |y, j| out.append(a, .{ .kind = .added, .new = j + 1, .text = y }) catch {};
        return out.items;
    }
    const w = m + 1;
    const lcs = a.alloc(u32, (n + 1) * w) catch return &.{};
    @memset(lcs, 0);
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        var j: usize = m;
        while (j > 0) {
            j -= 1;
            lcs[i * w + j] = if (std.mem.eql(u8, xs[i], ys[j])) lcs[(i + 1) * w + j + 1] + 1 else @max(lcs[(i + 1) * w + j], lcs[i * w + j + 1]);
        }
    }
    var all: std.ArrayList(DiffLine) = .empty;
    i = 0;
    var j: usize = 0;
    while (i < n or j < m) {
        if (i < n and j < m and std.mem.eql(u8, xs[i], ys[j])) {
            all.append(a, .{ .kind = .context, .old = i + 1, .new = j + 1, .text = xs[i] }) catch {};
            i += 1;
            j += 1;
        } else if (i < n and (j == m or lcs[(i + 1) * w + j] >= lcs[i * w + j + 1])) {
            all.append(a, .{ .kind = .removed, .old = i + 1, .text = xs[i] }) catch {};
            i += 1;
        } else {
            all.append(a, .{ .kind = .added, .new = j + 1, .text = ys[j] }) catch {};
            j += 1;
        }
    }
    const ctx = context orelse return all.items;
    var out: std.ArrayList(DiffLine) = .empty;
    const items = all.items;
    for (items, 0..) |l, k| {
        const lo = k -| ctx;
        const hi = @min(k + ctx, items.len -| 1);
        var near = false;
        for (items[lo .. hi + 1]) |x| if (x.kind != .context) {
            near = true;
        };
        if (near) out.append(a, l) catch {};
    }
    return out.items;
}

fn splitLines(a: std.mem.Allocator, text: []const u8) [][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (text.len == 0) return out.items;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| out.append(a, std.mem.trimEnd(u8, l, "\r")) catch {};
    if (text[text.len - 1] == '\n') _ = out.pop();
    return out.items;
}

const testing = std.testing;

test "line diff keeps changes and context" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const lines = lineDiff(arena.allocator(), "a\nb\nc\nd\ne\nf\n", "a\nb\nC\nd\ne\nf\ng\n", 1);
    const want = [_]struct { Line, []const u8 }{ .{ .context, "b" }, .{ .removed, "c" }, .{ .added, "C" }, .{ .context, "d" }, .{ .context, "f" }, .{ .added, "g" } };
    try testing.expectEqual(want.len, lines.len);
    for (want, lines) |w, l| {
        try testing.expectEqual(w[0], l.kind);
        try testing.expectEqualStrings(w[1], l.text);
    }
    const fresh = lineDiff(arena.allocator(), "", "x\ny", null);
    try testing.expectEqual(@as(?usize, 2), fresh[1].new);
}

test "numstat counts a rename under its new name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = parseNumstat(arena.allocator(), "2\t1\tsrc/a.rs\x003\t4\t\x00old.rs\x00new.rs\x00-\t-\tlogo.png\x00");
    try testing.expectEqual(@as(usize, 3), c.len);
    try testing.expectEqualStrings("new.rs", c[1].path);
    try testing.expectEqual(@as(usize, 4), c[1].removed);
    try testing.expectEqual(@as(usize, 0), c[2].added);
}

test "unified diffs number their lines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const l = parseUnified(arena.allocator(), "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -3,3 +3,3 @@ fn\n keep\n-old\n+new\n same\n");
    try testing.expectEqual(Line.hunk, l[0].kind);
    try testing.expectEqual(@as(?usize, 3), l[1].old);
    try testing.expectEqual(Line.removed, l[2].kind);
    try testing.expectEqual(@as(?usize, 4), l[3].new);
    try testing.expectEqual(@as(?usize, 5), l[4].old);
}
