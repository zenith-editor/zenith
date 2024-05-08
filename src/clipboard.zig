//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//

const std = @import("std");
const builtin = @import("builtin");

pub fn read(allocr: std.mem.Allocator) !?[]u8 {
  switch (builtin.os.tag) {
    .linux => { return readX11OrWayland(allocr); },
    else => { return null; },
  }
}

fn readX11OrWayland(allocr: std.mem.Allocator) !?[]u8 {
  const is_x11 = std.process.hasEnvVar(allocr, "DISPLAY") catch false;
  if (is_x11) {
    const result = try std.ChildProcess.run(.{
      .allocator = allocr,
      .argv = &.{"xclip", "-selection", "clipboard", "-o"},
    });
    defer allocr.free(result.stderr);
    if (result.stdout.len == 0) {
      defer allocr.free(result.stdout);
      return null;
    }
    return result.stdout;
  }
  return null;
}

pub fn write(allocr: std.mem.Allocator, buf: []const u8) !void {
  switch (builtin.os.tag) {
    .linux => { return writeX11OrWayland(allocr, buf); },
    else => { return; },
  }
}

fn writeX11OrWayland(allocr: std.mem.Allocator, buf: []const u8) !void {
  const is_x11 = std.process.hasEnvVar(allocr, "DISPLAY") catch false;
  if (is_x11) {
    var proc = std.ChildProcess.init(
      &.{"xclip", "-selection", "clipboard"},
      allocr,
    );
    proc.stdin_behavior = .Pipe;
    proc.stdout_behavior = .Close;
    proc.stderr_behavior = .Close;
    try proc.spawn();
    errdefer if (proc.kill()) |_| {} else |_| {};
    _ = try proc.stdin.?.writer().writeAll(buf);
    proc.stdin.?.close();
    return;
  }
  return;
}