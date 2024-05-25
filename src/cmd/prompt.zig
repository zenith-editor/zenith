//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const Cmd = @This();

const std = @import("std");

const editor = @import("../editor.zig");
const kbd = @import("../kbd.zig");

fn onInputted(self: *editor.Editor) !void {
  _ = self;
}

pub fn onKey(self: *editor.Editor, keysym: *const kbd.Keysym) !bool {
  const cmd_data = self.getCmdData();
  // copy of prompt_args must be stored here so
  // as to prevent it being overwritten
  const prompt_args = cmd_data.args.?.prompt;
  if (keysym.getPrint()) |key| {
    if (key == 'y') {
      try prompt_args.handleYes(self);
      return true;
    } else if (key == 'n') {
      try prompt_args.handleNo(self);
      return true;
    } else {
      cmd_data.replacePromptOverlay(self, PROMPT_ERR_ENTER_YES_OR_NO);
      return true;
    }
  }
  return false;
}

pub const PROMPT_ERR_ENTER_YES_OR_NO = "Please enter 'y' or 'n'";

pub const Fns: editor.CommandData.FnTable = .{
  .onInputted = Cmd.onInputted,
  .onKey = Cmd.onKey,
};
