const Cmd = @This();

const std = @import("std");
const builtin = @import("builtin");

const kbd = @import("../kbd.zig");
const text = @import("../text.zig");
const editor = @import("../editor.zig");


pub fn onInputted(self: *editor.Editor) !void {
  self.needs_update_cursor = true;
  var text_handler: *text.TextHandler = &self.text_handler;
  var cmd_data: *editor.CommandData = self.getCmdData();
  const line: u32 = std.fmt.parseInt(u32, cmd_data.cmdinp.items, 10) catch {
    cmd_data.promptoverlay = .{ .static = "Invalid integer!", };
    return;
  };
  if (line == 0) {
    cmd_data.promptoverlay = .{ .static = "Lines start at 1!" };
    return;
  }
  text_handler.gotoLine(self, line - 1) catch {
    cmd_data.promptoverlay = .{ .static = "Out of bounds!" };
    return;
  };
  self.setState(.text);
}

pub fn onKey(self: *editor.Editor, keysym: kbd.Keysym) !bool {
  if (keysym.getPrint()) |key| {
    if (key == 'g') {
      try self.text_handler.gotoLine(self, 0);
      self.setState(.text);
      return true;
    } else if (key == 'G') {
      try self.text_handler.gotoLine(
        self,
        @intCast(self.text_handler.lineinfo.getLen() - 1)
      );
      self.setState(.text);
      return true;
    }
  }
  return false;
}