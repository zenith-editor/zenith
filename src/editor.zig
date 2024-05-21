//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("config");

const config = @import("./config.zig");
const kbd = @import("./kbd.zig");
const str = @import("./str.zig");
const text = @import("./text.zig");
const sig = @import("./sig.zig");
const shortcuts = @import("./shortcuts.zig");
const encoding = @import("./encoding.zig");

const Expr = @import("./patterns.zig").Expr;

pub const State = enum {
  text,
  command,
  mark,
  
  const INIT = State.text;
};

const StateHandler = struct {
  handleInput: *const fn (self: *Editor, keysym: *const kbd.Keysym, is_clipboard: bool) anyerror!void,
  handleOutput: *const fn (self: *Editor) anyerror!void,
  onSet: ?*const fn (self: *Editor) void,
  onUnset: ?*const fn (self: *Editor, next_state: State) void,
  
  fn _createStateHandler(comptime T: type) StateHandler {
    return StateHandler {
      .handleInput = T.handleInput,
      .handleOutput = T.handleOutput,
      .onSet = (if (@hasDecl(T, "onSet")) @field(T, "onSet") else null),
      .onUnset = (if (@hasDecl(T, "onUnset")) @field(T, "onUnset") else null),
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
  };
};

pub const CommandData = struct {
  pub const FnTable = struct {
    onInputted: *const fn (self: *Editor) anyerror!void,
    /// Handle key, returns false if no key is handled
    onKey: ?*const fn (self: *Editor, keysym: *const kbd.Keysym) anyerror!bool = null,
    onUnset: ?*const fn (self: *Editor, next_state: State) void = null,
  };
  
  pub const Args = union(enum) {
    pub const ReplaceAll = struct {
      needle: text.TextHandler.ReplaceNeedle,
    };
    
    pub const Find = struct {
      regex: ?Expr = null,
    };
    
    replace_all: ReplaceAll,
    find: Find,
    
    fn deinit(self: *Args, allocr: std.mem.Allocator) void {
      switch (self.*) {
        .replace_all => |*e| {
          e.needle.deinit(allocr);
        },
        .find => |*e| {
          if (e.regex) |*regex| {
            regex.deinit(allocr);
          }
        },
      }
    }
  };
  
  /// Prompt
  prompt: ?[]const u8 = null,
  
  /// (Error) message to display on top of prompt
  promptoverlay: ?str.MaybeOwnedSlice = null,
  
  /// Input for command
  cmdinp: str.StringUnmanaged = .{},
  
  /// Position of cursor in cmdinp
  cmdinp_pos: text.TextPos = .{},
  
  /// Functions for the current executed command
  fns: FnTable,
  
  /// Optional arguments
  args: ?Args = null,
  
  fn deinit(self: *CommandData, E: *Editor) void {
    if (self.promptoverlay) |*promptoverlay| {
      promptoverlay.deinit(E.allocr());
    }
    if (self.args) |*args| {
      args.deinit(E.allocr());
    }
    self.cmdinp.deinit(E.allocr());
  }
  
  pub fn replace(self: *CommandData, E: *Editor, new_cmd_data: *const CommandData) void {
    self.deinit(E);
    self.* = new_cmd_data.*;
  }
  
  pub fn replaceArgs(self: *CommandData, E: *Editor, new_args: *const Args) void {
    if (self.args != null) {
      self.args.?.deinit(E.allocr());
    }
    self.args = new_args.*;
  }
  
  pub fn replacePromptOverlay(self: *CommandData, E: *Editor, static: []const u8) void {
    if (self.promptoverlay != null) {
      self.promptoverlay.?.deinit(E.allocr());
    }
    self.promptoverlay = .{ .static = static, };
  }
  
  pub fn replacePromptOverlayFmt(self: *CommandData, E: *Editor, comptime fmt: []const u8, args: anytype) !void {
    if (self.promptoverlay != null) {
      self.promptoverlay.?.deinit(E.allocr());
    }
    self.promptoverlay = .{
      .owned = try std.fmt.allocPrint(E.allocr(), fmt, args),
    };
  }
};

pub const Commands = struct {
  pub const Open = @import("./cmd/open.zig");
  pub const GotoLine = @import("./cmd/gotoline.zig");
  pub const Find = @import("./cmd/find.zig");
  pub const Replace = @import("./cmd/replace.zig");
};
  
pub const Editor = struct {
  const STATUS_BAR_HEIGHT = 2;
  const INPUT_BUFFER_SIZE = 64;
  
  const Private = struct {
    state: State,
    cmd_data: ?CommandData,
  };
  
  in: std.fs.File,
  inr: std.fs.File.Reader,
  in_buf: std.BoundedArray(u8, INPUT_BUFFER_SIZE) = .{},
  in_read: usize = 0,
  
  out: std.fs.File,
  outw: std.fs.File.Writer,
  
  orig_termios: ?std.posix.termios = null,
  
  needs_redraw: bool = true,
  needs_update_cursor: bool = true,
  
  state_handler: *const StateHandler,
  
  alloc_gpa: std.heap.GeneralPurposeAllocator(.{}),
  
  w_width: u32 = 0,
  w_height: u32 = 0,
  
  text_handler: text.TextHandler,
  
  conf: config.Reader,
  
  help_msg: ?*const shortcuts.HelpText = null,
  
  _priv: Private,
  
  // terminal extensions
  has_bracketed_paste: bool = false,
  
  pub fn create() !Editor {
    const stdin: std.fs.File = std.io.getStdIn();
    const stdout: std.fs.File = std.io.getStdOut();
    var alloc_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const text_handler: text.TextHandler = try text.TextHandler.create();
    var conf: config.Reader = .{};
    switch (config.Reader.open(alloc_gpa.allocator())) {
      .ok => |conf_ok| {
        conf = conf_ok;
      },
      .err => |err| {
        switch (err.type) {
          error.FileNotFound => {},
          else => {
            const writer = stdout.writer();
            try writer.print("Unable to read config file: {}\n", .{err});
            try writer.print("Press Enter to continue...\n",.{});
            _ = stdin.reader().readByte() catch {};
          },
        }
      },
    }
    var editor = Editor {
      .in = stdin,
      .inr = stdin.reader(),
      .out = stdout,
      .outw = stdout.writer(),
      .state_handler = &StateHandler.Text,
      .alloc_gpa = alloc_gpa,
      .text_handler = text_handler,
      .conf = conf,
      ._priv = .{
        .state = State.INIT,
        .cmd_data = null,
      },
    };
    try editor.updateWinSize();
    return editor;
  }
  
  pub fn allocr(self: *Editor) std.mem.Allocator {
    return self.alloc_gpa.allocator();
  }
  
  pub fn getState(self: *const Editor) State {
    return self._priv.state;
  }
  
  pub fn setState(self: *Editor, state: State) void {
    std.debug.assert(state != self._priv.state);
    const old_state_handler = StateHandler.List[@intFromEnum(self._priv.state)];
    if (old_state_handler.onUnset) |onUnset| {
      onUnset(self, state);
    }
    self._priv.state = state;
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
    return &self._priv.cmd_data.?;
  }
  
  pub fn setCmdData(self: *Editor, cmd_data: *const CommandData) void {
    std.debug.assert(self._priv.cmd_data == null);
    self._priv.cmd_data = cmd_data.*;
  }
  
  pub fn unsetCmdData(self: *Editor) void {
    self._priv.cmd_data.?.deinit(self);
    self._priv.cmd_data = null;
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
  
  fn readRaw(self: *Editor) !u8 {
    return self.inr.readByte();
  }
  
  fn readRawIntoBuffer(self: *Editor, size: usize) !void {
    self.in_buf.resize(INPUT_BUFFER_SIZE) catch unreachable;
    errdefer self.in_buf.resize(0) catch unreachable;
    const n_read = try self.inr.read(self.in_buf.slice()[0..size]);
    self.in_buf.resize(n_read) catch unreachable;
  }
  
  fn readByte(self: *Editor) !u8 {
    var byte: u8 = undefined;
    if (self.in_read < self.in_buf.len) {
      byte = self.in_buf.buffer[self.in_read];
      self.in_read += 1;
    } else {
      byte = try self.readRaw();
    }
    if (comptime build_config.dbg_print_read_byte) {
      if (std.ascii.isPrint(byte)) {
        std.debug.print("read: {} ({c})\n", .{byte, byte});
      } else {
        std.debug.print("read: {}\n", .{byte});
      }
    }
    return byte;
  }
  
  fn flushConsoleInput(self: *Editor) void {
    self.in_buf.resize(0) catch unreachable;
    while (true) {
      _ = self.readRaw() catch break;
    }
  }
  
  const EscapeMatcher = struct {
    buffered: std.BoundedArray(u8, 4) = .{},
    editor: *Editor,
    
    inline fn readByte(self: *EscapeMatcher) u8 {
      if (self.buffered.popOrNull()) |byte| {
        return byte;
      }
      return self.editor.readByte() catch 0;
    }
    
    inline fn match(self: *EscapeMatcher, bytes: []const u8) bool {
      for (bytes, 0..bytes.len) |byte, i| {
        const cmp = self.readByte();
        if (cmp != byte) {
          self.buffered.append(cmp) catch {
            @panic("EscapeMatcher buffer too small");
          };
          var it = std.mem.reverseIterator(bytes[0..i]);
          while (it.next()) |byte_read| {
            self.buffered.append(byte_read) catch {
              @panic("EscapeMatcher buffer too small");
            };
          }
          return false;
        }
      }
      return true;
    }
  };
  
  fn readKey(self: *Editor) ?kbd.Keysym {
    const raw = self.readByte() catch return null;
    if (raw == kbd.Keysym.ESC) {
      if (self.readByte() catch null) |possibleEsc| {
        if (possibleEsc == '[') {
          var matcher: EscapeMatcher = .{ .editor = self, };
          // 4 bytes
          if (matcher.match("200~")) { return kbd.Keysym.initSpecial(.paste_begin); }
          else if (matcher.match("201~")) { return kbd.Keysym.initSpecial(.paste_end); }
          else if (matcher.match("1;5D")) {
            return .{ .raw = 0, .key = .left, .ctrl_key = true, };
          }
          else if (matcher.match("1;5C")) {
            return .{ .raw = 0, .key = .right, .ctrl_key = true, };
          }
          // 2 bytes
          else if (matcher.match("3~")) { return kbd.Keysym.initSpecial(.del); }
          else if (matcher.match("5~")) { return kbd.Keysym.initSpecial(.pgup); }
          else if (matcher.match("6~")) { return kbd.Keysym.initSpecial(.pgdown); }
          // 1 byte
          else if (matcher.match("A")) { return kbd.Keysym.initSpecial(.up); }
          else if (matcher.match("B")) { return kbd.Keysym.initSpecial(.down); }
          else if (matcher.match("C")) { return kbd.Keysym.initSpecial(.right); }
          else if (matcher.match("D")) { return kbd.Keysym.initSpecial(.left); }
          else if (matcher.match("F")) { return kbd.Keysym.initSpecial(.end); }
          else if (matcher.match("H")) { return kbd.Keysym.initSpecial(.home); }
        }
        // unknown escape sequence, empty the buffer
        self.flushConsoleInput();
        return null;
      }
    }
    if (encoding.sequenceLen(raw)) |seqlen| {
      if (seqlen > 1) {
        var seq = std.BoundedArray(u8, 4).init(0) catch unreachable;
        seq.append(raw) catch unreachable;
        for (1..seqlen) |_| {
          const cont = self.readByte() catch {
            return null;
          };
          seq.append(cont) catch {
            return null;
          };
        }
        return kbd.Keysym.initMultibyte(seq.constSlice());
      }
    } else |_| {}
    return kbd.Keysym.init(raw);
  }
  
  // console output
  
  pub const ESC_CLEAR_SCREEN = "\x1b[2J";
  pub const ESC_CLEAR_LINE = "\x1b[2K";
  pub const ESC_RESET_POS = "\x1b[H";
  pub const ESC_COLOR_INVERT = "\x1b[7m";
  pub const ESC_COLOR_DEFAULT = "\x1b[0m";
  pub const ESC_COLOR_GRAY = "\x1b[38;5;8m";
  
  pub const HTAB_CHAR = ESC_COLOR_GRAY ++ "\xc2\xbb " ++ ESC_COLOR_DEFAULT;
  pub const HTAB_COLS = 2;
  pub const LINEWRAP_SYM = ESC_COLOR_GRAY ++ "\xe2\x8f\x8e" ++ ESC_COLOR_DEFAULT;
  
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
    var col = text_handler.cursor.gfx_col - text_handler.scroll.gfx_col;
    if (self.conf.show_line_numbers) {
       col += text_handler.line_digits + 1;
    }
    try self.moveCursor(text_handler.cursor.row - text_handler.scroll.row, col);
  }
  
  pub fn refreshScreen(self: *Editor) !void {
    try self.outw.writeAll(Editor.ESC_CLEAR_SCREEN);
    try self.outw.writeAll(Editor.ESC_RESET_POS);
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
  
  pub fn getTextWidth(self: *const Editor) u32 {
    if (self.conf.show_line_numbers) {
      return self.w_width - self.text_handler.line_digits - 1;
    } else {
      return self.w_width;
    }
  }
  
  pub fn getTextHeight(self: *const Editor) u32 {
    return self.w_height - STATUS_BAR_HEIGHT;
  }
  
  // handle input
  
  /// minimum number of consecutive bytes read to be considered
  /// from clipboard. this is a heuristic to detect input from clipboard
  /// if for some reason the vterm doesn't support it
  const TYPED_CLIPBOARD_BYTE_THRESHOLD = 3;
  
  fn handleInput(self: *Editor, is_clipboard: bool) !void {
    if (self.readKey()) |keysym| {
      if (self.help_msg != null) {
        self.help_msg = null;
        self.needs_redraw = true;
      }
      switch (keysym.key) {
        .paste_begin => {
          // see https://invisible-island.net/xterm/xterm-paste64.html
          while (self.readKey()) |keysym1| {
            switch (keysym1.key) {
              .paste_end => { break; },
              else => {
                try self.state_handler.handleInput(self, &keysym1, true);
              },
            }
          }
          return;
        },
        else => {},
      }
      try self.state_handler.handleInput(self, &keysym, is_clipboard);
    }
  }
  
  fn handleInputPolling(self: *Editor) !void {
    switch (builtin.target.os.tag) {
      .linux => {
        var pollfd = [1]std.posix.pollfd{
          .{
            .fd = std.posix.STDIN_FILENO,
            .events = std.os.linux.POLL.IN,
            .revents = 0,
          }
        };
        
        const pollres = std.posix.poll(
          &pollfd,
          0
        ) catch {
          return self.handleInput(false);
        };
        if (pollres == 0) {
          return self.handleInput(false);
        }
        
        while (true) {
          var int_bytes_avail: i32 = 0;
          if (std.os.linux.ioctl(
            std.posix.STDIN_FILENO,
            std.os.linux.T.FIONREAD,
            @intFromPtr(&int_bytes_avail)
          ) < 0) {
            // ignore error reading available bytes and return
            return self.handleInput(false);
          }
          
          // no more bytes left
          if (int_bytes_avail == 0) {
            return;
          }
        
          const bytes_avail: usize = @min(@as(usize, @intCast(int_bytes_avail)), self.in_buf.buffer.len);
          try self.readRawIntoBuffer(bytes_avail);
          if (self.has_bracketed_paste) {
            // handled in handleInput
            while (self.in_read < self.in_buf.len) {
              try self.handleInput(false);
            }
            self.in_buf.resize(0) catch unreachable;
          } else {
            var is_clipboard = bytes_avail > TYPED_CLIPBOARD_BYTE_THRESHOLD;
            while (self.in_read < self.in_buf.len) {
              if (self.in_buf.slice()[self.in_read] == kbd.Keysym.ESC) {
                is_clipboard = false;
              }
              try self.handleInput(is_clipboard);
            }
            self.in_buf.resize(0) catch unreachable;
          }
        }
      },
      else => {
        try self.handleInput(false);
      }
    }
  }
  
  // handle output
  
  const ColumnPrinter = struct {
    editor: *Editor,
    col: u32 = 0,
    text_width: u32,
    color_code: ?[]const u8 = null,
    
    inline fn setColor(self: *ColumnPrinter, color_code: ?[]const u8) !void {
      if (color_code == null) {
        if (self.color_code == null) {
          return;
        }
      } else if (self.color_code) |cur_color_code| {
        if (cur_color_code.ptr == color_code.?.ptr) {
          return;
        }
      }
      self.color_code = color_code;
      try self.writeColorCode();
    }
    
    fn writeColorCode(self: *ColumnPrinter) !void {
      try self.editor.writeAll(self.color_code orelse ESC_COLOR_DEFAULT);
    }
    
    fn writeAll(self: *ColumnPrinter, bytes: []const u8) !bool {
      var cwidth: u32 = 0;
      if (bytes.len == 1 and bytes[0] == '\t') {
        cwidth = HTAB_COLS;
      } else {
        cwidth = encoding.cwidth(std.unicode.utf8Decode(bytes) catch unreachable);
        if (cwidth == 0) {
          return true;
        }
      }
      if ((self.col + cwidth) > self.text_width) {
        return false;
      }
      if (bytes.len == 1 and bytes[0] == '\t') {
        try self.editor.writeAll(HTAB_CHAR);
      } else {
        try self.editor.writeAll(bytes);
      }
      self.col += cwidth;
      return true;
    }
  };
  
  pub fn renderText(self: *Editor) !void {
    if (self.getTextHeight() == 0) {
      return;
    }

    const text_handler: *const text.TextHandler = &self.text_handler;
    
    const text_width = self.getTextWidth();
    const text_height = self.getTextHeight();

    var row: u32 = 0;
    const cursor_row: u32 = text_handler.cursor.row - text_handler.scroll.row;
    var lineno: [16]u8 = undefined;
    for (text_handler.scroll.row..text_handler.lineinfo.getLen()) |i| {
      const offset_start: u32 = text_handler.lineinfo.getOffset(@intCast(i));
      const offset_end: u32 = text_handler.getRowOffsetEnd(@intCast(i));
      
      const offset_col: u32 = if (row == cursor_row) text_handler.scroll.col else 0;
      var iter = text_handler.iterate(offset_start + offset_col);
      
      try self.moveCursor(row, 0);
      
      // Line number
      
      const line_no: u32 = text_handler.lineinfo.getLineNo(@intCast(i));
      
      if (self.conf.show_line_numbers) {
        const lineno_slice = if (
          text_handler.lineinfo.isContLine(@intCast(i)) and
          comptime !build_config.dbg_show_cont_line_no
        )
          ">"
        else
          try std.fmt.bufPrint(&lineno, "{d}", .{line_no});
        for(0..(self.text_handler.line_digits - lineno_slice.len)) |_| {
          try self.outw.writeByte(' ');
        }
        if (
          (comptime build_config.dbg_show_multibyte_line) and
          self.text_handler.lineinfo.checkIsMultibyte(@intCast(i))
        ) {
          try self.outw.writeAll(ESC_COLOR_INVERT);
          try self.outw.writeAll(lineno_slice);
          try self.outw.writeAll(ESC_COLOR_DEFAULT);
        } else {
          try self.outw.writeAll(ESC_COLOR_GRAY);
          try self.outw.writeAll(lineno_slice);
          try self.outw.writeAll(ESC_COLOR_DEFAULT);
        }
        try self.outw.writeByte(' ');
      }
      
      // Column
      
      var printer: ColumnPrinter = .{
        .editor = self,
        .text_width = text_width,
      };
      
      if (text_handler.markers) |*markers| {
        if (iter.pos >= markers.start and iter.pos < markers.end) {
          try printer.setColor(ESC_COLOR_INVERT);
        }
        
        while (iter.nextCodepointSliceUntil(offset_end)) |bytes| {
          if (!try printer.writeAll(bytes)) {
            break;
          }
          if (iter.pos >= markers.end) {
            try printer.setColor(null);
          } else if (iter.pos >= markers.start) {
            try printer.setColor(ESC_COLOR_INVERT);
          }
        }
      }
      
      else if (comptime build_config.dbg_show_gap_buf) {
        const logical_gap_buf_start: u32 = self.text_handler.head_end;
        const logical_gap_buf_end: u32 =
          @intCast(logical_gap_buf_start + self.text_handler.gap.items.len);
          
        if (iter.pos >= logical_gap_buf_start and iter.pos < logical_gap_buf_end) {
          try printer.setColor(ESC_COLOR_INVERT);
        }
        
        while (iter.nextCodepointSliceUntil(offset_end)) |bytes| {
          if (iter.pos == logical_gap_buf_end) {
            try printer.setColor(null);
          } else if (iter.pos >= logical_gap_buf_start) {
            try printer.setColor(ESC_COLOR_INVERT);
          }
          if (!try printer.writeAll(bytes)) {
            break;
          }
        }
      }
      
      else {
        while (iter.nextCodepointSliceUntil(offset_end)) |bytes| {
          if (!try printer.writeAll(bytes)) {
            break;
          }
        }
      }
      
      try printer.setColor(null);
      
      if ((i+1) < text_handler.lineinfo.getLen() and text_handler.lineinfo.isContLine(@intCast(i + 1))) {
        try self.outw.writeAll(LINEWRAP_SYM);
      }
      
      row += 1;
      if (row == text_height) {
        break;
      }
    }
    
    try self.showUpperLayers();
    
    self.needs_update_cursor = true;
  }
  
  fn showUpperLayers(self: *Editor) !void {
    if (self.help_msg) |help_msg| {
      var row: u32 = 0;
      if (self.getTextHeight() >= help_msg.rows) {
        row = self.getTextHeight() - help_msg.rows;
      }
      try self.moveCursor(row, 0);
      try self.outw.writeAll(ESC_CLEAR_LINE);
      for (help_msg.text) |char| {
        if (char == '\n') {
          row += 1;
          try self.moveCursor(row, 0);
          try self.outw.writeAll(ESC_CLEAR_LINE);
        } else {
          try self.outw.writeByte(char);
        }
      }
    }
  }
  
  fn handleOutput(self: *Editor) !void {
    try self.state_handler.handleOutput(self);
  }
  
  // terminal extensions
  
  const ESC_EXT_PASTE = "\x1b[?2004h";
  const ESC_EXT_PASTE_DISABLE = "\x1b[?2004l";
  
  fn enableTermExts(self: *Editor) !void {
    try self.outw.writeAll(ESC_EXT_PASTE);
    // TODO: check if terminal actually supports bracketed pastes
    self.has_bracketed_paste = true;
  }
  fn disableTermExts(self: *Editor) !void {
    if (self.has_bracketed_paste) {
      try self.outw.writeAll(ESC_EXT_PASTE_DISABLE);
    }
  }
  
  // terminal restore
  
  pub fn restoreTerminal(self: *Editor) !void {
    try self.disableTermExts();
    try self.refreshScreen();
    try self.disableRawMode();
  }
  
  // tick
  
  const REFRESH_RATE_NS = 16700000;
  const REFRESH_RATE_MS = REFRESH_RATE_NS / 1000000;
  
  pub fn run(self: *Editor) !void {
    try self.enableRawMode();
    try self.enableTermExts();
    self.needs_redraw = true;
    var ts = std.time.microTimestamp();
    while (true) {
      if (sig.resized) {
        sig.resized = false;
        try self.updateWinSize();
        try self.text_handler.onResize(self);
      }
      self.handleInputPolling() catch |err| {
        if (err == error.Quit) {
          break;
        } else {
          return err;
        }
      };
      try self.handleOutput();
      
      const new_ts = std.time.microTimestamp();
      const elapsed = (new_ts - ts) * 1000;
      if (elapsed < REFRESH_RATE_NS) {
        const refresh_ts = REFRESH_RATE_NS - (new_ts - ts) * 1000;
        std.time.sleep(@intCast(refresh_ts));
      }
      ts = new_ts;
    }
    self.restoreTerminal() catch {};
  }
  
  /// opened_file_str must be allocated by E.allocr()
  pub fn openAtStart(self: *Editor, opened_file_str: str.StringUnmanaged) !void {
    self.setState(.command);
    self.setCmdData(&.{
      .prompt = Commands.Open.PROMPT_OPEN,
      .fns = Commands.Open.Fns,
      .cmdinp = opened_file_str,
    });
    try Commands.Open.onInputted(self);
  }
  
};
