const std = @import("std");
const builtin = @import("builtin");

// types
const String = std.ArrayListUnmanaged(u8);

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
  const GAP_SIZE = 128;
  
  const TextIterator = struct {
    text_handler: *const TextHandler,
    pos: u32 = 0,
    
    fn next(self: *TextIterator) ?u8 {
      const text_handler: *const TextHandler = self.text_handler;
      const logical_tail_start = text_handler.head_end + text_handler.gap.len;
      if (self.pos < text_handler.head_end) {
        const ch = text_handler.buffer.items[self.pos];
        self.pos += 1;
        return ch;
      } else if (self.pos >= text_handler.head_end and self.pos < logical_tail_start) {
        std.debug.assert(text_handler.head_end < logical_tail_start);
        const gap_relidx = self.pos - text_handler.head_end;
        const ch = text_handler.gap.slice()[gap_relidx];
        self.pos += 1;
        return ch;
      } else {
        const real_tailidx = text_handler.tail_start + (self.pos - logical_tail_start);
        if (real_tailidx >= text_handler.buffer.items.len) {
          return null;
        }
        const ch = text_handler.buffer.items[real_tailidx];
        self.pos += 1;
        return ch;
      }
    }
    
    fn nextUntil(self: *TextIterator, offset_end: u32) ?u8 {
      if (self.pos == offset_end) {
        return null;
      }
      return self.next();
    }
  };
  
  file: ?std.fs.File = null,
  
  /// Buffer of characters. Logical text buffer is then:
  ///
  /// text = buffer[0..(head_end)] ++ gap ++ buffer[tail_start..]
  buffer: String = .{},
  
  /// Real position where the head of the text ends (excluding the last
  /// character)
  head_end: u32 = 0,
  
  /// Real position where the tail of the text starts
  tail_start: u32 = 0,
  
  /// Gap buffer
  gap: std.BoundedArray(u8, GAP_SIZE) = .{},
  
  /// Logical offsets to start of lines. These offsets are defined based on
  /// positions within the logical text buffer above.
  /// These offsets do not contain the newline character.
  line_offsets: std.ArrayListUnmanaged(u32) = .{},
  
  /// Maximum number of digits needed to print line position (starting from 1)
  line_digits: u32 = 1,
  
  cursor: TextPos = .{},
  scroll: TextPos = .{},
  
  fn init(allocr: std.mem.Allocator) !TextHandler {
    var line_offsets = try std.ArrayListUnmanaged(u32).initCapacity(allocr, 1);
    try line_offsets.append(allocr, 0);
    return TextHandler { .line_offsets = line_offsets, };
  }
  
  // io
  
  fn open(self: *TextHandler, E: *Editor, file: std.fs.File) !void {
    if (self.file != null) {
      self.file.?.close();
    }
    self.cursor = TextPos {};
    self.scroll = TextPos {};
    self.file = file;
    self.buffer.clearAndFree(E.allocr());
    self.line_offsets.clearAndFree(E.allocr());
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
    for (self.buffer.items[0..self.head_end]) |byte| {
      try writer.writeByte(byte);
    }
    for (self.gap.slice()) |byte| {
      try writer.writeByte(byte);
    }
    for (self.buffer.items[self.tail_start..]) |byte| {
      try writer.writeByte(byte);
    }
  }
  
  fn readLines(self: *TextHandler, E: *Editor) !void {
    var file: std.fs.File = self.file.?;
    const allocr: std.mem.Allocator = E.allocr();
    self.buffer = String.fromOwnedSlice(try file.readToEndAlloc(allocr, std.math.maxInt(u32)));
    // first line
    try self.line_offsets.append(allocr, 0);
    var i: u32 = 0;
    for (self.buffer.items) |byte| {
      if (byte == '\n') {
        try self.line_offsets.append(allocr, i + 1);
      }
      i += 1;
    }
    self.calcLineDigits();
  }
  
  // general manip
  
  fn iterate(self: *const TextHandler, pos: u32) TextIterator {
    return TextIterator { .text_handler = self, .pos = pos, };
  }
  
  fn getLogicalLength(self: *const TextHandler) u32 {
    return @intCast(self.head_end + self.gap.len + (self.buffer.items.len - self.tail_start));
  }
  
  fn getNoLines(self: *const TextHandler) u32 {
    return @intCast(self.line_offsets.items.len);
  }
  
  fn calcLineDigits(self: *TextHandler) void {
    self.line_digits = std.math.log10(self.getNoLines() + 1) + 1;
  }
  
  fn getRowOffsetEnd(self: *const TextHandler, row: u32) u32 {
    // The newline character of the current line is not counted
    return if ((row + 1) < self.getNoLines())
      (self.line_offsets.items[row + 1] - 1)
    else
      self.getLogicalLength();
  }
  
  fn getRowLen(self: *const TextHandler, row: u32) u32 {
    const offset_start: u32 = self.line_offsets.items[row];
    const offset_end: u32 = self.getRowOffsetEnd(row);
    return offset_end - offset_start;
  }
  
  // gap
  
  fn flushGapBuffer(self: *TextHandler, E: *Editor) !void {
    if (self.tail_start > self.head_end) {
      // buffer contains deleted characters
      const deleted_chars = self.tail_start - self.head_end;
      const logical_tail_start = self.head_end + self.gap.len;
      const logical_len = self.getLogicalLength();
      if (deleted_chars > self.gap.len) {
        const gapdest: []u8 = self.buffer.items[self.head_end..logical_tail_start];
        @memcpy(gapdest, self.gap.slice());
        const taildest: []u8 = self.buffer.items[logical_tail_start..logical_len];
        std.mem.copyForwards(u8, taildest, self.buffer.items[self.tail_start..]);
      } else {
        const reserved_chars = self.gap.len - deleted_chars;
        _ = try self.buffer.addManyAt(E.allocr(), self.head_end, reserved_chars);
        const dest: []u8 = self.buffer.items[self.head_end..logical_tail_start];
        @memcpy(dest, self.gap.slice());
      }
      self.buffer.shrinkRetainingCapacity(logical_len);
    } else {
      try self.buffer.insertSlice(E.allocr(), self.head_end, self.gap.slice());
    }
    self.gap = .{};
  } 
  
  // cursor
  
  fn syncColumnAfterCursor(self: *TextHandler, E: *Editor) void {
    const rowlen: u32 = self.getRowLen(self.cursor.row);
    if (rowlen == 0) {
      self.cursor.col = 0;
    } else {
      if (self.cursor.col <= rowlen - 1) {
        return;
      }
      self.cursor.col = rowlen - 1;
    }
    const oldScrollCol = self.scroll.col;
    if (self.cursor.col > E.getTextWidth()) {
      self.scroll.col = self.cursor.col - E.getTextWidth();
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
    if (self.cursor.row == self.getNoLines() - 1) {
      return;
    }
    self.cursor.row += 1;
    self.syncColumnAfterCursor(E);
    if ((self.scroll.row + E.getTextHeight()) <= self.cursor.row) {
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
    if (self.cursor.col >= self.getRowLen(self.cursor.row)) {
      return;
    }
    self.cursor.col += 1;
    if ((self.cursor.col + self.scroll.col) >= E.getTextWidth()) {
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
    const rowlen: u32 = self.getRowLen(self.cursor.row);
    self.cursor.col = rowlen;
    self.syncColumnScroll(E);
    E.needs_redraw = true;
  }
  
  fn gotoLine(self: *TextHandler, E: *Editor, row: u32) !void {
    if (row >= self.getNoLines()) {
      return error.Overflow;
    }
    self.cursor.row = row;
    self.syncRowScroll(E);
    self.cursor.col = 0;
    self.scroll.col = 0;
  }
  
  fn syncColumnScroll(self: *TextHandler, E: *Editor) void {
    if (self.scroll.col > self.cursor.col) {
      if (E.getTextWidth() < self.cursor.col) {
        self.scroll.col = self.cursor.col - E.getTextWidth() + 1;
      } else if (self.cursor.col == 0) {
        self.scroll.col = 0;
      } else {
        self.scroll.col = self.cursor.col - 1;
      }
    } else if ((self.scroll.col + self.cursor.col) > E.getTextWidth()) {
      if (E.getTextWidth() > self.cursor.col) {
        self.scroll.col = E.getTextWidth() - self.cursor.col + 1;
      } else {
        self.scroll.col = self.cursor.col - E.getTextWidth() + 1;
      }
    } else {
      self.scroll.col = 0;
    }
  }
  
  fn syncRowScroll(self: *TextHandler, E: *Editor) void {
    if (self.scroll.row > self.cursor.row) {
      if (E.getTextHeight() < self.cursor.row) {
        self.scroll.row = self.cursor.row - E.getTextHeight() + 1;
      } else if (self.cursor.row == 0) {
        self.scroll.row = 0;
      } else {
        self.scroll.row = self.cursor.row - 1;
      }
    } else if ((self.scroll.row + self.cursor.row) > E.getTextHeight()) {
      if (E.getTextHeight() > self.cursor.row) {
        self.scroll.row = E.getTextHeight() - self.cursor.row + 1;
      } else {
        self.scroll.row = self.cursor.row - E.getTextHeight() + 1;
      }
    } else { 
      self.scroll.row = 0;
    }
  }
  
  // append
  
  fn incrementLineOffsets(self: *TextHandler, fromRow: u32) void {
    for (self.line_offsets.items[(fromRow + 1)..]) |*rowptr| {
      rowptr.* += 1;
    }
  }
  
  fn insertChar(self: *TextHandler, E: *Editor, char: u8) !void {
    const insidx: u32 = self.line_offsets.items[self.cursor.row] + self.cursor.col;
    // std.debug.print("ins: {} {} {}\n", .{insidx, self.head_end, (self.head_end + self.gap.len)});
    if (insidx > self.head_end and insidx <= self.head_end + self.gap.len) {
      // insertion within gap
      const gap_relidx = insidx - self.head_end;
      // std.debug.print("ins gap: {}\n", .{gap_relidx});
      if (gap_relidx == self.gap.len) {
        try self.gap.append(char);
      } else {
        try self.gap.insert(gap_relidx, char);
      }
      if (self.gap.len == GAP_SIZE) {
        try self.flushGapBuffer(E);
      }
    } else {
      // insertion outside of gap
      try self.flushGapBuffer(E);
      // std.debug.print("ins out of gap: {s}\n", .{self.buffer.items});
      self.head_end = insidx;
      self.tail_start = insidx;
      try self.gap.append(char);
    }
    if (char == '\n') {
      self.incrementLineOffsets(self.cursor.row);
      try self.line_offsets.insert(E.allocr(), self.cursor.row + 1, insidx + 1);
      self.calcLineDigits();
      // std.debug.print("{any} {any}", .{self.gap.slice(), self.line_offsets.items});
      
      self.cursor.row += 1;
      self.cursor.col = 0;
      if ((self.scroll.row + self.cursor.row) > E.getTextHeight()) {
        self.scroll.row += 1;
      }
      E.needs_redraw = true;
    } else {
      self.incrementLineOffsets(self.cursor.row);
      E.needs_redraw = true;
      self.goRight(E);
    }
  }
  
  // deletion
  
  fn decrementLineOffsets(self: *TextHandler, fromRow: u32) void {
    for (self.line_offsets.items[(fromRow + 1)..]) |*rowptr| {
      rowptr.* -= 1;
    }
  }
  
  fn deleteChar(self: *TextHandler, E: *Editor) !void {
    var delidx: u32 = self.line_offsets.items[self.cursor.row] + self.cursor.col;
    if (delidx == 0) {
      return;
    }
    delidx -= 1;
    
    const logical_tail_start = self.head_end + self.gap.len;
    // std.debug.print("{}/h{}/t{}\n",.{delidx, self.head_end,logical_tail_start});

    var deletedChar: ?u8 = null;
    if (delidx < self.head_end) {
      if (delidx == (self.head_end - 1)) {
        // deletion exactly before gap
        deletedChar = self.buffer.items[self.head_end - 1];
        self.head_end -= 1;
      } else {
        // deletion before gap
        const dest: []u8 = self.buffer.items[delidx..(self.head_end-1)];
        const src: []const u8 = self.buffer.items[(delidx+1)..self.head_end];
        deletedChar = self.buffer.items[delidx];
        std.mem.copyForwards(u8, dest, src);
        self.head_end -= 1;
      }
    } else if (delidx >= logical_tail_start) {
      const real_tailidx = self.tail_start + (delidx - logical_tail_start);
      if (delidx == logical_tail_start) {
        // deletion one char after gap
        deletedChar = self.buffer.items[real_tailidx];
        self.tail_start += 1;
      } else {
        // deletion after gap
        deletedChar = self.buffer.orderedRemove(real_tailidx);
      }
    } else {
      // deletion within gap
      const gap_relidx = delidx - self.head_end;
      deletedChar = self.gap.orderedRemove(gap_relidx);
    }
    
    if (self.cursor.col == 0) {
      std.debug.assert(deletedChar == '\n');
      const deletedrowidx = self.cursor.row;
      self.cursor.row -= 1;
      self.goTail(E);
      self.decrementLineOffsets(deletedrowidx);
      _ = self.line_offsets.orderedRemove(deletedrowidx);
    } else {
      self.decrementLineOffsets(self.cursor.row);
      self.goLeft(E);
    }

    E.needs_redraw = true;
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
          self.cmd_data = CommandData {
            .prompt = "Open file:",
            .onInputted = Commands.Open.onInputted,
          };
          self.setState(State.command);
        }
        else if (keysym.ctrl_key and keysym.key == 'g') {
          self.cmd_data = CommandData {
            .prompt = "Go to line (first = ^g, last = ^G):",
            .onInputted = Commands.GotoLine.onInputted,
            .onKey = Commands.GotoLine.onKey,
          };
          self.setState(State.command);
        }
        else if (keysym.raw == Keysym.BACKSPACE) {
          try self.text_handler.deleteChar(self);
        }
        else if (keysym.raw == Keysym.NEWLINE) {
          try self.text_handler.insertChar(self, '\n');
        }
        else if (keysym.isPrint()) {
          try self.text_handler.insertChar(self, keysym.key);
        }
      }
      
      fn handleOutput(self: *Editor) !void {
        if (self.needs_redraw) {
          try self.refreshScreen();
          try self.renderText();
          self.needs_redraw = false;
        }
        if (self.needs_update_cursor) {
          try self.renderStatus();
          try self.updateCursorPos();
          self.needs_update_cursor = false;
        }
      }
    };
    const Text: StateHandler = _createStateHandler(TextImpl);
    
    const CommandImpl = struct {
      fn handleInput(self: *Editor, keysym: Keysym) !void {
        var cmd_data: *Editor.CommandData = &self.cmd_data.?;
        if (keysym.raw == Keysym.ESC) {
          self.setState(.text);
        }
        
        if (cmd_data.onKey) |onKey| {
          if (try onKey(self, keysym)) {
            return;
          }
        }
        
        if (keysym.raw == Keysym.BACKSPACE) {
          _ = cmd_data.cmdinp.popOrNull();
          self.needs_update_cursor = true;
        }
        else if (keysym.raw == Keysym.NEWLINE) {
          try cmd_data.onInputted(self);
        }
        else if (keysym.isPrint()) {
          try cmd_data.cmdinp.append(self.allocr(), keysym.key);
          if (cmd_data.promptoverlay != null) {
            cmd_data.promptoverlay = null;
          }
          self.needs_update_cursor = true;
        }
      }
      
      fn renderStatus(self: *Editor) !void {
        try self.moveCursor(TextPos {.row = self.getTextHeight(), .col = 0});
        try self.writeAll(Editor.CLEAR_LINE);
        const cmd_data: *const Editor.CommandData = &self.cmd_data.?;
        if (cmd_data.promptoverlay) |promptoverlay| {
          try self.writeAll(promptoverlay);
        } else if (cmd_data.prompt) |prompt| {
          try self.writeAll(prompt);
        }
        try self.moveCursor(TextPos {.row = (self.getTextHeight() + 1), .col = 0});
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
    
    const List = [_]*const StateHandler{
      &Text,
      &Command,
      &Text, // quit
    };
  };
  
  const CommandData = struct {
    prompt: ?[]const u8 = null,
    promptoverlay: ?[]const u8 = null,
    cmdinp: String = .{},
    onInputted: *const fn (self: *Editor) anyerror!void,
    
    /// Handle key, returns false if no key is handled
    onKey: ?*const fn (self: *Editor, keysym: Keysym) anyerror!bool = null,
    
    fn deinit(self: *CommandData, E: *Editor) void {
      self.cmdinp.deinit(E.allocr());
    }
  };
  
  // commands
  const Commands = struct {
    const Open = struct {
      fn onInputted(self: *Editor) !void {
        self.needs_update_cursor = true;
        const cwd = std.fs.cwd();
        var cmd_data: *Editor.CommandData = &self.cmd_data.?;
        const path: []const u8 = cmd_data.cmdinp.items;
        var opened_file: ?std.fs.File = null;
        cwd.access(path, .{}) catch |err| switch(err) {
          error.FileNotFound => {
            opened_file = cwd.createFile(path, .{
              .read = true,
              .truncate = false
            }) catch |create_err| {
              std.debug.print("create file: {}", .{create_err});
              cmd_data.promptoverlay = "Unable to create new file!";
              return;
            };
          },
          else => {
            std.debug.print("access: {}", .{err});
            cmd_data.promptoverlay = "Unable to open file!";
            return;
          },
        };
        if (opened_file == null) {
          opened_file = cwd.openFile(path, .{
            .mode = .read_write,
            .lock = .shared,
          }) catch |err| {
            std.debug.print("w: {}", .{err});
            cmd_data.promptoverlay = "Unable to open file!";
            return;
          };
        }
        try self.text_handler.open(self, opened_file.?);
        self.setState(State.text);
        self.needs_redraw = true;
      }
    };
    
    const GotoLine = struct {
      fn onInputted(self: *Editor) !void {
        self.needs_update_cursor = true;
        var text_handler: *TextHandler = &self.text_handler;
        var cmd_data: *Editor.CommandData = &self.cmd_data.?;
        const line: u32 = std.fmt.parseInt(u32, cmd_data.cmdinp.items, 10) catch {
          cmd_data.promptoverlay = "Invalid integer!";
          return;
        };
        if (line == 0) {
          cmd_data.promptoverlay = "Lines start at 1!";
          return;
        }
        text_handler.gotoLine(self, line - 1) catch {
          cmd_data.promptoverlay = "Out of bounds!";
          return;
        };
        self.setState(State.text);
        self.needs_redraw = true;
      }
      
      fn onKey(self: *Editor, keysym: Keysym) !bool {
        if (keysym.isPrint()) {
          if (keysym.key == 'g') {
            try self.text_handler.gotoLine(self, 0);
            self.setState(State.text);
            self.needs_redraw = true;
            return true;
          } else if (keysym.key == 'G') {
            try self.text_handler.gotoLine(
              self,
              @intCast(self.text_handler.getNoLines() - 1)
            );
            self.setState(State.text);
            self.needs_redraw = true;
            return true;
          }
        }
        return false;
      }
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
  
  alloc_gpa: std.heap.GeneralPurposeAllocator(.{}),
  
  w_width: u32,
  w_height: u32,
  buffered_byte: u8,
  
  text_handler: TextHandler,
  
  cmd_data: ?CommandData,
  
  fn init() !Editor {
    const stdin: std.fs.File = std.io.getStdIn();
    const stdout: std.fs.File = std.io.getStdOut();
    var alloc_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const text_handler: TextHandler = try TextHandler.init(alloc_gpa.allocator());
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
      .cmd_data = null,
    };
  }
  
  fn allocr(self: *Editor) std.mem.Allocator {
    return self.alloc_gpa.allocator();
  }
  
  fn setState(self: *Editor, state: State) void {
    if (state != State.command) {
      if (self.cmd_data != null) {
        self.cmd_data.?.deinit(self);
        self.cmd_data = null;
      }
    } else {
      std.debug.assert(self.cmd_data != null);
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
      _ = byte;
      // std.debug.print("[{}]", .{byte});
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
              _ = byte1;
              // std.debug.print("[{}]", .{byte1});
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
    if (col > self.getTextWidth() - 1) { col = self.getTextWidth() - 1; }
    return self.writeFmt("\x1b[{d};{d}H", .{row + 1, col + 1});
  }
  
  fn updateCursorPos(self: *Editor) !void {
    const text_handler: *TextHandler = &self.text_handler;
    try self.moveCursor(TextPos {
      .row = text_handler.cursor.row - text_handler.scroll.row,
      .col = (text_handler.cursor.col - text_handler.scroll.col) + text_handler.line_digits + 1,
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
  
  fn getTextWidth(self: *Editor) u32 {
    return self.w_width - self.text_handler.line_digits - 1;
  }
  
  fn getTextHeight(self: *Editor) u32 {
    return self.w_height - STATUS_BAR_HEIGHT;
  }
  
  // handle input
  
  fn handleInput(self: *Editor) !void {
    if (self.readKey()) |keysym| {
      // std.debug.print("{}\n", .{keysym});
      try self.state_handler.handleInput(self, keysym);
    }
  }
  
  // handle output
  
  fn renderText(self: *Editor) !void {
    const text_handler: *const TextHandler = &self.text_handler;
    var row: u32 = 0;
    const cursor_row: u32 = text_handler.cursor.row - text_handler.scroll.row;
    var lineno: [16]u8 = undefined;
    for (text_handler.scroll.row..text_handler.getNoLines()) |i| {
      
      const offset_start: u32 = text_handler.line_offsets.items[i];
      const offset_end: u32 = text_handler.getRowOffsetEnd(@intCast(i));
      
      const colOffset: u32 = if (row == cursor_row) text_handler.scroll.col else 0;
      var iter = text_handler.iterate(offset_start + colOffset);
      
      try self.moveCursor(TextPos {.row = row, .col = 0});
      
      const lineno_slice = try std.fmt.bufPrint(&lineno, "{d}", .{i+1});
      for(0..(self.text_handler.line_digits - lineno_slice.len)) |_| {
        try self.outw.writeByte(' ');
      }
      try self.writeAll(lineno_slice);
      try self.outw.writeByte(' ');
      
      var col: u32 = 0;
      while (iter.nextUntil(offset_end)) |byte| {
        if (!(try self.renderCharInLine(byte, &col))) {
          break;
        }
      }
      
      row += 1;
      if (row == self.getTextHeight()) {
        break;
      }
    }
    self.needs_update_cursor = true;
  }
  
  fn renderCharInLine(self: *Editor, byte: u8, colref: *u32) !bool {
    if (colref.* == self.getTextWidth()) {
      return false;
    }
    if (std.ascii.isControl(byte)) {
      return true;
    }
    try self.outw.writeByte(byte);
    colref.* += 1;
    return true;
  }
  
  fn renderStatus(self: *Editor) !void {
    try self.moveCursor(TextPos {.row = self.getTextHeight(), .col = 0});
    const text_handler: *const TextHandler = &self.text_handler;
    try self.writeAll(CLEAR_LINE);
    try self.writeFmt(" {}:{}", .{text_handler.cursor.row+1, text_handler.cursor.col+1});
  }
  
  fn handleOutput(self: *Editor) !void {
    try self.state_handler.handleOutput(self);
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
