//! The composer's draft: images attached to it, and the `@` and `/`
//! pickers that complete files, skills and the agent's own commands.
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

pub fn attachImage(a: *App, mime: []const u8, bytes: []const u8, name: []const u8) bool {
    if (a.attachments.items.len >= state.max_images) {
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

pub fn mimeOf(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    return null;
}

/// Attaches image files by path; others are skipped.
pub fn attachFiles(a: *App, paths: []const []const u8) void {
    for (paths) |p| {
        const mime = mimeOf(p) orelse continue;
        const bytes = std.Io.Dir.cwd().readFileAlloc(a.io, p, a.gpa, .limited(16 << 20)) catch continue;
        defer a.gpa.free(bytes);
        if (!attachImage(a, mime, bytes, std.fs.path.basename(p))) break;
    }
}

/// Asks for images and attaches them.
pub fn chooseImages(a: *App) void {
    const paths = (myzig.dialog.open(a.gpa, .{ .title = "Attach images", .button = "Attach", .multiple = true, .extensions = &.{ "png", "jpg", "jpeg", "gif", "webp" } }) catch null) orelse return;
    defer myzig.dialog.freePaths(a.gpa, paths);
    attachFiles(a, paths);
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
