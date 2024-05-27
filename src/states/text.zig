//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const Impl = @This();

const std = @import("std");

const kbd = @import("../kbd.zig");
const text = @import("../text.zig");
const editor = @import("../editor.zig");

const this_shortcuts = @import("../shortcuts.zig").STATE_TEXT;
const this_shortcuts_help = @import("../shortcuts.zig").STATE_TEXT_HELP;

pub fn handleTextNavigation(self: *editor.Editor, keysym: *const kbd.Keysym) !bool {
  if (!keysym.ctrl_key and keysym.key == kbd.Keysym.Key.up) {
    self.text_handler.goUp(self);
    return true;
  }
  else if (!keysym.ctrl_key and keysym.key == kbd.Keysym.Key.down) {
    self.text_handler.goDown(self);
    return true;
  }
  else if (!keysym.ctrl_key and keysym.key == kbd.Keysym.Key.left) {
    self.text_handler.goLeft(self);
    return true;
  }
  else if (!keysym.ctrl_key and keysym.key == kbd.Keysym.Key.right) {
    self.text_handler.goRight(self);
    return true;
  }
  else if (keysym.ctrl_key and keysym.key == kbd.Keysym.Key.left) {
    self.text_handler.goLeftWord(self);
    return true;
  }
  else if (keysym.ctrl_key and keysym.key == kbd.Keysym.Key.right) {
    self.text_handler.goRightWord(self);
    return true;
  }
  else if (keysym.key == kbd.Keysym.Key.pgup) {
    self.text_handler.goPgUp(self, false);
    return true;
  }
  else if (keysym.key == kbd.Keysym.Key.pgdown) {
    self.text_handler.goPgDown(self, false);
    return true;
  }
  else if (keysym.key == kbd.Keysym.Key.scroll_up) {
    self.text_handler.goPgUp(self, true);
    return true;
  }
  else if (keysym.key == kbd.Keysym.Key.scroll_down) {
    self.text_handler.goPgDown(self, true);
    return true;
  }
  else if (keysym.key == kbd.Keysym.Key.home) {
    self.text_handler.goHead(self);
    return true;
  }
  else if (keysym.key == kbd.Keysym.Key.end) {
    self.text_handler.goTail(self);
    return true;
  }
  else if (keysym.isMouse()) {
    if (!keysym.key.mouse.is_release) {
      self.text_handler.gotoCursor(self, keysym.key.mouse.x - 1, keysym.key.mouse.y - 1);
      return true;
    }
  }
  return false;
}

pub fn handleInput(
  self: *editor.Editor,
  keysym: *const kbd.Keysym,
  is_clipboard: bool
) !void {
  if (try handleTextNavigation(self, keysym)) {
    return;
  }
  else if (this_shortcuts.key("help", keysym)) {
    self.copyHideableMsg(&this_shortcuts_help);
    self.needs_redraw = true;
  }
  else if (this_shortcuts.key("quit", keysym)) {
    if (self.text_handler.buffer_changed) {
      self.setState(editor.State.command);
      self.setCmdData(&.{
        .prompt = PROMPT_QUIT_CONFIRM,
        .fns = editor.Commands.Prompt.Fns,
        .args = .{
          .prompt = .{
            .handleYes = QuitPrompt.handleYes,
            .handleNo = QuitPrompt.handleNo,
          },
        },
      });
      return;
    }
    return error.Quit;
  }
  else if (this_shortcuts.key("save", keysym)) {
    if (
      self.text_handler.file == null and
      self.text_handler.file_path.items.len == 0
    ) {
      self.setState(editor.State.command);
      self.setCmdData(&.{
        .prompt = editor.Commands.Open.PROMPT_SAVE,
        .fns = editor.Commands.Open.FnsTryToSave,
      });
    } else {
      self.text_handler.save(self) catch |err| {
        self.setState(editor.State.command);
        self.setCmdData(&.{
          .prompt = editor.Commands.Open.PROMPT_SAVE_NEW,
          .fns = editor.Commands.Open.FnsTryToSave,
        });
        try editor.Commands.Open.setupUnableToSavePrompt(self, err);
      };
    }
  }
  else if (this_shortcuts.key("open", keysym)) {
    self.setState(editor.State.command);
    self.setCmdData(&.{
      .prompt = editor.Commands.Open.PROMPT_OPEN,
      .fns = editor.Commands.Open.Fns,
    });
  }
  else if (this_shortcuts.key("goto", keysym)) {
    self.setState(editor.State.command);
    self.setCmdData(&.{
      .prompt = editor.Commands.GotoLine.PROMPT,
      .fns = editor.Commands.GotoLine.Fns,
    });
  }
  else if (this_shortcuts.key("block", keysym)) {
    self.setState(editor.State.mark);
  }
  else if (this_shortcuts.key("all", keysym)) {
    self.setState(editor.State.mark);
    self.text_handler.markAll(self);
  }
  else if (this_shortcuts.key("line", keysym)) {
    self.setState(editor.State.mark);
    self.text_handler.markLine(self);
  }
  else if (this_shortcuts.key("dup", keysym)) {
    try self.text_handler.duplicateLine(self);
  }
  else if (this_shortcuts.key("delword", keysym)) {
    try self.text_handler.deleteWord(self);
  }
  else if (this_shortcuts.key("delline", keysym)) {
    try self.text_handler.deleteLine(self);
  }
  else if (this_shortcuts.key("paste", keysym)) {
    try self.text_handler.paste(self);
  }
  else if (this_shortcuts.key("find", keysym)) {
    self.setState(.command);
    self.setCmdData(&.{
      .prompt = editor.Commands.Find.PROMPT,
      .fns = editor.Commands.Find.Fns,
    });
  }
  else if (this_shortcuts.key("undo", keysym)) {
    self.text_handler.undo_mgr.undo(self) catch |err| {
      if (err == error.OutOfMemoryUndo) {
        try self.text_handler.handleUndoOOM(self);
      } else {
        return err;
      }
    };
  }
  else if (this_shortcuts.key("redo", keysym)) {
    self.text_handler.undo_mgr.redo(self) catch |err| {
      if (err == error.OutOfMemoryUndo) {
        try self.text_handler.handleUndoOOM(self);
      } else {
        return err;
      }
    };
  }
  else if (keysym.raw == kbd.Keysym.BACKSPACE) {
    try self.text_handler.deleteChar(self, false);
  }
  else if (keysym.key == kbd.Keysym.Key.del) {
    try self.text_handler.deleteChar(self, true);
  }
  else if (keysym.raw == kbd.Keysym.NEWLINE) {
    if (is_clipboard) {
      try self.text_handler.insertChar(self, "\n", true);
    } else {
      try self.text_handler.insertNewline(self);
    }
  }
  else if (!is_clipboard and keysym.raw == kbd.Keysym.TAB) {
    try self.text_handler.insertTab(self);
  }
  else if (!is_clipboard and keysym.isChar('{')) {
    try self.text_handler.insertCharPair(self, "{", "}");
  }
  else if (!is_clipboard and keysym.isChar('}')) {
    try self.text_handler.insertCharUnlessOverwrite(self, "}");
  }
  else if (!is_clipboard and keysym.isChar('(')) {
    try self.text_handler.insertCharPair(self, "(", ")");
  }
  else if (!is_clipboard and keysym.isChar(')')) {
    try self.text_handler.insertCharUnlessOverwrite(self, ")");
  }
  else if (!is_clipboard and keysym.isChar('[')) {
    try self.text_handler.insertCharPair(self, "[", "]");
  }
  else if (!is_clipboard and keysym.isChar(']')) {
    try self.text_handler.insertCharUnlessOverwrite(self, "]");
  }
  else if (!is_clipboard and keysym.isChar('\'')) {
    try self.text_handler.insertCharPair(self, "'", "'");
  }
  else if (!is_clipboard and keysym.isChar('"')) {
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
  try self.writeAll(editor.Editor.ESC_CLEAR_LINE);
  if (text_handler.buffer_changed) {
    try self.writeAll("[*] ");
  } else {
    try self.writeAll("[ ] ");
  }
  if (text_handler.file_path.items.len > 0) {
    try self.writeAll(editor.Editor.ESC_FG_EMPHASIZE);
    try self.writeAll(text_handler.file_path.items);
    try self.writeAll(editor.Editor.ESC_COLOR_DEFAULT);
  }
  var status: [32]u8 = undefined;
  const status_slice = try std.fmt.bufPrint(
    &status,
    "{d}:{d}",
    .{
      self.text_handler.lineinfo.getLineNo(self.text_handler.cursor.row),
      self.text_handler.cursor.gfx_col+1
    },
  );
  try self.moveCursor(
    self.getTextHeight(),
    @intCast(self.w_width - status_slice.len),
  );
  try self.writeAll(status_slice);
}

pub const PROMPT_QUIT_CONFIRM = "Save before quitting?";

const QuitPrompt = struct {
  fn handleYes(self: *editor.Editor) !void {
    self.text_handler.save(self) catch |err| {
      self.setState(editor.State.command);
      self.setCmdData(&.{
        .prompt = editor.Commands.Open.PROMPT_SAVE_NEW,
        .fns = editor.Commands.Open.FnsTryToSave,
      });
      try editor.Commands.Open.setupUnableToSavePrompt(self, err);
      return;
    };
    return error.Quit;
  }
  
  fn handleNo(self: *editor.Editor) !void {
    _ = self;
    return error.Quit;
  }
};