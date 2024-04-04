const std = @import("std");
const builtin = @import("builtin");

// keyboard event

const Keysym = struct {
  raw: u8,
  key: u8,
  ctrl_key: bool = false,
  
  const ESC: u8 = std.ascii.control_code.esc;
  const BACKSPACE: u8 = std.ascii.control_code.del;
  const NEWLINE: u8 = std.ascii.control_code.cr;
  
  const RAW_SPECIAL: u8 = 0;
  const UP: u8 = 0;
  const DOWN: u8 = 1;
  const RIGHT: u8 = 2;
  const LEFT: u8 = 3;
  const HOME: u8 = 4;
  const END: u8 = 5;
  
  fn init(raw: u8) Keysym {
    if (raw < std.ascii.control_code.us) {
      return Keysym {
        .raw = raw,
        .key = raw | 0b1100000,
        .ctrl_key = true,
      };
    } else {
      return Keysym {
        .raw = raw,
        .key = raw,
      };
    }
  }
  
  fn initSpecial(key: u8) Keysym {
    return Keysym {
      .raw = 0,
      .key = key,
    };
  }
  
  fn isSpecial(self: Keysym) bool {
    return (self.raw == @as(u8, 0)) or self.ctrl_key;
  }
  
  fn isPrint(self: Keysym) bool {
    return !self.isSpecial() and std.ascii.isPrint(self.raw);
  }
};

// text handling

const TextPos = struct {
  row: u32 = 0,
  col: u32 = 0,
};

const TextHandler = struct {
  /// List of null-terminated strings representing lines.
  /// the final null-byte represents padding for appending
  const Line = std.ArrayListUnmanaged(u8);
  const LineList = std.ArrayListUnmanaged(Line);
  
  file: ?std.fs.File,
  lines: LineList,
  cursor: TextPos,
  scroll: TextPos,
  
  fn init(allocr: std.mem.Allocator) !TextHandler {
    var lines = try LineList.initCapacity(allocr, 1);
    var firstline = try Line.initCapacity(allocr, 1);
    try firstline.append(allocr, 0);
    try lines.append(allocr, firstline);
    return TextHandler {
      .file = null,
      .lines = lines,
      .cursor = .{},
      .scroll = .{},
    };
  }
  
  fn open(self: *TextHandler, E: *Editor, file: std.fs.File) !void {
    if (self.file != null) {
      self.file.?.close();
    }
    self.cursor = TextPos {};
    self.scroll = TextPos {};
    self.file = file;
    self.lines.clearAndFree(E.allocr());
    try self.readLines(E);
  }
  
  fn save(self: *TextHandler) !void {
    if (self.file == null) {
      // TODO
      return;
    }
    const file: std.fs.File = self.file.?;
    try file.seekTo(0);
    try file.setEndPos(0);
    const writer: std.fs.File.Writer = file.writer();
    if (self.lines.items.len > 0) {
//       std.debug.print("{s}", .{self.lines.items[0].items}); 
      const firstline: *const Line = &self.lines.items[0];
      try writer.writeAll(firstline.items[0..(firstline.items.len-1)]);
      if (self.lines.items.len > 1) {
        for (self.lines.items[1..]) |line| {
          try writer.writeByte('\n');
          try writer.writeAll(line.items[0..(line.items.len-1)]);
        }
      }
    }
  }
  
  fn readLines(self: *TextHandler, E: *Editor) !void {
    var file: std.fs.File = self.file.?;
    const allocr: std.mem.Allocator = E.allocr();
    var line: Line = try Line.initCapacity(allocr, 1);
    var buf: [512]u8 = undefined;
    while (true) {
      const nread = try file.read(&buf);
      for (0..nread) |i| {
        if (buf[i] == '\n') {
          try line.append(allocr, 0);
          try self.lines.append(allocr, line);
          line = try Line.initCapacity(allocr, 1); // moved to self.lines
        } else {
          try line.append(allocr, buf[i]);
        }
      }
      if (nread == 0) {
        try line.append(allocr, 0);
        try self.lines.append(allocr, line);
        // line is moved, so no need to free
        return;
      }
    }
  }
  
  // cursor
  
  fn syncColumnAfterCursor(self: *TextHandler, E: *Editor) void {
    const rowlen: u32 = @intCast(self.lines.items[self.cursor.row].items.len);
    if (self.cursor.col <= rowlen - 1) {
      return;
    }
    self.cursor.col = rowlen - 1;
    const oldScrollCol = self.scroll.col;
    if (self.cursor.col > E.w_width) {
      self.scroll.col = self.cursor.col - E.w_width;
    } else {
      self.scroll.col = 0;
    }
    if (oldScrollCol != self.scroll.col) {
      E.needs_redraw = true;
    }
  }
  
  fn goUp(self: *TextHandler, E: *Editor) void {
    if (self.cursor.row == 0) {
      return;
    }
    self.cursor.row -= 1;
    self.syncColumnAfterCursor(E);
    if (self.cursor.row < self.scroll.row) {
      self.scroll.row -= 1;
      E.needs_redraw = true;
    }
    E.needs_update_cursor = true;
  }
  
  fn goDown(self: *TextHandler, E: *Editor) void {
    if (self.cursor.row == self.lines.items.len - 1) {
      return;
    }
    self.cursor.row += 1;
    self.syncColumnAfterCursor(E);
    if ((self.cursor.row + self.scroll.row) >= E.textHeight()) {
      self.scroll.row += 1;
      E.needs_redraw = true;
    }
    E.needs_update_cursor = true;
  }
  
  fn goLeft(self: *TextHandler, E: *Editor) void {
    if (self.cursor.col == 0) {
      return;
    }
    self.cursor.col -= 1;
    if (self.cursor.col < self.scroll.col) {
      self.scroll.col -= 1;
      E.needs_redraw = true;
    }
    E.needs_update_cursor = true;
  }
  
  fn goRight(self: *TextHandler, E: *Editor) void {
    if (self.cursor.col >= self.lines.items[self.cursor.row].items.len - 1) {
      return;
    }
    self.cursor.col += 1;
    if ((self.cursor.col + self.scroll.col) >= E.w_width) {
      self.scroll.col += 1;
      E.needs_redraw = true;
    }
    E.needs_update_cursor = true;
  }
  
  fn goHead(self: *TextHandler, E: *Editor) void {
    self.cursor.col = 0;
    if (self.scroll.col != 0) {
      E.needs_redraw = true;
    }
    self.scroll.col = 0;
    E.needs_update_cursor = true;
  }
  
  fn goTail(self: *TextHandler, E: *Editor) void {
    const line: *Line = &self.lines.items[self.cursor.row];
    const linelen: u32 = @intCast(line.items.len);
    self.cursor.col = linelen - 1;
    self.syncColumnScroll(E);
    E.needs_redraw = true;
  }
  
  fn syncColumnScroll(self: *TextHandler, E: *Editor) void {
    if ((self.scroll.col + self.cursor.col) > E.w_width) {
      if (E.w_width > self.cursor.col) {
        self.scroll.col = E.w_width - self.cursor.col + 1;
      } else {
        self.scroll.col = self.cursor.col - E.w_width + 1;
      }
    } else {
      self.scroll.col = 0;
    }
  }
  
  fn syncRowScroll(self: *TextHandler, E: *Editor) void {
    if ((self.scroll.row + self.cursor.row) > E.textHeight()) {
      if (E.textHeight() > self.cursor.row) {
        self.scroll.row = E.textHeight() - self.cursor.row + 1;
      } else {
        self.scroll.row = self.cursor.row - E.textHeight() + 1;
      }
    } else { 
      self.scroll.row = 0;
    }
  }
  
  // append
  
  fn insertChar(self: *TextHandler, E: *Editor, char: u8) !void {
    try self.lines.items[self.cursor.row].insert(E.allocr(), self.cursor.col, char);
    E.needs_redraw = true;
    self.goRight(E);
  }
  
  fn insertNewline(self: *TextHandler, E: *Editor) !void {
    const allocr: std.mem.Allocator = E.allocr();
    const cutpoint: usize = @intCast(self.cursor.col);
    const curline: *Line = &self.lines.items[self.cursor.row];
    
    std.debug.assert(cutpoint < curline.items.len);
    
    if (cutpoint < curline.items.len - 1) {
      // cutpoint lies inside text portion
      // newline_len includes sentinel value
      const newline_len: usize = curline.items.len - cutpoint;
      var newline: Line = .{};
      try newline.resize(allocr, newline_len);
      @memcpy(newline.items[0..newline_len], curline.items[cutpoint..]);
      std.debug.print("!{s}\n", .{curline.items[cutpoint..]});
      newline.items[newline_len - 1] = 0;
      // cut from the current line
      curline.shrinkAndFree(allocr, cutpoint + 1);
      curline.items[cutpoint] = 0;
      try self.lines.insert(allocr, self.cursor.row + 1, newline);
      // newline is moved
    } else {
      // cutpoint is at the end of text portion
      var newline: Line = try Line.initCapacity(allocr, 1);
      try newline.append(allocr, 0);
      try self.lines.insert(allocr, self.cursor.row + 1, newline);
      // newline is moved
    }
    
    self.cursor.row += 1;
    self.cursor.col = 0;
    if ((self.scroll.row + self.cursor.row) > E.textHeight()) {
      self.scroll.row += 1;
    }
    E.needs_redraw = true;
  }
  
  // deletion
  
  fn deleteChar(self: *TextHandler, E: *Editor) !void {
    var row: *Line = &self.lines.items[self.cursor.row];
    if (row.items.len == 1) {
      // empty line, so remove it
      return self.deleteCurrentLine(E);
    } else if (self.cursor.col == 0) {
      // placing cursor at the first column removes the line break
      return self.fuseWithPrevLine(E);
    } else if (self.cursor.col < row.items.len) {
      // remove character before the cursor
      _ = row.orderedRemove(self.cursor.col - 1);
    } else {
      // remove last character before the null terminator
      _ = row.orderedRemove(row.items.len - 2);
    }
    E.needs_redraw = true;
    self.goLeft(E);
  }
  
  fn deleteCurrentLine(self: *TextHandler, E: *Editor) !void {
    if (self.cursor.row == 0) {
      return;
    }
    var row: Line = self.lines.orderedRemove(self.cursor.row);
    defer row.deinit(E.allocr());
    self.cursor.row -= 1;
    self.goTail(E);
  }
  
  fn fuseWithPrevLine(self: *TextHandler, E: *Editor) !void {
    if (self.cursor.row == 0) {
      return;
    }
    var row: Line = self.lines.orderedRemove(self.cursor.row);
    defer row.deinit(E.allocr());
    self.cursor.row -= 1;
    self.goTail(E);
    var prevRow: *Line = &self.lines.items[self.cursor.row];
    // remove sentinel for previous line
    if (prevRow.pop() != 0) {
      std.debug.panic("expected sentinel value", .{});
    }
    try prevRow.appendSlice(E.allocr(), row.items);
  }
};

// editor

const Editor = struct {
  const State = enum {
    text,
    command,
    quit,
    
    const INIT = State.text;
  };
  
  const StateHandler = struct {
    handleInput: *const fn (self: *Editor, keysym: Keysym) anyerror!void,
    handleOutput: *const fn (self: *Editor) anyerror!void,
    
    fn _createStateHandler(comptime T: type) StateHandler {
      return StateHandler {
        .handleInput = T.handleInput,
        .handleOutput = T.handleOutput,
      };
    }
    
    const TextImpl = struct {
      fn handleInput(self: *Editor, keysym: Keysym) !void {
        if (keysym.raw == 0 and keysym.key == Keysym.UP) {
          self.text_handler.goUp(self);
        }
        else if (keysym.raw == 0 and keysym.key == Keysym.DOWN) {
          self.text_handler.goDown(self);
        }
        else if (keysym.raw == 0 and keysym.key == Keysym.LEFT) {
          self.text_handler.goLeft(self);
        }
        else if (keysym.raw == 0 and keysym.key == Keysym.RIGHT) {
          self.text_handler.goRight(self);
        }
        else if (keysym.raw == 0 and keysym.key == Keysym.HOME) {
          self.text_handler.goHead(self);
        }
        else if (keysym.raw == 0 and keysym.key == Keysym.END) {
          self.text_handler.goTail(self);
        }
        else if (keysym.ctrl_key and keysym.key == 'q') {
          self.setState(State.quit);
        }
        else if (keysym.ctrl_key and keysym.key == 's') {
          try self.text_handler.save();
        }
        else if (keysym.ctrl_key and keysym.key == 'o') {
          // TODO
        }
        else if (keysym.raw == Keysym.BACKSPACE) {
          try self.text_handler.deleteChar(self);
        }
        else if (keysym.raw == Keysym.NEWLINE) {
          try self.text_handler.insertNewline(self);
        }
        else if (keysym.isPrint()) {
          try self.text_handler.insertChar(self, keysym.key);
        }
      }
      
      fn handleOutput(self: *Editor) !void {
        try self.refreshScreen();
        try self.renderText();
      }
    };
    const Text: StateHandler = _createStateHandler(TextImpl);
    
    const CommandImpl = struct {
      fn handleInput(self: *Editor, keysym: Keysym) !void {
        _ = self;
        _ = keysym;
      }
      
      fn handleOutput(self: *Editor) !void {
        _ = self;
      }
    };
    const Command: StateHandler = _createStateHandler(CommandImpl);
    
    const List = [_]*const StateHandler{
      &Text,
      &Command,
      &Text, // quit
    };
  };
  
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
  text_handler: TextHandler,
  alloc_gpa: std.heap.GeneralPurposeAllocator(.{}),
  w_width: u32,
  w_height: u32,
  buffered_byte: u8,
  
  fn init() !Editor {
    const stdin: std.fs.File = std.io.getStdIn();
    const stdout: std.fs.File = std.io.getStdOut();
    var editor = Editor {
      .in = stdin,
      .inr = stdin.reader(),
      .out = stdout,
      .outw = stdout.writer(),
      .orig_termios = null,
      .needs_redraw = true,
      .needs_update_cursor = true,
      ._state = State.INIT,
      .state_handler = &StateHandler.Text,
      .text_handler = undefined,
      .alloc_gpa = .{},
      .w_width = 0,
      .w_height = 0,
      .buffered_byte = 0,
    };
    editor.text_handler = try TextHandler.init(editor.allocr());
    return editor;
  }
  
  fn allocr(self: *Editor) std.mem.Allocator {
    return self.alloc_gpa.allocator();
  }
  
  fn setState(self: *Editor, comptime state: State) void {
    self._state = state;
    self.state_handler = StateHandler.List[@intFromEnum(state)];
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
      std.debug.print("[{}]", .{byte});
    }
  }
  
  fn readKey(self: *Editor) ?Keysym {
    if (self.buffered_byte != 0) {
      const b = self.buffered_byte;
      self.buffered_byte = 0;
      return Keysym.init(b);
    }
    const raw = self.inr.readByte() catch return null;
    if (raw == Keysym.ESC) {
      if (self.inr.readByte() catch null) |possibleEsc| {
        if (possibleEsc == '[') {
          switch (self.inr.readByte() catch 0) {
            'A' => { return Keysym.initSpecial(Keysym.UP); },
            'B' => { return Keysym.initSpecial(Keysym.DOWN); },
            'C' => { return Keysym.initSpecial(Keysym.RIGHT); },
            'D' => { return Keysym.initSpecial(Keysym.LEFT); },
            'F' => { return Keysym.initSpecial(Keysym.END); },
            'H' => { return Keysym.initSpecial(Keysym.HOME); },
            else => |byte1| {
              // unknown escape sequence, empty the buffer
              std.debug.print("[{}]", .{byte1});
              self.flushConsoleInput();
            }
          }
        } else {
          self.buffered_byte = possibleEsc;
        }
      }
    }
    return Keysym.init(raw);
  }
  
  // console output
  
  const CLEAR_SCREEN = "\x1b[2J";
  const CLEAR_LINE = "\x1b[2K";
  const RESET_POS = "\x1b[H";
  
  fn writeAll(self: *Editor, bytes: []const u8) !void {
    return self.outw.writeAll(bytes);
  }
  
  fn writeFmt(self: *Editor, comptime fmt: []const u8, args: anytype,) !void {
    return std.fmt.format(self.outw, fmt, args);
  }
  
  fn moveCursor(self: *Editor, pos: TextPos) !void {
    var row = pos.row;
    if (row > self.w_height - 1) { row = self.w_height - 1; }
    var col = pos.col;
    if (col > self.w_width - 1) { col = self.w_width - 1; }
    return self.writeFmt("\x1b[{d};{d}H", .{row + 1, col + 1});
  }
  
  fn updateCursorPos(self: *Editor) !void {
    const text_handler: *TextHandler = &self.text_handler;
    try self.moveCursor(TextPos {
      .row = text_handler.cursor.row - text_handler.scroll.row,
      .col = text_handler.cursor.col - text_handler.scroll.col,
    });
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
  
  fn textHeight(self: *Editor) u32 {
    return self.w_height - STATUS_BAR_HEIGHT;
  }
  
  // handle input
  
  fn handleInput(self: *Editor) !void {
    if (self.readKey()) |keysym| {
      std.debug.print("{}\n", .{keysym});
      try self.state_handler.handleInput(self, keysym);
    }
  }
  
  // handle output
  
  fn renderText(self: *Editor) !void {
    const text_handler: *const TextHandler = &self.text_handler;
    var row: u32 = 0;
    const cursor_row: u32 = text_handler.cursor.row - text_handler.scroll.row;
    for (text_handler.lines.items[text_handler.scroll.row..]) |line| {
      if (row != cursor_row) {
        try self.renderLine(line.items, row, 0);
      } else {
        try self.renderLine(line.items, row, text_handler.scroll.col);
      }
      row += 1;
      if (row == self.textHeight()) {
        break;
      }
    }
    self.needs_update_cursor = true;
  }
  
  fn renderLine(self: *Editor, line: []const u8, row: u32, colOffset: u32) !void {
    try self.moveCursor(TextPos {.row = row, .col = 0});
    var col: u32 = 0;
    for (line[colOffset..line.len-1]) |byte| {
      if (col == self.w_width) {
        return;
      }
      if (std.ascii.isControl(byte)) {
        continue;
      }
      try self.outw.writeByte(byte);
      col += 1;
    }
  }
  
  fn renderStatus(self: *Editor) !void {
    try self.moveCursor(TextPos {.row = self.textHeight(), .col = 0});
    const text_handler: *const TextHandler = &self.text_handler;
    try self.writeAll(CLEAR_LINE);
    try self.writeFmt(" {}:{}", .{text_handler.cursor.row+1, text_handler.cursor.col+1});
  }
  
  fn handleOutput(self: *Editor) !void {
    if (!self.needs_redraw)
      return;
    try self.state_handler.handleOutput(self);
    self.needs_redraw = false;
  }
  
  // tick
  
  const REFRESH_RATE = 16700000;
  
  fn run(self: *Editor) !void {
    try self.updateWinSize();
    try self.enableRawMode();
    self.needs_redraw = true;
    self.setState(State.INIT);
    while (self._state != State.quit) {
      if (resized) {
        try self.updateWinSize();
        resized = false;
      }
      try self.handleInput();
      try self.handleOutput();
      if (self.needs_update_cursor) {
        try self.renderStatus();
        try self.updateCursorPos();
        self.needs_update_cursor = false;
      }
      std.time.sleep(Editor.REFRESH_RATE);
    }
    try self.refreshScreen();
    try self.disableRawMode();
  }
  
};

// signal handlers
var resized = false;
fn handle_sigwinch(signal: c_int) callconv(.C) void {
  _ = signal;
  resized = true;
}

pub fn main() !void {
  var opened_file: ?std.fs.File = null;
  {
    // arguments
    var args = std.process.args();
    _ = args.skip();
    const cwd = std.fs.cwd();
    while (args.next()) |arg| {
      if (opened_file != null) {
        // TODO
        return;
      }
      // std.debug.print("{}", .{arg});
      opened_file = try cwd.openFile(
        arg,
        std.fs.File.OpenFlags {
          .mode = .read_write,
          .lock = .shared,
        }
      );
    }
  }
  if (builtin.target.os.tag == .linux) {
    const sigaction = std.os.linux.Sigaction {
      .handler = .{ .handler = handle_sigwinch, },
      .mask = std.os.linux.empty_sigset,
      .flags = 0,
    };
    _ = std.os.linux.sigaction(std.os.linux.SIG.WINCH, &sigaction, null);
    // TODO log if sigaction fails
  }
  var E = try Editor.init();
  if (opened_file != null) {
    try E.text_handler.open(&E, opened_file.?);
  }
  try E.run();
}
