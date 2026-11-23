//! A session's turns, folded from ACP's updates as they arrive or replay:
//! each turn is a prompt, then the agent's thoughts, words and tool calls.
//! Everything a thread holds lives in its arena and goes with it.
const std = @import("std");
const ui = @import("myzig").ui;
const json = @import("../acp/json.zig");
const proto = @import("../acp/proto.zig");

pub const Image = struct {
    mime: []const u8,
    bytes: []const u8,
    /// The key it is decoded under.
    key: []const u8,
};

/// A file a prompt linked for the agent to read.
pub const File = struct {
    name: []const u8,
    /// Its path (or, replayed, the URI the agent was given).
    path: []const u8,
};

pub const Tool = struct {
    id: []const u8,
    name: []const u8,
    title: []const u8,
    kind: []const u8,
    status: []const u8,
    input: ?json.Value,
    output: []const u8 = "",
    diff: ?proto.Diff = null,
    location: ?[]const u8 = null,
    /// What a subagent this call started did: its words, thoughts and calls.
    children: std.ArrayList(Item) = .empty,

    /// Its subagent's last call, the deepest one when subagents nest.
    pub fn lastChild(t: *const Tool) ?*Tool {
        var i = t.children.items.len;
        while (i > 0) : (i -= 1) if (t.children.items[i - 1] == .tool) {
            const c = t.children.items[i - 1].tool;
            return c.lastChild() orelse c;
        };
        return null;
    }

    pub fn childCount(t: *const Tool) usize {
        var n: usize = 0;
        for (t.children.items) |it| if (it == .tool) {
            n += 1;
        };
        return n;
    }
};

pub const Item = union(enum) {
    text: std.ArrayList(u8),
    thought: std.ArrayList(u8),
    tool: *Tool,
};

pub const Turn = struct {
    prompt: std.ArrayList(u8) = .empty,
    images: std.ArrayList(Image) = .empty,
    files: std.ArrayList(File) = .empty,
    items: std.ArrayList(Item) = .empty,
    /// Milliseconds on the wall clock.
    started: i64,
    ended: ?i64 = null,
    /// Why it stopped, when not at its end.
    stop: ?[]const u8 = null,
    /// Its time counts: it ran here, rather than replayed.
    timed: bool,
    /// The answer's Markdown, kept across frames by the view.
    md: ?ui.Markdown = null,

    pub fn running(t: *const Turn) bool {
        return t.ended == null;
    }

    pub fn elapsed(t: *const Turn, now: i64) i64 {
        return (t.ended orelse now) - t.started;
    }

    /// Where the answer starts: after the last tool call.
    pub fn answerStart(t: *const Turn) usize {
        var i = t.items.items.len;
        while (i > 0) : (i -= 1) if (t.items.items[i - 1] == .tool) return i;
        return 0;
    }

    pub fn work(t: *const Turn) []const Item {
        return t.items.items[0..t.answerStart()];
    }

    /// The answer's text, in `a`'s memory when it has more than one part.
    pub fn answer(t: *const Turn, a: std.mem.Allocator) []const u8 {
        const rest = t.items.items[t.answerStart()..];
        var only: ?[]const u8 = null;
        var count: usize = 0;
        for (rest) |it| if (it == .text) {
            only = it.text.items;
            count += 1;
        };
        if (count <= 1) return only orelse "";
        var out: std.ArrayList(u8) = .empty;
        for (rest) |it| if (it == .text) out.appendSlice(a, it.text.items) catch {};
        return out.items;
    }

    pub fn toolCount(t: *const Turn) usize {
        var n: usize = 0;
        for (t.items.items) |it| if (it == .tool) {
            n += 1;
        };
        return n;
    }

    /// The last tool call, if any.
    pub fn lastTool(t: *const Turn) ?*Tool {
        var i = t.items.items.len;
        while (i > 0) : (i -= 1) if (t.items.items[i - 1] == .tool) return t.items.items[i - 1].tool;
        return null;
    }
};

pub const Plan = struct {
    content: []const u8,
    status: []const u8,
};

pub const Thread = struct {
    arena: std.heap.ArenaAllocator,
    turns: std.ArrayList(*Turn) = .empty,
    title: ?[]const u8 = null,
    usage: ?[2]u64 = null,
    recovery: ?proto.Recovery = null,
    plan: []Plan = &.{},
    /// The agent's own slash commands.
    commands: []proto.Command = &.{},
    /// Bumped by every change, for views that keep what they made of it.
    version: u64 = 0,
    /// Images the agent sent, which its answers show by their keys
    /// (`bmimg:…`, a Markdown image's destination).
    pictures: std.ArrayList(Image) = .empty,

    pub fn init(gpa: std.mem.Allocator) Thread {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(th: *Thread) void {
        for (th.turns.items) |t| if (t.md) |*m| m.deinit();
        th.arena.deinit();
    }

    /// Empties it, as a session reloads.
    pub fn reset(th: *Thread) void {
        const gpa = th.arena.child_allocator;
        th.deinit();
        th.* = .init(gpa);
    }

    fn a(th: *Thread) std.mem.Allocator {
        return th.arena.allocator();
    }

    pub fn last(th: *const Thread) ?*Turn {
        return if (th.turns.items.len == 0) null else th.turns.items[th.turns.items.len - 1];
    }

    pub fn running(th: *const Thread) bool {
        const t = th.last() orelse return false;
        return t.running();
    }

    /// Starts a turn for a prompt sent from here.
    pub fn begin(th: *Thread, prompt: []const u8, now: i64) *Turn {
        const t = th.newTurn(prompt, true, now);
        th.version += 1;
        return t;
    }

    fn newTurn(th: *Thread, prompt: []const u8, timed: bool, now: i64) *Turn {
        const t = th.a().create(Turn) catch @panic("out of memory");
        t.* = .{ .started = now, .timed = timed };
        t.prompt.appendSlice(th.a(), prompt) catch {};
        th.turns.append(th.a(), t) catch {};
        return t;
    }

    /// Ends the last turn: `reason` is ACP's stop reason, or an error.
    pub fn finish(th: *Thread, reason: union(enum) { stop: []const u8, err: []const u8 }, now: i64) void {
        const t = th.last() orelse return;
        if (t.ended == null) t.ended = now;
        t.stop = switch (reason) {
            .stop => |r| if (std.mem.eql(u8, r, "end_turn")) null else th.a().dupe(u8, stopText(r)) catch null,
            .err => |e| th.a().dupe(u8, e) catch null,
        };
        th.recovery = null;
        th.version += 1;
    }

    fn stopText(reason: []const u8) []const u8 {
        const eq = std.mem.eql;
        if (eq(u8, reason, "cancelled")) return "Stopped";
        if (eq(u8, reason, "max_tokens")) return "Stopped at the output limit";
        if (eq(u8, reason, "max_turn_requests")) return "Stopped after too many steps";
        if (eq(u8, reason, "refusal")) return "The model declined to answer";
        return reason;
    }

    /// The last turn's calls still under way, and its subagents', marked
    /// stopped: the user stopped the turn (ACP's cancellation).
    pub fn stopCalls(th: *Thread) void {
        const t = th.last() orelse return;
        stopIn(t.items.items);
        th.version += 1;
    }

    fn stopIn(items: []const Item) void {
        for (items) |it| if (it == .tool) {
            const x = it.tool;
            if (std.mem.eql(u8, x.status, "pending") or std.mem.eql(u8, x.status, "in_progress")) x.status = "cancelled";
            stopIn(x.children.items);
        };
    }

    /// Every turn ends, as a session's replay does.
    pub fn settle(th: *Thread, now: i64) void {
        for (th.turns.items) |t| if (t.ended == null) {
            t.ended = now;
        };
        th.version += 1;
    }

    pub fn apply(th: *Thread, u: proto.Update, now: i64) void {
        th.version += 1;
        switch (u) {
            .user_text => |text| th.userText(text, now),
            .user_file => |f| {
                const fresh = if (th.last()) |t| t.items.items.len == 0 and t.ended == null else false;
                if (!fresh) _ = th.openTurn("", now);
                const name = if (f.name.len > 0) f.name else std.fs.path.basename(f.uri);
                th.keepFile(th.last().?, name, f.uri);
            },
            .user_image => |img| {
                const fresh = if (th.last()) |t| t.items.items.len == 0 and t.ended == null else false;
                if (!fresh) _ = th.openTurn("", now);
                const t = th.last().?;
                const dec = std.base64.standard.Decoder;
                const n = dec.calcSizeForSlice(img.data) catch return;
                const bytes = th.a().alloc(u8, n) catch return;
                dec.decode(bytes, img.data) catch return;
                th.addImage(t, img.mime, bytes);
            },
            .agent_image => |img| {
                const dec = std.base64.standard.Decoder;
                const n = dec.calcSizeForSlice(img.data) catch return;
                const bytes = th.a().alloc(u8, n) catch return;
                dec.decode(bytes, img.data) catch return;
                const key = std.fmt.allocPrint(th.a(), "bmimg:{d}", .{th.pictures.items.len}) catch return;
                th.pictures.append(th.a(), .{ .mime = th.a().dupe(u8, img.mime) catch "", .bytes = bytes, .key = key }) catch return;
                th.pushText(std.fmt.allocPrint(th.a(), "\n\n![image]({s})\n\n", .{key}) catch return, false);
            },
            .recovery => |r| th.recovery = if (r) |x| .{
                .state = th.a().dupe(u8, x.state) catch "",
                .attempt = x.attempt,
                .message = th.a().dupe(u8, x.message) catch "",
            } else null,
            .text => |text| th.pushText(text, false),
            .thought => |text| th.pushText(text, true),
            .tool_call => |call| {
                const t = th.last() orelse return;
                th.addTool(&t.items, call);
            },
            .tool_change => |ch| if (th.findTool(ch.id)) |tool| th.changeTool(tool, ch),
            .title => |title| th.title = th.a().dupe(u8, title) catch th.title,
            .usage => |us| th.usage = .{ us.used, us.size },
            .plan => |entries| {
                const out = th.a().alloc(Plan, entries.len) catch return;
                for (entries, out) |e, *p| p.* = .{
                    .content = th.a().dupe(u8, json.strOr(e, "content", "")) catch "",
                    .status = th.a().dupe(u8, json.strOr(e, "status", "pending")) catch "",
                };
                th.plan = out;
            },
            .commands => |list| {
                const out = th.a().alloc(proto.Command, list.len) catch return;
                for (list, out) |c, *o| o.* = .{
                    .name = th.a().dupe(u8, json.strOr(c, "name", "")) catch "",
                    .description = th.a().dupe(u8, json.strOr(c, "description", "")) catch "",
                    .hint = th.a().dupe(u8, json.strOr(json.get(c, "input"), "hint", "")) catch "",
                };
                th.commands = out;
            },
            .subagent => |sub| th.subagent(null, sub),
            .message => |m| th.message(m),
            .notice, .mode, .options, .other => {},
        }
    }

    /// An update a subagent sent: under the call (or the subagent's
    /// session) `parent`, not in the turn's own work and answer. One whose
    /// parent is unknown keeps its calls and drops its words.
    pub fn applyUnder(th: *Thread, parent: []const u8, u: proto.Update, now: i64) void {
        const p = th.findTool(parent) orelse return switch (u) {
            .tool_call, .tool_change, .subagent, .message => th.apply(u, now),
            else => {},
        };
        th.version += 1;
        switch (u) {
            .text => |text| th.pushTextTo(&p.children, text, false),
            .thought => |text| th.pushTextTo(&p.children, text, true),
            .tool_call => |call| th.addTool(&p.children, call),
            .tool_change => |ch| if (th.findTool(ch.id)) |tool| th.changeTool(tool, ch),
            .subagent => |sub| th.subagent(p, sub),
            .message => |m| th.message(m),
            // Its plan, title, usage and the like are its session's, not this one's.
            else => {},
        }
    }

    /// A subagent run as a session of its own: a call in the log named for
    /// it (under `parent`, when a subagent started it), its state its status.
    fn subagent(th: *Thread, parent: ?*Tool, sub: proto.Subagent) void {
        if (sub.id.len == 0) return;
        const status: ?[]const u8 = if (sub.state) |st| (if (std.mem.eql(u8, st, "running")) "in_progress" else if (std.mem.eql(u8, st, "failed") or std.mem.eql(u8, st, "error")) "failed" else "completed") else null;
        if (th.findTool(sub.id)) |tool| {
            if (sub.title) |x| tool.title = th.a().dupe(u8, x) catch tool.title;
            if (sub.title != null or sub.description != null) th.setInput(tool, sub.title, sub.description, null);
            if (status) |x| tool.status = x;
            return;
        }
        const t = th.last() orelse return;
        th.addTool(if (parent) |p| &p.children else &t.items, .{ .id = sub.id, .name = "subagent_session", .title = sub.title orelse "Subagent", .kind = "other", .status = status orelse "in_progress" });
        if (th.findTool(sub.id)) |tool| th.setInput(tool, sub.title orelse "Subagent", sub.description, null);
    }

    /// The task handed to a subagent's session, or its report back.
    fn message(th: *Thread, m: proto.Message) void {
        if (th.findTool(m.to)) |tool| if (std.mem.eql(u8, tool.name, "subagent_session")) return th.setInput(tool, null, null, m.text);
        if (th.findTool(m.from)) |tool| if (std.mem.eql(u8, tool.name, "subagent_session")) {
            tool.output = th.a().dupe(u8, m.text) catch tool.output;
        };
    }

    /// A subagent session's call reads as Claude Code's Task call does.
    fn setInput(th: *Thread, tool: *Tool, title: ?[]const u8, description: ?[]const u8, prompt: ?[]const u8) void {
        var o: std.json.ObjectMap = if (tool.input) |v| (if (v == .object) v.object else .empty) else .empty;
        if (title) |x| o.put(th.a(), "subagent_type", .{ .string = th.a().dupe(u8, x) catch "" }) catch {};
        if (description) |x| o.put(th.a(), "description", .{ .string = th.a().dupe(u8, x) catch "" }) catch {};
        if (prompt) |x| o.put(th.a(), "prompt", .{ .string = th.a().dupe(u8, x) catch "" }) catch {};
        tool.input = .{ .object = o };
    }

    fn addTool(th: *Thread, list: *std.ArrayList(Item), call: proto.ToolCall) void {
        // A call the agent sends again replaces itself.
        if (th.findTool(call.id)) |old| {
            th.changeTool(old, .{ .id = call.id, .status = call.status, .title = call.title, .kind = call.kind, .input = call.input, .diff = call.diff, .output = call.output, .location = call.location });
            return;
        }
        const tool = th.a().create(Tool) catch return;
        tool.* = .{
            .id = th.a().dupe(u8, call.id) catch "",
            .name = th.a().dupe(u8, call.name) catch "",
            .title = th.a().dupe(u8, call.title) catch "",
            .kind = th.a().dupe(u8, call.kind) catch "",
            .status = th.a().dupe(u8, call.status) catch "",
            .input = if (call.input) |v| json.clone(th.a(), v) catch null else null,
            .output = th.a().dupe(u8, call.output orelse "") catch "",
            .diff = th.cloneDiff(call.diff),
            .location = if (call.location) |l| th.a().dupe(u8, l) catch null else null,
        };
        list.append(th.a(), .{ .tool = tool }) catch {};
    }

    /// The image the agent sent under `key`.
    pub fn picture(th: *const Thread, key: []const u8) ?Image {
        for (th.pictures.items) |p| if (std.mem.eql(u8, p.key, key)) return p;
        return null;
    }

    pub fn addImage(th: *Thread, t: *Turn, mime: []const u8, bytes: []const u8) void {
        const key = std.fmt.allocPrint(th.a(), "img-{x}", .{@intFromPtr(bytes.ptr)}) catch return;
        t.images.append(th.a(), .{ .mime = th.a().dupe(u8, mime) catch "", .bytes = bytes, .key = key }) catch {};
    }

    /// Keeps the name and path of a file the prompt of turn `t` linked.
    pub fn keepFile(th: *Thread, t: *Turn, name: []const u8, path: []const u8) void {
        t.files.append(th.a(), .{ .name = th.a().dupe(u8, name) catch return, .path = th.a().dupe(u8, path) catch return }) catch {};
    }

    /// Copies `bytes` into the thread, for an image sent from here.
    pub fn keepImage(th: *Thread, t: *Turn, mime: []const u8, bytes: []const u8) void {
        th.addImage(t, mime, th.a().dupe(u8, bytes) catch return);
    }

    fn cloneDiff(th: *Thread, d: ?proto.Diff) ?proto.Diff {
        const x = d orelse return null;
        return .{
            .path = th.a().dupe(u8, x.path) catch "",
            .old = if (x.old) |o| th.a().dupe(u8, o) catch null else null,
            .new = th.a().dupe(u8, x.new) catch "",
        };
    }

    fn changeTool(th: *Thread, tool: *Tool, ch: proto.ToolChange) void {
        if (ch.status) |s| tool.status = th.a().dupe(u8, s) catch tool.status;
        if (ch.title) |s| if (s.len > 0) {
            tool.title = th.a().dupe(u8, s) catch tool.title;
        };
        if (ch.kind) |s| if (s.len > 0) {
            tool.kind = th.a().dupe(u8, s) catch tool.kind;
        };
        if (ch.input) |v| tool.input = json.clone(th.a(), v) catch tool.input;
        if (ch.output) |o| tool.output = th.a().dupe(u8, o) catch tool.output;
        if (ch.diff) |_| tool.diff = th.cloneDiff(ch.diff);
        if (ch.location) |l| tool.location = th.a().dupe(u8, l) catch tool.location;
    }

    /// The call with `id`, among the turns' and their subagents'.
    pub fn findTool(th: *Thread, id: []const u8) ?*Tool {
        var ti = th.turns.items.len;
        while (ti > 0) : (ti -= 1) if (findIn(th.turns.items[ti - 1].items.items, id)) |x| return x;
        return null;
    }

    fn findIn(items: []const Item, id: []const u8) ?*Tool {
        var i = items.len;
        while (i > 0) : (i -= 1) if (items[i - 1] == .tool) {
            const tool = items[i - 1].tool;
            if (std.mem.eql(u8, tool.id, id)) return tool;
            if (findIn(tool.children.items, id)) |x| return x;
        };
        return null;
    }

    fn userText(th: *Thread, text: []const u8, now: i64) void {
        if (std.mem.indexOf(u8, text, "[Image #") != null) {
            var kept: std.ArrayList(u8) = .empty;
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |l| {
                if (isImageMark(l)) continue;
                if (kept.items.len > 0) kept.append(th.a(), '\n') catch {};
                kept.appendSlice(th.a(), l) catch {};
            }
            return th.userText(kept.items, now);
        }
        if (th.last()) |t| if (t.items.items.len == 0 and t.ended == null) {
            if (t.timed and t.prompt.items.len > 0) t.prompt.appendSlice(th.a(), "\n\n") catch {};
            t.prompt.appendSlice(th.a(), text) catch {};
            return;
        };
        _ = th.openTurn(text, now);
    }

    /// A new turn for a prompt the agent replays or was steered with. The
    /// turn before ends; the new one is timed when that one was live.
    fn openTurn(th: *Thread, prompt: []const u8, now: i64) *Turn {
        var live = false;
        if (th.last()) |t| {
            live = t.timed and t.ended == null;
            if (t.ended == null) t.ended = now;
        }
        return th.newTurn(prompt, live, now);
    }

    fn pushText(th: *Thread, text: []const u8, thought: bool) void {
        const t = th.last() orelse return;
        th.pushTextTo(&t.items, text, thought);
    }

    fn pushTextTo(th: *Thread, items: *std.ArrayList(Item), text: []const u8, thought: bool) void {
        if (items.items.len > 0) {
            const l = &items.items[items.items.len - 1];
            switch (l.*) {
                .text => |*s| if (!thought) return s.appendSlice(th.a(), text) catch {},
                .thought => |*s| if (thought) return s.appendSlice(th.a(), text) catch {},
                .tool => {},
            }
        }
        var s: std.ArrayList(u8) = .empty;
        s.appendSlice(th.a(), text) catch {};
        items.append(th.a(), if (thought) .{ .thought = s } else .{ .text = s }) catch {};
    }
};

fn isImageMark(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \r\t");
    if (!std.mem.startsWith(u8, t, "[Image #") or !std.mem.endsWith(u8, t, "]")) return false;
    const n = t[8 .. t.len - 1];
    if (n.len == 0) return false;
    for (n) |b| if (!std.ascii.isDigit(b)) return false;
    return true;
}

/// "1m 12s", "4s".
pub fn duration(buf: []u8, ms: i64) []const u8 {
    const s: i64 = @divTrunc(@max(ms, 0), 1000);
    if (s >= 60) return std.fmt.bufPrint(buf, "{d}m {d}s", .{ @divTrunc(s, 60), @mod(s, 60) }) catch "";
    return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "";
}

const testing = std.testing;

fn toolCall(id: []const u8) proto.Update {
    return .{ .tool_call = .{ .id = id, .name = "shell", .title = "Running", .kind = "execute", .status = "pending" } };
}

test "a turn folds chunks, tools and the answer" {
    var th = Thread.init(testing.allocator);
    defer th.deinit();
    _ = th.begin("list files", 0);
    th.apply(.{ .thought = "let me " }, 1);
    th.apply(.{ .thought = "look" }, 1);
    th.apply(.{ .text = "Listing." }, 1);
    th.apply(toolCall("c1"), 1);
    th.apply(.{ .tool_change = .{ .id = "c1", .status = "completed", .output = "a.txt\n" } }, 1);
    th.apply(.{ .text = "One file: " }, 1);
    th.apply(.{ .text = "a.txt" }, 1);
    th.apply(.{ .usage = .{ .used = 10, .size = 100 } }, 1);
    try testing.expect(th.running());
    th.finish(.{ .stop = "end_turn" }, 2);
    const t = th.turns.items[0];
    try testing.expect(!t.running() and t.stop == null);
    try testing.expectEqualStrings("let me look", t.items.items[0].thought.items);
    try testing.expectEqualStrings("completed", t.lastTool().?.status);
    try testing.expectEqualStrings("One file: a.txt", t.answer(th.arena.allocator()));
    try testing.expectEqual(@as(usize, 3), t.work().len);
    try testing.expectEqual(@as(u64, 10), th.usage.?[0]);
}

test "a subagent's work stays under the call that started it" {
    var th = Thread.init(testing.allocator);
    defer th.deinit();
    _ = th.begin("find it", 0);
    th.apply(.{ .tool_call = .{ .id = "task", .kind = "think", .status = "in_progress" } }, 1);
    th.applyUnder("task", .{ .thought = "searching" }, 1);
    th.applyUnder("task", toolCall("s1"), 1);
    th.applyUnder("task", .{ .text = "found it" }, 1);
    th.applyUnder("task", .{ .tool_change = .{ .id = "s1", .status = "completed" } }, 1);
    th.apply(.{ .tool_change = .{ .id = "task", .status = "completed", .output = "in shell.zig" } }, 2);
    th.apply(.{ .text = "It is in shell.zig." }, 2);
    const t = th.turns.items[0];
    const task = t.items.items[0].tool;
    try testing.expectEqual(@as(usize, 2), t.items.items.len);
    try testing.expectEqual(@as(usize, 3), task.children.items.len);
    try testing.expectEqualStrings("completed", task.lastChild().?.status);
    try testing.expectEqualStrings("It is in shell.zig.", t.answer(th.arena.allocator()));

    // A subagent run as its own session: announced, working, reporting.
    th.apply(.{ .subagent = .{ .id = "child", .title = "Reviewer", .description = "Review it", .state = "running" } }, 3);
    th.apply(.{ .message = .{ .from = "main", .to = "child", .text = "Check the notes." } }, 3);
    th.applyUnder("child", toolCall("c1"), 3);
    th.applyUnder("child", .{ .title = "not ours" }, 3);
    th.apply(.{ .subagent = .{ .id = "child", .state = "idle" } }, 4);
    th.apply(.{ .message = .{ .from = "child", .to = "main", .text = "All fine." } }, 4);
    const child = th.findTool("child").?;
    try testing.expectEqualStrings("completed", child.status);
    try testing.expectEqualStrings("All fine.", child.output);
    try testing.expectEqualStrings("Check the notes.", json.str(child.input, "prompt").?);
    try testing.expectEqual(@as(usize, 1), child.childCount());
    try testing.expect(th.title == null);
}

test "steering a live turn folds the work so far" {
    var th = Thread.init(testing.allocator);
    defer th.deinit();
    _ = th.begin("fix the bug", 0);
    th.apply(toolCall("c1"), 1);
    th.apply(.{ .user_text = "keep the old name" }, 2);
    th.apply(.{ .text = "Done." }, 3);
    try testing.expectEqual(@as(usize, 2), th.turns.items.len);
    try testing.expectEqualStrings("keep the old name", th.turns.items[1].prompt.items);
    try testing.expect(!th.turns.items[0].running());
    try testing.expect(th.turns.items[1].running() and th.turns.items[1].timed);

    var b = Thread.init(testing.allocator);
    defer b.deinit();
    _ = b.begin("fix the bug", 0);
    b.apply(.{ .user_text = "and add a test" }, 1);
    try testing.expectEqual(@as(usize, 1), b.turns.items.len);
    try testing.expectEqualStrings("fix the bug\n\nand add a test", b.turns.items[0].prompt.items);
}

test "replayed history splits into turns, images stay with their prompt" {
    var th = Thread.init(testing.allocator);
    defer th.deinit();
    th.apply(.{ .user_text = "match this\n[Image #1]" }, 0);
    try testing.expectEqualStrings("match this", th.turns.items[0].prompt.items);
    th.apply(.{ .user_image = .{ .mime = "image/png", .data = "aGk=" } }, 0);
    th.apply(.{ .text = "ok" }, 0);
    th.apply(.{ .user_text = "second" }, 0);
    try testing.expectEqual(@as(usize, 2), th.turns.items.len);
    try testing.expectEqualStrings("hi", th.turns.items[0].images.items[0].bytes);
    th.settle(5);
    try testing.expect(!th.running());
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("1m 12s", duration(&buf, 72_000));
}
