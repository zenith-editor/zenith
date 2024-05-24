//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const Impl = @This();

const kbd = @import("../kbd.zig");
const text = @import("../text.zig");
const editor = @import("../editor.zig");
const encoding = @import("../encoding.zig");

const CMD_PROMPT = editor.Editor.ESC_FG_EMPHASIZE ++ " >" ++ editor.Editor.ESC_COLOR_DEFAULT;
const CMD_PROMPT_COLS = 2;

pub fn onUnset(self: *editor.Editor, next_state: editor.State) void {
  const cmd_data: *editor.CommandData = self.getCmdData();
  if (cmd_data.fns.onUnset) |cmdOnUnset| {
    cmdOnUnset(self, next_state);
  }
  self.unsetCmdData();
}

pub fn handleInput(
  self: *editor.Editor,
  keysym: *const kbd.Keysym,
  is_clipboard: bool
) !void {
  _ = is_clipboard;
  
  var cmd_data: *editor.CommandData = self.getCmdData();
  if (keysym.raw == kbd.Keysym.ESC) {
    self.setState(.text);
    return;
  }
  
  if (cmd_data.promptoverlay != null) {
    cmd_data.promptoverlay.?.deinit(self.allocr());
    cmd_data.promptoverlay = null;
  }
  
  if (cmd_data.fns.onKey) |onKey| {
    if (try onKey(self, keysym)) {
      return;
    }
  }
  
  if (keysym.raw == kbd.Keysym.BACKSPACE) {
    Impl.deleteCharBack(self, cmd_data);
  }
  else if (keysym.key == kbd.Keysym.Key.del) {
    Impl.deleteCharFront(self, cmd_data);
  }
  else if (keysym.raw == kbd.Keysym.NEWLINE) {
    try cmd_data.fns.onInputted(self);
  }
  
  else if (keysym.key == kbd.Keysym.Key.left) {
    Impl.goLeft(self, cmd_data);
  }
  else if (keysym.key == kbd.Keysym.Key.right) {
    Impl.goRight(self, cmd_data);
  }
  else if (keysym.key == kbd.Keysym.Key.home) {
    cmd_data.cmdinp_pos.col = 0;
    cmd_data.cmdinp_pos.gfx_col = 0;
    self.needs_update_cursor = true;
  }
  else if (keysym.key == kbd.Keysym.Key.end) {
    cmd_data.cmdinp_pos.col = 0;
    cmd_data.cmdinp_pos.gfx_col = 0;
    while (cmd_data.cmdinp_pos.col < cmd_data.cmdinp.items.len) {
      const start_byte = cmd_data.cmdinp.items[cmd_data.cmdinp_pos.col];
      const seqlen = encoding.sequenceLen(start_byte) catch unreachable;
      cmd_data.cmdinp_pos.col += seqlen;
      cmd_data.cmdinp_pos.gfx_col += 1;
    }
    self.needs_update_cursor = true;
  }
  
  else if (keysym.getPrint()) |key| {
    try cmd_data.cmdinp.insert(self.allocr(), cmd_data.cmdinp_pos.col, key);
    cmd_data.cmdinp_pos.col += 1;
    cmd_data.cmdinp_pos.gfx_col += 1;
    self.needs_update_cursor = true;
  }
  else if (keysym.getMultibyte()) |seq| {
    try cmd_data.cmdinp.insertSlice(self.allocr(), cmd_data.cmdinp_pos.col, seq);
    cmd_data.cmdinp_pos.col += @intCast(seq.len);
    cmd_data.cmdinp_pos.gfx_col += 1;
    self.needs_update_cursor = true;
  }
}

pub fn renderStatus(self: *editor.Editor) !void {
  try self.moveCursor(self.getTextHeight(), 0);
  try self.writeAll(editor.Editor.ESC_CLEAR_LINE);
  const cmd_data: *editor.CommandData = self.getCmdData();
  if (cmd_data.promptoverlay) |promptoverlay| {
    try self.writeAll(promptoverlay.slice());
  } else if (cmd_data.prompt) |prompt| {
    try self.writeAll(prompt);
  }
  try self.moveCursor((self.getTextHeight() + 1), 0);
  try self.writeAll(editor.Editor.ESC_CLEAR_LINE);
  try self.writeAll(CMD_PROMPT);
  var col: u32 = 0;
  for (cmd_data.cmdinp.items) |byte| {
    if (col > self.getTextWidth()) {
      return;
    }
    try self.outw.writeByte(byte);
    col += 1;
  }
  try self.moveCursor(
    (self.getTextHeight() + 1),
    @intCast(CMD_PROMPT_COLS + cmd_data.cmdinp_pos.gfx_col)
  );
}

pub fn handleOutput(self: *editor.Editor) !void {
  if (self.needs_redraw) {
    try self.refreshScreen();
    try self.renderText();
    self.needs_redraw = false;
  }
  if (self.needs_update_cursor) {
    try Impl.renderStatus(self);
    self.needs_update_cursor = false;
  }
}

fn goLeft(self: *editor.Editor, cmd_data: *editor.CommandData) void {
  var pos: *text.TextPos = &cmd_data.cmdinp_pos;
  if (pos.col == 0) {
    return;
  }
  pos.col -= 1;
  const start_byte = cmd_data.cmdinp.items[pos.col];
  if (encoding.isContByte(start_byte)) {
    // prev char is multi byte
    while (pos.col > 0) {
      const maybe_cont_byte = cmd_data.cmdinp.items[pos.col];
      if (encoding.isContByte(maybe_cont_byte)) {
        pos.col -= 1;
      } else {
        break;
      }
    }
  }
  pos.gfx_col -= 1;
  self.needs_update_cursor = true;
}

fn goRight(self: *editor.Editor, cmd_data: *editor.CommandData) void {
  var pos: *text.TextPos = &cmd_data.cmdinp_pos;
  if (pos.col == cmd_data.cmdinp.items.len) {
    return;
  }
  const start_byte = cmd_data.cmdinp.items[pos.col];
  const seqlen = encoding.sequenceLen(start_byte) catch unreachable;
  pos.col += seqlen;
  pos.gfx_col += 1;
  self.needs_update_cursor = true;
}

fn deleteCharBack(self: *editor.Editor, cmd_data: *editor.CommandData) void {
  const pos: *text.TextPos = &cmd_data.cmdinp_pos;
  if (pos.col == 0) {
    return;
  }
  Impl.goLeft(self, cmd_data);
  const start_byte = cmd_data.cmdinp.items[pos.col];
  const seqlen = encoding.sequenceLen(start_byte) catch unreachable;
  cmd_data.cmdinp.replaceRangeAssumeCapacity(pos.col, seqlen, "");
  self.needs_update_cursor = true;
}

fn deleteCharFront(self: *editor.Editor, cmd_data: *editor.CommandData) void {
  const pos: *text.TextPos = &cmd_data.cmdinp_pos;
  if (pos.col == cmd_data.cmdinp.items.len) {
    return;
  }
  const start_byte = cmd_data.cmdinp.items[pos.col];
  const seqlen = encoding.sequenceLen(start_byte) catch unreachable;
  cmd_data.cmdinp.replaceRangeAssumeCapacity(pos.col, seqlen, "");
  self.needs_update_cursor = true;
}
