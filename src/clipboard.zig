//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//

const std = @import("std");
const builtin = @import("builtin");

const LinuxProtocol = enum {
    Unknown,
    X11,
    Wayland,
};

fn getWhichProtocolLinux() LinuxProtocol {
    if (std.process.hasEnvVarConstant("WAYLAND_DISPLAY")) {
        return .Wayland;
    } else if (std.process.hasEnvVarConstant("DISPLAY")) {
        return .X11;
    }
    return .Unknown;
}

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

fn readLinux(allocator: std.mem.Allocator) !?[]u8 {
    const argv: []const []const u8 = switch (getWhichProtocolLinux()) {
        .Wayland => &.{"wl-paste"},
        .X11 => &.{ "xclip", "-selection", "clipboard", "-o" },
        else => {
            return null;
        },
    };
    const proc = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    errdefer {
        _ = proc.kill();
    }
    defer allocator.free(proc.stderr);
    if (proc.stdout.len == 0) {
        defer allocator.free(proc.stdout);
        return null;
    }
    return proc.stdout;
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

fn writeLinux(allocator: std.mem.Allocator, buf: []const u8) !void {
    const argv: []const []const u8 = switch (getWhichProtocolLinux()) {
        .Wayland => &.{"wl-copy"},
        .X11 => &.{ "xclip", "-selection", "clipboard" },
        else => {
            return;
        },
    };
    var proc = std.process.Child.init(
        argv,
        allocator,
    );
    proc.stdin_behavior = .Pipe;
    proc.stdout_behavior = .Close;
    proc.stderr_behavior = .Close;
    try proc.spawn();
    errdefer {
        _ = proc.kill() catch {};
    }
    _ = try proc.stdin.?.writer().writeAll(buf);
    proc.stdin.?.close();
    return;
}
