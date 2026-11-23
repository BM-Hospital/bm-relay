//! A session's agent: starting its process, greeting it, opening the
//! session in it (new, or loaded again), the updates and questions it
//! sends, setting its options, and putting idle ones down. One process
//! per session, as fx-ui runs fx: a session's agent, model and mode are
//! its own.
const std = @import("std");
const app_mod = @import("app.zig");
const state = @import("state.zig");
const rpc = @import("../acp/rpc.zig");
const proto = @import("../acp/proto.zig");
const json = @import("../acp/json.zig");
const transcript = @import("../model/transcript.zig");
const tools = @import("../model/tools.zig");
const turns = @import("turns.zig");
const npx = @import("../host/npx.zig");

const App = app_mod.App;
const Session = state.Session;
const Workspace = state.Workspace;

pub const version = "0.1.0";

pub const Open = union(enum) {
    new,
    /// Loads the session of this id again: its turns replay.
    load,
};

/// What a request carries to its callback: which session, and why.
const Op = struct {
    a: *App,
    key: u64,
    open: Open = .new,
    /// The option being set, for `optionSet`.
    option: [64]u8 = undefined,
    option_len: usize = 0,

    fn make(a: *App, s: *Session, open: Open) *Op {
        const op = a.gpa.create(Op) catch @panic("out of memory");
        op.* = .{ .a = a, .key = s.key, .open = open };
        return op;
    }

    fn free(op: *Op) void {
        op.a.gpa.destroy(op);
    }

    /// The session, if it is still there and still on this connection.
    fn session(op: *Op, conn: *rpc.Conn) ?*Session {
        const s = op.a.byKey(op.key) orelse return null;
        return if (s.conn == conn) s else null;
    }
};

fn sessionOf(a: *App, conn: *rpc.Conn) ?*Session {
    for (a.workspaces.items) |w| for (w.sessions.items) |s| if (s.conn == conn) return s;
    return null;
}

/// Starts the agent of `s` in its folder and opens it there.
pub fn connect(a: *App, s: *Session, ws: *Workspace, open: Open) void {
    s.setError(null);
    if (s.conn) |c| c.stop();
    s.conn = null;
    const prof = a.store.agent(s.agent) orelse {
        s.setError(a.print("There is no agent named “{s}” in Settings.", .{s.agent}));
        return;
    };
    if (prof.command.len == 0) {
        s.setError(a.print("{s} has no command to start it. Set one in Settings → Agents.", .{prof.name}));
        return;
    }
    // An agent npx starts runs from npx's cache with node: npx would first
    // ask the registry for a newer version, a second or two each time.
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const argv = npx.direct(arena.allocator(), a.io, a.env, prof.command) orelse prof.command;
    npx.check(a.gpa, a.io, a.env, prof.command);
    const conn = rpc.Conn.start(a.gpa, a.io, .{ .argv = argv, .cwd = ws.path, .env = a.env }, .{ .ctx = a, .message = onMessage, .exited = onExited }) catch |e| {
        s.setError(startFailed(a, prof.name, argv[0], e));
        return;
    };
    s.conn = conn;
    s.opening = true;
    if (open == .load) {
        s.clearPermission();
        // A session it showed before keeps showing while it replays.
        s.dropReplay();
        if (s.thread.turns.items.len > 0) s.replay = .init(a.gpa) else s.thread.reset();
    }
    const fs = .{ .readTextFile = false, .writeTextFile = false };
    const info = .{ .name = "bm-agent", .title = "BM Coding Agent", .version = version };
    const cb: rpc.Callback = .{ .ctx = Op.make(a, s, open), .func = initialized };
    // Subagents shown: Codex's adapter then sends what they do, as sessions
    // of their own. Claude Code's would hide its Task calls in that form;
    // without it, it stamps a subagent's updates with the call instead.
    if (runsClaudeCode(prof.command))
        conn.request("initialize", .{ .protocolVersion = 1, .clientCapabilities = .{ .fs = fs, .terminal = false }, .clientInfo = info }, cb)
    else
        conn.request("initialize", .{ .protocolVersion = 1, .clientCapabilities = .{ .fs = fs, .terminal = false, .subagents = .{} }, .clientInfo = info }, cb);
}

/// Why an agent's command did not start, said so the user can fix it.
pub fn startFailed(a: *App, name: []const u8, exe: []const u8, e: anyerror) []const u8 {
    if (e == error.FileNotFound) {
        const base = std.fs.path.stem(exe);
        if (std.mem.eql(u8, base, "npx") or std.mem.eql(u8, base, "node") or std.mem.eql(u8, base, "npm"))
            return a.print("{s} runs on Node.js, which is not installed (or not on PATH). Install it from nodejs.org, then restart the app.", .{name});
        return a.print("Could not start {s}: `{s}` is not installed, or not on PATH. Install it, or set its command in Settings → Agents.", .{ name, exe });
    }
    return a.print("Could not start {s} (`{s}`): {s}", .{ name, exe, @errorName(e) });
}

pub fn runsClaudeCode(command: []const []const u8) bool {
    for (command) |w| if (std.mem.indexOf(u8, w, "claude-agent-acp") != null or std.mem.indexOf(u8, w, "claude-code-acp") != null) return true;
    return false;
}

fn initialized(ctx: ?*anyopaque, conn: *rpc.Conn, reply: rpc.Reply) void {
    const op: *Op = @ptrCast(@alignCast(ctx.?));
    const a = op.a;
    const s = op.session(conn) orelse return op.free();
    switch (reply) {
        .gone => return op.free(),
        .err => |e| {
            op.free();
            fail(a, s, a.print("The agent did not start: {s}", .{e}));
            return;
        },
        .ok => |v| {
            _ = s.caps_arena.reset(.free_all);
            s.caps = proto.parseCapabilities(s.caps_arena.allocator(), v);
        },
    }
    const ws = a.workspaceOf(s) orelse return op.free();
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const servers = mcpServers(a, arena.allocator(), s.caps);
    switch (op.open) {
        .load => {
            const id = s.id orelse return op.free();
            if (!s.caps.load) {
                op.free();
                s.opening = false;
                s.loaded = true;
                s.setError(a.print("{s} can't open past sessions, so this one can't be shown. Start a new session to go on.", .{a.agentName(s.agent)}));
                a.redraw();
                return;
            }
            conn.request("session/load", .{ .sessionId = id, .cwd = ws.path, .mcpServers = servers }, .{ .ctx = op, .func = opened });
        },
        .new => {
            // No session yet: the agent makes one at the first prompt
            // (`create`), so sessions nobody wrote in are not kept by it.
            op.free();
            s.opening = false;
            showOptions(a, s);
            if (a.first_prompt) |p| {
                a.first_prompt = null;
                defer a.gpa.free(p);
                if (a.active == s) _ = turns.submit(a, p);
            }
            a.redraw();
        },
    }
}

/// The options the agent's last new session offered, with the defaults
/// chosen since: what the composer shows before this one exists.
fn showOptions(a: *App, s: *Session) void {
    const text = a.store.agentOptions(s.agent) orelse return;
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(json.Value, arena.allocator(), text, .{}) catch return;
    s.setOptions(proto.parseOptions(a.gpa, v));
    for ([_][]const u8{ "model", "mode", "thought_level" }) |cat| {
        const want = a.store.default(a.print("{s}.{s}", .{ s.agent, cat })) orelse continue;
        const o = s.option(cat) orelse continue;
        for (o.choices) |c| if (std.mem.eql(u8, c.value, want)) {
            s.options.setCurrent(o.id, want);
            break;
        };
    }
}

/// Asks the agent for the session of `s`, which has none yet: its first
/// prompt is waiting in the queue, and goes once the session is made.
pub fn create(a: *App, s: *Session) void {
    if (s.id != null or s.opening) return;
    const conn = s.conn orelse return;
    const ws = a.workspaceOf(s) orelse return;
    s.opening = true;
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const servers = mcpServers(a, arena.allocator(), s.caps);
    const op = Op.make(a, s, .new);
    const text = std.mem.trim(u8, a.store.data.instructions, " \r\n\t");
    const Params = struct {
        cwd: []const u8,
        mcpServers: json.Value,
        systemPrompt: ?[]const struct { type: []const u8 = "text", text: []const u8 } = null,
        _meta: ?json.Value = null,
    };
    var p: Params = .{ .cwd = ws.path, .mcpServers = servers };
    if (text.len > 0) {
        if (std.mem.eql(u8, s.agent, "fx")) {
            p.systemPrompt = &.{.{ .text = text }};
        } else {
            p._meta = metaPrompt(arena.allocator(), text);
        }
    }
    conn.request("session/new", p, .{ .ctx = op, .func = opened });
    a.redraw();
}

/// `_meta.systemPrompt.append`, which Claude Code's adapter reads.
fn metaPrompt(a: std.mem.Allocator, text: []const u8) ?json.Value {
    var inner: std.json.ObjectMap = .empty;
    inner.put(a, "append", .{ .string = text }) catch return null;
    var outer: std.json.ObjectMap = .empty;
    outer.put(a, "systemPrompt", .{ .object = inner }) catch return null;
    return .{ .object = outer };
}

/// The MCP servers set up in Settings, as ACP passes them to a session.
fn mcpServers(a: *App, ar: std.mem.Allocator, caps: proto.Capabilities) json.Value {
    var list = std.json.Array.init(ar);
    for (a.store.data.mcp) |m| {
        if (m.off) continue;
        var o: std.json.ObjectMap = .empty;
        o.put(ar, "name", .{ .string = m.name }) catch continue;
        if (std.mem.eql(u8, m.kind, "stdio")) {
            o.put(ar, "command", .{ .string = m.command }) catch continue;
            var args = std.json.Array.init(ar);
            for (m.args) |x| args.append(.{ .string = x }) catch {};
            o.put(ar, "args", .{ .array = args }) catch continue;
            o.put(ar, "env", pairs(ar, m.env)) catch continue;
        } else {
            if (std.mem.eql(u8, m.kind, "http") and !caps.mcp_http) continue;
            if (std.mem.eql(u8, m.kind, "sse") and !caps.mcp_sse) continue;
            o.put(ar, "type", .{ .string = m.kind }) catch continue;
            o.put(ar, "url", .{ .string = m.url }) catch continue;
            o.put(ar, "headers", pairs(ar, m.headers)) catch continue;
        }
        list.append(.{ .object = o }) catch {};
    }
    return .{ .array = list };
}

fn pairs(ar: std.mem.Allocator, kvs: anytype) json.Value {
    var list = std.json.Array.init(ar);
    for (kvs) |kv| {
        var o: std.json.ObjectMap = .empty;
        o.put(ar, "name", .{ .string = kv.key }) catch continue;
        o.put(ar, "value", .{ .string = kv.value }) catch continue;
        list.append(.{ .object = o }) catch {};
    }
    return .{ .array = list };
}

fn opened(ctx: ?*anyopaque, conn: *rpc.Conn, reply: rpc.Reply) void {
    const op: *Op = @ptrCast(@alignCast(ctx.?));
    defer op.free();
    const a = op.a;
    const s = op.session(conn) orelse return;
    s.opening = false;
    const v = switch (reply) {
        .gone => return s.dropReplay(),
        .err => |e| return fail(a, s, explain(a, s, e)),
        .ok => |v| v,
    };
    s.setOptions(proto.parseOptions(a.gpa, v));
    keepModels(a, s);
    if (op.open == .new) if (json.stringify(a.gpa, v)) |text| {
        defer a.gpa.free(text);
        a.store.setAgentOptions(s.agent, text);
    } else |_| {};
    switch (op.open) {
        .load => {
            s.takeReplay();
            s.thread.settle(a.now());
            s.loaded = true;
        },
        .new => {
            const id = json.str(v, "sessionId") orelse return fail(a, s, "The agent gave the session no id.");
            // Kept in the store from its first prompt: an empty one is not listed.
            s.setId(id);
            applyDefaults(a, s);
            // The prompt that asked for it.
            _ = turns.sendNext(a, s);
        },
    }
    a.to_end = true;
    a.redraw();
}

/// Words for a failure to open a session, with what to do about it.
fn explain(a: *App, s: *Session, e: []const u8) []const u8 {
    const lower = std.ascii.allocLowerString(a.gpa, e) catch return e;
    defer a.gpa.free(lower);
    if (std.mem.indexOf(u8, lower, "auth") != null or std.mem.indexOf(u8, lower, "login") != null or std.mem.indexOf(u8, lower, "sign in") != null) {
        const how = if (std.mem.eql(u8, s.agent, "claude")) "run `claude` in a terminal and sign in" else if (std.mem.eql(u8, s.agent, "codex")) "run `codex login` in a terminal" else if (std.mem.eql(u8, s.agent, "gemini")) "run `gemini` in a terminal and sign in" else if (std.mem.eql(u8, s.agent, "pi")) "set up a provider in `pi` (see `pi auth`)" else if (std.mem.eql(u8, s.agent, "opencode")) "run `opencode auth` in a terminal and add a provider" else "sign in with its own command line";
        return a.print("{s} needs you to sign in first: {s}, then start a new session. ({s})", .{ a.agentName(s.agent), how, e });
    }
    return a.print("The session did not open: {s}", .{e});
}

fn fail(a: *App, s: *Session, why: []const u8) void {
    s.opening = false;
    s.dropReplay();
    s.setError(why);
    if (s.conn) |c| c.stop();
    s.conn = null;
    a.redraw();
}

/// Remembers the models the agent offers, for the model menu.
fn keepModels(a: *App, s: *Session) void {
    const m = s.option("model") orelse return;
    if (m.choices.len == 0) return;
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const values = arena.allocator().alloc([]const u8, m.choices.len) catch return;
    const names = arena.allocator().alloc([]const u8, m.choices.len) catch return;
    for (m.choices, values, names) |c, *v, *n| {
        v.* = c.value;
        n.* = c.name;
    }
    a.store.setModels(s.agent, values, names);
}

/// Sets the options the user chose as defaults where the new session's
/// differ: its model, mode and thinking.
fn applyDefaults(a: *App, s: *Session) void {
    for ([_][]const u8{ "model", "mode", "thought_level" }) |cat| {
        const want = a.store.default(a.print("{s}.{s}", .{ s.agent, cat })) orelse continue;
        const o = s.option(cat) orelse continue;
        if (std.mem.eql(u8, o.current, want)) continue;
        for (o.choices) |c| if (std.mem.eql(u8, c.value, want)) {
            setOption(a, s, cat, want);
            break;
        };
    }
}

/// Sets one of a session's options, as ACP has it set.
pub fn setOption(a: *App, s: *Session, key: []const u8, value: []const u8) void {
    const o = s.option(key) orelse return;
    const id = s.id orelse {
        // No session yet: the choice is the agent's default, which the
        // session gets as it is made (`applyDefaults`).
        a.store.setDefault(a.print("{s}.{s}", .{ s.agent, o.category }), value);
        a.store.save();
        s.options.setCurrent(o.id, value);
        return a.redraw();
    };
    const conn = s.conn orelse return;
    const op = Op.make(a, s, .new);
    const n = @min(o.id.len, op.option.len);
    @memcpy(op.option[0..n], o.id[0..n]);
    op.option_len = n;
    const cb: rpc.Callback = .{ .ctx = op, .func = optionSet };
    switch (o.via) {
        .config => conn.request("session/set_config_option", .{ .sessionId = id, .configId = o.id, .value = value }, cb),
        .model => conn.request("session/set_model", .{ .sessionId = id, .modelId = value }, cb),
        .mode => conn.request("session/set_mode", .{ .sessionId = id, .modeId = value }, cb),
    }
    s.options.setCurrent(o.id, value);
    a.redraw();
}

fn optionSet(ctx: ?*anyopaque, conn: *rpc.Conn, reply: rpc.Reply) void {
    const op: *Op = @ptrCast(@alignCast(ctx.?));
    defer op.free();
    const s = op.session(conn) orelse return;
    switch (reply) {
        .gone => {},
        .err => |e| s.setError(op.a.print("Could not change {s}: {s}", .{ op.option[0..op.option_len], e })),
        .ok => |v| if (json.get(v, "configOptions") != null) {
            s.setOptions(proto.parseOptions(op.a.gpa, v));
            keepModels(op.a, s);
        },
    }
    op.a.redraw();
}

// ---------------------------------------------------------------------------
// What the agent sends of its own accord.

fn onMessage(ctx: *anyopaque, conn: *rpc.Conn, msg: rpc.Incoming) void {
    const a: *App = @ptrCast(@alignCast(ctx));
    const s = sessionOf(a, conn) orelse {
        if (msg.id) |id| conn.respondError(id, -32603, "No such session");
        return;
    };
    const eq = std.mem.eql;
    if (eq(u8, msg.method, "session/update")) return update(a, s, msg.params);
    if (eq(u8, msg.method, "session/request_permission")) {
        if (msg.id) |id| return permission(a, s, conn, id, msg.params);
        return;
    }
    if (msg.id) |id| conn.respondError(id, -32601, "Method not found");
}

fn update(a: *App, s: *Session, params: ?json.Value) void {
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const raw = json.get(params, "update");
    const u = proto.parseUpdate(arena.allocator(), raw);
    // A subagent's: stamped with the call that started it (Claude Code), or
    // sent under its own session's id (subagents run as sessions).
    const from = json.str(params, "sessionId");
    const child = if (from) |f| (if (s.id) |id| !std.mem.eql(u8, f, id) else false) else false;
    if (proto.parentOf(raw) orelse if (child) from else null) |parent| {
        s.target().applyUnder(parent, u, a.now());
        a.redraw();
        return;
    }
    switch (u) {
        .user_text => |text| if (s.steering.items.len > 0) {
            var at: usize = 0;
            for (s.steering.items, 0..) |x, i| if (std.mem.eql(u8, x, text)) {
                at = i;
                break;
            };
            a.gpa.free(s.steering.orderedRemove(at));
        },
        .mode => |m| s.options.setCurrent("mode", m),
        .options => |v| {
            var o: std.json.ObjectMap = .empty;
            o.put(arena.allocator(), "configOptions", v) catch {};
            s.setOptions(proto.parseOptions(a.gpa, .{ .object = o }));
        },
        .title => |t| if (s.id) |id| {
            a.store.putSession(.{ .id = id, .agent = "", .cwd = "", .title = t });
            a.store.save();
        },
        .notice => |n| a.settings.noteSkillWarnings(a.gpa, n),
        else => {},
    }
    s.target().apply(u, a.now());
    // A replay off screen moves nothing.
    if (s.replay != null) return;
    a.to_end = true;
    a.redraw();
}

fn permission(a: *App, s: *Session, conn: *rpc.Conn, id: json.Value, params: ?json.Value) void {
    if (s.permission) |old| conn.respond(old.request, .{ .outcome = .{ .outcome = "cancelled" } });
    s.clearPermission();
    const p = a.gpa.create(state.Pending) catch return conn.respondError(id, -32603, "Out of memory");
    p.* = .{ .arena = .init(a.gpa), .request = .null, .tool = undefined, .options = &.{}, .preview = null };
    const ar = p.arena.allocator();
    p.request = json.clone(ar, id) catch .null;
    const call = proto.parseToolCall(ar, json.get(params, "toolCall"));
    // The call as the transcript knows it fills in what the request leaves out.
    const known = s.thread.findTool(call.id);
    p.tool = .{
        .id = ar.dupe(u8, call.id) catch "",
        .name = ar.dupe(u8, if (call.name.len > 0) call.name else if (known) |k| k.name else "") catch "",
        .title = ar.dupe(u8, if (call.title.len > 0) call.title else if (known) |k| k.title else "") catch "",
        .kind = ar.dupe(u8, if (call.kind.len > 0) call.kind else if (known) |k| k.kind else "") catch "",
        .status = "pending",
        .input = if (call.input) |v| json.clone(ar, v) catch null else if (known) |k| k.input else null,
        .diff = if (call.diff) |d| .{ .path = ar.dupe(u8, d.path) catch "", .old = if (d.old) |o| ar.dupe(u8, o) catch null else null, .new = ar.dupe(u8, d.new) catch "" } else if (known) |k| k.diff else null,
        .location = if (call.location) |l| ar.dupe(u8, l) catch null else if (known) |k| k.location else null,
    };
    const opts = proto.permissionOptions(ar, params);
    for (opts) |*o| o.* = .{ .id = ar.dupe(u8, o.id) catch "", .name = ar.dupe(u8, o.name) catch "", .kind = ar.dupe(u8, o.kind) catch "" };
    p.options = opts;
    const cwd = if (a.workspaceOf(s)) |w| w.path else "";
    p.preview = tools.editPreview(ar, a.io, &p.tool, cwd);
    s.permission = p;
    a.notify(a.label(s), tools.question(&p.tool));
    a.to_end = true;
    a.redraw();
}

fn onExited(ctx: *anyopaque, conn: *rpc.Conn, why: []const u8) void {
    const a: *App = @ptrCast(@alignCast(ctx));
    const s = sessionOf(a, conn) orelse return;
    s.conn = null;
    s.opening = false;
    s.clearPermission();
    s.dropReplay();
    const msg = a.print("{s} stopped: {s}", .{ a.agentName(s.agent), why });
    if (s.thread.running()) s.thread.finish(.{ .err = msg }, a.now());
    s.setError(msg);
    a.redraw();
}

/// Answers the waiting approval with the option of `kind`, or cancels it.
pub fn answerPermission(a: *App, s: *Session, kind: ?[]const u8) void {
    const p = s.permission orelse return;
    const conn = s.conn orelse return s.clearPermission();
    const chosen: ?[]const u8 = if (kind) |k| p.optionOf(k) else null;
    if (chosen) |opt| {
        conn.respond(p.request, .{ .outcome = .{ .outcome = "selected", .optionId = opt } });
        if (std.mem.eql(u8, kind.?, "allow_always")) {
            var buf: [256]u8 = undefined;
            const g = tools.grant(&buf, &p.tool);
            var dup = false;
            for (s.grants.items) |x| if (std.mem.eql(u8, x, g)) {
                dup = true;
            };
            if (!dup) s.grants.append(a.gpa, a.gpa.dupe(u8, g) catch return) catch {};
        }
    } else conn.respond(p.request, .{ .outcome = .{ .outcome = "cancelled" } });
    s.clearPermission();
    a.redraw();
}

// ---------------------------------------------------------------------------
// Putting agents down and picking them up.

/// Stops the agents of sessions nobody is looking at, that do nothing and
/// can be loaded again: their turns replay when they are opened.
pub fn restIdle(a: *App, keep: [2]?*Session) void {
    for (a.workspaces.items) |w| for (w.sessions.items) |s| {
        const conn = s.conn orelse continue;
        if (s == keep[0] or s == keep[1] or s == a.beside) continue;
        if (s.thread.running() or s.permission != null or s.tally != null or s.opening) continue;
        if (s.isEmpty() or s.id == null or !s.caps.load) continue;
        var recent = false;
        for (a.recent.items) |k| if (k == s.key) {
            recent = true;
        };
        if (recent) continue;
        conn.stop();
        s.conn = null;
        s.loaded = false;
    };
}

/// Stops every agent not running a turn, as the app quits.
pub fn stopAll(a: *App) void {
    for (a.workspaces.items) |w| for (w.sessions.items) |s| if (s.conn) |c| {
        c.stop();
        s.conn = null;
    };
}

/// Switches the active session to `model` of the agent `agent_id`. Within
/// its own agent the option changes; another agent needs another session.
pub fn pickModel(a: *App, agent_id: []const u8, model: []const u8) void {
    const s = a.active orelse return;
    a.store.setDefault(a.print("{s}.model", .{agent_id}), model);
    if (std.mem.eql(u8, s.agent, agent_id)) {
        a.store.save();
        return setOption(a, s, "model", model);
    }
    if (s.thread.running()) {
        s.setError("Stop this turn before switching to another agent.");
        return a.redraw();
    }
    a.store.data.agent = a.store.dupe(agent_id);
    a.store.save();
    const ws = a.workspaceOf(s) orelse return;
    if (s.isEmpty()) {
        s.setAgent(agent_id);
        if (s.id) |x| a.gpa.free(x);
        s.id = null;
        s.setOptions(.empty(a.gpa));
        connect(a, s, ws, .new);
    } else {
        @import("sessions.zig").newSessionIn(a, ws);
        a.toast(a.print("New session on {s}", .{a.agentName(agent_id)}));
    }
    a.redraw();
}

/// Reloads the session, as after its agent stopped: a new process, the
/// same session.
pub fn reload(a: *App, s: *Session) void {
    if (s.thread.running()) return;
    const ws = a.workspaceOf(s) orelse return;
    s.clearGrants();
    for (s.steering.items) |x| a.gpa.free(x);
    s.steering.clearRetainingCapacity();
    s.skipped = null;
    connect(a, s, ws, if (s.id != null) .load else .new);
}

test {
    _ = transcript;
}
