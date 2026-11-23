//! What ACP's messages mean: session updates, permission requests and a
//! session's options, read from JSON into types. The types borrow from the
//! message: copy what must outlive it. `Options` is the exception, with an
//! arena of its own.
const std = @import("std");
const json = @import("json.zig");
const Value = json.Value;

pub const Recovery = struct {
    state: []const u8,
    attempt: i64,
    message: []const u8,
};

pub const Diff = struct {
    path: []const u8,
    old: ?[]const u8,
    new: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8 = "",
    title: []const u8 = "",
    kind: []const u8 = "",
    status: []const u8 = "pending",
    input: ?Value = null,
    /// The first diff among its content, which says what an edit does.
    diff: ?Diff = null,
    /// The text among its content, joined.
    output: ?[]const u8 = null,
    /// The first file it names, from its locations.
    location: ?[]const u8 = null,
};

/// A change to a call: only what the agent sent is set.
pub const ToolChange = struct {
    id: []const u8,
    status: ?[]const u8 = null,
    title: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    input: ?Value = null,
    diff: ?Diff = null,
    output: ?[]const u8 = null,
    location: ?[]const u8 = null,
};

pub const PlanEntry = struct {
    content: []const u8,
    status: []const u8,
    priority: []const u8,
};

pub const Command = struct {
    name: []const u8,
    description: []const u8,
    hint: []const u8,
};

/// A subagent run as a session of its own (ACP's `subagent_update`):
/// announced, then its state as it changes.
pub const Subagent = struct {
    id: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// "running", "idle", or why it stopped; null when unchanged.
    state: ?[]const u8 = null,
};

/// A message between a session and its subagent's (ACP's `session_message`):
/// the task handed over, or the report sent back.
pub const Message = struct {
    from: []const u8,
    to: []const u8,
    text: []const u8,
};

pub const Update = union(enum) {
    user_text: []const u8,
    user_image: struct { mime: []const u8, data: []const u8 },
    /// An image among the agent's words (base64, as ACP sends it).
    agent_image: struct { mime: []const u8, data: []const u8 },
    text: []const u8,
    thought: []const u8,
    notice: []const u8,
    tool_call: ToolCall,
    tool_change: ToolChange,
    title: []const u8,
    usage: struct { used: u64, size: u64 },
    recovery: ?Recovery,
    plan: []const Value,
    commands: []const Value,
    mode: []const u8,
    options: Value,
    subagent: Subagent,
    message: Message,
    other,
};

/// The call whose subagent sent an update: Claude Code's adapter stamps
/// each of a subagent's updates with the id of the Task call that started it.
pub fn parentOf(u: ?Value) ?[]const u8 {
    return json.str(json.at(u, &.{ "_meta", "claudeCode" }), "parentToolUseId");
}

pub fn parseUpdate(a: std.mem.Allocator, u: ?Value) Update {
    const kind = json.strOr(u, "sessionUpdate", "");
    const content = json.get(u, "content");
    const text = json.strOr(content, "text", "");
    const eq = std.mem.eql;
    if (eq(u8, kind, "user_message_chunk")) {
        if (eq(u8, json.strOr(content, "type", ""), "image"))
            return .{ .user_image = .{ .mime = json.strOr(content, "mimeType", ""), .data = json.strOr(content, "data", "") } };
        return .{ .user_text = text };
    }
    if (eq(u8, kind, "agent_message_chunk")) {
        if (eq(u8, json.strOr(content, "type", ""), "image"))
            return .{ .agent_image = .{ .mime = json.strOr(content, "mimeType", "image/png"), .data = json.strOr(content, "data", "") } };
        return if (isNotice(text)) .{ .notice = text } else .{ .text = text };
    }
    if (eq(u8, kind, "agent_thought_chunk")) return .{ .thought = text };
    if (eq(u8, kind, "tool_call")) return .{ .tool_call = parseToolCall(a, u) };
    if (eq(u8, kind, "tool_call_update")) {
        const parts = json.get(u, "content");
        return .{ .tool_change = .{
            .id = json.strOr(u, "toolCallId", ""),
            .status = json.str(u, "status"),
            .title = json.str(u, "title"),
            .kind = json.str(u, "kind"),
            .input = json.get(u, "rawInput"),
            .diff = if (parts != null) firstDiff(json.array(u, "content")) else null,
            .output = if (parts != null) joinText(a, json.array(u, "content")) else null,
            .location = firstLocation(u),
        } };
    }
    if (eq(u8, kind, "session_info_update")) {
        const meta = json.at(u, &.{ "_meta", "fx" });
        if (json.has(meta, "modelResponseRecovery")) {
            const r = json.get(meta, "modelResponseRecovery") orelse return .{ .recovery = null };
            return .{ .recovery = .{ .state = json.strOr(r, "state", ""), .attempt = json.int(r, "attempt") orelse 0, .message = json.strOr(r, "message", "") } };
        }
        if (json.str(u, "title")) |t| return .{ .title = t };
        return .other;
    }
    if (eq(u8, kind, "usage_update")) return .{ .usage = .{
        .used = @intCast(@max(0, json.int(u, "used") orelse 0)),
        .size = @intCast(@max(0, json.int(u, "size") orelse 0)),
    } };
    if (eq(u8, kind, "plan")) return .{ .plan = json.array(u, "entries") };
    if (eq(u8, kind, "subagent_update")) {
        const st = json.get(u, "state");
        return .{ .subagent = .{
            .id = json.strOr(u, "sessionId", ""),
            .title = json.str(u, "title"),
            .description = json.str(u, "description"),
            .state = json.str(st, "state") orelse json.str(st, "stopReason") orelse if (st != null and st.? == .string) st.?.string else null,
        } };
    }
    if (eq(u8, kind, "session_message")) return .{ .message = .{
        .from = json.strOr(u, "senderSessionId", ""),
        .to = json.strOr(u, "recipientSessionId", ""),
        .text = blocksText(a, content) orelse "",
    } };
    if (eq(u8, kind, "available_commands_update")) return .{ .commands = json.array(u, "availableCommands") };
    if (eq(u8, kind, "current_mode_update")) return .{ .mode = json.strOr(u, "currentModeId", json.strOr(u, "modeId", "")) };
    if (eq(u8, kind, "config_option_update") or eq(u8, kind, "config_options_update")) {
        if (json.get(u, "configOptions")) |o| return .{ .options = o };
    }
    return .other;
}

pub fn parseToolCall(a: std.mem.Allocator, call: ?Value) ToolCall {
    return .{
        .id = json.strOr(call, "toolCallId", ""),
        .name = json.strOr(call, "name", ""),
        .title = json.strOr(call, "title", ""),
        .kind = json.strOr(call, "kind", ""),
        .status = json.strOr(call, "status", "pending"),
        .input = json.get(call, "rawInput"),
        .diff = firstDiff(json.array(call, "content")),
        .output = joinText(a, json.array(call, "content")),
        .location = firstLocation(call),
    };
}

fn firstDiff(parts: []const Value) ?Diff {
    for (parts) |p| if (std.mem.eql(u8, json.strOr(p, "type", ""), "diff")) {
        return .{ .path = json.strOr(p, "path", ""), .old = json.str(p, "oldText"), .new = json.strOr(p, "newText", "") };
    };
    return null;
}

fn firstLocation(call: ?Value) ?[]const u8 {
    for (json.array(call, "locations")) |l| if (json.str(l, "path")) |p| return p;
    return null;
}

/// The text of a content block, or of a list of them, joined.
fn blocksText(a: std.mem.Allocator, v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    if (x != .array) return json.str(x, "text");
    var out: std.ArrayList(u8) = .empty;
    for (x.array.items) |b| if (json.str(b, "text") orelse json.str(json.get(b, "content"), "text")) |t| {
        if (out.items.len > 0) out.append(a, '\n') catch {};
        out.appendSlice(a, t) catch {};
    };
    return if (out.items.len > 0) out.items else null;
}

/// The text of a call's content, joined; null when there is none.
fn joinText(a: std.mem.Allocator, parts: []const Value) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var any = false;
    for (parts) |p| {
        const inner = json.get(p, "content");
        if (json.str(inner, "text")) |t| {
            any = true;
            out.appendSlice(a, t) catch {};
        }
    }
    return if (any) out.items else null;
}

/// fx's notes on its own context, not part of the answer.
pub fn isNotice(text: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var any = false;
    while (lines.next()) |l| {
        if (std.mem.trim(u8, l, " \r\t").len == 0) continue;
        any = true;
        if (!std.mem.startsWith(u8, l, "[context] ") and !std.mem.startsWith(u8, l, "skill discovery warning:")) return false;
    }
    return any;
}

pub const PermissionOption = struct {
    id: []const u8,
    name: []const u8,
    kind: []const u8,
};

pub fn permissionOptions(a: std.mem.Allocator, params: ?Value) []PermissionOption {
    const list = json.array(params, "options");
    const out = a.alloc(PermissionOption, list.len) catch return &.{};
    for (list, out) |o, *p| p.* = .{ .id = json.strOr(o, "optionId", ""), .name = json.strOr(o, "name", ""), .kind = json.strOr(o, "kind", "") };
    return out;
}

// ---------------------------------------------------------------------------
// A session's options: its model, mode, thinking and the rest.

pub const Choice = struct {
    value: []const u8,
    name: []const u8,
    description: []const u8 = "",
};

/// How an option is set: ACP's config options, or the older
/// `session/set_model` and `session/set_mode`.
pub const Via = enum { config, model, mode };

pub const ConfigOption = struct {
    id: []const u8,
    name: []const u8,
    /// "model", "mode", "thought_level" or "" (from ACP's `category`, or
    /// from the id where there is none).
    category: []const u8,
    current: []const u8,
    choices: []Choice,
    via: Via = .config,
};

pub const Options = struct {
    arena: std.heap.ArenaAllocator,
    list: []ConfigOption = &.{},

    pub fn empty(gpa: std.mem.Allocator) Options {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(o: *Options) void {
        o.arena.deinit();
    }

    /// An option by its id or, failing that, its category.
    pub fn find(o: *const Options, key: []const u8) ?*ConfigOption {
        for (o.list) |*x| if (std.mem.eql(u8, x.id, key)) return x;
        for (o.list) |*x| if (std.mem.eql(u8, x.category, key)) return x;
        return null;
    }

    pub fn current(o: *const Options, key: []const u8) ?[]const u8 {
        const x = o.find(key) orelse return null;
        return x.current;
    }

    /// Marks `value` as the current choice of `key`, as the agent will.
    pub fn setCurrent(o: *Options, key: []const u8, value: []const u8) void {
        const x = o.find(key) orelse return;
        x.current = o.arena.allocator().dupe(u8, value) catch return;
    }
};

/// Reads a session's options from a reply to `session/new`,
/// `session/load` or `session/set_config_option`: ACP's `configOptions`,
/// or else the older `models` and `modes`.
pub fn parseOptions(gpa: std.mem.Allocator, result: ?Value) Options {
    var o = Options.empty(gpa);
    const a = o.arena.allocator();
    var list: std.ArrayList(ConfigOption) = .empty;
    if (json.get(result, "configOptions")) |opts| if (opts == .array) {
        for (opts.array.items) |x| {
            const id = json.strOr(x, "id", "");
            var choices: std.ArrayList(Choice) = .empty;
            for (json.array(x, "options")) |c| {
                // Grouped choices hold their own list.
                if (json.get(c, "options")) |inner| if (inner == .array) {
                    for (inner.array.items) |ic| choices.append(a, choice(a, ic)) catch {};
                    continue;
                };
                choices.append(a, choice(a, c)) catch {};
            }
            list.append(a, .{
                .id = a.dupe(u8, id) catch "",
                .name = a.dupe(u8, json.strOr(x, "name", id)) catch "",
                .category = a.dupe(u8, json.str(x, "category") orelse categoryOf(id)) catch "",
                .current = a.dupe(u8, currentOf(x)) catch "",
                .choices = choices.items,
            }) catch {};
        }
    };
    const has = struct {
        fn f(l: []const ConfigOption, cat: []const u8) bool {
            for (l) |x| if (std.mem.eql(u8, x.category, cat) or std.mem.eql(u8, x.id, cat)) return true;
            return false;
        }
    }.f;
    if (!has(list.items, "model")) if (json.get(result, "models")) |m| {
        var choices: std.ArrayList(Choice) = .empty;
        for (json.array(m, "availableModels")) |c| choices.append(a, .{
            .value = a.dupe(u8, json.strOr(c, "modelId", "")) catch "",
            .name = a.dupe(u8, json.strOr(c, "name", json.strOr(c, "modelId", ""))) catch "",
            .description = a.dupe(u8, json.strOr(c, "description", "")) catch "",
        }) catch {};
        if (choices.items.len > 0) list.append(a, .{ .id = "model", .name = "Model", .category = "model", .current = a.dupe(u8, json.strOr(m, "currentModelId", "")) catch "", .choices = choices.items, .via = .model }) catch {};
    };
    if (!has(list.items, "mode") and !modesAreThinking(list.items, json.get(result, "modes"))) if (json.get(result, "modes")) |m| {
        var choices: std.ArrayList(Choice) = .empty;
        for (json.array(m, "availableModes")) |c| choices.append(a, .{
            .value = a.dupe(u8, json.strOr(c, "id", "")) catch "",
            .name = a.dupe(u8, json.strOr(c, "name", json.strOr(c, "id", ""))) catch "",
            .description = a.dupe(u8, json.strOr(c, "description", "")) catch "",
        }) catch {};
        if (choices.items.len > 0) list.append(a, .{ .id = "mode", .name = "Mode", .category = "mode", .current = a.dupe(u8, json.strOr(m, "currentModeId", "")) catch "", .choices = choices.items, .via = .mode }) catch {};
    };
    o.list = list.items;
    return o;
}

/// Some adapters (pi's) list the thinking levels again as modes: those are
/// not permission modes, and the thinking option already shows them.
fn modesAreThinking(list: []const ConfigOption, modes: ?Value) bool {
    var thinking: ?*const ConfigOption = null;
    for (list) |*x| if (std.mem.eql(u8, x.category, "thought_level")) {
        thinking = x;
    };
    const t = thinking orelse return false;
    const avail = json.array(modes, "availableModes");
    if (avail.len == 0) return false;
    for (avail) |m| {
        const id = json.strOr(m, "id", "");
        var found = false;
        for (t.choices) |ch| if (std.mem.eql(u8, ch.value, id)) {
            found = true;
        };
        if (!found) return false;
    }
    return true;
}

fn choice(a: std.mem.Allocator, c: Value) Choice {
    const v = json.strOr(c, "value", json.strOr(c, "id", ""));
    return .{
        .value = a.dupe(u8, v) catch "",
        .name = a.dupe(u8, json.strOr(c, "name", v)) catch "",
        .description = a.dupe(u8, json.strOr(c, "description", "")) catch "",
    };
}

fn currentOf(x: Value) []const u8 {
    const v = json.get(x, "currentValue") orelse return "";
    return switch (v) {
        .string => |s| s,
        .bool => |b| if (b) "on" else "off",
        else => "",
    };
}

fn categoryOf(id: []const u8) []const u8 {
    const eq = std.mem.eql;
    if (eq(u8, id, "model")) return "model";
    if (eq(u8, id, "mode")) return "mode";
    if (eq(u8, id, "thinking") or eq(u8, id, "reasoning") or eq(u8, id, "effort") or eq(u8, id, "thought_level")) return "thought_level";
    return "";
}

pub fn isOn(value: []const u8) bool {
    return std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "true");
}

// ---------------------------------------------------------------------------
// Capabilities, from the reply to `initialize`.

pub const Capabilities = struct {
    load: bool = false,
    list: bool = false,
    /// `session/delete`: the agent forgets a session, its history too.
    delete: bool = false,
    images: bool = false,
    mcp_http: bool = false,
    mcp_sse: bool = false,
    version: []const u8 = "",
    name: []const u8 = "",
    /// The ways to sign in the agent offers, by id and name.
    auth: []const [2][]const u8 = &.{},
};

pub fn parseCapabilities(a: std.mem.Allocator, result: ?Value) Capabilities {
    const caps = json.get(result, "agentCapabilities");
    var auth: std.ArrayList([2][]const u8) = .empty;
    for (json.array(result, "authMethods")) |m| auth.append(a, .{
        a.dupe(u8, json.strOr(m, "id", "")) catch "",
        a.dupe(u8, json.strOr(m, "name", "")) catch "",
    }) catch {};
    const sess = json.get(caps, "sessionCapabilities");
    return .{
        .load = json.boolean(caps, "loadSession"),
        .list = json.has(sess, "list") or json.has(caps, "listSessions"),
        .delete = json.has(sess, "delete"),
        .images = json.boolean(json.get(caps, "promptCapabilities"), "image"),
        .mcp_http = json.boolean(json.get(caps, "mcpCapabilities"), "http"),
        .mcp_sse = json.boolean(json.get(caps, "mcpCapabilities"), "sse"),
        .version = a.dupe(u8, json.strOr(json.get(result, "agentInfo"), "version", "")) catch "",
        .name = a.dupe(u8, json.strOr(json.get(result, "agentInfo"), "title", json.strOr(json.get(result, "agentInfo"), "name", ""))) catch "",
        .auth = auth.items,
    };
}

test "a tool call and its update" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(Value, aa,
        \\{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Running","kind":"execute","status":"pending","rawInput":{"command":"ls"}}
    , .{});
    const u = parseUpdate(aa, v);
    try std.testing.expectEqualStrings("c1", u.tool_call.id);
    try std.testing.expectEqualStrings("ls", json.str(u.tool_call.input, "command").?);
    const w = try std.json.parseFromSliceLeaky(Value, aa,
        \\{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"a.txt\n"}},{"type":"diff","path":"/x","oldText":"a","newText":"b"}]}
    , .{});
    const c = parseUpdate(aa, w).tool_change;
    try std.testing.expectEqualStrings("completed", c.status.?);
    try std.testing.expectEqualStrings("a.txt\n", c.output.?);
    try std.testing.expectEqualStrings("b", c.diff.?.new);
}

test "options from config options or from models and modes" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"sessionId":"s","models":{"currentModelId":"m1","availableModels":[{"modelId":"m1","name":"One"},{"modelId":"m2","name":"Two"}]},"modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Ask"},{"id":"bypassPermissions","name":"Full"}]}}
    , .{});
    var o = parseOptions(a, v);
    defer o.deinit();
    try std.testing.expectEqualStrings("m1", o.current("model").?);
    try std.testing.expectEqual(Via.mode, o.find("mode").?.via);
    try std.testing.expectEqual(@as(usize, 2), o.find("mode").?.choices.len);
    const w = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"x","options":[{"group":"g","name":"G","options":[{"value":"x","name":"X"}]}]}]}
    , .{});
    var p = parseOptions(a, w);
    defer p.deinit();
    try std.testing.expectEqualStrings("X", p.find("model").?.choices[0].name);
}

test "thinking levels listed again as modes are not a mode" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"modes":{"currentModeId":"medium","availableModes":[{"id":"low","name":"Thinking: low"},{"id":"medium","name":"Thinking: medium"}]},"configOptions":[{"id":"thought_level","name":"Thinking","category":"thought_level","currentValue":"medium","options":[{"value":"low","name":"Low"},{"value":"medium","name":"Medium"}]}]}
    , .{});
    var o = parseOptions(a, v);
    defer o.deinit();
    try std.testing.expect(o.find("mode") == null);
    try std.testing.expectEqualStrings("medium", o.current("thought_level").?);
}

test "notices are fx's notes, not text" {
    try std.testing.expect(isNotice("[context] skill catalog shortened\n"));
    try std.testing.expect(!isNotice("[x] done"));
}
