//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const Cmd = @This();

const std = @import("std");
const builtin = @import("builtin");

const kbd = @import("../kbd.zig");
const editor = @import("../editor.zig");

const Expr = @import("../patterns/expr.zig");

pub fn onUnset(self: *editor.Editor, next_state: editor.State) void {
  if (next_state == .text) {
    self.text_handler.markers = null;
  }
}

fn findForwards(self: *editor.Editor, cmd_data: *editor.CommandData) !void {
  var text_handler = &self.text_handler;
  if (cmd_data.cmdinp.items.len == 0) {
    return;
  }
  try self.text_handler.flushGapBuffer(self);
  
  const offset = if (self.text_handler.markers) |*markers|
    (markers.end)
  else
    (text_handler.calcOffsetFromCursor());
  
  if (offset >= text_handler.buffer.items.len) {
    cmd_data.replacePromptOverlay(self, .{ .static = PROMPT_NOT_FOUND, });
    return;
  }
  
  var opt_pos: ?usize = null;
  var opt_end: ?usize = null;
  if (cmd_data.args != null and cmd_data.args.?.find.regex != null) {
    const regex = cmd_data.args.?.find.regex.?;
    if (try regex.find(text_handler.buffer.items[offset..])) |find_result| {
      opt_pos = offset + find_result.start;
      opt_end = offset + find_result.end;
    }
  } else {
    opt_pos = std.mem.indexOfPos(
      u8,
      text_handler.buffer.items,
      offset,
      cmd_data.cmdinp.items,
    );
    if (opt_pos) |pos| {
      opt_end = pos + cmd_data.cmdinp.items.len;
    }
  }
  
  if (opt_pos) |pos| {
    try text_handler.gotoPos(self, @intCast(pos));
    self.text_handler.markers = .{
      .start = @intCast(pos),
      .end = @intCast(opt_end.?),
      .start_cur = self.text_handler.cursor,
    };
  } else {
    cmd_data.replacePromptOverlay(self, .{ .static = PROMPT_NOT_FOUND, });
  }
}

fn findBackwards(self: *editor.Editor, cmd_data: *editor.CommandData) !void { 
  var text_handler = &self.text_handler;
  if (cmd_data.cmdinp.items.len == 0) {
    return;
  }
  
  const offset = if (self.text_handler.markers) |*markers|
    (markers.start)
  else
    (text_handler.calcOffsetFromCursor());
  
  if (offset == 0) {
    cmd_data.replacePromptOverlay(self, .{ .static = PROMPT_NOT_FOUND, });
    return;
  }
  
  try self.text_handler.flushGapBuffer(self);
  
  var opt_pos: ?usize = null;
  var opt_end: ?usize = null;
  if (cmd_data.args != null and cmd_data.args.?.find.regex != null) {
    const regex = cmd_data.args.?.find.regex.?;
    if (try regex.findBackwards(text_handler.buffer.items[0..offset])) |find_result| {
      opt_pos = find_result.start;
      opt_end = find_result.end;
    }
  } else {
    opt_pos = std.mem.lastIndexOf(
      u8,
      text_handler.buffer.items[0..offset],
      cmd_data.cmdinp.items,
    );
    if (opt_pos) |pos| {
      opt_end = pos + cmd_data.cmdinp.items.len;
    }
  }
  
  if (opt_pos) |pos| {
    try text_handler.gotoPos(self, @intCast(pos));
    self.text_handler.markers = .{
      .start = @intCast(pos),
      .end = @intCast(opt_end.?),
      .start_cur = self.text_handler.cursor,
    };
  } else {
    cmd_data.replacePromptOverlay(self, .{ .static = PROMPT_NOT_FOUND, });
  }
}

pub fn onInputted(self: *editor.Editor) !void {
  self.needs_update_cursor = true;
  const cmd_data: *editor.CommandData = self.getCmdData();
  try Cmd.findForwards(self, cmd_data);
}

fn toBlockMode(self: *editor.Editor, cmd_data: *editor.CommandData) !void {
  if (self.text_handler.markers != null) {
    self.setState(editor.State.mark);
    self.needs_redraw = true;
  } else {
    cmd_data.replacePromptOverlay(self, .{ .static = PROMPT_NOTHING_MARKED, });
  }
}

fn toReplace(self: *editor.Editor, cmd_data: *editor.CommandData) void {
  if (self.text_handler.markers != null) {
    cmd_data.replace(self, .{
      .prompt = editor.Commands.Replace.PROMPT,
      .fns = editor.Commands.Replace.Fns,
    });
  } else {
    cmd_data.replacePromptOverlay(self, .{ .static = PROMPT_NOTHING_MARKED, });
  }
}

fn toReplaceAll(self: *editor.Editor, cmd_data: *editor.CommandData) !void {
  if (self.text_handler.markers == null) {
    self.text_handler.markAll(self);
  }
  const needle = try self.allocr().dupe(u8, cmd_data.cmdinp.items);
  cmd_data.replace(self, .{
    .prompt = editor.Commands.Replace.PROMPT_ALL,
    .fns = editor.Commands.Replace.FnsAll,
    .args = .{
      .replace_all = .{ .needle = needle, },
    },
  });
}

pub fn onKey(self: *editor.Editor, keysym: kbd.Keysym) !bool {
  const cmd_data: *editor.CommandData = self.getCmdData();
  if (keysym.key == kbd.Keysym.Key.up) {
    try Cmd.findBackwards(self, cmd_data);
    return true;
  }
  else if (keysym.key == kbd.Keysym.Key.down) {
    try Cmd.findForwards(self, cmd_data);
    return true;
  }
  else if (keysym.ctrl_key and keysym.isChar('b')) {
    try Cmd.toBlockMode(self, cmd_data);
    return true;
  }
  else if (keysym.ctrl_key and keysym.isChar('r')) {
    Cmd.toReplace(self, cmd_data);
    self.needs_update_cursor = true;
    return true;
  }
  else if (keysym.ctrl_key and keysym.isChar('h')) {
    try Cmd.toReplaceAll(self, cmd_data);
    self.needs_update_cursor = true;
    return true;
  }
  else if (keysym.ctrl_key and keysym.isChar('e')) {
    switch (Expr.create(self.allocr(), cmd_data.cmdinp.items)) {
      .ok => |expr| {
        cmd_data.replaceArgs(self, .{ .find = .{
          .regex = expr,
        }, });
        try Cmd.findForwards(self, cmd_data);
      },
      .err => |err| {
        cmd_data.replacePromptOverlay(self, .{
          .owned = try std.fmt.allocPrint(
            self.allocr(),
            "Invalid regex (ERR: {}@{})",
            .{err.type, err.pos}
          ),
        });
        self.needs_update_cursor = true;
      },
    }
    return true;
  }
  return false;
}

pub const PROMPT = "Find (next = Enter, ^b = to block, ^r = to replace, ^h = to repl. all):";
pub const PROMPT_NOTHING_MARKED = "Nothing marked!";
pub const PROMPT_NOT_FOUND = "Not found!";

pub const Fns: editor.CommandData.FnTable = .{
  .onInputted = Cmd.onInputted,
  .onKey = Cmd.onKey,
  .onUnset = Cmd.onUnset,
};