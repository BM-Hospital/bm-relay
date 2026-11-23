//! Reading a turn's tool calls: what a step is doing, what it touched,
//! what a question asks, the diff an edit will make. ACP names a call's
//! kind; its input is the agent's own, so the common keys of each agent
//! (fx, Claude Code, Codex) are tried in turn.
const std = @import("std");
const json = @import("../acp/json.zig");
const transcript = @import("transcript.zig");
const git = @import("../host/git.zig");
const Tool = transcript.Tool;
const Turn = transcript.Turn;

const eq = std.mem.eql;

pub fn failed(t: *const Tool) bool {
    return eq(u8, t.status, "failed");
}

pub fn live(t: *const Tool) bool {
    return eq(u8, t.status, "in_progress") or eq(u8, t.status, "pending");
}

pub fn field(t: *const Tool, key: []const u8) ?[]const u8 {
    return json.str(t.input, key);
}

/// A subagent's name and task, when the call hands work to one.
pub fn delegated(t: *const Tool) ?[2][]const u8 {
    if (eq(u8, t.name, "subagent") and eq(u8, field(t, "action") orelse "", "message"))
        return .{ field(t, "agent") orelse "subagent", field(t, "message") orelse "" };
    // Claude Code's Task tool.
    if (field(t, "subagent_type")) |agent| return .{ agent, field(t, "description") orelse field(t, "prompt") orelse "" };
    return null;
}

/// What a subagent reported back, when there is a report.
pub fn report(a: std.mem.Allocator, t: *const Tool) ?[]const u8 {
    _ = delegated(t) orelse return null;
    const at = std.mem.indexOfScalar(u8, t.output, '{') orelse return if (t.output.len > 0) t.output else null;
    const v = std.json.parseFromSliceLeaky(json.Value, a, std.mem.trim(u8, t.output[at..], " \r\n\t"), .{}) catch return t.output;
    return json.str(v, "output") orelse t.output;
}

/// A step as the work log shows it: a verb and what it acted on.
pub fn summarize(t: *const Tool) [2][]const u8 {
    if (isQuestion(t)) return .{ "Asked", questionText(t) orelse "a question" };
    if (delegated(t)) |d| return .{ d[0], firstLine(d[1]) };
    if (eq(u8, t.name, "subagent")) return .{ "Subagents", t.title };
    const keys = [_][]const u8{ "command", "cmd", "path", "file_path", "filePath", "notebook_path", "pattern", "query", "url" };
    var detail: []const u8 = t.title;
    for (keys) |k| if (field(t, k)) |v| {
        detail = v;
        break;
    } else if (json.get(t.input, k)) |v| if (v == .array and v.array.items.len > 0 and v.array.items[v.array.items.len - 1] == .string) {
        // Codex runs commands as an argv: its last word is the script.
        detail = v.array.items[v.array.items.len - 1].string;
        break;
    };
    if (detail.len == 0) detail = t.location orelse "";
    const verb: []const u8 = if (eq(u8, t.kind, "execute")) "Ran" else if (eq(u8, t.kind, "edit")) "Edited" else if (eq(u8, t.kind, "read")) "Read" else if (eq(u8, t.kind, "search")) "Searched" else if (eq(u8, t.kind, "fetch")) "Fetched" else if (eq(u8, t.kind, "delete")) "Deleted" else if (eq(u8, t.kind, "move")) "Moved" else if (eq(u8, t.kind, "think")) "Thought" else if (t.name.len > 0) t.name else if (t.title.len > 0) t.title else "Used a tool";
    if (verb.ptr == t.title.ptr and eq(u8, detail, t.title)) return .{ verb, "" };
    return .{ verb, detail };
}

fn present(verb: []const u8) []const u8 {
    const pairs = [_][2][]const u8{ .{ "Ran", "Running" }, .{ "Edited", "Editing" }, .{ "Read", "Reading" }, .{ "Searched", "Searching" }, .{ "Fetched", "Fetching" }, .{ "Deleted", "Deleting" }, .{ "Moved", "Moving" }, .{ "Thought", "Thinking" } };
    for (pairs) |p| if (eq(u8, verb, p[0])) return p[1];
    return verb;
}

pub fn stopped(t: *const Tool) bool {
    return eq(u8, t.status, "cancelled");
}

pub fn step(t: *const Tool) [2][]const u8 {
    const s = summarize(t);
    const verb = if (failed(t)) "Failed" else if (stopped(t)) "Stopped" else if (live(t)) present(s[0]) else s[0];
    return .{ verb, s[1] };
}

/// A step waiting for the user's approval.
pub fn awaiting(t: *const Tool) [2][]const u8 {
    const s = summarize(t);
    const pairs = [_][2][]const u8{ .{ "Ran", "Waiting to run" }, .{ "Edited", "Waiting to edit" }, .{ "Read", "Waiting to read" }, .{ "Searched", "Waiting to search" }, .{ "Fetched", "Waiting to fetch" }, .{ "Deleted", "Waiting to delete" } };
    for (pairs) |p| if (eq(u8, s[0], p[0])) return .{ p[1], s[1] };
    return .{ "Waiting", s[1] };
}

pub fn firstLine(s: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, s, '\n') orelse return s;
    return s[0..i];
}

fn baseName(p: []const u8) []const u8 {
    var i = p.len;
    while (i > 0) : (i -= 1) if (p[i - 1] == '/' or p[i - 1] == '\\') return p[i..];
    return p;
}

/// What a running turn is on, for the sidebar and the composer.
pub fn doing(buf: []u8, turn: *const Turn) []const u8 {
    const t = turn.lastTool() orelse return "Working";
    if (!live(t)) return "Working";
    const s = step(t);
    const short = if (eq(u8, t.kind, "read") or eq(u8, t.kind, "edit") or eq(u8, t.kind, "delete")) baseName(s[1]) else firstLine(s[1]);
    if (short.len == 0) return s[0];
    return std.fmt.bufPrint(buf, "{s} {s}", .{ s[0], short }) catch s[0];
}

/// The path an edit names.
pub fn editedPath(t: *const Tool) ?[]const u8 {
    if (field(t, "path")) |p| return p;
    if (field(t, "file_path")) |p| return p;
    if (field(t, "filePath")) |p| return p;
    if (t.diff) |d| return d.path;
    return t.location;
}

fn editTexts(t: *const Tool) ?[2][]const u8 {
    if (t.diff) |d| if (d.old) |o| return .{ o, d.new };
    const old = field(t, "old_string") orelse field(t, "old_text") orelse field(t, "oldText") orelse return null;
    const new = field(t, "new_string") orelse field(t, "new_text") orelse field(t, "newText") orelse "";
    return .{ old, new };
}

/// Lines an edit adds and removes, as the work log shows them.
pub fn editStat(a: std.mem.Allocator, t: *const Tool) ?[2]usize {
    if (editTexts(t)) |x| return git.counts(git.lineDiff(a, x[0], x[1], null));
    if (t.diff) |d| return git.counts(git.lineDiff(a, "", d.new, null));
    return null;
}

/// The lines an edit waiting for approval will change.
pub fn editPreview(a: std.mem.Allocator, io: std.Io, t: *const Tool, cwd: []const u8) ?[]git.DiffLine {
    const content = field(t, "content") orelse if (t.diff) |d| (if (d.old == null) d.new else null) else null;
    if (content) |new| if (editedPath(t)) |p| {
        var dir = std.Io.Dir.cwd().openDir(io, cwd, .{}) catch return git.lineDiff(a, "", new, 3);
        defer dir.close(io);
        const old = dir.readFileAlloc(io, p, a, .limited(4 << 20)) catch "";
        return git.lineDiff(a, old, new, 3);
    };
    const x = editTexts(t) orelse return null;
    return git.lineDiff(a, x[0], x[1], null);
}

/// The path of `p` inside `cwd`, or `p` itself.
pub fn relative(cwd: []const u8, p: []const u8) []const u8 {
    if (p.len > cwd.len + 1 and std.ascii.eqlIgnoreCase(p[0..cwd.len], cwd) and (p[cwd.len] == '/' or p[cwd.len] == '\\')) return p[cwd.len + 1 ..];
    return p;
}

fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx = if (x == '\\') '/' else std.ascii.toLower(x);
        const ny = if (y == '\\') '/' else std.ascii.toLower(y);
        if (nx != ny) return false;
    }
    return true;
}

/// The files a finished turn edited or deleted, as git sees them now.
pub fn touched(a: std.mem.Allocator, turn: *const Turn, cwd: []const u8, status: []const git.Change) []git.Change {
    var seen: std.ArrayList(git.Change) = .empty;
    if (turn.running()) return seen.items;
    for (turn.items.items) |it| {
        if (it != .tool) continue;
        const t = it.tool;
        if (!eq(u8, t.kind, "edit") and !eq(u8, t.kind, "delete") and !eq(u8, t.kind, "move")) continue;
        const p = editedPath(t) orelse continue;
        const rel = relative(cwd, p);
        for (status) |c| if (samePath(c.path, rel)) {
            var dup = false;
            for (seen.items) |s| if (eq(u8, s.path, c.path)) {
                dup = true;
            };
            if (!dup) seen.append(a, c) catch {};
            break;
        };
    }
    return seen.items;
}

/// The lines turns added and removed, beyond what their files had before.
pub fn delta(a: std.mem.Allocator, turns: []const *Turn, cwd: []const u8, before: []const git.Change, after: []const git.Change) [2]usize {
    var files: std.ArrayList(git.Change) = .empty;
    for (turns) |t| for (touched(a, t, cwd, after)) |c| {
        var dup = false;
        for (files.items) |f| if (eq(u8, f.path, c.path)) {
            dup = true;
        };
        if (!dup) files.append(a, c) catch {};
    };
    var r: [2]usize = .{ 0, 0 };
    for (files.items) |now| {
        var was: [2]usize = .{ 0, 0 };
        for (before) |b| if (eq(u8, b.path, now.path)) {
            was = .{ b.added, b.removed };
            break;
        };
        r[0] += now.added -| was[0];
        r[1] += now.removed -| was[1];
    }
    return r;
}

fn isQuestion(t: *const Tool) bool {
    return eq(u8, t.name, "ask_user_question") or json.get(t.input, "questions") != null;
}

fn questionText(t: *const Tool) ?[]const u8 {
    const qs = json.array(t.input, "questions");
    if (qs.len == 0) return null;
    return json.str(qs[0], "question");
}

pub const Question = struct {
    asks: []const u8,
    options: []const []const u8,
};

/// The question the turn's last asking call put, with its options.
pub fn asked(a: std.mem.Allocator, turn: *const Turn) ?Question {
    var last: ?*Tool = null;
    for (turn.items.items) |it| if (it == .tool and isQuestion(it.tool)) {
        last = it.tool;
    };
    const t = last orelse return null;
    const qs = json.array(t.input, "questions");
    if (qs.len == 0) return null;
    var opts: std.ArrayList([]const u8) = .empty;
    for (json.array(qs[0], "options")) |o| {
        if (o == .string) opts.append(a, o.string) catch {} else if (json.str(o, "label")) |l| opts.append(a, l) catch {};
    }
    if (opts.items.len == 0) return null;
    return .{ .asks = json.strOr(qs[0], "question", ""), .options = opts.items };
}

/// The approval card's heading: what the call wants, and on what.
pub fn wants(t: *const Tool, cwd: []const u8) [2][]const u8 {
    const s = summarize(t);
    const detail = relative(cwd, firstLine(s[1]));
    const w: []const u8 = if (eq(u8, t.kind, "execute")) "Wants to run" else if (eq(u8, t.kind, "edit")) "Wants to edit" else if (eq(u8, t.kind, "delete")) "Wants to delete" else if (eq(u8, t.kind, "fetch")) "Wants to fetch" else if (eq(u8, t.kind, "read")) "Wants to read" else if (eq(u8, t.kind, "move")) "Wants to move" else "Wants to use";
    return .{ w, if (detail.len > 0) detail else t.title };
}

/// What a notification asks.
pub fn question(t: *const Tool) []const u8 {
    if (eq(u8, t.kind, "execute")) return "Run this command?";
    if (eq(u8, t.kind, "edit") or eq(u8, t.kind, "delete")) return "Make this change?";
    if (eq(u8, t.kind, "fetch")) return "Fetch this?";
    return "Allow this?";
}

/// The grant "Allow always" adds, as the composer lists it.
pub fn grant(buf: []u8, t: *const Tool) []const u8 {
    const s = summarize(t);
    if (eq(u8, t.kind, "execute")) {
        var words = std.mem.tokenizeAny(u8, s[1], " \t\n");
        const w1 = words.next() orelse "";
        const w2 = words.next() orelse "";
        return std.fmt.bufPrint(buf, "Run {s}{s}{s}", .{ w1, if (w2.len > 0) " " else "", w2 }) catch "Run commands";
    }
    if (eq(u8, t.kind, "edit")) return "Edit files";
    if (eq(u8, t.kind, "delete")) return "Delete files";
    if (eq(u8, t.kind, "fetch")) return "Fetch from the web";
    return std.fmt.bufPrint(buf, "Use {s}", .{if (t.name.len > 0) t.name else t.title}) catch "Use a tool";
}

const testing = std.testing;

fn mk(a: std.mem.Allocator, kind: []const u8, input: []const u8, status: []const u8) !*Tool {
    const t = try a.create(Tool);
    t.* = .{ .id = "x", .name = "", .title = "", .kind = kind, .status = status, .input = try std.json.parseFromSliceLeaky(json.Value, a, input, .{}) };
    return t;
}

test "a step says what it is doing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try mk(a, "read", "{\"path\":\"src/shell.rs\"}", "in_progress");
    try testing.expectEqualStrings("Reading", step(r)[0]);
    const e = try mk(a, "execute", "{\"command\":\"ls -la\"}", "pending");
    try testing.expectEqualStrings("Waiting to run", awaiting(e)[0]);
    try testing.expectEqualStrings("ls -la", awaiting(e)[1]);
    const w = wants(try mk(a, "edit", "{\"file_path\":\"/ws/src/main.rs\"}", "pending"), "/ws");
    try testing.expectEqualStrings("Wants to edit", w[0]);
    try testing.expectEqualStrings("src/main.rs", w[1]);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Run cargo check", grant(&buf, try mk(a, "execute", "{\"command\":\"cargo check --all\"}", "pending")));
}

test "a turn counts only what it moved" {
    var th = transcript.Thread.init(testing.allocator);
    defer th.deinit();
    _ = th.begin("go", 0);
    th.apply(.{ .tool_call = .{ .id = "c", .kind = "edit", .status = "completed", .input = (try std.json.parseFromSliceLeaky(json.Value, th.arena.allocator(), "{\"path\":\"/ws/main.py\"}", .{})) } }, 0);
    th.finish(.{ .stop = "end_turn" }, 1);
    const before = [_]git.Change{ .{ .path = "main.py", .code = 'M', .staged = false, .added = 6, .removed = 0 }, .{ .path = "other.py", .code = 'M', .staged = false, .added = 1, .removed = 1 } };
    const after = [_]git.Change{ .{ .path = "main.py", .code = 'M', .staged = false, .added = 7, .removed = 2 }, .{ .path = "other.py", .code = 'M', .staged = false, .added = 9, .removed = 9 } };
    const d = delta(th.arena.allocator(), th.turns.items, "/ws", &before, &after);
    try testing.expectEqual([2]usize{ 1, 2 }, d);
}
