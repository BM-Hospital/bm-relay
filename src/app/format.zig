//! Names and times for people: "2h ago", day headings, model names.
const std = @import("std");

/// "now", "5m ago", "3h ago", "2d ago", "4w ago".
pub fn ago(buf: []u8, now_ms: i64, then_ms: i64) []const u8 {
    if (then_ms <= 0) return "";
    const s = @divTrunc(@max(now_ms - then_ms, 0), 1000);
    if (s < 60) return "now";
    if (s < 3600) return std.fmt.bufPrint(buf, "{d}m ago", .{@divTrunc(s, 60)}) catch "";
    if (s < 86400) return std.fmt.bufPrint(buf, "{d}h ago", .{@divTrunc(s, 3600)}) catch "";
    if (s < 86400 * 14) return std.fmt.bufPrint(buf, "{d}d ago", .{@divTrunc(s, 86400)}) catch "";
    return std.fmt.bufPrint(buf, "{d}w ago", .{@divTrunc(s, 86400 * 7)}) catch "";
}

/// The local day of a time, as days since the epoch, with the zone's
/// offset in minutes.
pub fn dayOf(ms: i64, offset_min: i64) i64 {
    return @divFloor(ms + offset_min * 60_000, 86_400_000);
}

/// "Today", "Yesterday", or the date.
pub fn day(buf: []u8, now_ms: i64, then_ms: i64, offset_min: i64) []const u8 {
    const d = dayOf(then_ms, offset_min);
    const today = dayOf(now_ms, offset_min);
    if (d == today) return "Today";
    if (d == today - 1) return "Yesterday";
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(d, 0) * 86400) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
    return std.fmt.bufPrint(buf, "{s} {d}, {d}", .{ months[md.month.numeric() - 1], md.day_index + 1, yd.year }) catch "";
}

/// A model's name as menus show it: the name the agent gave, or its id
/// with words capitalized ("claude-opus-5-5" → "Claude Opus 5.5").
pub fn modelName(buf: []u8, id: []const u8, given: []const u8) []const u8 {
    if (given.len > 0 and !std.mem.eql(u8, given, id)) {
        // "anthropic/Claude Opus 4.8": the provider is said elsewhere.
        if (std.mem.lastIndexOfScalar(u8, given, '/')) |i| if (i + 1 < given.len and std.mem.indexOfScalar(u8, given[i + 1 ..], ' ') != null) return given[i + 1 ..];
        return given;
    }
    var tail = id;
    if (std.mem.lastIndexOfScalar(u8, tail, '/')) |i| tail = tail[i + 1 ..];
    var w: usize = 0;
    var start = true;
    var prev_digit = false;
    for (tail) |ch| {
        if (w + 1 >= buf.len) break;
        if (ch == '-' or ch == '_') {
            buf[w] = ' ';
            w += 1;
            start = true;
            continue;
        }
        // "5-5" reads as "5.5".
        if (start and std.ascii.isDigit(ch) and prev_digit and w > 0 and buf[w - 1] == ' ') buf[w - 1] = '.';
        buf[w] = if (start) std.ascii.toUpper(ch) else ch;
        prev_digit = std.ascii.isDigit(ch);
        start = false;
        w += 1;
    }
    return buf[0..w];
}

/// `s` cut to `max` characters by an ellipsis in its middle, its start and
/// end kept: a branch name's kind and its ticket read on either side.
pub fn middle(buf: []u8, s: []const u8, max: usize) []const u8 {
    if (max < 5 or std.unicode.utf8CountCodepoints(s) catch s.len <= max) return s;
    const keep = max - 1;
    const head = boundary(s, byteAt(s, keep - keep / 2));
    const tail = boundary(s, byteAt(s, (std.unicode.utf8CountCodepoints(s) catch s.len) - keep / 2));
    return std.fmt.bufPrint(buf, "{s}…{s}", .{ s[0..head], s[tail..] }) catch s;
}

/// The byte where the `n`th character of `s` starts.
fn byteAt(s: []const u8, n: usize) usize {
    var count: usize = 0;
    for (s, 0..) |b, i| {
        if (b & 0xc0 == 0x80) continue;
        if (count == n) return i;
        count += 1;
    }
    return s.len;
}

/// `i`, moved back to the start of the character it is in.
fn boundary(s: []const u8, i: usize) usize {
    var at = @min(i, s.len);
    while (at > 0 and at < s.len and s[at] & 0xc0 == 0x80) at -= 1;
    return at;
}

/// Where a web link starts in `s` at `i`: after a space, a bracket or the
/// start, "https://", "http://" or "www.", as Markdown's autolinks.
fn linkAt(s: []const u8, i: usize) bool {
    if (i > 0 and !std.ascii.isWhitespace(s[i - 1]) and std.mem.indexOfScalar(u8, "([<\"'", s[i - 1]) == null) return false;
    const r = s[i..];
    return std.mem.startsWith(u8, r, "https://") or std.mem.startsWith(u8, r, "http://") or std.mem.startsWith(u8, r, "www.");
}

/// Where a link that starts at `i` ends: at a space or `<`, before the
/// punctuation that ends a sentence.
fn linkEnd(s: []const u8, i: usize) usize {
    var e = i;
    while (e < s.len and !std.ascii.isWhitespace(s[e]) and s[e] != '<') e += 1;
    while (e > i and std.mem.indexOfScalar(u8, ".,;:!?)\"'", s[e - 1]) != null) e -= 1;
    return e;
}

pub fn hasLink(s: []const u8) bool {
    for (0..s.len) |i| if (linkAt(s, i)) return true;
    return false;
}

/// `s` as Markdown that shows exactly `s`: every mark escaped but in its
/// links (which Markdown then links), its lines kept as lines, spaces
/// that start a line kept (not read as code).
pub fn plainMarkdown(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var line_start = true;
    while (i < s.len) {
        if (linkAt(s, i)) {
            const e = linkEnd(s, i);
            out.appendSlice(a, s[i..e]) catch {};
            i = e;
            line_start = false;
            continue;
        }
        const ch = s[i];
        if (ch == '\r') {
            i += 1;
            continue;
        }
        if (ch == '\n') {
            // A line of its own: a hard break, unless a blank line follows.
            const next_blank = i + 1 < s.len and (s[i + 1] == '\n' or s[i + 1] == '\r');
            if (!line_start and !next_blank) out.append(a, '\\') catch {};
            out.append(a, '\n') catch {};
            line_start = true;
            i += 1;
            continue;
        }
        if (line_start and (ch == ' ' or ch == '\t')) {
            out.appendSlice(a, "&nbsp;") catch {};
            i += 1;
            continue;
        }
        line_start = false;
        if (ch < 0x80 and std.ascii.isPrint(ch) and !std.ascii.isAlphanumeric(ch) and ch != ' ') out.append(a, '\\') catch {};
        out.append(a, ch) catch {};
        i += 1;
    }
    return out.items;
}

/// The first letter capitalized.
pub fn capitalized(buf: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    if (n > 0) buf[0] = std.ascii.toUpper(buf[0]);
    return buf[0..n];
}

/// "1.2k", "34k", "1.5M".
pub fn tokens(buf: []u8, n: u64) []const u8 {
    if (n < 1000) return std.fmt.bufPrint(buf, "{d}", .{n}) catch "";
    if (n < 10_000) return std.fmt.bufPrint(buf, "{d:.1}k", .{@as(f64, @floatFromInt(n)) / 1000}) catch "";
    if (n < 1_000_000) return std.fmt.bufPrint(buf, "{d}k", .{n / 1000}) catch "";
    return std.fmt.bufPrint(buf, "{d:.1}M", .{@as(f64, @floatFromInt(n)) / 1_000_000}) catch "";
}

test "times and names" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("now", ago(&buf, 10_000, 5_000));
    try std.testing.expectEqualStrings("2h ago", ago(&buf, 7_200_000 + 10, 10));
    try std.testing.expectEqualStrings("Claude Opus 5.5", modelName(&buf, "claude-opus-5-5", ""));
    try std.testing.expectEqualStrings("Sonnet", modelName(&buf, "x", "Sonnet"));
    try std.testing.expectEqualStrings("Claude Opus 4.8", modelName(&buf, "anthropic/claude-opus-4-8", "anthropic/Claude Opus 4.8"));
    try std.testing.expectEqualStrings("Today", day(&buf, 86_400_000 * 3, 86_400_000 * 3 + 5, 0));
    try std.testing.expectEqualStrings("34k", tokens(&buf, 34_500));
    try std.testing.expectEqualStrings("main", middle(&buf, "main", 24));
    try std.testing.expectEqualStrings("feature/B…-for-sso", middle(&buf, "feature/BM-1234-refactor-the-auth-for-sso", 18));
    try std.testing.expectEqual(@as(usize, 18), try std.unicode.utf8CountCodepoints(middle(&buf, "feature/BM-1234-refactor-the-auth-for-sso", 18)));
    try std.testing.expectEqualStrings("nhá…dài", middle(&buf, "nhánh-tên-rất-dài", 7));

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try std.testing.expect(hasLink("open https://github.com/x please") and !hasLink("no links, a.b"));
    try std.testing.expectEqualStrings("see https://a.io/x_y\\.", plainMarkdown(ar, "see https://a.io/x_y."));
    try std.testing.expectEqualStrings("\\*not bold\\* https://a.io\\\nnext", plainMarkdown(ar, "*not bold* https://a.io\nnext"));
    try std.testing.expectEqualStrings("&nbsp;&nbsp;&nbsp;&nbsp;code\\? www.a.io", plainMarkdown(ar, "    code? www.a.io"));
}

/// The company a model is from, by its id: "openrouter/openai/gpt-5" (a
/// router's) → "openai", "anthropic/claude-x" → "anthropic"; "" when the
/// id does not say ("gpt-5").
pub fn vendorOf(id: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, id, '/');
    const first = it.next() orelse return "";
    const second = it.next() orelse return "";
    return if (it.next() != null) second else first;
}

/// A company's name as it writes it: "openai" → "OpenAI".
pub fn vendorName(buf: []u8, key: []const u8) []const u8 {
    const known = [_]struct { []const u8, []const u8 }{
        .{ "openai", "OpenAI" },             .{ "anthropic", "Anthropic" },   .{ "google", "Google" },
        .{ "meta-llama", "Meta" },           .{ "mistralai", "Mistral" },     .{ "mistral", "Mistral" },
        .{ "deepseek", "DeepSeek" },         .{ "qwen", "Qwen" },             .{ "x-ai", "xAI" },
        .{ "xai", "xAI" },                   .{ "nvidia", "NVIDIA" },         .{ "moonshotai", "Moonshot" },
        .{ "z-ai", "Z.ai" },                 .{ "zai", "Z.ai" },              .{ "minimax", "MiniMax" },
        .{ "cohere", "Cohere" },             .{ "microsoft", "Microsoft" },   .{ "amazon", "Amazon" },
        .{ "perplexity", "Perplexity" },     .{ "ai21", "AI21" },             .{ "ibm-granite", "IBM Granite" },
        .{ "openrouter", "OpenRouter" },     .{ "github-copilot", "GitHub Copilot" }, .{ "opencode", "OpenCode" },
        .{ "baidu", "Baidu" },               .{ "tencent", "Tencent" },       .{ "bytedance", "ByteDance" },
    };
    if (key.len == 0) return "Other";
    for (known) |k| if (std.ascii.eqlIgnoreCase(k[0], key)) return k[1];
    // "aion-labs" → "Aion Labs".
    var w: usize = 0;
    var start = true;
    for (key) |ch| {
        if (w >= buf.len) break;
        if (ch == '-' or ch == '_') {
            buf[w] = ' ';
            start = true;
        } else {
            buf[w] = if (start) std.ascii.toUpper(ch) else ch;
            start = false;
        }
        w += 1;
    }
    return buf[0..w];
}

/// Whether a model costs nothing: "… (free)", or a router's ":free".
pub fn isFree(id: []const u8, name: []const u8) bool {
    return std.mem.endsWith(u8, id, ":free") or std.mem.endsWith(u8, name, "(free)");
}

/// The name without " (free)": a badge says it.
pub fn withoutFree(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, " (free)")) name[0 .. name.len - " (free)".len] else name;
}

test "a model's company" {
    try std.testing.expectEqualStrings("openai", vendorOf("openrouter/openai/gpt-5"));
    try std.testing.expectEqualStrings("anthropic", vendorOf("anthropic/claude-x"));
    try std.testing.expectEqualStrings("", vendorOf("gpt-5"));
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("OpenAI", vendorName(&buf, "openai"));
    try std.testing.expectEqualStrings("Aion Labs", vendorName(&buf, "aion-labs"));
    try std.testing.expect(isFree("x/y:free", "Y"));
    try std.testing.expectEqualStrings("Nemotron", withoutFree("Nemotron (free)"));
}
