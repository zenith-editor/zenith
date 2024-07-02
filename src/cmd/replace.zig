//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");
const builtin = @import("builtin");

const kbd = @import("../kbd.zig");
const editor = @import("../editor.zig");

fn onUnset(self: *editor.Editor, _: editor.State) void {
    self.text_handler.markers = null;
}

fn onInputted(self: *editor.Editor) !void {
    self.needs_update_cursor = true;
    const cmd_data: *editor.CommandData = self.getCmdData();
    try self.text_handler.replaceMarked(cmd_data.cmdinp.items);
}

fn onInputtedRepAll(self: *editor.Editor) !void {
    self.needs_update_cursor = true;
    const cmd_data: *editor.CommandData = self.getCmdData();
    const replacements = try self.text_handler.replaceAllMarked(cmd_data.args.?.replace_all.needle, cmd_data.cmdinp.items);
    try cmd_data.replacePromptOverlayFmt(self, PROMPT_REPS_DONE, .{replacements});
}

pub const PROMPT = "Replace with:";
pub const PROMPT_ALL = "Replace every instance with:";
pub const PROMPT_REPS_DONE = "{} reps done";

pub const Fns: editor.CommandData.FnTable = .{
    .onInputted = onInputted,
    .onUnset = onUnset,
};

pub const FnsAll: editor.CommandData.FnTable = .{
    .onInputted = onInputtedRepAll,
    .onUnset = onUnset,
};
