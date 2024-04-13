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
  if (keysym.key == kbd.Keysym.Key.up) {
    self.text_handler.goUp(self);
  }
  else if (keysym.key == kbd.Keysym.Key.down) {
    self.text_handler.goDown(self);
  }
  else if (keysym.key == kbd.Keysym.Key.left) {
    self.text_handler.goLeft(self);
  }
  else if (keysym.key == kbd.Keysym.Key.right) {
    self.text_handler.goRight(self);
  }
  else if (keysym.key == kbd.Keysym.Key.pgup) {
    self.text_handler.goPgUp(self);
  }
  else if (keysym.key == kbd.Keysym.Key.pgdown) {
    self.text_handler.goPgDown(self);
  }
  else if (keysym.key == kbd.Keysym.Key.home) {
    self.text_handler.goHead(self);
  }
  else if (keysym.key == kbd.Keysym.Key.end) {
    try self.text_handler.goTail(self);
  }
  else if (keysym.ctrl_key and keysym.isChar('q')) {
    self.setState(editor.State.quit);
  }
  else if (keysym.ctrl_key and keysym.isChar('s')) {
    if (self.text_handler.file == null) {
      self.setState(editor.State.command);
      self.setCmdData(.{
        .prompt = "Save file:",
        .onInputted = editor.Commands.Open.onInputtedTryToSave,
      });
    } else {
      self.text_handler.save(self) catch |err| {
        self.setState(editor.State.command);
        self.setCmdData(.{
          .prompt = "Save file to new location:",
          .onInputted = editor.Commands.Open.onInputtedTryToSave,
        });
        try editor.Commands.Open.setupUnableToSavePrompt(self, err);
      };
    }
  }
  else if (keysym.ctrl_key and keysym.isChar('o')) {
    self.setState(editor.State.command);
    self.setCmdData(.{
      .prompt = "Open file:",
      .onInputted = editor.Commands.Open.onInputted,
    });
  }
  else if (keysym.ctrl_key and keysym.isChar('g')) {
    self.setState(editor.State.command);
    self.setCmdData(.{
      .prompt = "Go to line (first = g, last = G):",
      .onInputted = editor.Commands.GotoLine.onInputted,
      .onKey = editor.Commands.GotoLine.onKey,
    });
  }
  else if (keysym.ctrl_key and keysym.isChar('b')) {
    self.setState(editor.State.mark);
  }
  else if (keysym.ctrl_key and keysym.isChar('v')) {
    try self.text_handler.paste(self);
  }
  else if (keysym.ctrl_key and keysym.isChar('z')) {
    try self.text_handler.undo_mgr.undo(self);
  }
  else if (keysym.ctrl_key and keysym.isChar('f')) {
    self.setState(.command);
    self.setCmdData(.{
      .prompt = "Find (next = Enter):",
      .onInputted = editor.Commands.Find.onInputted,
      .onKey = editor.Commands.Find.onKey,
    });
  }
  else if (keysym.ctrl_key and keysym.isChar('y')) {
    try self.text_handler.undo_mgr.redo(self);
  }
  else if (keysym.raw == kbd.Keysym.BACKSPACE) {
    try self.text_handler.deleteChar(self, false);
  }
  else if (keysym.key == kbd.Keysym.Key.del) {
    try self.text_handler.deleteChar(self, true);
  }
  else if (keysym.raw == kbd.Keysym.NEWLINE) {
    try self.text_handler.insertChar(self, "\n");
  }
  else if (keysym.getPrint()) |key| {
    try self.text_handler.insertChar(self, &[_]u8{key});
  }
  else if (keysym.getMultibyte()) |seq| {
    try self.text_handler.insertChar(self, seq);
  }
}

pub fn handleOutput(self: *editor.Editor) !void {
  if (self.needs_redraw) {
    try self.refreshScreen();
    try self.renderText();
    self.needs_redraw = false;
  }
  if (self.needs_update_cursor) {
    try Impl.renderStatus(self);
    try self.updateCursorPos();
    self.needs_update_cursor = false;
  }
}

pub fn renderStatus(self: *editor.Editor) !void {
  try self.moveCursor(self.getTextHeight(), 0);
  const text_handler: *const text.TextHandler = &self.text_handler;
  try self.writeAll(editor.Editor.CLEAR_LINE);
  if (text_handler.buffer_changed) {
    try self.writeAll("[*]");
  } else {
    try self.writeAll("[ ]");
  }
  try self.writeFmt(" {}:{}", .{text_handler.cursor.row+1, text_handler.cursor.col+1});
}
