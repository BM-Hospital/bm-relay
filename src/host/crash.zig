//! When the app fails for good (a panic, a bad memory access, the stack
//! running out), it says so instead of vanishing: what happened goes to
//! `crash.log` beside the state file, a message box says it (but after a
//! stack overflow, with no stack left to draw one), and the next launch
//! shows it once. Zig has no exceptions to catch: these are the faults no
//! code can recover from, so the app still ends after them.
//!
//! Everything here runs while the app is failing: no allocation, fixed
//! buffers, the system's own calls.
const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

var path_buf: [1024]u8 = undefined;
var path_len: usize = 0;
var version: []const u8 = "";

/// Where crashes go: `crash.log` in `dir`. Call it early, on the main thread.
pub fn init(dir: []const u8, app_version: []const u8) void {
    const name = "crash.log";
    if (dir.len + 1 + name.len >= path_buf.len) return;
    @memcpy(path_buf[0..dir.len], dir);
    path_buf[dir.len] = std.fs.path.sep;
    @memcpy(path_buf[dir.len + 1 ..][0..name.len], name);
    path_len = dir.len + 1 + name.len;
    version = app_version;
    // Room for the handler when the main thread's stack runs out.
    if (is_windows) _ = win.SetThreadStackGuarantee(&guarantee);
}

var guarantee: u32 = 64 * 1024;

pub fn path() []const u8 {
    return path_buf[0..path_len];
}

/// Writes what happened to `crash.log`, and, when `box`, says it in a
/// message box.
pub fn report(kind: []const u8, msg: []const u8, addr: ?usize, box: bool) void {
    var text_buf: [4096]u8 = undefined;
    var at_buf: [32]u8 = undefined;
    const at = if (addr) |x| std.fmt.bufPrint(&at_buf, "at 0x{x}\n", .{x}) catch "" else "";
    const text = std.fmt.bufPrint(&text_buf, "BM Relay {s} stopped: {s}\n{s}\n{s}", .{ version, kind, msg, at }) catch text_buf[0..0];
    write(text);
    if (box) say(kind, msg);
}

fn write(text: []const u8) void {
    if (path_len == 0) return;
    if (is_windows) {
        var wide: [1024]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], path()) catch return;
        wide[n] = 0;
        const h = win.CreateFileW(@ptrCast(&wide), 0x40000000, 0, null, 2, 0x80, null);
        if (h == win.INVALID_HANDLE_VALUE) return;
        defer _ = win.CloseHandle(h);
        var done: u32 = 0;
        _ = win.WriteFile(h, text.ptr, @intCast(text.len), &done, null);
        return;
    }
    var z: [1025]u8 = undefined;
    @memcpy(z[0..path_len], path());
    z[path_len] = 0;
    const f = std.c.fopen(@ptrCast(&z), "wb") orelse return;
    _ = std.c.fwrite(text.ptr, 1, text.len, f);
    _ = std.c.fclose(f);
}

fn say(kind: []const u8, msg: []const u8) void {
    if (!is_windows) return;
    var buf: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "BM Relay ran into a problem and has to close.\n\n{s}: {s}\n\nThe details are in {s}. Open it again to go on where you were.", .{ kind, msg, path() }) catch return;
    var wide: [2048]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], text) catch return;
    wide[n] = 0;
    _ = win.MessageBoxW(null, @ptrCast(&wide), std.unicode.utf8ToUtf16LeStringLiteral("BM Relay"), 0x10 | 0x10000);
}

/// The panic handler (`pub const panic` in main): reported, then Zig's own
/// (its stack trace on stderr).
pub fn panicked(msg: []const u8, ret: ?usize) noreturn {
    report("Panic", msg, ret, true);
    std.debug.defaultPanic(msg, ret);
}

/// A bad memory access or the stack running out (`root.debug`).
pub fn faulted(addr: ?usize, name: []const u8, ctx: anytype) noreturn {
    const overflow = std.mem.eql(u8, name, "Stack overflow");
    report(name, if (overflow) "the stack ran out (something nested too deep)" else "a bad memory access", addr, !overflow);
    std.debug.defaultHandleSegfault(addr, name, ctx);
}

/// The crash the last run left, once: read, then kept as `crash.shown.log`.
pub fn takeLast(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    if (path_len == 0) return null;
    const cwd = std.Io.Dir.cwd();
    const text = cwd.readFileAlloc(io, path(), gpa, .limited(64 * 1024)) catch return null;
    var shown_buf: [1100]u8 = undefined;
    const shown = std.fmt.bufPrint(&shown_buf, "{s}.shown", .{path()}) catch return text;
    cwd.rename(path(), cwd, shown, io) catch cwd.deleteFile(io, path()) catch {};
    return text;
}

const win = struct {
    const HANDLE = ?*anyopaque;
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disposition: u32, flags: u32, template: HANDLE) callconv(.winapi) HANDLE;
    extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, len: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;
    extern "kernel32" fn SetThreadStackGuarantee(size: *u32) callconv(.winapi) i32;
    extern "user32" fn MessageBoxW(hwnd: ?*anyopaque, text: [*:0]const u16, caption: [*:0]const u16, kind: u32) callconv(.winapi) i32;
};

test "a crash is written where it was said to go, and shown once" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    init(dir, "9.9.9");
    defer path_len = 0;
    report("Panic", "index out of bounds", 0x1234, false);
    const text = takeLast(std.testing.allocator, io).?;
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "9.9.9 stopped: Panic") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "index out of bounds") != null);
    try std.testing.expect(takeLast(std.testing.allocator, io) == null);
}
