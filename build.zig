const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Set by `myzig build`: release builds without debug information, and
    // Windows' icon, manifest and version information.
    const strip = b.option(bool, "strip", "Strip debug information");
    const win32_res = b.option([]const u8, "win32-res", "A compiled resource file (.res) to link on Windows");

    const myzig_dep = b.dependency("myzig", .{ .target = target, .optimize = optimize });
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "myzig", .module = myzig_dep.module("myzig") },
            .{ .name = "mainthread", .module = myzig_dep.module("mainthread") },
        },
    });
    if (win32_res) |res| if (target.result.os.tag == .windows) root.addObjectFile(.{ .cwd_relative = res });
    // The version, from build.zig.zon: About and crash reports say it.
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    root.addOptions("app_options", options);

    const exe = b.addExecutable(.{ .name = "bm-relay", .root_module = root });
    if (b.option(bool, "windows-gui", "A Windows app without a console") orelse false) exe.subsystem = .windows;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the app").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = root });
    b.step("test", "Run the app's tests").dependOn(&b.addRunArtifact(tests).step);
}
