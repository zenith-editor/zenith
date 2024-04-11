//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");
const builtin = @import("builtin");

pub var resized = false;

fn sigwinch(signal: c_int) callconv(.C) void {
  _ = signal;
  resized = true;
}

pub fn registerSignals() void {
  if (builtin.target.os.tag == .linux) {
    const sigaction = std.os.linux.Sigaction {
      .handler = .{ .handler = sigwinch, },
      .mask = std.os.linux.empty_sigset,
      .flags = 0,
    };
    _ = std.os.linux.sigaction(std.os.linux.SIG.WINCH, &sigaction, null);
  }
}