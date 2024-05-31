const std = @import("std");
const kbd = @import("./kbd.zig");
const HideableMessage = @import("./editor.zig").HideableMessage;

pub const Section = struct {
  name: []const u8,
  list: []const Shortcut,
  
  pub fn key(comptime self: *const Section,
             comptime id: []const u8,
             keysym: *const kbd.Keysym) bool {
    inline for (self.list) |*shortcut| {
      if (comptime std.mem.eql(u8, shortcut.id, id)) {
        return shortcut.checkKey(keysym);
      }
    }
    @compileError("unknown id");
  }
  
  // comptime magic to generate help document:
  
  fn genHelpTail(comptime tail: []const Shortcut) []const u8 {
    const tailstr = if (tail.len > 1) "\n" ++ genHelpTail(tail[1..]) else "";
    return tail[0].genHelp() ++ tailstr;
  }
  
  fn genHelp(comptime self: *const Section) HideableMessage {
    comptime {
      const text = Section.genHelpTail(self.list);
      var rows: u32 = 1;
      for (text) |char| {
        if (char == '\n') {
          rows += 1;
        }
      }
      return .{
        .header = self.name,
        .text = .{ .static = text, },
        .rows = rows,
      };
    }
  }
};

pub const Shortcut = struct {
  key: u8,
  ctrl: bool = false,
  id: []const u8,
  desc: []const u8,
  
  fn checkKey(comptime self: *const Shortcut, keysym: *const kbd.Keysym) bool {
    if (self.ctrl and !keysym.ctrl_key)
      return false;
    if (!keysym.isChar(self.key))
      return false;
    return true;
  }
  
  fn genHelp(comptime self: *const Shortcut) []const u8 {
    if (self.ctrl) {
      return std.fmt.comptimePrint("^{c}: {s}", .{self.key, self.desc});
    } else {
      return std.fmt.comptimePrint("{c}: {s}", .{self.key, self.desc});
    }
  }
};

pub const STATE_TEXT = Section {
  .name = "text mode",
  .list = &[_]Shortcut{
    .{ .key='h', .ctrl=true, .id="help", .desc="help (or next page)" },
    .{ .key='q', .ctrl=true, .id="quit", .desc="quit" },
    .{ .key='s', .ctrl=true, .id="save", .desc="save" },
    .{ .key='o', .ctrl=true, .id="open", .desc="open (cmd)" },
    .{ .key='g', .ctrl=true, .id="goto", .desc="go to line (cmd)" },
    .{ .key='a', .ctrl=true, .id="all", .desc="select all" },
    .{ .key='l', .ctrl=true, .id="line", .desc="mark line" },
    .{ .key='b', .ctrl=true, .id="block", .desc="block mode" },
    .{ .key='d', .ctrl=true, .id="dup", .desc="duplicate line" },
    .{ .key='k', .ctrl=true, .id="delline", .desc="delete line" },
    .{ .key='w', .ctrl=true, .id="delword", .desc="delete word" },
    .{ .key='v', .ctrl=true, .id="paste", .desc="paste" },
    .{ .key='z', .ctrl=true, .id="undo", .desc="undo" },
    .{ .key='y', .ctrl=true, .id="redo", .desc="redo" },
    .{ .key='f', .ctrl=true, .id="find", .desc="find (cmd)" },
  },
};
pub const STATE_TEXT_HELP = STATE_TEXT.genHelp();

pub const STATE_MARK = Section {
  .name = "Mark mode",
  .list = &[_]Shortcut{
    .{ .key='h', .ctrl=true, .id="help", .desc="help" },
    .{ .key='c', .ctrl=true, .id="copy", .desc="copy" },
    .{ .key='x', .ctrl=true, .id="cut", .desc="cut" },
    .{ .key='r', .ctrl=true, .id="rep", .desc="send to replace (cmd)" },
    .{ .key='f', .ctrl=true, .id="find", .desc="send to find (cmd)" },
    .{ .key='>', .ctrl=false, .id="indent", .desc="indent" },
    .{ .key='<', .ctrl=false, .id="dedent", .desc="dedent" },
  },
};
pub const STATE_MARK_HELP = STATE_MARK.genHelp();

pub const CMD_FIND = Section {
  .name = "Find",
  .list = &[_]Shortcut{
    .{ .key='h', .ctrl=true, .id="help", .desc="help" },
    .{ .key='b', .ctrl=true, .id="block", .desc="send to block mode (cmd)" },
    .{ .key='r', .ctrl=true, .id="rep", .desc="replace with..." },
    .{ .key='s', .ctrl=true, .id="allrep", .desc="replace all with..." },
    .{ .key='g', .ctrl=true, .id="resub", .desc="replace all with... (regex)" },
    .{ .key='e', .ctrl=true, .id="refind", .desc="find (regex)" },
    .{ .key='w', .ctrl=true, .id="refindb", .desc="find backwards (regex)" },
    .{ .key='x', .ctrl=true, .id="clear", .desc="clear selection" },
  },
};
pub const CMD_FIND_HELP = CMD_FIND.genHelp();

pub const CMD_GOTO_LINE = Section {
  .name = "Go to line",
  .list = &[_]Shortcut{
    .{ .key='h', .ctrl=true, .id="help", .desc="help" },
    .{ .key='g', .ctrl=false, .id="first", .desc="go to first line" },
    .{ .key='G', .ctrl=false, .id="last", .desc="go to last line" },
  },
};
pub const CMD_GOTO_LINE_HELP = CMD_GOTO_LINE.genHelp();