const Cmd = @This();

const std = @import("std");
const builtin = @import("builtin");

const kbd = @import("../kbd.zig");
const editor = @import("../editor.zig");

pub fn findForwards(self: *editor.Editor, cmd_data: *editor.CommandData) !void {
  var text_handler = &self.text_handler;
  const opt_pos = std.mem.indexOfPos(
    u8,
    text_handler.buffer.items,
    text_handler.calcOffsetFromCursor() + 1,
    cmd_data.cmdinp.items,
  );
  if (opt_pos) |pos| {
    try text_handler.gotoPos(self, @intCast(pos));
  } else {
    cmd_data.promptoverlay = .{ .static = "Not found!", };
  }
}

pub fn findBackwards(self: *editor.Editor, cmd_data: *editor.CommandData) !void {
  var text_handler = &self.text_handler;
  const opt_pos = std.mem.lastIndexOf(
    u8,
    text_handler.buffer.items[0..text_handler.calcOffsetFromCursor()],
    cmd_data.cmdinp.items,
  );
  if (opt_pos) |pos| {
    try text_handler.gotoPos(self, @intCast(pos));
  } else {
    cmd_data.promptoverlay = .{ .static = "Not found!", };
  }
}

pub fn onInputted(self: *editor.Editor) !void {
  self.needs_update_cursor = true;
  try self.text_handler.flushGapBuffer(self);
  const cmd_data: *editor.CommandData = self.getCmdData();
  try Cmd.findForwards(self, cmd_data);
}

pub fn onKey(self: *editor.Editor, keysym: kbd.Keysym) !bool {
  self.needs_update_cursor = true;
  const cmd_data: *editor.CommandData = self.getCmdData();
  if (keysym.key == kbd.Keysym.Key.up) {
    try self.text_handler.flushGapBuffer(self);
    try Cmd.findBackwards(self, cmd_data);
    return true;
  }
  else if (keysym.key == kbd.Keysym.Key.down) {
    try self.text_handler.flushGapBuffer(self);
    try Cmd.findForwards(self, cmd_data);
    return true;
  }
  return false;
}