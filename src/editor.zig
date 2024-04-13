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

pub const State = enum {
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
  
  const TextImpl = @import("./states/text.zig");
  const Text: StateHandler = _createStateHandler(TextImpl);
  
  const CommandImpl = @import("./states/command.zig");
  const Command: StateHandler = _createStateHandler(CommandImpl);
  
  const MarkImpl = @import("./states/mark.zig");
  const Mark: StateHandler = _createStateHandler(MarkImpl);
  
  const List = [_]*const StateHandler{
    &Text,
    &Command,
    &Mark,
    &Text, // quit
  };
};

pub const CommandData = struct {
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

pub const Commands = struct {
  pub const Open = @import("./cmd/open.zig");
  pub const GotoLine = @import("./cmd/gotoline.zig");
  pub const Find = @import("./cmd/find.zig");
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
  
  pub fn setState(self: *Editor, state: State) void {
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
  
  pub fn getCmdData(self: *Editor) *CommandData {
    return &self._cmd_data.?;
  }
  
  pub fn setCmdData(self: *Editor, cmd_data: CommandData) void {
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
  
  pub const CLEAR_SCREEN = "\x1b[2J";
  pub const CLEAR_LINE = "\x1b[2K";
  pub const RESET_POS = "\x1b[H";
  pub const COLOR_INVERT = "\x1b[7m";
  pub const COLOR_DEFAULT = "\x1b[0m";
  
  pub fn writeAll(self: *Editor, bytes: []const u8) !void {
    return self.outw.writeAll(bytes);
  }
  
  pub fn writeFmt(self: *Editor, comptime fmt: []const u8, args: anytype,) !void {
    return std.fmt.format(self.outw, fmt, args);
  }
  
  pub fn moveCursor(self: *Editor, p_row: u32, p_col: u32) !void {
    var row = p_row;
    if (row > self.w_height - 1) { row = self.w_height - 1; }
    var col = p_col;
    if (col > self.w_width - 1) { col = self.w_width - 1; }
    return self.writeFmt("\x1b[{d};{d}H", .{row + 1, col + 1});
  }
  
  pub fn updateCursorPos(self: *Editor) !void {
    const text_handler: *text.TextHandler = &self.text_handler;
    try self.moveCursor(
      text_handler.cursor.row - text_handler.scroll.row,
      (text_handler.cursor.gfx_col - text_handler.scroll.gfx_col) + text_handler.line_digits + 1,
    );
  }
  
  pub fn refreshScreen(self: *Editor) !void {
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
  
  pub fn renderText(self: *Editor) !void {
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
          pos += @intCast(bytes.len);
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
