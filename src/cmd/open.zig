const Cmd = @This();

const std = @import("std");
const builtin = @import("builtin");

const editor = @import("../editor.zig");

pub fn onInputtedGeneric(self: *editor.Editor) !?std.fs.File {
  self.needs_update_cursor = true;
  const cwd = std.fs.cwd();
  var cmd_data: *editor.CommandData = self.getCmdData();
  const path: []const u8 = cmd_data.cmdinp.items;
  var opened_file: ?std.fs.File = null;
  cwd.access(path, .{}) catch |err| switch(err) {
    error.FileNotFound => {
      opened_file = cwd.createFile(path, .{
        .read = true,
        .truncate = false
      }) catch |create_err| {
        cmd_data.promptoverlay = .{
          .owned = try std.fmt.allocPrint(
            self.allocr(),
            "Unable to create new file! (ERR: {})",
            .{create_err}
          ),
        };
        return null;
      };
    },
    else => {
      cmd_data.promptoverlay = .{
        .owned = try std.fmt.allocPrint(
          self.allocr(),
          "Unable to open file! (ERR: {})",
          .{err}
        ),
      };
      return null;
    },
  };
  if (opened_file == null) {
    opened_file = cwd.openFile(path, .{
      .mode = .read_write,
      .lock = .shared,
    }) catch |err| {
      cmd_data.promptoverlay = .{
        .owned = try std.fmt.allocPrint(
          self.allocr(),
          "Unable to open file! (ERR: {})",
          .{err}
        ),
      };
      return null;
    };
  }
  return opened_file;
}

pub fn onInputted(self: *editor.Editor) !void {
  if (try Cmd.onInputtedGeneric(self)) |opened_file| {
    try self.text_handler.open(self, opened_file, true);
    self.setState(.text);
    self.needs_redraw = true;
  }
}

pub fn setupUnableToSavePrompt(self: *editor.Editor, err: anyerror) !void {
  self.getCmdData().promptoverlay = .{
    .owned = try std.fmt.allocPrint(
      self.allocr(),
      "Unable to save file, try saving to another location! (ERR: {})",
      .{err}
    ),
  };
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