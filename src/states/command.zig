//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const Impl = @This();

const kbd = @import("../kbd.zig");
const text = @import("../text.zig");
const editor = @import("../editor.zig");

pub fn handleInput(self: *editor.Editor, keysym: kbd.Keysym) !void {
  var cmd_data: *editor.CommandData = self.getCmdData();
  if (keysym.raw == kbd.Keysym.ESC) {
    self.setState(.text);
    return;
  }
  
  if (cmd_data.promptoverlay != null) {
    cmd_data.promptoverlay.?.deinit(self.allocr());
    cmd_data.promptoverlay = null;
  }
  
  if (cmd_data.onKey) |onKey| {
    if (try onKey(self, keysym)) {
      return;
    }
  }
  
  if (keysym.raw == kbd.Keysym.BACKSPACE) {
    _ = cmd_data.cmdinp.popOrNull();
    self.needs_update_cursor = true;
  }
  else if (keysym.raw == kbd.Keysym.NEWLINE) {
    try cmd_data.onInputted(self);
  }
  else if (keysym.getPrint()) |key| {
    try cmd_data.cmdinp.append(self.allocr(), key);
    self.needs_update_cursor = true;
  }
  else if (keysym.getMultibyte()) |seq| {
    try cmd_data.cmdinp.appendSlice(self.allocr(), seq);
    self.needs_update_cursor = true;
  }
}

pub fn renderStatus(self: *editor.Editor) !void {
  try self.moveCursor(self.getTextHeight(), 0);
  try self.writeAll(editor.Editor.CLEAR_LINE);
  const cmd_data: *editor.CommandData = self.getCmdData();
  if (cmd_data.promptoverlay) |promptoverlay| {
    try self.writeAll(promptoverlay.slice());
  } else if (cmd_data.prompt) |prompt| {
    try self.writeAll(prompt);
  }
  try self.moveCursor((self.getTextHeight() + 1), 0);
  try self.writeAll(editor.Editor.CLEAR_LINE);
  try self.writeAll(" >");
  var col: u32 = 0;
  for (cmd_data.cmdinp.items) |byte| {
    if (col > self.getTextWidth()) {
      return;
    }
    try self.outw.writeByte(byte);
    col += 1;
  }
}

pub fn handleOutput(self: *editor.Editor) !void {
  if (self.needs_redraw) {
    try self.refreshScreen();
    try self.renderText();
  }
  if (self.needs_update_cursor) {
    try Impl.renderStatus(self);
    self.needs_update_cursor = false;
  }
}