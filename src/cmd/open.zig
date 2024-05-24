//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const Cmd = @This();

const std = @import("std");
const builtin = @import("builtin");

const text = @import("../text.zig");
const editor = @import("../editor.zig");

fn onInputtedGeneric(self: *editor.Editor) !?text.TextHandler.OpenFileArgs {
  self.needs_update_cursor = true;
  const cwd = std.fs.cwd();
  var cmd_data: *editor.CommandData = self.getCmdData();
  const file_path: []const u8 = cmd_data.cmdinp.items;
  var opened_file: ?std.fs.File = null;
  cwd.access(file_path, .{}) catch |err| switch(err) {
    error.FileNotFound => {
      return .{
        .file = opened_file,
        .file_path = file_path,
      };
    },
    else => {
      try cmd_data.replacePromptOverlayFmt(self, PROMPT_ERR_OPEN_FILE, .{err});
      return null;
    },
  };
  if (opened_file == null) {
    opened_file = cwd.openFile(file_path, .{
      .mode = .read_write,
      .lock = .shared,
    }) catch |err| {
      try cmd_data.replacePromptOverlayFmt(self, PROMPT_ERR_OPEN_FILE, .{err});
      return null;
    };
  }
  return .{
    .file = opened_file,
    .file_path = file_path,
  };
}

pub fn onInputted(self: *editor.Editor) !void {
  if (try Cmd.onInputtedGeneric(self)) |opened_file| {
    self.text_handler.open(self, opened_file, true) catch |err| {
      try self.getCmdData().replacePromptOverlayFmt(self, PROMPT_ERR_OPEN_FILE, .{err});
      return;
    };
    self.setState(.text);
    self.needs_redraw = true;
  }
}

pub fn setupUnableToSavePrompt(self: *editor.Editor, err: anyerror) !void {
  try self.getCmdData().replacePromptOverlayFmt(self, PROMPT_ERR_SAVE_FILE, .{err});
  // TODO: offer user another location to save
}

pub fn onInputtedTryToSave(self: *editor.Editor) !void {
  if (try Cmd.onInputtedGeneric(self)) |opened_file| {
    try self.text_handler.open(self, opened_file, false);
    self.text_handler.save(self) catch |err| {
      try Cmd.setupUnableToSavePrompt(self, err);
      return;
    };
    self.setState(.text);
    self.needs_redraw = true;
  }
}

pub const PROMPT_OPEN = "Open file:";
pub const PROMPT_SAVE = "Save file:";
pub const PROMPT_SAVE_NEW = "Save file to new location:";
pub const PROMPT_ERR_NEW_FILE = "Unable to create new file! (ERR: {})";
pub const PROMPT_ERR_OPEN_FILE = "Unable to open file! (ERR: {})";
pub const PROMPT_ERR_SAVE_FILE =
  "Unable to save file, try saving to another location! (ERR: {})";

pub const Fns: editor.CommandData.FnTable = .{
  .onInputted = Cmd.onInputted,
};

pub const FnsTryToSave: editor.CommandData.FnTable = .{
  .onInputted = Cmd.onInputtedTryToSave,
};
