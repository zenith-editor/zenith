//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const Impl = @This();

const kbd = @import("../kbd.zig");
const text = @import("../text.zig");
const editor = @import("../editor.zig");
const std = @import("std");

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
        .prompt = editor.Commands.Open.PROMPT_SAVE,
        .fns = editor.Commands.Open.FnsTryToSave,
      });
    } else {
      self.text_handler.save(self) catch |err| {
        self.setState(editor.State.command);
        self.setCmdData(.{
          .prompt = editor.Commands.Open.PROMPT_SAVE_NEW,
          .fns = editor.Commands.Open.FnsTryToSave,
        });
        try editor.Commands.Open.setupUnableToSavePrompt(self, err);
      };
    }
  }
  else if (keysym.ctrl_key and keysym.isChar('o')) {
    self.setState(editor.State.command);
    self.setCmdData(.{
      .prompt = editor.Commands.Open.PROMPT_OPEN,
      .fns = editor.Commands.Open.Fns,
    });
  }
  else if (keysym.ctrl_key and keysym.isChar('g')) {
    self.setState(editor.State.command);
    self.setCmdData(.{
      .prompt = editor.Commands.GotoLine.PROMPT,
      .fns = editor.Commands.GotoLine.Fns,
    });
  }
  else if (keysym.ctrl_key and keysym.isChar('a')) {
    self.setState(editor.State.mark);
    self.text_handler.markAll(self);
  }
  else if (keysym.ctrl_key and keysym.isChar('l')) {
    self.setState(editor.State.mark);
    self.text_handler.markLine(self);
  }
  else if (keysym.ctrl_key and keysym.isChar('b')) {
    self.setState(editor.State.mark);
  }
  else if (keysym.ctrl_key and keysym.isChar('d')) {
    try self.text_handler.duplicateLine(self);
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
      .prompt = editor.Commands.Find.PROMPT,
      .fns = editor.Commands.Find.Fns,
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
    try self.text_handler.insertNewline(self);
  }
  else if (keysym.raw == kbd.Keysym.TAB) {
    try self.text_handler.insertTab(self);
  }
  else if (keysym.isChar('{')) {
    try self.text_handler.insertCharPair(self, "{", "}");
  }
  else if (keysym.isChar('(')) {
    try self.text_handler.insertCharPair(self, "(", ")");
  }
  else if (keysym.isChar('[')) {
    try self.text_handler.insertCharPair(self, "[", "]");
  }
  else if (keysym.isChar('\'')) {
    try self.text_handler.insertCharPair(self, "'", "'");
  }
  else if (keysym.isChar('"')) {
    try self.text_handler.insertCharPair(self, "\"", "\"");
  }
  else if (keysym.getPrint()) |key| {
    try self.text_handler.insertChar(self, &[_]u8{key}, true);
  }
  else if (keysym.getMultibyte()) |seq| {
    try self.text_handler.insertChar(self, seq, true);
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
  try self.writeFmt(" {}:{}", .{text_handler.cursor.row+1, text_handler.cursor.gfx_col+1});
}
