//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");

const str = @import("./str.zig");
const sig = @import("./sig.zig");
const editor = @import("./editor.zig");

fn showHelp(program_name: []const u8) !void {
  const writer = std.io.getStdOut().writer();
  try writer.print(
    \\Usage: {s} [options] [file]
    \\
    \\Key bindings:
    \\ ^q: quit
    \\ ^s: save
    \\ ^o: open
    \\ ^b: block mode
    \\ ^v: paste
    \\ ^g: goto line (cmd)
    \\ ^f: find (cmd)
    \\ ^z: undo
    \\
    \\ Within cmd mode:
    \\  esc: change to text mode
    \\
    \\Options:
    \\  -h/--help: Show this help message
    \\
  , .{program_name});
}

pub fn main() !void {
  var opt_opened_file: ?[]const u8 = null;
  {
    // arguments
    var args = std.process.args();
    const program_name = args.next() orelse unreachable;
    while (args.next()) |arg| {
      if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
        return showHelp(program_name);
      }
      if (opt_opened_file != null) {
        return;
      }
      opt_opened_file = arg;
    }
  }
  sig.registerSignals();
  var E = try editor.Editor.create();
  if (opt_opened_file) |opened_file| {
    var opened_file_str: str.String = .{};
    try opened_file_str.appendSlice(E.allocr(), opened_file);
    try E.openAtStart(opened_file_str);
  }
  try E.run();
}