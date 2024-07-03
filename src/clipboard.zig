//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//

const std = @import("std");
const builtin = @import("builtin");

pub fn read(allocator: std.mem.Allocator) !?[]u8 {
    switch (builtin.os.tag) {
        inline .linux => {
            return readLinux(allocator);
        },
        else => {
            return null;
        },
    }
}

pub fn write(allocator: std.mem.Allocator, buf: []const u8) !void {
    switch (builtin.os.tag) {
        inline .linux => {
            return writeLinux(allocator, buf);
        },
        else => {
            return;
        },
    }
}

// Shared utils

fn spawnWriteToStdin(allocator: std.mem.Allocator, argv: []const []const u8, buf: []const u8) !void {
    var proc = std.process.Child.init(
        argv,
        allocator,
    );
    proc.expand_arg0 = .expand;
    proc.stdin_behavior = .Pipe;
    proc.stdout_behavior = .Close;
    proc.stderr_behavior = .Close;
    try proc.spawn();
    errdefer {
        _ = proc.kill() catch {};
    }
    _ = try proc.stdin.?.writer().writeAll(buf);
    proc.stdin.?.close();
}

fn spawnReadFromStdout(allocator: std.mem.Allocator, argv: []const []const u8) !?[]u8 {
    const proc = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .expand_arg0 = .expand,
    });
    defer allocator.free(proc.stderr);
    if (proc.stdout.len == 0) {
        defer allocator.free(proc.stdout);
        return null;
    }
    return proc.stdout;
}

// Linux

const LinuxProtocol = enum {
    Unknown,
    X11,
    Wayland,
};

fn getWhichProtocolLinux() LinuxProtocol {
    if (std.process.hasEnvVarConstant("WAYLAND_DISPLAY") and !std.process.hasEnvVarConstant("ZENITH_USE_WAYLAND_CLIPBOARD")) {
        return .Wayland;
    } else if (std.process.hasEnvVarConstant("DISPLAY")) {
        return .X11;
    }
    return .Unknown;
}

fn readLinux(allocator: std.mem.Allocator) !?[]u8 {
    switch (getWhichProtocolLinux()) {
        .Wayland => return spawnReadFromStdout(allocator, &.{"wl-paste"}),
        .X11 => return spawnReadFromStdout(allocator, &.{ "xclip", "-selection", "clipboard", "-o" }),
        else => {
            return null;
        },
    }
}

fn writeLinux(allocator: std.mem.Allocator, buf: []const u8) !void {
    switch (getWhichProtocolLinux()) {
        .Wayland => try spawnWriteToStdin(allocator, &.{"wl-copy"}, buf),
        .X11 => try spawnWriteToStdin(allocator, &.{ "xclip", "-selection", "clipboard" }, buf),
        else => {},
    }
}
