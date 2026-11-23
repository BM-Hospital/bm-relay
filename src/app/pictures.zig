//! Pictures an answer shows. Markdown's `![…](path)` of a file (in the
//! session's folder, or anywhere by its absolute path), read once and kept;
//! and images the agent sent (`agent_image` updates), which the thread
//! keeps under `bmimg:` names. Web addresses show their description: the
//! app fetches nothing.
const std = @import("std");
const ui = @import("myzig").ui;
const app_mod = @import("app.zig");
const state = @import("state.zig");

const App = app_mod.App;
const Session = state.Session;

/// The files read, by path: their bytes, or empty for one that could not be.
pub const Cache = std.StringHashMapUnmanaged([]u8);

pub fn deinit(gpa: std.mem.Allocator, cache: *Cache) void {
    var it = cache.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        gpa.free(e.value_ptr.*);
    }
    cache.deinit(gpa);
}

const Ctx = struct { a: *App, s: *Session };

/// The reader a session's Markdown shows pictures with, for this frame.
pub fn reader(a: *App, c: *ui.Context, s: *Session) ?ui.MarkdownImageReader {
    const ctx = c.alloc().create(Ctx) catch return null;
    ctx.* = .{ .a = a, .s = s };
    return .{ .ctx = ctx, .read = read };
}

const most = 16 << 20;

fn read(ctx_ptr: *anyopaque, c: *ui.Context, url: []const u8) ?ui.MarkdownImage {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    const a = ctx.a;
    if (std.mem.startsWith(u8, url, "bmimg:")) {
        const img = ctx.s.thread.picture(url) orelse return null;
        return .{ .key = img.key, .bytes = img.bytes, .svg = std.mem.eql(u8, img.mime, "image/svg+xml") };
    }
    if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "data:")) return null;
    const path = resolve(c.alloc(), a, ctx.s, url) orelse return null;
    if (!picture(path)) return null;
    const bytes = a.pictures.get(path) orelse blk: {
        const got = std.Io.Dir.cwd().readFileAlloc(a.io, path, a.gpa, .limited(most)) catch a.gpa.alloc(u8, 0) catch return null;
        const key = a.gpa.dupe(u8, path) catch {
            a.gpa.free(got);
            return null;
        };
        a.pictures.put(a.gpa, key, got) catch {
            a.gpa.free(key);
            a.gpa.free(got);
            return null;
        };
        break :blk got;
    };
    if (bytes.len == 0) return null;
    return .{ .key = c.print("pic:{s}", .{path}), .bytes = bytes, .svg = std.ascii.endsWithIgnoreCase(path, ".svg") };
}

/// A destination as a path: `file://` taken off, `%20` read, a relative
/// one from the session's folder.
fn resolve(ar: std.mem.Allocator, a: *App, s: *Session, url: []const u8) ?[]const u8 {
    var p = url;
    if (std.mem.startsWith(u8, p, "file:///")) p = p["file:///".len..] else if (std.mem.startsWith(u8, p, "file://")) p = p["file://".len..];
    const decoded = std.mem.replaceOwned(u8, ar, p, "%20", " ") catch return null;
    if (std.fs.path.isAbsolute(decoded)) return decoded;
    const w = a.workspaceOf(s) orelse return null;
    return std.fs.path.join(ar, &.{ w.path, decoded }) catch null;
}

fn picture(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

test "a picture's path" {
    try std.testing.expect(picture("docs/shot.PNG") and picture("a.svg") and !picture("notes.md"));
}
