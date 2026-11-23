//! The composer's draft: images and files attached to it (chosen, pasted
//! or dropped), and the `@` and `/` pickers that complete files, skills
//! and the agent's own commands.
const std = @import("std");
const myzig = @import("myzig");
const app_mod = @import("app.zig");
const state = @import("state.zig");
const pickers = @import("../host/pickers.zig");

const App = app_mod.App;

/// The draft's text, in `gpa`'s memory.
pub fn text(a: *App) []u8 {
    return a.composer.text(a.gpa);
}

/// Replaces the draft as an edit (undo takes it back), the caret at its
/// end. An edit, not a new document: the text area's view follows edits.
pub fn setText(a: *App, t: []const u8) void {
    a.composer.setText(t);
    updatePicker(a);
}

pub fn clear(a: *App) void {
    a.composer.setText("");
    a.picker = null;
}

fn count(a: *App, files: bool) usize {
    var n: usize = 0;
    for (a.attachments.items) |at| {
        if (at.isFile() == files) n += 1;
    }
    return n;
}

pub fn attachImage(a: *App, mime: []const u8, bytes: []const u8, name: []const u8) bool {
    if (count(a, false) >= state.max_images) {
        refuse(a, a.print("A prompt carries at most {d} images.", .{state.max_images}));
        return false;
    }
    if (bytes.len > state.max_image_bytes) {
        refuse(a, "That image is larger than 3.75 MiB, the most an agent takes.");
        return false;
    }
    a.attachments.append(a.gpa, .{
        .mime = mime,
        .bytes = a.gpa.dupe(u8, bytes) catch return false,
        .name = a.gpa.dupe(u8, name) catch return false,
    }) catch return false;
    a.redraw();
    return true;
}

fn refuse(a: *App, why: []const u8) void {
    if (a.active) |s| s.setError(why) else a.failToast(why);
}

pub fn removeAttachment(a: *App, i: usize) void {
    if (i >= a.attachments.items.len) return;
    a.attachments.orderedRemove(i).deinit(a.gpa);
}

/// The image on the clipboard, if any: true when one was attached.
pub fn pasteImage(a: *App) bool {
    const png = (myzig.clipboard.readImage(a.gpa) catch null) orelse return false;
    defer a.gpa.free(png);
    return attachImage(a, "image/png", png, "Pasted image");
}

/// The files on the clipboard (copied in Explorer or Finder), attached:
/// true when there were some.
pub fn pasteFiles(a: *App) bool {
    const paths = (myzig.clipboard.readFiles(a.gpa) catch null) orelse return false;
    defer {
        for (paths) |p| a.gpa.free(p);
        a.gpa.free(paths);
    }
    if (paths.len == 0) return false;
    _ = attachFiles(a, paths);
    return true;
}

pub fn mimeOf(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    return null;
}

/// Attaches the file at `path` for the agent to read: a link to it, not
/// its bytes. False when no more can go.
pub fn attachFile(a: *App, path: []const u8, size: u64) bool {
    for (a.attachments.items) |at| if (std.mem.eql(u8, at.path, path)) return true;
    if (count(a, true) >= state.max_files) {
        refuse(a, a.print("A prompt carries at most {d} files.", .{state.max_files}));
        return false;
    }
    const name = a.gpa.dupe(u8, std.fs.path.basename(path)) catch return false;
    const owned = a.gpa.dupe(u8, path) catch {
        a.gpa.free(name);
        return false;
    };
    a.attachments.append(a.gpa, .{ .mime = "", .bytes = &.{}, .name = name, .path = owned, .size = size }) catch {
        a.gpa.free(name);
        a.gpa.free(owned);
        return false;
    };
    a.redraw();
    return true;
}

/// Attaches files by path, chosen or dropped: an image as itself (the
/// agent sees it), another file as a link the agent reads. Folders are
/// left out; how many went is the result.
pub fn attachFiles(a: *App, paths: []const []const u8) usize {
    var n: usize = 0;
    var folders: usize = 0;
    for (paths) |p| {
        const st = std.Io.Dir.cwd().statFile(a.io, p, .{}) catch continue;
        if (st.kind == .directory) {
            folders += 1;
            continue;
        }
        if (mimeOf(p)) |mime| if (st.size <= state.max_image_bytes) {
            const bytes = std.Io.Dir.cwd().readFileAlloc(a.io, p, a.gpa, .limited(state.max_image_bytes + 1)) catch continue;
            defer a.gpa.free(bytes);
            if (!attachImage(a, mime, bytes, std.fs.path.basename(p))) break;
            n += 1;
            continue;
        };
        if (!attachFile(a, p, st.size)) break;
        n += 1;
    }
    if (folders > 0 and n == 0) refuse(a, "Folders are not attached: mention one with @, or open it from Add folder.");
    return n;
}

/// Asks for files, any and several, and attaches them.
pub fn chooseFiles(a: *App) void {
    const paths = (myzig.dialog.open(a.gpa, .{ .title = "Attach files", .button = "Attach", .multiple = true }) catch null) orelse return;
    defer myzig.dialog.freePaths(a.gpa, paths);
    _ = attachFiles(a, paths);
}

/// A file's path as a `file://` URI: forward slashes, a drive letter
/// after a third slash, and what a URI can't hold escaped.
pub fn fileUri(ar: std.mem.Allocator, path: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(ar, "file://") catch return "";
    if (path.len > 0 and path[0] != '/' and path[0] != '\\') out.append(ar, '/') catch {};
    for (path) |ch| {
        const keep = std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~/:", ch) != null;
        if (ch == '\\') {
            out.append(ar, '/') catch {};
        } else if (keep) {
            out.append(ar, ch) catch {};
        } else {
            out.print(ar, "%{X:0>2}", .{ch}) catch {};
        }
    }
    return out.items;
}

test "a path as a file URI" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try std.testing.expectEqualStrings("file:///D:/BM/my%20notes/a.txt", fileUri(ar, "D:\\BM\\my notes\\a.txt"));
    try std.testing.expectEqualStrings("file:///home/x/%C3%A9.md", fileUri(ar, "/home/x/\xc3\xa9.md"));
}

// ---------------------------------------------------------------------------
// Pickers.

pub const Item = struct {
    title: []const u8,
    detail: []const u8,
    insert: []const u8,
};

/// What the picker lists now, in `ar`'s memory.
pub fn items(a: *App, ar: std.mem.Allocator) []Item {
    const p = a.picker orelse return &.{};
    const ws = a.workspace() orelse return &.{};
    var out: std.ArrayList(Item) = .empty;
    if (p.kind == '/') {
        var names: std.ArrayList([]const u8) = .empty;
        var details: std.ArrayList([]const u8) = .empty;
        if (a.active) |s| for (s.thread.commands) |c| {
            names.append(ar, c.name) catch {};
            details.append(ar, c.description) catch {};
        };
        for (ws.skills) |sk| {
            var dup = false;
            for (names.items) |n| if (std.mem.eql(u8, n, sk.name)) {
                dup = true;
            };
            if (dup) continue;
            names.append(ar, sk.name) catch {};
            details.append(ar, sk.description) catch {};
        }
        for (pickers.rank(ar, names.items, p.query, 6)) |i| out.append(ar, .{
            .title = names.items[i],
            .detail = details.items[i],
            .insert = std.fmt.allocPrint(ar, "/{s} ", .{names.items[i]}) catch continue,
        }) catch {};
    } else {
        for (pickers.rank(ar, ws.files, p.query, 8)) |i| {
            const f = ws.files[i];
            const cut = std.mem.lastIndexOfScalar(u8, f, '/');
            out.append(ar, .{
                .title = if (cut) |c| f[c + 1 ..] else f,
                .detail = if (cut) |c| f[0..c] else "",
                .insert = std.fmt.allocPrint(ar, "@{s} ", .{f}) catch continue,
            }) catch {};
        }
    }
    return out.items;
}

/// Opens, moves or closes the picker after the draft changed.
pub fn updatePicker(a: *App) void {
    const t = text(a);
    defer a.gpa.free(t);
    const old = a.picker;
    const trig = pickers.trigger(t) orelse {
        a.picker = null;
        return;
    };
    // The query is kept in the picker's own buffer: the draft changes.
    a.picker = .{ .kind = trig.kind, .query = keepQuery(a, trig.query) };
    if (old) |o| if (o.kind == trig.kind and std.mem.eql(u8, o.query, a.picker.?.query)) {
        a.picker.?.selected = o.selected;
    };
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    if (items(a, arena.allocator()).len == 0) a.picker = null;
}

var query_buf: [256]u8 = undefined;

fn keepQuery(a: *App, q: []const u8) []const u8 {
    _ = a;
    const n = @min(q.len, query_buf.len);
    @memcpy(query_buf[0..n], q[0..n]);
    return query_buf[0..n];
}

pub fn pickerStep(a: *App, step: isize) void {
    const p = &(a.picker orelse return);
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const n = items(a, arena.allocator()).len;
    if (n == 0) return;
    const cur: isize = @intCast(p.selected);
    a.picker.?.selected = @intCast(@mod(cur + step, @as(isize, @intCast(n))));
}

/// Puts the chosen item into the draft.
pub fn acceptPick(a: *App) void {
    const p = a.picker orelse return;
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const list = items(a, arena.allocator());
    if (p.selected >= list.len) return;
    const insert = list[p.selected].insert;
    a.picker = null;
    if (p.kind == '/') return setText(a, insert);
    const t = text(a);
    defer a.gpa.free(t);
    const start = std.mem.lastIndexOfScalar(u8, t, '@') orelse t.len;
    const next = std.fmt.allocPrint(arena.allocator(), "{s}{s}", .{ t[0..start], insert }) catch return;
    setText(a, next);
    a.picker = null;
}

/// Starts a mention at the end of the draft.
pub fn mention(a: *App) void {
    const t = text(a);
    defer a.gpa.free(t);
    const sep: []const u8 = if (t.len == 0 or std.ascii.isWhitespace(t[t.len - 1])) "" else " ";
    const next = std.fmt.allocPrint(a.gpa, "{s}{s}@", .{ t, sep }) catch return;
    defer a.gpa.free(next);
    setText(a, next);
}
