// Contains code adapted from Zig's standard library

// The MIT License (Expat)

// Copyright (c) Zig contributors

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

const std = @import("std");
const builtin = @import("builtin");
const sig = @import("./sig.zig");

const ErrInt = std.meta.Int(.unsigned, @sizeOf(anyerror) * 8);

/// Custom run function to spawn a separate process that takes control of the current termios.
/// This implementation is here because you can't cleanly run a function before the exec call
/// by using the standard library.
///
/// TODO: use zig's standard library if something like rust's pre_exec is implemented
pub fn run(args: struct {
    argv: []const []const u8,
    captured_stdout: *std.ArrayList(u8),
    piped_stdin: std.fs.File,
    piped_stdout: std.fs.File,
    max_stdout_size: usize = std.math.maxInt(u32),
    poll_timeout: i32 = 1,
}) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const envp: [*:null]const ?[*:0]const u8 = (try std.process.createEnvironFromExisting(arena, @ptrCast(std.os.environ.ptr), .{})).ptr;

    const err_pipe = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer destroyPipe(err_pipe);

    const comm_pipe = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer destroyPipe(comm_pipe);

    const stdout_pipe = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer destroyPipe(stdout_pipe);

    const stderr_pipe = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer destroyPipe(stderr_pipe);

    const argv_buf = try arena.allocSentinel(?[*:0]const u8, args.argv.len, null);
    for (args.argv, 0..) |arg, i| argv_buf[i] = (try arena.dupeZ(u8, arg)).ptr;

    const pid_result = try std.posix.fork();
    if (pid_result == 0) {
        // we are the child
        // read from the comm_pipe to wait until we finished setting up the terminal
        _ = try readIntFd(comm_pipe[0]);

        if (args.piped_stdin.handle != std.posix.STDIN_FILENO) {
            std.posix.dup2(args.piped_stdin.handle, std.posix.STDIN_FILENO) catch |err| {
                forkChildErrReport(err_pipe[1], err);
            };
        }
        std.posix.dup2(stdout_pipe[1], std.posix.STDOUT_FILENO) catch |err| {
            forkChildErrReport(err_pipe[1], err);
        };
        std.posix.dup2(stderr_pipe[1], std.posix.STDERR_FILENO) catch |err| {
            forkChildErrReport(err_pipe[1], err);
        };

        const err = std.posix.execvpeZ(argv_buf.ptr[0].?, argv_buf.ptr, envp);
        forkChildErrReport(err_pipe[1], err);
    }

    errdefer {
        std.posix.kill(pid_result, std.posix.SIG.KILL) catch {};
    }

    // we are the parent
    const parent_pgid: std.posix.pid_t = try std.posix.tcgetpgrp(args.piped_stdin.handle);
    // TODO: use std.posix.setpgid if that is added
    {
        const rc = std.os.linux.syscall2(.setpgid, @intCast(pid_result), @intCast(parent_pgid));
        const errno = std.posix.errno(rc);
        if (errno != .SUCCESS) {
            return std.posix.unexpectedErrno(errno);
        }
    }
    sig.sigchld_triggered = false;

    // finished setting up, ready to run exec
    try writeIntFd(comm_pipe[1], 0);

    {
        // early exit if forked process errored
        try writeIntFd(err_pipe[1], std.math.maxInt(ErrInt));
        const err_int = try readIntFd(err_pipe[0]);
        if (err_int != std.math.maxInt(ErrInt)) {
            return @errorFromInt(err_int);
        }
    }

    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = stderr_pipe[0],
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
        .{
            .fd = stdout_pipe[0],
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    while (!sig.sigchld_triggered) {
        const poll_res = std.posix.poll(&poll_fds, args.poll_timeout) catch {
            break;
        };

        if (poll_res == 0) {
            continue;
        }

        const bufsize = 512;

        // stderr
        {
            const poll_fd = &poll_fds[0];
            if (poll_fd.revents & std.posix.POLL.IN != 0) {
                var buf: [bufsize]u8 = undefined;
                const amt = try std.posix.read(poll_fd.fd, &buf);
                if (amt == 0) {
                    break;
                }
                try args.piped_stdout.writer().writeAll(buf[0..amt]);
            }
        }

        // stdout
        {
            const poll_fd = &poll_fds[1];
            if (poll_fd.revents & std.posix.POLL.IN != 0) {
                var buf: [bufsize]u8 = undefined;
                const amt = try std.posix.read(poll_fd.fd, &buf);
                if (amt == 0) {
                    break;
                }
                try args.captured_stdout.appendSlice(buf[0..amt]);
            }
        }
    }
}

fn destroyPipe(pipe: [2]std.posix.fd_t) void {
    if (pipe[0] != -1) std.posix.close(pipe[0]);
    if (pipe[0] != pipe[1]) std.posix.close(pipe[1]);
}

// Child of fork calls this to report an error to the fork parent.
// Then the child exits.
fn forkChildErrReport(fd: i32, err: anyerror) noreturn {
    writeIntFd(fd, @as(ErrInt, @intFromError(err))) catch {};
    // If we're linking libc, some naughty applications may have registered atexit handlers
    // which we really do not want to run in the fork child. I caught LLVM doing this and
    // it caused a deadlock instead of doing an exit syscall. In the words of Avril Lavigne,
    // "Why'd you have to go and make things so complicated?"
    if (builtin.link_libc) {
        // The _exit(2) function does nothing but make the exit syscall, unlike exit(3)
        std.c._exit(1);
    }
    std.posix.exit(1);
}

fn writeIntFd(fd: i32, value: ErrInt) !void {
    const file: std.fs.File = .{ .handle = fd };
    file.writer().writeInt(u64, @intCast(value), .little) catch return error.SystemResources;
}

fn readIntFd(fd: i32) !ErrInt {
    const file: std.fs.File = .{ .handle = fd };
    return @intCast(file.reader().readInt(u64, .little) catch return error.SystemResources);
}
