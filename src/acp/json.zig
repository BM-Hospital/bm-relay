//! Reading `std.json.Value`s without ceremony: a missing key, a value of
//! another type or a null all read as absent.
const std = @import("std");
pub const Value = std.json.Value;

pub fn get(v: ?Value, key: []const u8) ?Value {
    const o = v orelse return null;
    if (o != .object) return null;
    const got = o.object.get(key) orelse return null;
    if (got == .null) return null;
    return got;
}

/// `get` along a path of keys.
pub fn at(v: ?Value, keys: []const []const u8) ?Value {
    var cur = v;
    for (keys) |k| cur = get(cur, k);
    return cur;
}

pub fn str(v: ?Value, key: []const u8) ?[]const u8 {
    const got = get(v, key) orelse return null;
    return if (got == .string) got.string else null;
}

pub fn strOr(v: ?Value, key: []const u8, fallback: []const u8) []const u8 {
    return str(v, key) orelse fallback;
}

pub fn int(v: ?Value, key: []const u8) ?i64 {
    const got = get(v, key) orelse return null;
    return switch (got) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

pub fn boolean(v: ?Value, key: []const u8) bool {
    const got = get(v, key) orelse return false;
    return got == .bool and got.bool;
}

pub fn array(v: ?Value, key: []const u8) []const Value {
    const got = get(v, key) orelse return &.{};
    return if (got == .array) got.array.items else &.{};
}

/// Whether a key is present, even as null.
pub fn has(v: ?Value, key: []const u8) bool {
    const o = v orelse return false;
    return o == .object and o.object.contains(key);
}

/// A value as JSON text, in `a`'s memory.
pub fn stringify(a: std.mem.Allocator, v: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(a, v, .{});
}

/// A deep copy of `v` into `a`.
pub fn clone(a: std.mem.Allocator, v: Value) !Value {
    return switch (v) {
        .null, .bool, .integer, .float => v,
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .array => |arr| blk: {
            var out = std.json.Array.init(a);
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |x| out.appendAssumeCapacity(try clone(a, x));
            break :blk .{ .array = out };
        },
        .object => |o| blk: {
            var out: std.json.ObjectMap = .empty;
            try out.ensureTotalCapacity(a, o.count());
            var it = o.iterator();
            while (it.next()) |e| out.putAssumeCapacity(try a.dupe(u8, e.key_ptr.*), try clone(a, e.value_ptr.*));
            break :blk .{ .object = out };
        },
    };
}

test "reads through missing keys" {
    const a = std.testing.allocator;
    const p = try std.json.parseFromSlice(Value, a, "{\"a\":{\"b\":\"x\",\"n\":3,\"z\":null}}", .{});
    defer p.deinit();
    try std.testing.expectEqualStrings("x", str(at(p.value, &.{"a"}), "b").?);
    try std.testing.expectEqual(@as(?i64, 3), int(get(p.value, "a"), "n"));
    try std.testing.expect(str(p.value, "nope") == null);
    try std.testing.expect(get(get(p.value, "a"), "z") == null);
    try std.testing.expect(has(get(p.value, "a"), "z"));
}
