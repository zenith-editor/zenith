//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");
const builtin = @import("builtin");

pub var resized = false;
pub var sigchld_triggered = false;

fn sigwinch(signal: c_int) callconv(.C) void {
  _ = signal;
  resized = true;
}

fn sigchld(signal: c_int) callconv(.C) void {
  _ = signal;
  sigchld_triggered = true;
}

pub fn registerSignals() void {
  if (builtin.target.os.tag == .linux) {
    _ = std.os.linux.sigaction(std.os.linux.SIG.WINCH, &std.os.linux.Sigaction{
      .handler = .{ .handler = sigwinch, },
      .mask = std.os.linux.empty_sigset,
      .flags = 0,
    }, null);
    _ = std.os.linux.sigaction(std.os.linux.SIG.CHLD, &std.os.linux.Sigaction{
      .handler = .{ .handler = sigchld, },
      .mask = std.os.linux.empty_sigset,
      .flags = 0,
    }, null);
  }
}