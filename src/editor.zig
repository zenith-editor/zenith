//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config");

const config = @import("./config.zig");
const kbd = @import("./kbd.zig");
const str = @import("./str.zig");
const text = @import("./text.zig");
const sig = @import("./sig.zig");
const shortcuts = @import("./shortcuts.zig");
const encoding = @import("./encoding.zig");
const highlight = @import("./highlight.zig");

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
    
    pub const Prompt = struct {
      handleYes: *const fn(self: *Editor) anyerror!void,
      handleNo: *const fn(self: *Editor) anyerror!void,
    };
    
    replace_all: ReplaceAll,
    find: Find,
    prompt: Prompt,
    
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
        else => {},
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
      promptoverlay.deinit(E.allocr);
    }
    if (self.args) |*args| {
      args.deinit(E.allocr);
    }
    self.cmdinp.deinit(E.allocr);
  }
  
  pub fn replace(self: *CommandData, E: *Editor, new_cmd_data: *const CommandData) void {
    self.deinit(E);
    self.* = new_cmd_data.*;
  }
  
  pub fn replaceArgs(self: *CommandData, E: *Editor, new_args: *const Args) void {
    if (self.args != null) {
      self.args.?.deinit(E.allocr);
    }
    self.args = new_args.*;
  }
  
  pub fn replacePromptOverlay(self: *CommandData, E: *Editor, static: []const u8) void {
    if (self.promptoverlay != null) {
      self.promptoverlay.?.deinit(E.allocr);
    }
    self.promptoverlay = .{ .static = static, };
  }
  
  pub fn replacePromptOverlayFmt(self: *CommandData, E: *Editor, comptime fmt: []const u8, args: anytype) !void {
    if (self.promptoverlay != null) {
      self.promptoverlay.?.deinit(E.allocr);
    }
    self.promptoverlay = .{
      .owned = try std.fmt.allocPrint(E.allocr, fmt, args),
    };
  }
};

pub const Commands = struct {
  pub const Open = @import("./cmd/open.zig");
  pub const GotoLine = @import("./cmd/gotoline.zig");
  pub const Find = @import("./cmd/find.zig");
  pub const Replace = @import("./cmd/replace.zig");
  pub const Prompt = @import("./cmd/prompt.zig");
};

pub const HideableMessage = struct {
  text: str.MaybeOwnedSlice,
  rows: u32,
  
  pub fn deinit(self: *HideableMessage, allocator: std.mem.Allocator) void {
    self.text.deinit(allocator);
  }
};

pub const Editor = struct {
  const STATUS_BAR_HEIGHT = 2;
  const INPUT_BUFFER_SIZE = 64;
  
  in: std.fs.File,
  inr: std.fs.File.Reader,
  /// Number of bytes read for this character
  in_read: usize = 0,
  
  out: std.fs.File,
  outw: std.fs.File.Writer,
  
  orig_termios: ?std.posix.termios = null,
  
  needs_redraw: bool = true,
  needs_update_cursor: bool = true,
  
  state_handler: *const StateHandler,
  
  allocr: std.mem.Allocator,
  
  w_width: u32 = 0,
  w_height: u32 = 0,
  
  text_handler: text.TextHandler,
  
  highlight_last_iter_idx: usize = 0,
  
  conf: config.Reader,
  
  unprotected_hideable_msg: ?HideableMessage = null,
  
  unprotected_state: State,
  
  unprotected_cmd_data: ?CommandData,
  
  // terminal extensions
  has_bracketed_paste: bool = false,
  has_alt_screen_buf: bool = false,
  has_alt_scroll_mode: bool = false,
  has_mouse_tracking: bool = false,
  
  pub fn create(allocr: std.mem.Allocator) !Editor {
    const stdin: std.fs.File = std.io.getStdIn();
    const stdout: std.fs.File = std.io.getStdOut();
    var editor = Editor {
      .in = stdin,
      .inr = stdin.reader(),
      .out = stdout,
      .outw = stdout.writer(),
      .state_handler = &StateHandler.Text,
      .allocr = allocr,
      .text_handler = try text.TextHandler.create(),
      .conf = .{},
      .unprotected_state = State.INIT,
      .unprotected_cmd_data = null,
    };
    try editor.loadConfig();
    try editor.updateWinSize();
    return editor;
  }
  
  fn loadConfig(self: *Editor) !void {
    var result = config.Reader.open(self.allocr);
    
    switch (result) {
      .ok => |conf_ok| {
        self.conf = conf_ok;
      },
      .err => |*err| {
        defer err.deinit(self.allocr);
        if (err.type == error.FileNotFound and err.location == .not_loaded) {
          // ignored
        } else {
          const writer = self.outw;
          switch (err.location) {
            .not_loaded => {
              try writer.print("Unable to read config file: {}\n", .{err.type});
            },
            .main => {
              try writer.print(
                "Unable to read config file <{s}:+{}>: {}\n",
                .{ self.conf.config_filepath orelse "???", err.pos orelse 0, err.type });
            },
            .highlight => |path| {
              try writer.print(
                "Unable to read config file <{s}:+{}>: {}\n",
                .{ path, err.pos.?, err.type });
            },
          }
          try writer.print("Press Enter to continue...\n",.{});
          _ = self.inr.readByte() catch {};
        }
      },
    }
    
    self.text_handler.undo_mgr.setMemoryLimit(self.conf.undo_memory_limit);
  }
  
  pub fn getState(self: *const Editor) State {
    return self.unprotected_state;
  }
  
  pub fn setState(self: *Editor, state: State) void {
    std.debug.assert(state != self.unprotected_state);
    const old_state_handler = StateHandler.List[@intFromEnum(self.unprotected_state)];
    if (old_state_handler.onUnset) |onUnset| {
      onUnset(self, state);
    }
    self.unprotected_state = state;
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
    return &self.unprotected_cmd_data.?;
  }
  
  pub fn setCmdData(self: *Editor, cmd_data: *const CommandData) void {
    std.debug.assert(self.unprotected_cmd_data == null);
    self.unprotected_cmd_data = cmd_data.*;
  }
  
  pub fn unsetCmdData(self: *Editor) void {
    self.unprotected_cmd_data.?.deinit(self);
    self.unprotected_cmd_data = null;
  }
  
  // hideable message
  
  pub fn setHideableMsgConst(self: *Editor, static: []const u8) void {
    if (self.unprotected_hideable_msg) |*msg| {
      msg.deinit(self.allocr);
    }
    self.unprotected_hideable_msg = .{
      .text = .{ .static = static, },
      .rows = 1,
    };
  }
  
  pub fn copyHideableMsg(self: *Editor, other: *const HideableMessage) void {
    if (self.unprotected_hideable_msg) |*msg| {
      msg.deinit(self.allocr);
    }
    std.debug.assert(!other.text.isOwned());
    self.unprotected_hideable_msg = other.*;
  }
  
  pub fn unsetHideableMsg(self: *Editor) void {
    if (self.unprotected_hideable_msg != null) {
      self.unprotected_hideable_msg.?.deinit(self.allocr);
      self.unprotected_hideable_msg = null;
    }
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
  
  fn readByte(self: *Editor) !u8 {
    const byte: u8 = try self.readRaw();
    self.in_read += 1;
    if (comptime build_config.dbg_print_read_byte) {
      if (std.ascii.isPrint(byte)) {
        std.debug.print("read: {} ({c})\n", .{byte, byte});
      } else {
        std.debug.print("read: {}\n", .{byte});
      }
    }
    return byte;
  }
  
  fn readEsc(self: *Editor) !u8 {
    const start = std.time.milliTimestamp();
    var now: i64 = start;
    while ((now - start) < self.conf.escape_time) {
      if (self.readRaw()) |byte| {
        if (comptime build_config.dbg_print_read_byte) {
          if (std.ascii.isPrint(byte)) {
            std.debug.print("readEsc: {} ({c})\n", .{byte, byte});
          } else {
            std.debug.print("readEsc: {}\n", .{byte});
          }
        }
        return byte;
      } else |_| {}
      std.time.sleep(std.time.ns_per_ms);
      now = std.time.milliTimestamp();
    }
    return error.EndOfStream;
  }
  
  fn flushConsoleInput(self: *Editor) void {
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
      return self.editor.readEsc() catch 0;
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
    self.in_read = 0;
    const raw = self.readByte() catch return null;
    if (raw == kbd.Keysym.ESC) {
      if (self.readEsc()) |possible_esc| {
        if (possible_esc == '[') {
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
          else if (matcher.match("<0;")) {
            var input: std.BoundedArray(u8, 16) = .{};
            var is_release = false;
            while (self.readEsc() catch null) |cont| {
              if (cont == 'M' or cont == 'm') {
                is_release = cont == 'm';
                break;
              } else {
                input.append(cont) catch {
                  // escape sequence too large
                  self.flushConsoleInput();
                  return null;
                };
              }
            }
            var iter = std.mem.splitScalar(u8, input.slice(), ';');
            var x: ?u32 = null;
            var y: ?u32 = null;

            while (iter.next()) |value| {
              const pos = std.fmt.parseInt(u32, value, 10) catch return null;
              if (x == null) { x = pos; }
              else if (y == null) { y = pos; }
              else { break; }
            }
            
            return kbd.Keysym.initMouse(
              x orelse return null,
              y orelse return null,
              is_release
            );
          }
          else if (matcher.match("<64;")) {
            while (self.readEsc() catch null) |cont| {
              if (cont == 'M' or cont == 'm') {
                break;
              }
            }
            return kbd.Keysym.initSpecial(.scroll_up);
          }
          else if (matcher.match("<65;")) {
            while (self.readByte() catch null) |cont| {
              if (cont == 'M' or cont == 'm') {
                break;
              }
            }
            return kbd.Keysym.initSpecial(.scroll_down);
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
          else {
            self.flushConsoleInput();
            return null;
          }
        } else {
          self.flushConsoleInput();
          return null;
        }
      } else |_| {}
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
  
  pub const ESC_FG_BOLD = "\x1b[1m";
  pub const ESC_FG_ITALIC = "\x1b[3m";
  pub const ESC_FG_UNDERLINE = "\x1b[4m";
  pub const ESC_FG_EMPHASIZE = "\x1b[38;5;8m";
  
  pub const HTAB_CHAR = ESC_FG_EMPHASIZE ++ "\xc2\xbb " ++ ESC_COLOR_DEFAULT;
  pub const HTAB_COLS = 2;
  pub const LINEWRAP_SYM = ESC_FG_EMPHASIZE ++ "\xe2\x8f\x8e" ++ ESC_COLOR_DEFAULT;
  pub const LINENO_COLOR = ESC_FG_EMPHASIZE;
  
  pub const COLOR_CODE_INVERT: ColorCode = .{
    .bg = .invert,
  };
  
  pub const ColorCode = struct {
    pub const Bg = union(enum) {
      transparent,
      coded: u32,
      invert,
      
      pub fn eql(self: *const Bg, other: *const Bg) bool {
        switch (self.*) {
          .transparent => {
            switch(other.*) {
              .transparent => return true,
              else => return false,
            }
          },
          .invert => {
            switch(other.*) {
              .invert => return true,
              else => return false,
            }
          },
          .coded => |coded| {
            switch(other.*) {
              .coded => |c1| return coded == c1,
              else => return false,
            }
          },
        }
      }
    };
    
    pub const Decoration = struct {
      is_bold: bool = false,
      is_italic: bool = false,
      is_underline: bool = false,
      
      pub fn eql(self: *const Decoration, other: *const Decoration) bool {
        return (
          self.is_bold == other.is_bold and
          self.is_italic == other.is_italic and
          self.is_underline == other.is_underline
        );
      }
    };
    
    fg: ?u32 = null,
    bg: Bg = .transparent,
    deco: Decoration = .{},
    
    pub const MAX_COLORS = 15;
    
    pub const COLOR_STR = [_][]const u8{
      "black",
      "dark-red",
      "dark-green",
      "dark-yellow",
      "dark-blue",
      "dark-purple",
      "dark-cyan",
      "gray",
      "dark-gray",
      "red",
      "green",
      "yellow",
      "blue",
      "purple",
      "cyan",
      "white",
    };
    
    pub fn init(fg: ?u32, bg: ?u32, deco: Decoration) ColorCode {
      return .{
        .fg = (if (fg != null and fg.? <= MAX_COLORS) fg.? else null),
        .bg = blk: {
          if (bg) |coded| {
            break :blk .{ .coded = coded };
          } else {
            break :blk .transparent;
          }
        },
        .deco = deco,
      };
    }
    
    pub fn eql(self: *const ColorCode, other: *const ColorCode) bool {
      return (
        self.fg == other.fg and
        self.bg.eql(&other.bg) and
        self.deco.eql(&other.deco)
      );
    }
    
    pub fn idFromStr(s: []const u8) ?u32 {
      for (COLOR_STR, 0..COLOR_STR.len) |color_cmp, i| {
        if (std.mem.eql(u8, color_cmp, s)) {
          return @intCast(i);
        }
      }
      return null;
    }
  };
  
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
  
  pub fn getTextLeftPadding(self: *const Editor) u32 {
    if (self.conf.show_line_numbers) {
      return self.text_handler.line_digits + 1;
    } else {
      return 0;
    }
  }
  
  pub fn getTextWidth(self: *const Editor) u32 {
    return self.w_width - self.getTextLeftPadding();
  }
  
  pub fn getTextHeight(self: *const Editor) u32 {
    return self.w_height - STATUS_BAR_HEIGHT;
  }
  
  // handle input
  
  /// minimum number of consecutive bytes read to be considered
  /// from clipboard. this is a heuristic to detect input from clipboard
  /// if for some reason the vterm doesn't support it
  const TYPED_CLIPBOARD_BYTE_THRESHOLD = 3;
  
  const HandleInputResult = struct {
    is_special: bool = false,
    nread: usize = 0,
  };
  
  fn handleInput(self: *Editor, is_clipboard: bool) !HandleInputResult {
    var nread: usize = 0;
    if (self.readKey()) |keysym| {
      nread += self.in_read;
      if (self.unprotected_hideable_msg != null) {
        self.unsetHideableMsg();
        self.needs_redraw = true;
      }
      switch (keysym.key) {
        .paste_begin => {
          // see https://invisible-island.net/xterm/xterm-paste64.html
          while (self.readKey()) |keysym1| {
            nread += self.in_read;
            switch (keysym1.key) {
              .paste_end => { break; },
              else => {
                try self.state_handler.handleInput(self, &keysym1, true);
              },
            }
          }
          return .{ .is_special = true, .nread = nread };
        },
        else => {},
      }
      try self.state_handler.handleInput(self, &keysym, is_clipboard);
      return .{
        .is_special = keysym.isSpecial(),
        .nread = nread,
      };
    }
    return .{};
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
          _ = try self.handleInput(false);
          return;
        };
        
        if (pollres == 0) {
          _ = try self.handleInput(false);
          return;
        }
        
        while (true) {
          var int_bytes_avail: i32 = 0;
          if (std.os.linux.ioctl(
            std.posix.STDIN_FILENO,
            std.os.linux.T.FIONREAD,
            @intFromPtr(&int_bytes_avail)
          ) < 0) {
            // ignore error reading available bytes and return
            _ = try self.handleInput(false);
            return;
          }
          
          // no more bytes left
          if (int_bytes_avail == 0) {
            return;
          }
        
          const bytes_avail: usize = @intCast(int_bytes_avail);
          var bytes_read: usize = 0;
          
          // although you could read *bytes_avail* bytes of input from stdin
          // into a buffer, doing so would remove timing information needed
          // to parse escape sequences
          
          if (self.has_bracketed_paste) {
            // bracketed pasting is handled in handleInput
            while (bytes_read < bytes_avail) {
              const res = try self.handleInput(false);
              if (res.nread == 0) {
                break;
              }
              bytes_read += res.nread;
            }
          } else {
            const is_clipboard = bytes_avail > TYPED_CLIPBOARD_BYTE_THRESHOLD;
            while (bytes_read < bytes_avail) {
              const res = try self.handleInput(is_clipboard);
              if (res.nread == 0) {
                break;
              }
              bytes_read += res.nread;
            }
          }
          
          // remaining keys
          while (bytes_read < bytes_avail) {
            const res = try self.handleInput(false);
            if (res.nread == 0) {
              break;
            }
            bytes_read += res.nread;
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
    color_code: ?ColorCode = null,
    
    inline fn setColor(self: *ColumnPrinter, opt_color_code: ?*const ColorCode) !void {
      if (opt_color_code == null) {
        if (self.color_code == null) {
          return;
        }
      } else if (self.color_code) |cur_color_code| {
        if (cur_color_code.eql(opt_color_code.?)) {
          return;
        }
      }
      if (opt_color_code) |color_code| {
        self.color_code = color_code.*;
      } else {
        self.color_code = null;
      }
      try self.writeColorCode();
    }
    
    fn writeColorCode(self: *ColumnPrinter) !void {
      if (self.color_code) |color_code| {
        try self.editor.writeAll(ESC_COLOR_DEFAULT);
        switch (color_code.bg) {
          .transparent => {},
          .coded => |coded| {
            try self.editor.writeFmt("\x1b[48;5;{d}m", .{coded});
          },
          .invert => {
            try self.editor.writeAll(ESC_COLOR_INVERT);
            return;
          }
        }
        if (color_code.fg) |fg| {
          try self.editor.writeFmt("\x1b[38;5;{d}m", .{fg});
        }
        if (color_code.deco.is_bold) {
          try self.editor.writeAll(ESC_FG_BOLD);
        }
        if (color_code.deco.is_italic) {
          try self.editor.writeAll(ESC_FG_ITALIC);
        }
        if (color_code.deco.is_underline) {
          try self.editor.writeAll(ESC_FG_UNDERLINE);
        }
      } else {
        try self.editor.writeAll(ESC_COLOR_DEFAULT);
      }
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
      var highlight_iter = text_handler.highlight.iterate(iter.pos, &self.highlight_last_iter_idx);
      
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
          try self.outw.writeAll(LINENO_COLOR);
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
          try printer.setColor(&COLOR_CODE_INVERT);
        }
        
        while (iter.nextCodepointSliceUntilWithCurPos(offset_end)) |bytes_with_pos| {
          const curr_highlight = highlight_iter.nextCodepoint(@intCast(bytes_with_pos.bytes.len));
          if  (
            bytes_with_pos.pos >= markers.end or
            bytes_with_pos.pos < markers.start
          ) {
            if (curr_highlight != null) {
              try printer.setColor(self.getHighlightColor(&curr_highlight.?));
            } else {
              try printer.setColor(null);
            }
          } else if (bytes_with_pos.pos >= markers.start) {
            try printer.setColor(&COLOR_CODE_INVERT);
          }
          if (!try printer.writeAll(bytes_with_pos.bytes)) {
            break;
          }
        }
      }
      
      else if (comptime build_config.dbg_show_gap_buf) {
        const logical_gap_buf_start: u32 = self.text_handler.head_end;
        const logical_gap_buf_end: u32 =
          @intCast(logical_gap_buf_start + self.text_handler.gap.items.len);
          
        if (iter.pos >= logical_gap_buf_start and iter.pos < logical_gap_buf_end) {
          try printer.setColor(&COLOR_CODE_INVERT);
        }
        
        while (iter.nextCodepointSliceUntilWithCurPos(offset_end)) |bytes_with_pos| {
          const curr_highlight = highlight_iter.next(bytes_with_pos.bytes.len);
          if (
            bytes_with_pos.pos >= logical_gap_buf_end or
            bytes_with_pos.pos < logical_gap_buf_start
          ) {
            if (curr_highlight != null) {
              try printer.setColor(self.getHighlightColor(&curr_highlight.?));
            } else {
              try printer.setColor(null);
            }
          } else if (bytes_with_pos.pos >= logical_gap_buf_start) {
            try printer.setColor(&COLOR_CODE_INVERT);
          }
          if (!try printer.writeAll(bytes_with_pos.bytes)) {
            break;
          }
        }
      }
      
      else {
        while (iter.nextCodepointSliceUntil(offset_end)) |bytes| {
          const curr_highlight = highlight_iter.nextCodepoint(@intCast(bytes.len));
          if (curr_highlight != null) {
            try printer.setColor(self.getHighlightColor(&curr_highlight.?));
          } else {
            try printer.setColor(null);
          }
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
  
  fn getHighlightColor(self: *const Editor, token: *const highlight.Token) *const ColorCode {
    const token_type = &self.text_handler.highlight.token_types.items[token.typeid];
    return &token_type.color;
  }
  
  fn showUpperLayers(self: *Editor) !void {
    if (self.unprotected_hideable_msg) |msg| {
      var row: u32 = 0;
      if (self.getTextHeight() >= msg.rows) {
        row = self.getTextHeight() - msg.rows;
      }
      try self.moveCursor(row, 0);
      try self.outw.writeAll(ESC_CLEAR_LINE);
      for (msg.text.slice()) |char| {
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
  
  const TermExt = struct {
    ansi: []const []const u8,
    flag: []const u8,
    conf: []const u8,
  };
  
  const TERM_EXT = [_]TermExt {
    .{ .ansi=&.{"2004"}, .flag="has_bracketed_paste", .conf="force_bracketed_paste" },
    .{ .ansi=&.{"1049"}, .flag="has_alt_screen_buf", .conf="force_alt_screen_buf" },
    .{ .ansi=&.{"1007"}, .flag="has_alt_scroll_mode", .conf="force_alt_scroll_mode" },
    // enables mouse tracking, sgr mouse mode
    .{ .ansi=&.{"1000","1006"}, .flag="has_mouse_tracking", .conf="force_mouse_tracking" },
  };
  
  fn enableTermExts(self: *Editor) !void {
    inline for(&TERM_EXT) |*term_ext| {
      if (@field(self.conf, term_ext.conf)) {
        inline for (term_ext.ansi) |ansi| {
          try self.outw.writeAll("\x1b[?" ++ ansi ++ "h");
        }
        @field(self, term_ext.flag) = true;
      } else {
        @field(self, term_ext.flag) = false;
      }
    }
  }
  fn disableTermExts(self: *Editor) !void {
    inline for(&TERM_EXT) |*term_ext| {
      if (@field(self, term_ext.flag)) {
        inline for (term_ext.ansi) |ansi| {
          try self.outw.writeAll("\x1b[?" ++ ansi ++ "l");
        }
      }
    }
  }
  
  // terminal restore
  
  pub fn restoreTerminal(self: *Editor) !void {
    try self.disableTermExts();
    try self.refreshScreen();
    try self.disableRawMode();
  }
  
  // tick
  
  const REFRESH_RATE_MS = 16;
  
  pub fn run(self: *Editor) !void {
    try self.enableRawMode();
    try self.enableTermExts();
    self.needs_redraw = true;
    var ts = std.time.milliTimestamp();
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
      
      const new_ts = std.time.milliTimestamp();
      const elapsed = (new_ts - ts);
      if (elapsed < REFRESH_RATE_MS) {
        const refresh_ts = (REFRESH_RATE_MS - (new_ts - ts)) * std.time.ns_per_ms;
        std.time.sleep(@intCast(refresh_ts));
      }
      ts = new_ts;
    }
    self.restoreTerminal() catch {};
  }
  
  /// opened_file_str must be allocated by E.allocr
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
