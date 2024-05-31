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

const this_shortcuts = @import("../shortcuts.zig").STATE_MARK;
const this_shortcuts_help = @import("../shortcuts.zig").STATE_MARK_HELP;

const handleTextNavigation = @import("./text.zig").handleTextNavigation;

pub fn onSet(self: *editor.Editor) void {
  if (self.text_handler.markers == null) {
    self.text_handler.markStart(self);
  }
}

pub fn onUnset(self: *editor.Editor, next_state: editor.State) void {
  if (next_state == .text) {
    self.text_handler.markers = null;
  }
}

pub fn handleInput(
  self: *editor.Editor,
  keysym: *const kbd.Keysym,
  is_clipboard: bool
) !void {
  _ = is_clipboard;
  
  if (keysym.raw == kbd.Keysym.ESC) {
    self.setState(.text);
    return;
  }
  
  if (try handleTextNavigation(self, keysym)) {
    if (self.conf.update_mark_on_nav and self.text_handler.markers != null) {
      self.text_handler.markEnd(self);
    }
    return;
  }
  else if (keysym.raw == kbd.Keysym.NEWLINE) {
    if (self.text_handler.markers == null) {
      self.text_handler.markStart(self);
    } else {
      self.text_handler.markEnd(self);
    }
  }
  
  else if (keysym.key == kbd.Keysym.Key.del) {
    try self.text_handler.deleteMarked(self);
  }
  else if (keysym.raw == kbd.Keysym.BACKSPACE) {
    try self.text_handler.deleteMarked(self);
    self.setState(.text);
  }
  
  else if (this_shortcuts.key("help", keysym)) {
    self.copyHideableMsg(&this_shortcuts_help);
    self.needs_redraw = true;
  }
  
  else if (this_shortcuts.key("copy", keysym)) {
    try self.text_handler.copy(self);
    self.setState(.text);
  }
  else if (this_shortcuts.key("cut", keysym)) {
    try self.text_handler.copy(self);
    try self.text_handler.deleteMarked(self);
    self.setState(.text);
  }
  
  else if (this_shortcuts.key("rep", keysym)) {
    self.setState(.command);
    self.setCmdData(&.{
      .prompt = editor.Commands.Replace.PROMPT,
      .fns = editor.Commands.Replace.Fns,
    });
  }
  else if (this_shortcuts.key("find", keysym)) {
    self.setState(.command);
    self.setCmdData(&.{
      .prompt = editor.Commands.Find.PROMPT,
      .fns = editor.Commands.Find.Fns,
    });
  }
  
  else if (this_shortcuts.key("indent", keysym)) {
    try self.text_handler.indentMarked(self);
  }
  else if (this_shortcuts.key("dedent", keysym)) {
    try self.text_handler.dedentMarked(self);
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
  try self.writeAll(editor.Editor.ESC_CLEAR_LINE);
  try self.writeAll("Enter: mark end, Del: delete");
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
    self.getTextHeight() + 1,
    @intCast(self.w_width - status_slice.len),
  );
  try self.writeAll(status_slice);
}