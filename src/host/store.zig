//! The app's own saved state, one JSON file: the folders, the sessions
//! started here, names given to them, defaults, the agents and MCP servers
//! the user set up. Read once at start, written whole on every change.
//! Its strings live in an arena: a change makes new slices and leaves the
//! old ones until the arena is compacted.
const std = @import("std");
const Io = std.Io;

pub const KV = struct { key: []const u8, value: []const u8 };

/// An ACP agent and how to start it.
pub const Agent = struct {
    id: []const u8,
    name: []const u8,
    command: []const []const u8,
    /// Set by the user to stop offering it.
    off: bool = false,
};

/// A session started here: enough to list it and open it again.
pub const Saved = struct {
    id: []const u8,
    agent: []const u8,
    cwd: []const u8,
    title: []const u8 = "",
    /// The name the user gave it.
    name: []const u8 = "",
    /// Milliseconds on the wall clock.
    updated: i64 = 0,
    added: usize = 0,
    removed: usize = 0,
    hidden: bool = false,
    /// The model it last ran on.
    model: []const u8 = "",
};

pub const Mcp = struct {
    name: []const u8,
    /// "stdio", "http" or "sse".
    kind: []const u8 = "stdio",
    command: []const u8 = "",
    args: []const []const u8 = &.{},
    url: []const u8 = "",
    env: []const KV = &.{},
    headers: []const KV = &.{},
    off: bool = false,
};

/// The models an agent offered, kept so the menu can list them before a
/// session of that agent runs.
pub const Models = struct {
    agent: []const u8,
    values: []const []const u8,
    names: []const []const u8,
};

pub const Data = struct {
    workspaces: []const []const u8 = &.{},
    sessions: []const Saved = &.{},
    defaults: []const KV = &.{},
    agents: []const Agent = &.{},
    mcp: []const Mcp = &.{},
    models: []const Models = &.{},
    /// Each agent's options as its last new session offered them (the JSON
    /// of `session/new`'s result): the composer shows them before a session
    /// exists, which is at the first prompt.
    agent_options: []const KV = &.{},
    instructions: []const u8 = "",
    mute: bool = false,
    /// The agent new sessions use.
    agent: []const u8 = "claude",
    /// The default agents this file has been offered: one added to the
    /// app later is offered once, and stays gone if the user removes it.
    known_agents: []const []const u8 = &.{},
    /// "system", "light" or "dark": dark, as the app first looked, until
    /// the user picks.
    theme: []const u8 = "dark",
    /// The accent's name (`tokens.Accent`).
    accent: []const u8 = "green",
    /// Every text scaled by it: 1 is as designed.
    text_size: f32 = 1,
    /// The sidebar's width in points, as last dragged.
    sidebar_width: f32 = 264,
};

pub const default_agents = [_]Agent{
    .{ .id = "claude", .name = "Claude Code", .command = &.{ "npx", "-y", "@agentclientprotocol/claude-agent-acp" } },
    .{ .id = "codex", .name = "Codex", .command = &.{ "npx", "-y", "@agentclientprotocol/codex-acp" } },
    .{ .id = "gemini", .name = "Gemini CLI", .command = &.{ "gemini", "--experimental-acp" } },
    .{ .id = "fx", .name = "fx", .command = &.{ "fx", "acp" } },
    // pi speaks its own RPC; pi-acp runs `pi --mode rpc` and speaks ACP.
    .{ .id = "pi", .name = "pi", .command = &.{ "npx", "-y", "pi-acp" } },
    .{ .id = "opencode", .name = "OpenCode", .command = &.{ "opencode", "acp" } },
};

/// Default commands of earlier versions: an agent still on one moves to
/// today's (a command the user changed is left as it is).
const retired = [_]struct { id: []const u8, command: []const []const u8 }{
    // Zed's adapter moved to the ACP organisation and kept up with Codex.
    .{ .id = "codex", .command = &.{ "npx", "-y", "@zed-industries/codex-acp" } },
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    path: ?[]const u8,
    data: Data = .{},

    pub fn init(gpa: std.mem.Allocator, io: Io, path: ?[]const u8) Store {
        return .{ .gpa = gpa, .io = io, .arena = .init(gpa), .path = path };
    }

    pub fn deinit(s: *Store) void {
        s.arena.deinit();
    }

    pub fn a(s: *Store) std.mem.Allocator {
        return s.arena.allocator();
    }

    pub fn load(s: *Store) void {
        defer s.offerNewAgents();
        const path = s.path orelse return;
        const bytes = std.Io.Dir.cwd().readFileAlloc(s.io, path, s.gpa, .limited(16 << 20)) catch return;
        defer s.gpa.free(bytes);
        s.data = std.json.parseFromSliceLeaky(Data, s.a(), bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch .{};
    }

    /// Adds the default agents this file has not seen yet, and moves those
    /// still on a default command since retired to the current one.
    fn offerNewAgents(s: *Store) void {
        if (s.data.agents.len == 0) {
            s.data.agents = &default_agents;
        } else {
            var list: std.ArrayList(Agent) = .empty;
            list.appendSlice(s.a(), s.data.agents) catch return;
            for (list.items) |*x| for (retired) |r| {
                if (!std.mem.eql(u8, x.id, r.id) or !sameList(x.command, r.command)) continue;
                for (default_agents) |d| if (std.mem.eql(u8, d.id, r.id)) {
                    x.command = d.command;
                };
            };
            for (default_agents) |d| {
                var seen = s.agent(d.id) != null;
                for (s.data.known_agents) |k| if (std.mem.eql(u8, k, d.id)) {
                    seen = true;
                };
                if (!seen) list.append(s.a(), d) catch {};
            }
            s.data.agents = list.items;
        }
        const ids = s.a().alloc([]const u8, default_agents.len) catch return;
        for (default_agents, ids) |d, *i| i.* = d.id;
        s.data.known_agents = ids;
    }

    pub fn save(s: *Store) void {
        const path = s.path orelse return;
        const text = std.json.Stringify.valueAlloc(s.gpa, s.data, .{ .whitespace = .indent_2 }) catch return;
        defer s.gpa.free(text);
        if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(s.io, dir) catch {};
        std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = path, .data = text }) catch |e| std.log.warn("save {s}: {s}", .{ path, @errorName(e) });
        // A long run leaves old slices behind: start again from the file.
        if (s.arena.queryCapacity() > 4 << 20) s.compact(text);
    }

    fn compact(s: *Store, text: []const u8) void {
        var fresh: std.heap.ArenaAllocator = .init(s.gpa);
        const data = std.json.parseFromSliceLeaky(Data, fresh.allocator(), text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            fresh.deinit();
            return;
        };
        s.arena.deinit();
        s.arena = fresh;
        s.data = data;
    }

    pub fn dupe(s: *Store, text: []const u8) []const u8 {
        return s.a().dupe(u8, text) catch "";
    }

    // Workspaces.

    pub fn addWorkspace(s: *Store, path: []const u8) void {
        for (s.data.workspaces) |w| if (std.mem.eql(u8, w, path)) return;
        s.data.workspaces = append([]const u8, s.a(), s.data.workspaces, s.dupe(path));
    }

    pub fn removeWorkspace(s: *Store, path: []const u8) void {
        var out: std.ArrayList([]const u8) = .empty;
        for (s.data.workspaces) |w| if (!std.mem.eql(u8, w, path)) out.append(s.a(), w) catch {};
        s.data.workspaces = out.items;
    }

    // Defaults: "model", "mode", "thinking" and the like, by agent:
    // "claude.model".

    pub fn default(s: *const Store, key: []const u8) ?[]const u8 {
        for (s.data.defaults) |kv| if (std.mem.eql(u8, kv.key, key)) return kv.value;
        return null;
    }

    pub fn setDefault(s: *Store, key: []const u8, value: ?[]const u8) void {
        var out: std.ArrayList(KV) = .empty;
        for (s.data.defaults) |kv| if (!std.mem.eql(u8, kv.key, key)) out.append(s.a(), kv) catch {};
        if (value) |v| out.append(s.a(), .{ .key = s.dupe(key), .value = s.dupe(v) }) catch {};
        s.data.defaults = out.items;
    }

    // Sessions.

    pub fn session(s: *const Store, id: []const u8) ?*const Saved {
        for (s.data.sessions) |*x| if (std.mem.eql(u8, x.id, id)) return x;
        return null;
    }

    /// Adds or changes a session's record; fields of `with` that are empty
    /// or zero keep what was there.
    pub fn putSession(s: *Store, with: Saved) void {
        var list: std.ArrayList(Saved) = .empty;
        list.appendSlice(s.a(), s.data.sessions) catch return;
        for (list.items) |*x| if (std.mem.eql(u8, x.id, with.id)) {
            if (with.agent.len > 0) x.agent = s.dupe(with.agent);
            if (with.cwd.len > 0) x.cwd = s.dupe(with.cwd);
            if (with.title.len > 0) x.title = s.dupe(with.title);
            if (with.updated != 0) x.updated = with.updated;
            if (with.model.len > 0) x.model = s.dupe(with.model);
            if (with.name.len > 0) x.name = s.dupe(with.name);
            s.data.sessions = list.items;
            return;
        };
        var n = with;
        n.id = s.dupe(with.id);
        n.agent = s.dupe(with.agent);
        n.cwd = s.dupe(with.cwd);
        n.title = s.dupe(with.title);
        n.model = s.dupe(with.model);
        n.name = s.dupe(with.name);
        list.append(s.a(), n) catch return;
        s.data.sessions = list.items;
    }

    /// A session's record to change in place (then `save`).
    pub fn sessionMut(s: *Store, id: []const u8) ?*Saved {
        const list = s.a().dupe(Saved, s.data.sessions) catch return null;
        s.data.sessions = list;
        for (list) |*x| if (std.mem.eql(u8, x.id, id)) return x;
        return null;
    }

    pub fn forgetSession(s: *Store, id: []const u8) void {
        var out: std.ArrayList(Saved) = .empty;
        for (s.data.sessions) |x| if (!std.mem.eql(u8, x.id, id)) out.append(s.a(), x) catch {};
        s.data.sessions = out.items;
    }

    // Agents.

    pub fn agent(s: *const Store, id: []const u8) ?*const Agent {
        for (s.data.agents) |*x| if (std.mem.eql(u8, x.id, id)) return x;
        return null;
    }

    pub fn setAgents(s: *Store, list: []const Agent) void {
        const out = s.a().alloc(Agent, list.len) catch return;
        for (list, out) |x, *o| o.* = .{ .id = s.dupe(x.id), .name = s.dupe(x.name), .command = s.dupeList(x.command), .off = x.off };
        s.data.agents = out;
    }

    pub fn dupeList(s: *Store, list: []const []const u8) []const []const u8 {
        const out = s.a().alloc([]const u8, list.len) catch return &.{};
        for (list, out) |x, *o| o.* = s.dupe(x);
        return out;
    }

    pub fn setMcp(s: *Store, list: []const Mcp) void {
        s.data.mcp = s.a().dupe(Mcp, list) catch return;
    }

    pub fn models(s: *const Store, agent_id: []const u8) ?*const Models {
        for (s.data.models) |*m| if (std.mem.eql(u8, m.agent, agent_id)) return m;
        return null;
    }

    pub fn agentOptions(s: *const Store, agent_id: []const u8) ?[]const u8 {
        for (s.data.agent_options) |kv| if (std.mem.eql(u8, kv.key, agent_id)) return kv.value;
        return null;
    }

    pub fn setAgentOptions(s: *Store, agent_id: []const u8, json_text: []const u8) void {
        if (s.agentOptions(agent_id)) |old| if (std.mem.eql(u8, old, json_text)) return;
        var out: std.ArrayList(KV) = .empty;
        for (s.data.agent_options) |kv| if (!std.mem.eql(u8, kv.key, agent_id)) out.append(s.a(), kv) catch {};
        out.append(s.a(), .{ .key = s.dupe(agent_id), .value = s.dupe(json_text) }) catch {};
        s.data.agent_options = out.items;
        s.save();
    }

    pub fn setModels(s: *Store, agent_id: []const u8, values: []const []const u8, names: []const []const u8) void {
        if (s.models(agent_id)) |m| if (sameList(m.values, values) and sameList(m.names, names)) return;
        var out: std.ArrayList(Models) = .empty;
        for (s.data.models) |m| if (!std.mem.eql(u8, m.agent, agent_id)) out.append(s.a(), m) catch {};
        out.append(s.a(), .{ .agent = s.dupe(agent_id), .values = s.dupeList(values), .names = s.dupeList(names) }) catch {};
        s.data.models = out.items;
        s.save();
    }
};

fn sameList(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

fn append(comptime T: type, a: std.mem.Allocator, list: []const T, item: T) []const T {
    const out = a.alloc(T, list.len + 1) catch return list;
    @memcpy(out[0..list.len], list);
    out[list.len] = item;
    return out;
}

/// Splits a command line into words, with double quotes around words that
/// hold spaces.
pub fn splitCommand(a: std.mem.Allocator, line: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var quoted = false;
    var any = false;
    for (line) |ch| {
        if (ch == '"') {
            quoted = !quoted;
            any = true;
        } else if ((ch == ' ' or ch == '\t') and !quoted) {
            if (any) out.append(a, word.toOwnedSlice(a) catch "") catch {};
            any = false;
        } else {
            word.append(a, ch) catch {};
            any = true;
        }
    }
    if (any) out.append(a, word.toOwnedSlice(a) catch "") catch {};
    return out.items;
}

/// The words of a command as one line, quoting those with spaces.
pub fn joinCommand(a: std.mem.Allocator, words: []const []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (words, 0..) |w, i| {
        if (i > 0) out.append(a, ' ') catch {};
        const q = std.mem.indexOfAny(u8, w, " \t") != null or w.len == 0;
        if (q) out.append(a, '"') catch {};
        out.appendSlice(a, w) catch {};
        if (q) out.append(a, '"') catch {};
    }
    return out.items;
}

test "a store round-trips and keeps one record per session" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa, std.testing.io, null);
    defer s.deinit();
    s.load();
    try std.testing.expect(s.agent("claude") != null);
    try std.testing.expect(s.agent("pi") != null);
    try std.testing.expect(s.agent("opencode") != null);
    s.putSession(.{ .id = "a", .agent = "claude", .cwd = "/w", .title = "One" });
    s.putSession(.{ .id = "a", .agent = "", .cwd = "", .updated = 5 });
    try std.testing.expectEqual(@as(usize, 1), s.data.sessions.len);
    try std.testing.expectEqualStrings("One", s.data.sessions[0].title);
    try std.testing.expectEqual(@as(i64, 5), s.data.sessions[0].updated);
    s.setDefault("claude.model", "opus");
    s.setDefault("claude.model", "sonnet");
    try std.testing.expectEqualStrings("sonnet", s.default("claude.model").?);
    const words = splitCommand(s.a(), "npx -y \"my agent\" --flag");
    try std.testing.expectEqual(@as(usize, 4), words.len);
    try std.testing.expectEqualStrings("my agent", words[2]);
    try std.testing.expectEqualStrings("npx -y \"my agent\" --flag", joinCommand(s.a(), words));
}

test "an agent on a retired default command moves to today's" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa, std.testing.io, null);
    defer s.deinit();
    s.data.agents = &.{
        .{ .id = "codex", .name = "Codex", .command = &.{ "npx", "-y", "@zed-industries/codex-acp" } },
        .{ .id = "claude", .name = "Claude Code", .command = &.{"my-claude"} },
    };
    s.offerNewAgents();
    try std.testing.expectEqualStrings("@agentclientprotocol/codex-acp", s.agent("codex").?.command[2]);
    try std.testing.expectEqualStrings("my-claude", s.agent("claude").?.command[0]);
}

test "an agent added to the defaults is offered once" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa, std.testing.io, null);
    defer s.deinit();
    // A file from before pi was a default, with the user's own list.
    s.data.agents = &.{.{ .id = "claude", .name = "Claude Code", .command = &.{"x"} }};
    s.offerNewAgents();
    try std.testing.expect(s.agent("pi") != null);
    // Removed by the user, it stays removed.
    s.data.agents = &.{.{ .id = "claude", .name = "Claude Code", .command = &.{"x"} }};
    s.offerNewAgents();
    try std.testing.expect(s.agent("pi") == null);
}
