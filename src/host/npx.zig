//! `npx -y <package>` without npx. Each time it runs, npx asks the npm
//! registry whether the package has a newer version: one to two seconds
//! before the agent starts. The copy npx keeps in its cache runs the same
//! with node at once, so an agent started that way is started from there,
//! and npm is asked about newer versions in the background (`check`),
//! once a run of the app per package: when there is one, the next start
//! goes through npx, which fetches it.
const std = @import("std");
const Io = std.Io;
const json = @import("../acp/json.zig");

/// The package an agent's command runs through npx, and the arguments
/// after it, when it is `npx -y <package> [args…]` and names no version.
pub const Call = struct {
    package: []const u8,
    rest: []const []const u8,
};

pub fn callOf(argv: []const []const u8) ?Call {
    if (argv.len < 3) return null;
    const exe = std.fs.path.basename(argv[0]);
    if (!std.ascii.eqlIgnoreCase(exe, "npx") and !std.ascii.eqlIgnoreCase(exe, "npx.cmd")) return null;
    var yes = false;
    var i: usize = 1;
    while (i < argv.len and std.mem.startsWith(u8, argv[i], "-")) : (i += 1) {
        const f = argv[i];
        if (std.mem.eql(u8, f, "-y") or std.mem.eql(u8, f, "--yes")) {
            yes = true;
        } else if (!std.mem.eql(u8, f, "-q") and !std.mem.eql(u8, f, "--quiet")) return null;
    }
    if (!yes or i >= argv.len) return null;
    const pkg = argv[i];
    // "@scope/name" is a package; "name@1.2" or "@scope/name@latest" pins one.
    if (std.mem.lastIndexOfScalar(u8, pkg, '@')) |at| if (at > 0) return null;
    return .{ .package = pkg, .rest = argv[i + 1 ..] };
}

/// Where npm keeps its cache: npm_config_cache, or npm's default.
pub fn cacheDir(a: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]const u8 {
    if (env.get("npm_config_cache") orelse env.get("NPM_CONFIG_CACHE")) |d| return d;
    if (@import("builtin").os.tag == .windows) {
        const local = env.get("LOCALAPPDATA") orelse return null;
        return std.fs.path.join(a, &.{ local, "npm-cache" }) catch null;
    }
    const home = env.get("HOME") orelse return null;
    return std.fs.path.join(a, &.{ home, ".npm" }) catch null;
}

/// A copy of a package npx has installed: its version and the script its
/// command runs.
pub const Cached = struct {
    version: []const u8,
    script: []const u8,
};

/// The newest copy of `package` in npx's cache, in `a`'s memory.
pub fn cached(a: std.mem.Allocator, io: Io, cache: []const u8, package: []const u8) ?Cached {
    const root = std.fs.path.join(a, &.{ cache, "_npx" }) catch return null;
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var best: ?Cached = null;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        const home = std.fs.path.join(a, &.{ root, e.name, "node_modules", package }) catch continue;
        const manifest = std.fs.path.join(a, &.{ home, "package.json" }) catch continue;
        const text = Io.Dir.cwd().readFileAlloc(io, manifest, a, .limited(1 << 20)) catch continue;
        const v = std.json.parseFromSliceLeaky(json.Value, a, text, .{}) catch continue;
        const version = json.str(v, "version") orelse continue;
        const entry = binOf(v, package) orelse continue;
        const script = std.fs.path.join(a, &.{ home, entry }) catch continue;
        // A copy npx is still installing has no script yet.
        Io.Dir.cwd().access(io, script, .{}) catch continue;
        if (best) |b| if (!newer(version, b.version)) continue;
        best = .{ .version = version, .script = script };
    }
    return best;
}

/// The script a package's command runs: its only one, or the one named
/// for the package.
fn binOf(manifest: json.Value, package: []const u8) ?[]const u8 {
    const bin = json.get(manifest, "bin") orelse return null;
    if (bin == .string) return bin.string;
    if (bin != .object) return null;
    if (bin.object.count() == 1) {
        const only = bin.object.values()[0];
        return if (only == .string) only.string else null;
    }
    const short = if (std.mem.lastIndexOfScalar(u8, package, '/')) |i| package[i + 1 ..] else package;
    return json.str(bin, short);
}

/// Whether version `a` comes after `b` ("0.109.1" after "0.95.0").
pub fn newer(a: []const u8, b: []const u8) bool {
    var x = std.mem.splitScalar(u8, cut(a), '.');
    var y = std.mem.splitScalar(u8, cut(b), '.');
    while (true) {
        const p = x.next();
        const q = y.next();
        if (p == null and q == null) return false;
        const m = std.fmt.parseInt(u64, p orelse "0", 10) catch 0;
        const n = std.fmt.parseInt(u64, q orelse "0", 10) catch 0;
        if (m != n) return m > n;
    }
}

/// A version without its pre-release or build part.
fn cut(v: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, v, "-+") orelse v.len;
    return v[0..end];
}

/// Packages npm said have a newer version than the cached one, this run:
/// they start through npx, which fetches it.
var stale: std.StringHashMapUnmanaged(void) = .empty;
/// Packages already asked about, this run.
var asked: std.StringHashMapUnmanaged(void) = .empty;
var lock: std.atomic.Mutex = .unlocked;

fn locked() void {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
}

/// `argv` to start with node from npx's cache, in `a`'s memory; null when
/// npx should start it (not an npx command, nothing cached, or newer on npm).
pub fn direct(a: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, argv: []const []const u8) ?[]const []const u8 {
    const call = callOf(argv) orelse return null;
    locked();
    const old = stale.contains(call.package);
    lock.unlock();
    if (old) return null;
    const cache = cacheDir(a, env) orelse return null;
    const copy = cached(a, io, cache, call.package) orelse return null;
    var out: std.ArrayList([]const u8) = .empty;
    out.appendSlice(a, &.{ "node", copy.script }) catch return null;
    out.appendSlice(a, call.rest) catch return null;
    return out.items;
}

/// Asks npm, off the main thread, whether `package` has a version newer
/// than the cached one; once a run per package.
pub fn check(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, argv: []const []const u8) void {
    const call = callOf(argv) orelse return;
    locked();
    const seen = asked.contains(call.package);
    const name = if (seen) null else gpa.dupe(u8, call.package) catch null;
    if (name) |n| asked.put(gpa, n, {}) catch {};
    lock.unlock();
    const pkg = name orelse return;
    const job = gpa.create(Job) catch return;
    job.* = .{ .gpa = gpa, .io = io, .env = env, .package = pkg };
    @import("jobs.zig").spawn(Job, job, Job.run, Job.done);
}

/// Forgets what this run learned, as the app quits.
pub fn deinit(gpa: std.mem.Allocator) void {
    locked();
    defer lock.unlock();
    var it = asked.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    asked.deinit(gpa);
    stale.deinit(gpa);
}

const Job = struct {
    gpa: std.mem.Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    package: []const u8,

    fn done(j: *Job) void {
        j.gpa.destroy(j);
    }

    fn run(j: *Job) void {
        var arena: std.heap.ArenaAllocator = .init(j.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const cache = cacheDir(a, j.env) orelse return;
        const copy = cached(a, j.io, cache, j.package) orelse return;
        const npm = if (@import("builtin").os.tag == .windows) "npm.cmd" else "npm";
        const r = std.process.run(a, j.io, .{
            .argv = &.{ npm, "view", j.package, "version" },
            .environ_map = j.env,
            .create_no_window = true,
        }) catch return;
        if (!r.term.success()) return;
        const latest = std.mem.trim(u8, r.stdout, " \r\n\t");
        if (latest.len == 0 or !newer(latest, copy.version)) return;
        locked();
        defer lock.unlock();
        stale.put(j.gpa, j.package, {}) catch {};
    }
};

test "an npx command, its package and the newest cached copy" {
    const c = callOf(&.{ "npx", "-y", "@agentclientprotocol/codex-acp", "--flag" }).?;
    try std.testing.expectEqualStrings("@agentclientprotocol/codex-acp", c.package);
    try std.testing.expectEqual(@as(usize, 1), c.rest.len);
    try std.testing.expect(callOf(&.{ "npx", "-y", "pi-acp@0.0.30" }) == null);
    try std.testing.expect(callOf(&.{ "npx", "pi-acp" }) == null);
    try std.testing.expect(callOf(&.{ "opencode", "acp" }) == null);
    try std.testing.expect(callOf(&.{ "npx", "-y", "@scope/pkg@latest" }) == null);
    try std.testing.expect(newer("0.109.1", "0.95.0"));
    try std.testing.expect(!newer("2.9.0", "2.9.0"));
    try std.testing.expect(newer("2.10.0-beta.1", "2.9.9"));
    try std.testing.expect(!newer("1.0", "1.0.1"));
}
