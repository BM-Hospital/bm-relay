//! An agent's process and everything it starts. An ACP agent is often a
//! script that starts another (`npx` runs Node, which runs the adapter,
//! which runs the agent), so killing the first process alone would leave
//! the rest running. On Windows the process starts suspended, joins a job
//! that kills all its members when it is closed, then runs; elsewhere it
//! leads a process group of its own.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const windows = std.os.windows;

const is_windows = builtin.os.tag == .windows;

pub const Proc = struct {
    child: std.process.Child,
    stdin: ?Io.File,
    stdout: Io.File,
    stderr: ?Io.File,
    job: if (is_windows) ?windows.HANDLE else void,

    /// Ends the process and all it started. The pipes stay open: their
    /// readers close them when they see their end.
    pub fn kill(p: *Proc, io: Io) void {
        if (p.stdin) |f| f.close(io);
        p.stdin = null;
        if (is_windows) {
            if (p.job) |j| {
                _ = TerminateJobObject(j, 1);
                windows.CloseHandle(j);
                p.job = null;
            }
        } else if (p.child.id) |pid| {
            std.posix.kill(-pid, std.posix.SIG.TERM) catch {};
        }
        if (p.child.id != null) p.child.kill(io);
    }
};

pub const Options = struct {
    argv: []const []const u8,
    cwd: []const u8,
    env: ?*const std.process.Environ.Map = null,
};

pub fn spawn(io: Io, o: Options) !Proc {
    const child = try std.process.spawn(io, .{
        .argv = o.argv,
        .cwd = .{ .path = o.cwd },
        .environ_map = o.env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
        .start_suspended = is_windows,
        .pgid = if (is_windows) null else 0,
    });
    var p: Proc = .{
        .child = child,
        .stdin = child.stdin,
        .stdout = child.stdout.?,
        .stderr = child.stderr,
        .job = if (is_windows) null else {},
    };
    // The pipes are the Proc's now, so that ending the child leaves them
    // to their readers.
    p.child.stdin = null;
    p.child.stdout = null;
    p.child.stderr = null;
    if (is_windows) {
        p.job = makeJob();
        if (p.job) |j| {
            if (child.id) |h| _ = AssignProcessToJobObject(j, h);
        }
        _ = ResumeThread(child.thread_handle);
    }
    return p;
}

// Windows' jobs, declared here: the standard library has none of them.
const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64 = 0,
    PerJobUserTimeLimit: i64 = 0,
    LimitFlags: u32 = 0,
    MinimumWorkingSetSize: usize = 0,
    MaximumWorkingSetSize: usize = 0,
    ActiveProcessLimit: u32 = 0,
    Affinity: usize = 0,
    PriorityClass: u32 = 0,
    SchedulingClass: u32 = 0,
};
const IO_COUNTERS = extern struct { a: u64 = 0, b: u64 = 0, c: u64 = 0, d: u64 = 0, e: u64 = 0, f: u64 = 0 };
const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
    IoInfo: IO_COUNTERS = .{},
    ProcessMemoryLimit: usize = 0,
    JobMemoryLimit: usize = 0,
    PeakProcessMemoryUsed: usize = 0,
    PeakJobMemoryUsed: usize = 0,
};
const JobObjectExtendedLimitInformation: u32 = 9;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x2000;

extern "kernel32" fn CreateJobObjectW(attrs: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetInformationJobObject(job: windows.HANDLE, class: u32, info: *anyopaque, len: u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn AssignProcessToJobObject(job: windows.HANDLE, process: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn TerminateJobObject(job: windows.HANDLE, code: u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ResumeThread(thread: windows.HANDLE) callconv(.winapi) u32;

fn makeJob() ?windows.HANDLE {
    const j = CreateJobObjectW(null, null) orelse return null;
    var info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    _ = SetInformationJobObject(j, JobObjectExtendedLimitInformation, &info, @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
    return j;
}
