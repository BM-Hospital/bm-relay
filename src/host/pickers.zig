//! What the composer's `@` and `/` complete: the folder's files, and the
//! skills on disk, ranked by how well they match what was typed.
const std = @import("std");
const Io = std.Io;

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    path: []const u8,
};

/// The skills in the workspace's and the home folder's `.fx`, `.agents`
/// and `.claude` folders, the first of each name, sorted. In `a`'s memory.
pub fn skills(a: std.mem.Allocator, io: Io, workspace: []const u8, home: []const u8) []Skill {
    var found: std.ArrayList(Skill) = .empty;
    for ([_][]const u8{ workspace, home }) |base| {
        if (base.len == 0) continue;
        for ([_][]const u8{ ".fx", ".agents", ".claude" }) |harness| {
            const root = std.fs.path.join(a, &.{ base, harness, "skills" }) catch continue;
            var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var it = dir.iterate();
            while (it.next(io) catch null) |e| {
                if (e.kind != .directory and e.kind != .sym_link) continue;
                const file = std.fs.path.join(a, &.{ root, e.name, "SKILL.md" }) catch continue;
                const text = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(256 << 10)) catch continue;
                var dup = false;
                for (found.items) |s| if (std.mem.eql(u8, s.name, e.name)) {
                    dup = true;
                };
                if (dup) continue;
                found.append(a, .{ .name = a.dupe(u8, e.name) catch continue, .description = description(a, text), .path = file }) catch {};
            }
        }
    }
    std.mem.sort(Skill, found.items, {}, struct {
        fn lt(_: void, x: Skill, y: Skill) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    return found.items;
}

/// The `description:` of a skill's front matter, folded lines joined.
pub fn description(a: std.mem.Allocator, text: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, text, "---")) return "";
    const body = text[3..];
    const end = std.mem.indexOf(u8, body, "\n---") orelse body.len;
    var lines = std.mem.splitScalar(u8, body[0..end], '\n');
    var out: std.ArrayList(u8) = .empty;
    var in = false;
    while (lines.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (!in) {
            if (!std.mem.startsWith(u8, l, "description:")) continue;
            in = true;
            const first = std.mem.trim(u8, std.mem.trim(u8, l["description:".len..], " \t"), "\">|");
            out.appendSlice(a, std.mem.trim(u8, first, " \t")) catch {};
            continue;
        }
        if (l.len == 0 or (l[0] != ' ' and l[0] != '\t')) break;
        if (out.items.len > 0) out.append(a, ' ') catch {};
        out.appendSlice(a, std.mem.trim(u8, l, " \t")) catch {};
    }
    return std.mem.trim(u8, out.items, " ");
}

/// How well `query` matches `text`, both lowercase: null for no match.
/// Letters in a row and at word starts count more.
pub fn score(text: []const u8, query: []const u8) ?i32 {
    if (query.len == 0) return 0;
    var best: ?i32 = null;
    for (text, 0..) |b, start| {
        if (std.ascii.toLower(b) != query[0]) continue;
        if (scoreFrom(text, query, start)) |sc| best = if (best) |x| @max(x, sc) else sc;
    }
    return best;
}

fn scoreFrom(text: []const u8, query: []const u8, start: usize) ?i32 {
    var sc: i32 = 0;
    var at = start;
    var previous: ?usize = null;
    for (query) |q| {
        var found: ?usize = null;
        var i = at;
        while (i < text.len) : (i += 1) if (std.ascii.toLower(text[i]) == q) {
            found = i;
            break;
        };
        const f = found orelse return null;
        sc += 1;
        if (previous != null and previous.? + 1 == f) sc += 3;
        if (f == 0 or std.mem.indexOfScalar(u8, "/\\_-. ", text[f - 1]) != null) sc += 2;
        previous = f;
        at = f + 1;
    }
    return sc;
}

/// The indices of `items` that match `query`, best first, at most `limit`.
pub fn rank(a: std.mem.Allocator, keys: []const []const u8, query: []const u8, limit: usize) []usize {
    const lower = std.ascii.allocLowerString(a, query) catch return &.{};
    const Scored = struct { score: i32, len: usize, index: usize };
    var list: std.ArrayList(Scored) = .empty;
    for (keys, 0..) |k, i| if (score(k, lower)) |sc| list.append(a, .{ .score = sc, .len = k.len, .index = i }) catch {};
    std.mem.sort(Scored, list.items, {}, struct {
        fn lt(_: void, x: Scored, y: Scored) bool {
            if (x.score != y.score) return x.score > y.score;
            return x.len < y.len;
        }
    }.lt);
    const n = @min(list.items.len, limit);
    const out = a.alloc(usize, n) catch return &.{};
    for (list.items[0..n], out) |s, *o| o.* = s.index;
    return out;
}

/// What the draft asks to complete: a leading `/` and the word after it,
/// or a trailing `@` mention.
pub fn trigger(draft: []const u8) ?struct { kind: u8, query: []const u8 } {
    if (draft.len > 0 and draft[0] == '/' and std.mem.indexOfAny(u8, draft, " \t\n") == null)
        return .{ .kind = '/', .query = draft[1..] };
    var i = draft.len;
    while (i > 0 and !std.ascii.isWhitespace(draft[i - 1])) i -= 1;
    const word = draft[i..];
    if (word.len > 0 and word[0] == '@') return .{ .kind = '@', .query = word[1..] };
    return null;
}

const testing = std.testing;

test "ranks contiguous and word-start matches first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const files = [_][]const u8{ "src/views/sidebar.rs", "src/state/side_effects.rs", "docs/inside.md" };
    const r = rank(arena.allocator(), &files, "side", 10);
    try testing.expectEqual(@as(usize, 0), r[0]);
    try testing.expectEqual(@as(usize, 0), rank(arena.allocator(), &files, "zzz", 10).len);
}

test "triggers on a leading slash or a trailing mention" {
    try testing.expectEqualStrings("rev", trigger("/rev").?.query);
    try testing.expect(trigger("/review now") == null);
    const t = trigger("match rows in @side").?;
    try testing.expectEqual(@as(u8, '@'), t.kind);
    try testing.expectEqualStrings("side", t.query);
    try testing.expect(trigger("plain text") == null);
}

test "reads a folded description" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("Review the diff for bugs.", description(arena.allocator(), "---\nname: review\ndescription: >\n  Review the diff\n  for bugs.\n---\n# Review\n"));
    try testing.expectEqualStrings("One line", description(arena.allocator(), "---\ndescription: \"One line\"\n---\n"));
}
