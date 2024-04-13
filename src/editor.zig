//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");
const builtin = @import("builtin");

const kbd = @import("./kbd.zig");
const str = @import("./str.zig");
const text = @import("./text.zig");
const sig = @import("./sig.zig");

const State = enum {
  text,
  command,
  mark,
  quit,
  
  const INIT = State.text;
};

const StateHandler = struct {
  handleInput: *const fn (self: *Editor, keysym: kbd.Keysym) anyerror!void,
  handleOutput: *const fn (self: *Editor) anyerror!void,
  onSet: ?*const fn (self: *Editor) void,
  
  fn _voidFnOrNull(comptime T: type, comptime name: []const u8)
  ?*const fn (self: *Editor) void {
    if (@hasDecl(T, name)) {
      return @field(T, name);
    } else {
      return null;
    }
  }
  
  fn _createStateHandler(comptime T: type) StateHandler {
    return StateHandler {
      .handleInput = T.handleInput,
      .handleOutput = T.handleOutput,
      .onSet = _voidFnOrNull(T, "onSet"),
    };
  }
  
  const TextImpl = struct {
    fn handleInput(self: *Editor, keysym: kbd.Keysym) !void {
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
        self.setState(State.quit);
      }
      else if (keysym.ctrl_key and keysym.isChar('s')) {
        if (self.text_handler.file == null) {
          self.setState(State.command);
          self.setCmdData(CommandData {
            .prompt = "Save file:",
            .onInputted = Commands.Open.onInputtedTryToSave,
          });
        } else {
          self.text_handler.save(self) catch |err| {
            self.setState(State.command);
            self.setCmdData(CommandData {
              .prompt = "Save file to new location:",
              .onInputted = Commands.Open.onInputtedTryToSave,
            });
            try Commands.Open.setupUnableToSavePrompt(self, err);
          };
        }
      }
      else if (keysym.ctrl_key and keysym.isChar('o')) {
        self.setState(State.command);
        self.setCmdData(CommandData {
          .prompt = "Open file:",
          .onInputted = Commands.Open.onInputted,
        });
      }
      else if (keysym.ctrl_key and keysym.isChar('g')) {
        self.setState(State.command);
        self.setCmdData(CommandData {
          .prompt = "Go to line (first = g, last = G):",
          .onInputted = Commands.GotoLine.onInputted,
          .onKey = Commands.GotoLine.onKey,
        });
      }
      else if (keysym.ctrl_key and keysym.isChar('b')) {
        self.setState(State.mark);
      }
      else if (keysym.ctrl_key and keysym.isChar('v')) {
        try self.text_handler.paste(self);
      }
      else if (keysym.ctrl_key and keysym.isChar('z')) {
        try self.text_handler.undo_mgr.undo(self);
      }
      else if (keysym.ctrl_key and keysym.isChar('f')) {
        self.setState(State.command);
        self.setCmdData(CommandData {
          .prompt = "Find (next = Enter):",
          .onInputted = Commands.Find.onInputted,
          .onKey = Commands.Find.onKey,
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
    
    fn handleOutput(self: *Editor) !void {
      if (self.needs_redraw) {
        try self.refreshScreen();
        try self.renderText();
        self.needs_redraw = false;
      }
      if (self.needs_update_cursor) {
        try TextImpl.renderStatus(self);
        try self.updateCursorPos();
        self.needs_update_cursor = false;
      }
    }
    
    fn renderStatus(self: *Editor) !void {
      try self.moveCursor(self.getTextHeight(), 0);
      const text_handler: *const text.TextHandler = &self.text_handler;
      try self.writeAll(Editor.CLEAR_LINE);
      if (text_handler.buffer_changed) {
        try self.writeAll("[*]");
      } else {
        try self.writeAll("[ ]");
      }
      try self.writeFmt(" {}:{}", .{text_handler.cursor.row+1, text_handler.cursor.col+1});
    }
  };
  const Text: StateHandler = _createStateHandler(TextImpl);
  
  const CommandImpl = struct {
    fn handleInput(self: *Editor, keysym: kbd.Keysym) !void {
      var cmd_data: *CommandData = self.getCmdData();
      if (keysym.raw == kbd.Keysym.ESC) {
        self.setState(.text);
        return;
      }
      
      if (cmd_data.promptoverlay != null) {
        cmd_data.promptoverlay.?.deinit(self.allocr());
        cmd_data.promptoverlay = null;
      }
      
      if (cmd_data.onKey) |onKey| {
        if (try onKey(self, keysym)) {
          return;
        }
      }
      
      if (keysym.raw == kbd.Keysym.BACKSPACE) {
        _ = cmd_data.cmdinp.popOrNull();
        self.needs_update_cursor = true;
      }
      else if (keysym.raw == kbd.Keysym.NEWLINE) {
        try cmd_data.onInputted(self);
      }
      else if (keysym.getPrint()) |key| {
        try cmd_data.cmdinp.append(self.allocr(), key);
        self.needs_update_cursor = true;
      }
      else if (keysym.getMultibyte()) |seq| {
        try cmd_data.cmdinp.appendSlice(self.allocr(), seq);
        self.needs_update_cursor = true;
      }
    }
    
    fn renderStatus(self: *Editor) !void {
      try self.moveCursor(self.getTextHeight(), 0);
      try self.writeAll(Editor.CLEAR_LINE);
      const cmd_data: *CommandData = self.getCmdData();
      if (cmd_data.promptoverlay) |promptoverlay| {
        try self.writeAll(promptoverlay.slice());
      } else if (cmd_data.prompt) |prompt| {
        try self.writeAll(prompt);
      }
      try self.moveCursor((self.getTextHeight() + 1), 0);
      try self.writeAll(Editor.CLEAR_LINE);
      try self.writeAll(" >");
      var col: u32 = 0;
      for (cmd_data.cmdinp.items) |byte| {
        if (col > self.getTextWidth()) {
          return;
        }
        try self.outw.writeByte(byte);
        col += 1;
      }
    }
    
    fn handleOutput(self: *Editor) !void {
      if (self.needs_redraw) {
        try self.refreshScreen();
        try self.renderText();
      }
      if (self.needs_update_cursor) {
        try CommandImpl.renderStatus(self);
        self.needs_update_cursor = false;
      }
    }
  };
  const Command: StateHandler = _createStateHandler(CommandImpl);
  
  const MarkImpl = struct {
    fn onSet(self: *Editor) void {
      self.text_handler.markStart(self);
    }
    
    fn resetState(self: *Editor) void {
      self.text_handler.markers = null;
      self.setState(.text);
    }
    
    fn handleInput(self: *Editor, keysym: kbd.Keysym) !void {
      if (keysym.raw == kbd.Keysym.ESC) {
        MarkImpl.resetState(self);
        return;
      }
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
      else if (keysym.key == kbd.Keysym.Key.home) {
        self.text_handler.goHead(self);
      }
      else if (keysym.key == kbd.Keysym.Key.end) {
        try self.text_handler.goTail(self);
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
        MarkImpl.resetState(self);
      }
      
      else if (keysym.ctrl_key and keysym.isChar('c')) {
        try self.text_handler.copy(self);
        MarkImpl.resetState(self);
      }
      else if (keysym.ctrl_key and keysym.isChar('x')) {
        try self.text_handler.copy(self);
        try self.text_handler.deleteMarked(self);
        MarkImpl.resetState(self);
      }
    }
    
    fn handleOutput(self: *Editor) !void {
      if (self.needs_redraw) {
        try self.refreshScreen();
        try self.renderText();
        self.needs_redraw = false;
      }
      if (self.needs_update_cursor) {
        try MarkImpl.renderStatus(self);
        try self.updateCursorPos();
        self.needs_update_cursor = false;
      }
    }
    
    fn renderStatus(self: *Editor) !void {
      try self.moveCursor(self.getTextHeight(), 0);
      try self.writeAll(Editor.CLEAR_LINE);
      try self.writeAll("Enter: mark end, Del: delete");
      var status: [32]u8 = undefined;
      const status_slice = try std.fmt.bufPrint(
        &status,
        "{d}:{d}",
        .{self.text_handler.cursor.row,self.text_handler.cursor.col}, 
      );
      try self.moveCursor(
        self.getTextHeight() + 1,
        @intCast(self.w_width - status_slice.len),
      );
      try self.writeAll(status_slice);
    }
  };
  const Mark: StateHandler = _createStateHandler(MarkImpl);
  
  const List = [_]*const StateHandler{
    &Text,
    &Command,
    &Mark,
    &Text, // quit
  };
};

const CommandData = struct {
  prompt: ?[]const u8 = null,
  promptoverlay: ?str.MaybeOwnedSlice = null,
  cmdinp: str.String = .{},
  onInputted: *const fn (self: *Editor) anyerror!void,
  
  /// Handle key, returns false if no key is handled
  onKey: ?*const fn (self: *Editor, keysym: kbd.Keysym) anyerror!bool = null,
  
  fn deinit(self: *CommandData, E: *Editor) void {
    if (self.promptoverlay) |*promptoverlay| {
      promptoverlay.deinit(E.allocr());
    }
    self.cmdinp.deinit(E.allocr());
  }
};

// commands
const Commands = struct {
  const Open = struct {
    fn onInputtedGeneric(self: *Editor) !?std.fs.File {
      self.needs_update_cursor = true;
      const cwd = std.fs.cwd();
      var cmd_data: *CommandData = self.getCmdData();
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
    
    fn onInputted(self: *Editor) !void {
      if (try Open.onInputtedGeneric(self)) |opened_file| {
        try self.text_handler.open(self, opened_file, true);
        self.setState(State.text);
        self.needs_redraw = true;
      }
    }
    
    fn setupUnableToSavePrompt(self: *Editor, err: anyerror) !void {
      self.getCmdData().promptoverlay = .{
        .owned = try std.fmt.allocPrint(
          self.allocr(),
          "Unable to save file, try saving to another location! (ERR: {})",
          .{err}
        ),
      };
    }
    
    fn onInputtedTryToSave(self: *Editor) !void {
      if (try Open.onInputtedGeneric(self)) |opened_file| {
        try self.text_handler.open(self, opened_file, false);
        self.text_handler.save(self) catch |err| {
          try Open.setupUnableToSavePrompt(self, err);
          return;
        };
        self.setState(State.text);
        self.needs_redraw = true;
      }
    }
  };
  
  const GotoLine = struct {
    fn onInputted(self: *Editor) !void {
      self.needs_update_cursor = true;
      var text_handler: *text.TextHandler = &self.text_handler;
      var cmd_data: *CommandData = self.getCmdData();
      const line: u32 = std.fmt.parseInt(u32, cmd_data.cmdinp.items, 10) catch {
        cmd_data.promptoverlay = .{ .static = "Invalid integer!", };
        return;
      };
      if (line == 0) {
        cmd_data.promptoverlay = .{ .static = "Lines start at 1!" };
        return;
      }
      text_handler.gotoLine(self, line - 1) catch {
        cmd_data.promptoverlay = .{ .static = "Out of bounds!" };
        return;
      };
      self.setState(State.text);
    }
    
    fn onKey(self: *Editor, keysym: kbd.Keysym) !bool {
      if (keysym.getPrint()) |key| {
        if (key == 'g') {
          try self.text_handler.gotoLine(self, 0);
          self.setState(State.text);
          return true;
        } else if (key == 'G') {
          try self.text_handler.gotoLine(
            self,
            @intCast(self.text_handler.lineinfo.getLen() - 1)
          );
          self.setState(State.text);
          return true;
        }
      }
      return false;
    }
  };
  
  const Find = struct {
    fn findForwards(self: *Editor, cmd_data: *CommandData) !void {
      var text_handler = &self.text_handler;
      const opt_pos = std.mem.indexOfPos(
        u8,
        text_handler.buffer.items,
        text_handler.calcOffsetFromCursor() + 1,
        cmd_data.cmdinp.items,
      );
      if (opt_pos) |pos| {
        try text_handler.gotoPos(self, @intCast(pos));
      } else {
        cmd_data.promptoverlay = .{ .static = "Not found!", };
      }
    }
    
    fn findBackwards(self: *Editor, cmd_data: *CommandData) !void {
      var text_handler = &self.text_handler;
      const opt_pos = std.mem.lastIndexOf(
        u8,
        text_handler.buffer.items[0..text_handler.calcOffsetFromCursor()],
        cmd_data.cmdinp.items,
      );
      if (opt_pos) |pos| {
        try text_handler.gotoPos(self, @intCast(pos));
      } else {
        cmd_data.promptoverlay = .{ .static = "Not found!", };
      }
    }
    
    fn onInputted(self: *Editor) !void {
      self.needs_update_cursor = true;
      try self.text_handler.flushGapBuffer(self);
      const cmd_data: *CommandData = self.getCmdData();
      try Find.findForwards(self, cmd_data);
    }
    
    fn onKey(self: *Editor, keysym: kbd.Keysym) !bool {
      self.needs_update_cursor = true;
      const cmd_data: *CommandData = self.getCmdData();
      if (keysym.key == kbd.Keysym.Key.up) {
        try self.text_handler.flushGapBuffer(self);
        try Find.findBackwards(self, cmd_data);
        return true;
      }
      else if (keysym.key == kbd.Keysym.Key.down) {
        try self.text_handler.flushGapBuffer(self);
        try Find.findForwards(self, cmd_data);
        return true;
      }
      return false;
    }
  };
};
  
pub const Editor = struct {
  const STATUS_BAR_HEIGHT = 2;
  
  in: std.fs.File,
  inr: std.fs.File.Reader,
  
  out: std.fs.File,
  outw: std.fs.File.Writer,
  
  orig_termios: ?std.posix.termios,
  
  needs_redraw: bool,
  needs_update_cursor: bool,
  
  _state: State,
  state_handler: *const StateHandler,
  
  alloc_gpa: std.heap.GeneralPurposeAllocator(.{}),
  
  w_width: u32,
  w_height: u32,
  buffered_byte: u8,
  
  text_handler: text.TextHandler,
  
  _cmd_data: ?CommandData,
  
  pub fn init() !Editor {
    const stdin: std.fs.File = std.io.getStdIn();
    const stdout: std.fs.File = std.io.getStdOut();
    const alloc_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const text_handler: text.TextHandler = try text.TextHandler.init();
    return Editor {
      .in = stdin,
      .inr = stdin.reader(),
      .out = stdout,
      .outw = stdout.writer(),
      .orig_termios = null,
      .needs_redraw = true,
      .needs_update_cursor = true,
      ._state = State.INIT,
      .state_handler = &StateHandler.Text,
      .alloc_gpa = alloc_gpa,
      .w_width = 0,
      .w_height = 0,
      .buffered_byte = 0,
      .text_handler = text_handler,
      ._cmd_data = null,
    };
  }
  
  pub fn allocr(self: *Editor) std.mem.Allocator {
    return self.alloc_gpa.allocator();
  }
  
  fn setState(self: *Editor, state: State) void {
    if (state == self._state) {
      return;
    }
    if (self._state == .command) {
      self._cmd_data.?.deinit(self);
      self._cmd_data = null;
    }
    self._state = state;
    const state_handler = StateHandler.List[@intFromEnum(state)];
    self.state_handler = state_handler;
    if (state_handler.onSet) |onSet| {
      onSet(self);
    }
    self.needs_redraw = true;
    self.needs_update_cursor = true;
  }
  
  // command data
  
  fn getCmdData(self: *Editor) *CommandData {
    return &self._cmd_data.?;
  }
  
  fn setCmdData(self: *Editor, cmd_data: CommandData) void {
    std.debug.assert(self._cmd_data == null);
    self._cmd_data = cmd_data;
  }
  
  // raw mode
  
  fn enableRawMode(self: *Editor) !void {
    var termios = try std.posix.tcgetattr(self.in.handle);
    self.orig_termios = termios;
    
    termios.iflag.BRKINT = false;
    termios.iflag.ICRNL = false;
    termios.iflag.INPCK = false;
    termios.iflag.ISTRIP = false;
    termios.iflag.IXON = false;
    termios.iflag.IUTF8 = false;
    
    termios.oflag.OPOST = false;
    
    termios.cflag.CSIZE = std.posix.CSIZE.CS8;
    
    termios.lflag.ECHO = false;
    termios.lflag.ICANON = false;
    termios.lflag.IEXTEN = false;
    termios.lflag.ISIG = false;
    
    termios.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    termios.cc[@intFromEnum(std.posix.V.TIME)] = 1;
    
    try std.posix.tcsetattr(self.in.handle, std.posix.TCSA.FLUSH, termios);
  }
  
  fn disableRawMode(self: *Editor) !void {
    if (self.orig_termios) |termios| {
      try std.posix.tcsetattr(self.in.handle, std.posix.TCSA.FLUSH, termios);
    }
  }
  
  // console input
  
  fn flushConsoleInput(self: *Editor) void {
    while (true) {
      const byte = self.inr.readByte() catch break;
      std.log.debug("readKey: unk [{}]\n", .{byte});
    }
  }
  
  fn readKey(self: *Editor) ?kbd.Keysym {
    if (self.buffered_byte != 0) {
      const b = self.buffered_byte;
      self.buffered_byte = 0;
      return kbd.Keysym.init(b);
    }
    const raw = self.inr.readByte() catch return null;
    if (raw == kbd.Keysym.ESC) {
      if (self.inr.readByte() catch null) |possibleEsc| {
        if (possibleEsc == '[') {
          switch (self.inr.readByte() catch 0) {
            'A' => { return kbd.Keysym.initSpecial(.up); },
            'B' => { return kbd.Keysym.initSpecial(.down); },
            'C' => { return kbd.Keysym.initSpecial(.right); },
            'D' => { return kbd.Keysym.initSpecial(.left); },
            'F' => { return kbd.Keysym.initSpecial(.end); },
            'H' => { return kbd.Keysym.initSpecial(.home); },
            '3' => {
              switch (self.inr.readByte() catch 0) {
                '~' => { return kbd.Keysym.initSpecial(.del); },
                else => {
                  self.flushConsoleInput();
                  return null;
                },
              }
            },
            '5' => {
              switch (self.inr.readByte() catch 0) {
                '~' => { return kbd.Keysym.initSpecial(.pgup); },
                else => {
                  self.flushConsoleInput();
                  return null;
                },
              }
            },
            '6' => {
              switch (self.inr.readByte() catch 0) {
                '~' => { return kbd.Keysym.initSpecial(.pgdown); },
                else => {
                  self.flushConsoleInput();
                  return null;
                },
              }
            },
            else => |byte1| {
              // unknown escape sequence, empty the buffer
              std.log.debug("readKey: unk [{}]\n", .{byte1});
              self.flushConsoleInput();
              return null;
            }
          }
        } else {
          self.buffered_byte = possibleEsc;
        }
      }
    }
    if (text.Encoding.sequenceLen(raw)) |seqlen| {
      if (seqlen > 1) {
        var seq = std.BoundedArray(u8, 4).init(0) catch unreachable;
        seq.append(raw) catch unreachable;
        for (1..seqlen) |_| {
          const cont = self.inr.readByte() catch {
            return null;
          };
          seq.append(cont) catch {
            return null;
          };
        }
        return kbd.Keysym.initMultibyte(seq.constSlice());
      }
    }
    return kbd.Keysym.init(raw);
  }
  
  // console output
  
  const CLEAR_SCREEN = "\x1b[2J";
  const CLEAR_LINE = "\x1b[2K";
  const RESET_POS = "\x1b[H";
  const COLOR_INVERT = "\x1b[7m";
  const COLOR_DEFAULT = "\x1b[0m";
  
  fn writeAll(self: *Editor, bytes: []const u8) !void {
    return self.outw.writeAll(bytes);
  }
  
  fn writeFmt(self: *Editor, comptime fmt: []const u8, args: anytype,) !void {
    return std.fmt.format(self.outw, fmt, args);
  }
  
  fn moveCursor(self: *Editor, p_row: u32, p_col: u32) !void {
    var row = p_row;
    if (row > self.w_height - 1) { row = self.w_height - 1; }
    var col = p_col;
    if (col > self.w_width - 1) { col = self.w_width - 1; }
    return self.writeFmt("\x1b[{d};{d}H", .{row + 1, col + 1});
  }
  
  fn updateCursorPos(self: *Editor) !void {
    const text_handler: *text.TextHandler = &self.text_handler;
    try self.moveCursor(
      text_handler.cursor.row - text_handler.scroll.row,
      (text_handler.cursor.gfx_col - text_handler.scroll.gfx_col) + text_handler.line_digits + 1,
    );
  }
  
  fn refreshScreen(self: *Editor) !void {
    try self.writeAll(Editor.CLEAR_SCREEN);
    try self.writeAll(Editor.RESET_POS);
  }
  
  // console dims
  
  fn updateWinSize(self: *Editor) !void {
    if (builtin.target.os.tag == .linux) {
      const oldw = self.w_width;
      const oldh = self.w_height;
      var wsz: std.os.linux.winsize = undefined;
      const rc = std.os.linux.ioctl(self.in.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&wsz));
      if (std.os.linux.E.init(rc) == .SUCCESS) {
        self.w_height = wsz.ws_row;
        self.w_width = wsz.ws_col;
      }
      if (oldw != 0 and oldh != 0) {
        self.text_handler.syncColumnScroll(self);
        self.text_handler.syncRowScroll(self);
      }
      self.needs_redraw = true;
    }
  }
  
  pub fn getTextWidth(self: *Editor) u32 {
    return self.w_width - self.text_handler.line_digits - 1;
  }
  
  pub fn getTextHeight(self: *Editor) u32 {
    return self.w_height - STATUS_BAR_HEIGHT;
  }
  
  // handle input
  
  fn handleInput(self: *Editor) !void {
    if (self.readKey()) |keysym| {
      try self.state_handler.handleInput(self, keysym);
    }
  }
  
  // handle output
  
  fn renderText(self: *Editor) !void {
    const text_handler: *const text.TextHandler = &self.text_handler;
    var row: u32 = 0;
    const cursor_row: u32 = text_handler.cursor.row - text_handler.scroll.row;
    var lineno: [16]u8 = undefined;
    for (text_handler.scroll.row..text_handler.lineinfo.getLen()) |i| {
      const offset_start: u32 = text_handler.lineinfo.getOffset(@intCast(i));
      const offset_end: u32 = text_handler.getRowOffsetEnd(@intCast(i));
      
      const colOffset: u32 = if (row == cursor_row) text_handler.scroll.col else 0;
      var iter = text_handler.iterate(offset_start + colOffset);
      
      try self.moveCursor(row, 0);
      
      const lineno_slice = try std.fmt.bufPrint(&lineno, "{d}", .{i+1});
      for(0..(self.text_handler.line_digits - lineno_slice.len)) |_| {
        try self.outw.writeByte(' ');
      }
      if (
        (comptime builtin.mode == .Debug) and
        self.text_handler.lineinfo.checkIsMultibyte(@intCast(i))
      ) {
        try self.writeAll(COLOR_INVERT);
        try self.writeAll(lineno_slice);
        try self.writeAll(COLOR_DEFAULT);
      } else {
        try self.writeAll(lineno_slice);
      }
      try self.outw.writeByte(' ');
      
      if (text_handler.markers) |*markers| {
        var col: u32 = 0;
        var pos = offset_start;
        if (pos > markers.start and pos < markers.end) {
          try self.writeAll(COLOR_INVERT);
        }
        while (iter.nextCharUntil(offset_end)) |bytes| {
          if (!(try self.renderCharInLineMarked(bytes, &col, markers, pos))) {
            break;
          }
          pos += 1;
        }
        try self.writeAll(COLOR_DEFAULT);
      } else {
        var col: u32 = 0;
        while (iter.nextCharUntil(offset_end)) |bytes| {
          if (!(try self.renderCharInLine(bytes, &col))) {
            break;
          }
        }
      }
      
      row += 1;
      if (row == self.getTextHeight()) {
        break;
      }
    }
    self.needs_update_cursor = true;
  }
  
  fn renderCharInLine(self: *Editor, bytes: []const u8, colref: *u32) !bool {
    if (colref.* == self.getTextWidth()) {
      return false;
    }
    if (bytes.len == 1 and std.ascii.isControl(bytes[0])) {
      return true;
    }
    try self.outw.writeAll(bytes);
    colref.* += 1;
    return true;
  }
  
  fn renderCharInLineMarked(
    self: *Editor, bytes: []const u8, colref: *u32,
    markers: *const text.TextHandler.Markers,
    pos: u32,
  ) !bool {
    if (pos == markers.start) {
      try self.writeAll(COLOR_INVERT);
      return self.renderCharInLine(bytes, colref);
    } else if (pos >= markers.end) {
      try self.writeAll(COLOR_DEFAULT);
      return self.renderCharInLine(bytes, colref);
    } else {
      return self.renderCharInLine(bytes, colref);
    }
  }
  
  fn handleOutput(self: *Editor) !void {
    try self.state_handler.handleOutput(self);
  }
  
  // tick
  
  const REFRESH_RATE = 16700000;
  
  pub fn run(self: *Editor) !void {
    try self.updateWinSize();
    try self.enableRawMode();
    self.needs_redraw = true;
    while (self._state != State.quit) {
      if (sig.resized) {
        try self.updateWinSize();
        sig.resized = false;
      }
      try self.handleInput();
      try self.handleOutput();
      std.time.sleep(Editor.REFRESH_RATE);
    }
    try self.refreshScreen();
    try self.disableRawMode();
  }
  
  pub fn openAtStart(self: *Editor, opened_file_str: str.String) !void {
    self.setState(.command);
    self.setCmdData(CommandData {
      .prompt = "Open file:",
      .onInputted = Commands.Open.onInputted,
      .cmdinp = opened_file_str,
    });
    try Commands.Open.onInputted(self);
  }
  
};
