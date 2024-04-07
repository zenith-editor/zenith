const std = @import("std");
const builtin = @import("builtin");

// types
const String = std.ArrayListUnmanaged(u8);

// keyboard event

const Keysym = struct {
  const Key = union(enum) {
    normal: u8,
    // special keys
    up,
    down,
    left,
    right,
    home,
    end,
    del,
  };
  
  raw: u8,
  key: Key,
  ctrl_key: bool = false,
  
  const ESC: u8 = std.ascii.control_code.esc;
  const BACKSPACE: u8 = std.ascii.control_code.del;
  const NEWLINE: u8 = std.ascii.control_code.cr;
  
  fn init(raw: u8) Keysym {
    if (raw < std.ascii.control_code.us) {
      return Keysym {
        .raw = raw,
        .key = .{ .normal = (raw | 0b1100000), },
        .ctrl_key = true,
      };
    } else {
      return Keysym {
        .raw = raw,
        .key = .{ .normal = raw, },
      };
    }
  }
  
  fn initSpecial(comptime key: Key) Keysym {
    switch(key) {
      .normal => { @compileError("initSpecial requires special key"); },
      else => {
        return Keysym {
          .raw = 0,
          .key = key,
        };
      },
      
    }
  }
  
  fn isSpecial(self: Keysym) bool {
    if (self.ctrl_key)
      return true;
    return switch(self.key) {
      .normal => false,
      else => true,
    };
  }
  
  fn getPrint(self: Keysym) ?u8 {
    if (!self.isSpecial() and std.ascii.isPrint(self.raw)) {
      return switch(self.key) {
        .normal => |c| c,
        else => null,
      };
    } else {
      return null;
    }
  }
  
  fn isChar(self: Keysym, char: u8) bool {
    return switch(self.key) {
      .normal => |c| c == char,
      else => false,
    };
  }
};

// undo+redo
const UndoManager = struct {
  const Action = union(enum) {
    const Append = struct {
      pos: u32,
      len: u32,
    };
    
    const Delete = struct {
      pos: u32,
      orig_buffer: String,
      
      fn deinit(self: *Delete, E: *Editor) void {
        self.orig_buffer.deinit(E.allocr());
      }
    };
    
    append: Append,
    delete: Delete,
  };
  
  stack: std.ArrayListUnmanaged(Action) = .{},
  
  // actions
  
  fn do_append(self: *UndoManager, E: *Editor, pos: u32, len: u32) !void {
    // defer std.debug.print("{}\n", .{self.stack});
    if (self.stack.items.len > 0) {
      switch (self.stack.items[self.stack.items.len - 1]) {
        Action.append => |*append| {
          if (append.pos + append.len == pos) {
            append.len += len;
            return;
          }
        },
        else => {},
      }
    }
    try self.stack.append(E.allocr(), .{
      .append = Action.Append {
        .pos = pos,
        .len = len,
      },
    });
  }
  
  fn do_delete(self: *UndoManager, E: *Editor, pos: u32, len: u32) !void {
    // defer std.debug.print("{}\n", .{self.stack});
    if (self.stack.items.len > 0) {
      switch (self.stack.items[self.stack.items.len - 1]) {
        .delete => |*delete| {
          if (delete.pos + delete.orig_buffer.items.len == pos) {
            try delete.orig_buffer.appendSlice(
              E.allocr(),
              E.text_handler.buffer.items[pos..(pos + len)],
            );
            return;
          } else if (pos + len == delete.pos) {
            delete.pos = pos;
            try delete.orig_buffer.insertSlice(
              E.allocr(), 0,
              E.text_handler.buffer.items[pos..(pos + len)],
            );
            return;
          }
        },
        else => {},
      }
    }
    var orig_buffer: String = .{};
    try orig_buffer.appendSlice(
      E.allocr(),
      E.text_handler.buffer.items[pos..(pos + len)],
    );
    try self.stack.append(E.allocr(), .{
      .delete = Action.Delete {
        .pos = pos,
        .orig_buffer = orig_buffer,
      },
    });
  }
  
  // undo
  
  fn undo(self: *UndoManager, E: *Editor) !void {
    if (self.stack.items.len > 0) {
      var act = self.stack.pop();
      switch (act) {
        .append => |*append| {
          try E.text_handler.deleteRegionAtPos(E, append.pos, append.pos + append.len);
        },
        .delete => |*delete| {
          defer delete.deinit(E);
          try E.text_handler.insertSliceAtPos(E, delete.pos, delete.orig_buffer.items);
        },
      }
      // act is deinit
    }
  }
  
};

// line offsets

const LineOffsetList = struct {
  const _Utils = struct {
    fn lower_u32(context: void, lhs: u32, rhs: u32) bool {
      _ = context;
      return lhs < rhs;
    }
  };
  
  buf: std.ArrayListUnmanaged(u32),
  alloc_gpa: std.heap.GeneralPurposeAllocator(.{}),
  
  fn init() !LineOffsetList {
    // TODO custom page-based allocator
    var alloc_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    var buf = try std.ArrayListUnmanaged(u32).initCapacity(alloc_gpa.allocator(), 1);
    try buf.append(alloc_gpa.allocator(), 0);
    return LineOffsetList {
      .buf = buf,
      .alloc_gpa = alloc_gpa,
    };
  }

  fn allocr(self: *LineOffsetList) std.mem.Allocator {
    return self.alloc_gpa.allocator();
  }
  
  fn getLen(self: *const LineOffsetList) u32 {
    return @intCast(self.buf.items.len);
  }
  
  fn get(self: *const LineOffsetList, idx: u32) u32 {
    return self.buf.items[idx];
  }
  
  fn clear(self: *LineOffsetList) void {
    self.buf.clearRetainingCapacity();
  }
  
  fn orderedRemove(self: *LineOffsetList, idx: u32) u32 {
    return self.buf.orderedRemove(idx);
  }
  
  fn shrinkRetainingCapacity(self: *LineOffsetList, len: u32) void {
    self.buf.shrinkRetainingCapacity(len);
  }
  
  fn append(self: *LineOffsetList, offset: u32) !void {
    try self.buf.append(self.allocr(), offset);
  }
  
  fn insert(self: *LineOffsetList, idx: u32, offset: u32) !void {
    try self.buf.insert(self.allocr(), idx, offset);
  }
  
  fn insertSlice(self: *LineOffsetList, idx: u32, slice: []const u32) !void {
    try self.buf.insertSlice(self.allocr(), idx, slice);
  }
  
  fn increaseOffsets(self: *LineOffsetList, from: u32, delta: u32) void {
    for (self.buf.items[from..]) |*offset| {
       offset.* += delta;
    }
  }
  
  fn decreaseOffsets(self: *LineOffsetList, from: u32, delta: u32) void {
    for (self.buf.items[from..]) |*offset| {
       offset.* -= delta;
    }
  }
  
  fn findMaxLineBeforeOffset(self: *const LineOffsetList, offset: u32) u32 {
    const idx = std.sort.lowerBound(
      u32,
      offset,
      self.buf.items,
      {},
      _Utils.lower_u32,
    );
    if (idx >= self.buf.items.len) {
      return @intCast(idx);
    }
    if (self.buf.items[idx] > offset) {
      return @intCast(idx - 1);
    }
    return @intCast(idx);
  }
  
  fn findMinLineAfterOffset(self: *const LineOffsetList, offset: u32) u32 {
    return @intCast(std.sort.upperBound(
      u32,
      offset,
      self.buf.items,
      {},
      _Utils.lower_u32,
    ));
  }
  
  fn removeLinesInRange(
    self: *LineOffsetList,
    delete_start: u32, delete_end: u32, line_start: u32, line_end: u32
  ) void {
    const n_deleted = delete_end - delete_start;
    
    // deleted region must lie between lines [line_start, line_end]
    var opt_line_pivot_dest: ?u32 = null;
    var opt_line_pivot_src: ?u32 = null;
    for (self.buf.items[line_start..line_end], line_start..) |*line_offset, line| {
      if (line_offset.* == delete_start) {
        opt_line_pivot_dest = @intCast(line);
        break;
      } else if (line_offset.* < delete_start) {
        opt_line_pivot_dest = @intCast(line + 1);
        break;
      }
    }
    for (self.buf.items[line_end..], line_end..) |*line_offset, line| {
      if (line_offset.* >= delete_end) {
        if (opt_line_pivot_src == null) {
          opt_line_pivot_src = @intCast(line);
        }
        line_offset.* -= n_deleted;
      }
    }
    // std.debug.print("{?} {?}\n", .{opt_line_pivot_dest, opt_line_pivot_src});
    
    if (opt_line_pivot_dest != null and opt_line_pivot_src != null) {
      // moved region is within the text
      const line_pivot_dest = opt_line_pivot_dest.?;
      const line_pivot_src = opt_line_pivot_src.?;
      if (line_pivot_dest < line_pivot_src) {
        const new_len = self.buf.items.len - (line_pivot_src - line_pivot_dest);
        std.mem.copyForwards(
          u32,
          self.buf.items[line_pivot_dest..new_len],
          self.buf.items[line_pivot_src..]
        );
        self.buf.shrinkRetainingCapacity(new_len);
        // std.debug.print("{}\n", .{self.buf});
      }
    }
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
  
  const Markers = struct {
    /// Logical position of starting marker
    start: u32,
    /// Logical position of ending marker
    end: u32,
    /// Cursor at starting marker
    start_cur: TextPos,
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
  /// These offsets do contain the newline character.
  line_offsets: LineOffsetList,
  
  /// Maximum number of digits needed to print line position (starting from 1)
  line_digits: u32 = 1,
  
  cursor: TextPos = .{},
  scroll: TextPos = .{},
  
  markers: ?Markers = null,
  
  clipboard: String = .{},
  
  undo_mgr: UndoManager = .{},
  
  fn init() !TextHandler {
    return TextHandler {
      .line_offsets = try LineOffsetList.init(),
    };
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
    self.line_offsets.clear();
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
    try self.line_offsets.append(0);
    var i: u32 = 0;
    for (self.buffer.items) |byte| {
      if (byte == '\n') {
        try self.line_offsets.append(i + 1);
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
  
  fn calcLineDigits(self: *TextHandler) void {
    self.line_digits = std.math.log10(self.line_offsets.getLen() + 1) + 1;
  }
  
  fn getRowOffsetEnd(self: *const TextHandler, row: u32) u32 {
    // The newline character of the current line is not counted
    return if ((row + 1) < self.line_offsets.getLen())
      (self.line_offsets.get(row + 1) - 1)
    else
      self.getLogicalLength();
  }
  
  fn getRowLen(self: *const TextHandler, row: u32) u32 {
    const offset_start: u32 = self.line_offsets.get(row);
    const offset_end: u32 = self.getRowOffsetEnd(row);
    return offset_end - offset_start;
  }
  
  fn calcOffsetFromCursor(self: *const TextHandler) u32 {
    return self.line_offsets.get(self.cursor.row) + self.cursor.col;
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
    self.head_end = 0;
    self.tail_start = 0;
    self.gap = .{};
  } 
  
  // cursor
  
  fn syncColumnAfterCursor(self: *TextHandler, E: *Editor) void {
    const rowlen: u32 = self.getRowLen(self.cursor.row);
    if (rowlen == 0) {
      self.cursor.col = 0;
    } else {
      if (self.cursor.col <= rowlen) {
        return;
      }
      self.cursor.col = rowlen;
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
    if (self.cursor.row == self.line_offsets.getLen() - 1) {
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
    if ((self.scroll.col + E.getTextWidth()) <= self.cursor.col) {
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
    if (row >= self.line_offsets.getLen()) {
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
  
  fn insertChar(self: *TextHandler, E: *Editor, char: u8) !void {
    const insidx: u32 = self.calcOffsetFromCursor();
    
    try self.undo_mgr.do_append(E, insidx, 1);
    
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
        self.head_end = insidx;
        self.tail_start = insidx;
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
      self.line_offsets.increaseOffsets(self.cursor.row + 1, 1);
      try self.line_offsets.insert(self.cursor.row + 1, insidx + 1);
      self.calcLineDigits();
      // std.debug.print("{any} {any}", .{self.gap.slice(), self.line_offsets.items});
      
      self.cursor.row += 1;
      self.cursor.col = 0;
      if ((self.scroll.row + E.getTextHeight()) <= self.cursor.row) {
        self.scroll.row += 1;
      }
      E.needs_redraw = true;
    } else {
      self.line_offsets.increaseOffsets(self.cursor.row + 1, 1);
      E.needs_redraw = true;
      self.goRight(E);
    }
  }
  
  fn shiftAndInsertNewLines(
    self: *TextHandler, E: *Editor,
    slice: []const u8,
    insidx: u32,
    first_row_after_insidx: u32
  ) !std.ArrayListUnmanaged(u32) {
    const allocr: std.mem.Allocator = E.allocr();
    
    if (first_row_after_insidx < self.line_offsets.getLen()) {
      self.line_offsets.increaseOffsets(first_row_after_insidx, @intCast(slice.len));
    }
    
    var newlines: std.ArrayListUnmanaged(u32) = .{};
    var absidx: u32 = insidx;
    for (slice) |byte| {
      if (byte == '\n') {
        try newlines.append(allocr, absidx + 1);
      }
      absidx += 1;
    }
    try self.buffer.insertSlice(allocr, insidx, slice);
    if (newlines.items.len > 0) {
      try self.line_offsets.insertSlice(first_row_after_insidx, newlines.items);
      self.calcLineDigits();
    }
    return newlines;
  }
  
  fn insertSlice(self: *TextHandler, E: *Editor, slice: []const u8) !void {
    const insidx: u32 = self.calcOffsetFromCursor();
    try self.undo_mgr.do_append(E, insidx, @intCast(slice.len));
    
    // assume that the gap buffer is flushed to make it easier
    // for us to insert the region
    try self.flushGapBuffer(E);
    
    const first_row_after_insidx: u32 = self.cursor.row + 1;
    var newlines = try self.shiftAndInsertNewLines(E, slice, insidx, first_row_after_insidx);
    defer newlines.deinit(E.allocr());
    
    if (newlines.items.len > 0) {
      self.cursor.row += @intCast(newlines.items.len);
      self.cursor.col = @intCast((insidx + slice.len) - newlines.items[newlines.items.len - 1]);
    } else {
      self.cursor.col += @intCast(slice.len);
    }
    E.needs_redraw = true;
  }
  
  /// Inserts slice at specified position. Used by UndoManager.
  fn insertSliceAtPos(self: *TextHandler, E: *Editor, insidx: u32, slice: []const u8) !void {
    // assume that the gap buffer is flushed to make it easier
    // for us to insert the region
    try self.flushGapBuffer(E);
    
    // counting from zero, the first row AFTER where the slice is inserted
    const first_row_after_insidx: u32 = self.line_offsets.findMinLineAfterOffset(insidx);
    var newlines = try self.shiftAndInsertNewLines(E, slice, insidx, first_row_after_insidx);
    defer newlines.deinit(E.allocr());
    
    const row_at_end_of_slice: u32 = @intCast(first_row_after_insidx - 1 + newlines.items.len);
    
    self.cursor.row = row_at_end_of_slice;
    if (newlines.items.len > 0) {
      self.cursor.col = @intCast((insidx + slice.len) - newlines.items[newlines.items.len - 1]);
    } else {
      self.cursor.col = @intCast((insidx + slice.len) - self.line_offsets.get(self.cursor.row));
    }
    E.needs_redraw = true;
  }
  
  // deletion
  fn deleteChar(self: *TextHandler, E: *Editor, deleteNextChar: bool) !void {
    var delidx: u32 = self.calcOffsetFromCursor();
    
    if (deleteNextChar) {
      delidx += 1;
      if (delidx > self.getLogicalLength()) {
        return;
      }
    }
    if (delidx == 0) {
      return;
    }
    delidx -= 1;
    try self.undo_mgr.do_delete(E, delidx, 1);
    
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
    
    if (deleteNextChar) {
      if (delidx == self.getRowOffsetEnd(self.cursor.row)) {
        // deleting next line
        if ((self.cursor.row + 1) == self.line_offsets.getLen()) {
          // do nothing if deleting last line
        } else {
          const deletedrowidx = self.cursor.row + 1;
          self.line_offsets.decreaseOffsets(deletedrowidx, 1);
          _ = self.line_offsets.orderedRemove(deletedrowidx);
        }
      } else {
        self.line_offsets.decreaseOffsets(self.cursor.row, 1);
      }
    } else {
      if (self.cursor.col == 0) {
        std.debug.assert(deletedChar == '\n');
        const deletedrowidx = self.cursor.row;
        self.cursor.row -= 1;
        self.goTail(E);
        self.line_offsets.decreaseOffsets(deletedrowidx, 1);
        _ = self.line_offsets.orderedRemove(deletedrowidx);
      } else {
        self.line_offsets.decreaseOffsets(self.cursor.row, 1);
        self.goLeft(E);
      }
    }

    E.needs_redraw = true;
  }
  
  fn cleanupLineOffsetsAfterDeletion(
    self: *TextHandler,
    delete_start: u32,
    delete_end: u32,
  ) void {
    // (estimated) line that contains the first character of the deleted region
    const line_start = self.line_offsets.findMaxLineBeforeOffset(delete_start);
    if (line_start >= self.line_offsets.getLen()) {
      // region starts in last line
      return;
    }
    
    // (estimated) line that contains the last character of the deleted region
    const line_end = self.line_offsets.findMaxLineBeforeOffset(delete_end);
    // std.debug.print("delete line: {} {}\n", .{line_start, line_end});
    // std.debug.print("{}\n", .{self.line_offsets});
    if (line_end == self.line_offsets.getLen()) {
      // region ends at last line
      self.line_offsets.shrinkRetainingCapacity(line_start + 1);
      return;
    }
    
    self.line_offsets.removeLinesInRange(delete_start, delete_end, line_start, line_end);
  }
  
  /// Delete region at specified position. Used by UndoManager.
  fn deleteRegionAtPos(self: *TextHandler, E: *Editor, delete_start: u32, delete_end: u32) !void {
    // assume that the gap buffer is flushed to make it easier
    // for us to delete the region
    try self.flushGapBuffer(E);
    
    const n_deleted = delete_end - delete_start;
    
    if (delete_end >= self.buffer.items.len) {
      const new_len = self.buffer.items.len - n_deleted;
      self.buffer.shrinkRetainingCapacity(new_len);
    } else {
      // Remove chars from buffer
      const new_len = self.buffer.items.len - n_deleted;
      std.mem.copyForwards(
        u8,
        self.buffer.items[delete_start..new_len],
        self.buffer.items[delete_end..]
      );
      self.buffer.shrinkRetainingCapacity(new_len);
    }
    
    self.cleanupLineOffsetsAfterDeletion(delete_start, delete_end);
    
    const first_row_after_delete: u32 = self.line_offsets.findMinLineAfterOffset(delete_start);
    
    self.cursor.row = first_row_after_delete - 1;
    self.cursor.col = delete_start - self.line_offsets.get(self.cursor.row);
    
    E.needs_redraw = true;
  }
  
  fn deleteMarked(self: *TextHandler, E: *Editor) !void {
    if (self.markers) |markers| {
      try self.undo_mgr.do_delete(E, markers.start, markers.end - markers.start);
      try self.deleteRegionAtPos(E, markers.start, markers.end);
      
      self.cursor = markers.start_cur;
      if (self.cursor.row >= self.line_offsets.getLen()) {
        self.cursor.row = self.line_offsets.getLen() - 1;
        self.cursor.col = self.getRowLen(self.cursor.row);
      }
      self.syncColumnScroll(E);
      self.syncRowScroll(E);
      
      self.markers = null;
    }
  }
  
  // markers
  
  fn markStart(self: *TextHandler, E: *Editor) void {
    var markidx: u32 = self.calcOffsetFromCursor();
    const logical_len = self.getLogicalLength();
    if (markidx >= logical_len) {
      markidx = logical_len;
    }
    self.markers = .{
      .start = markidx,
      .end = markidx,
      .start_cur = self.cursor,
    };
    E.needs_redraw = true;
    E.needs_update_cursor = true;
  }
  
  fn markEnd(self: *TextHandler, E: *Editor) void {
    var markidx: u32 = self.calcOffsetFromCursor();
    const logical_len = self.getLogicalLength();
    if (markidx >= logical_len) {
      markidx = logical_len;
    }
    if (self.markers) |*markers| {
      if (markidx > markers.start) {
        markers.end = markidx;
      } else {
        const end: u32 = markers.start;
        markers.* = .{
          .start = markidx,
          .end = end,
          .start_cur = self.cursor,
        };
      }
    } else {
      unreachable;
    }
    E.needs_redraw = true;
  }
  
  // clipboard
  
  fn copy(self: *TextHandler, E: *Editor) !void {
    if (self.markers) |*markers| {
      try self.flushGapBuffer(E);
      
      const n_copied = markers.end - markers.start;
      try self.clipboard.resize(E.allocr(), n_copied);
      @memcpy(self.clipboard.items, self.buffer.items[markers.start..markers.end]);
    }
  }
  
  fn paste(self: *TextHandler, E: *Editor) !void {
    if (self.clipboard.items.len > 0) {
      try self.insertSlice(E, self.clipboard.items);
    }
  }

};

// editor

const Editor = struct {
  const State = enum {
    text,
    command,
    mark,
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
        if (keysym.key == Keysym.Key.up) {
          self.text_handler.goUp(self);
        }
        else if (keysym.key == Keysym.Key.down) {
          self.text_handler.goDown(self);
        }
        else if (keysym.key == Keysym.Key.left) {
          self.text_handler.goLeft(self);
        }
        else if (keysym.key == Keysym.Key.right) {
          self.text_handler.goRight(self);
        }
        else if (keysym.key == Keysym.Key.home) {
          self.text_handler.goHead(self);
        }
        else if (keysym.key == Keysym.Key.end) {
          self.text_handler.goTail(self);
        }
        else if (keysym.ctrl_key and keysym.isChar('q')) {
          self.setState(State.quit);
        }
        else if (keysym.ctrl_key and keysym.isChar('s')) {
          try self.text_handler.save();
        }
        else if (keysym.ctrl_key and keysym.isChar('o')) {
          self.cmd_data = CommandData {
            .prompt = "Open file:",
            .onInputted = Commands.Open.onInputted,
          };
          self.setState(State.command);
        }
        else if (keysym.ctrl_key and keysym.isChar('g')) {
          self.cmd_data = CommandData {
            .prompt = "Go to line (first = ^g, last = ^G):",
            .onInputted = Commands.GotoLine.onInputted,
            .onKey = Commands.GotoLine.onKey,
          };
          self.setState(State.command);
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
        else if (keysym.raw == Keysym.BACKSPACE) {
          try self.text_handler.deleteChar(self, false);
        }
        else if (keysym.key == Keysym.Key.del) {
          try self.text_handler.deleteChar(self, true);
        }
        else if (keysym.raw == Keysym.NEWLINE) {
          try self.text_handler.insertChar(self, '\n');
        }
        else if (keysym.getPrint()) |key| {
          try self.text_handler.insertChar(self, key);
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
        try self.moveCursor(TextPos {.row = self.getTextHeight(), .col = 0});
        const text_handler: *const TextHandler = &self.text_handler;
        try self.writeAll(CLEAR_LINE);
        try self.writeFmt(" {}:{}", .{text_handler.cursor.row+1, text_handler.cursor.col+1});
      }
    };
    const Text: StateHandler = _createStateHandler(TextImpl);
    
    const CommandImpl = struct {
      fn handleInput(self: *Editor, keysym: Keysym) !void {
        var cmd_data: *Editor.CommandData = &self.cmd_data.?;
        if (keysym.raw == Keysym.ESC) {
          self.setState(.text);
          return;
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
        else if (keysym.getPrint()) |key| {
          try cmd_data.cmdinp.append(self.allocr(), key);
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
    
    const MarkImpl = struct {
      fn onSet(self: *Editor) void {
        self.text_handler.markStart(self);
      }
      
      fn resetState(self: *Editor) void {
        self.text_handler.markers = null;
        self.setState(.text);
      }
      
      fn handleInput(self: *Editor, keysym: Keysym) !void {
        if (keysym.raw == Keysym.ESC) {
          MarkImpl.resetState(self);
          return;
        }
        if (keysym.key == Keysym.Key.up) {
          self.text_handler.goUp(self);
        }
        else if (keysym.key == Keysym.Key.down) {
          self.text_handler.goDown(self);
        }
        else if (keysym.key == Keysym.Key.left) {
          self.text_handler.goLeft(self);
        }
        else if (keysym.key == Keysym.Key.right) {
          self.text_handler.goRight(self);
        }
        else if (keysym.key == Keysym.Key.home) {
          self.text_handler.goHead(self);
        }
        else if (keysym.key == Keysym.Key.end) {
          self.text_handler.goTail(self);
        }
        else if (keysym.raw == Keysym.NEWLINE) {
          if (self.text_handler.markers == null) {
            self.text_handler.markStart(self);
          } else {
            self.text_handler.markEnd(self);
          }
        }
        
        else if (keysym.key == Keysym.Key.del) {
          try self.text_handler.deleteMarked(self);
        }
        else if (keysym.raw == Keysym.BACKSPACE) {
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
        try self.moveCursor(TextPos {.row = self.getTextHeight(), .col = 0});
        try self.writeAll(CLEAR_LINE);
        try self.writeAll("Enter: mark end, Del: delete");
        var status: [32]u8 = undefined;
        const status_slice = try std.fmt.bufPrint(
          &status,
          "{d}:{d}",
          .{self.text_handler.cursor.row,self.text_handler.cursor.col}, 
        );
        try self.moveCursor(TextPos {
          .row = self.getTextHeight() + 1,
          .col = @intCast(self.w_width - status_slice.len),
        });
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
        if (keysym.getPrint()) |key| {
          if (key == 'g') {
            try self.text_handler.gotoLine(self, 0);
            self.setState(State.text);
            self.needs_redraw = true;
            return true;
          } else if (key == 'G') {
            try self.text_handler.gotoLine(
              self,
              @intCast(self.text_handler.line_offsets.getLen() - 1)
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
    const alloc_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const text_handler: TextHandler = try TextHandler.init();
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
    if (state == self._state) {
      return;
    }
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
            'A' => { return Keysym.initSpecial(.up); },
            'B' => { return Keysym.initSpecial(.down); },
            'C' => { return Keysym.initSpecial(.right); },
            'D' => { return Keysym.initSpecial(.left); },
            'F' => { return Keysym.initSpecial(.end); },
            'H' => { return Keysym.initSpecial(.home); },
            '3' => {
              switch (self.inr.readByte() catch 0) {
                '~' => { return Keysym.initSpecial(.del); },
                else => {
                  self.flushConsoleInput();
                  return null;
                },
              }
            },
            else => |byte1| {
              // unknown escape sequence, empty the buffer
              _ = byte1;
              // std.debug.print("[{}]", .{byte1});
              self.flushConsoleInput();
              return null;
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
  const COLOR_INVERT = "\x1b[7m";
  const COLOR_DEFAULT = "\x1b[0m";
  
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
    for (text_handler.scroll.row..text_handler.line_offsets.getLen()) |i| {
      const offset_start: u32 = text_handler.line_offsets.get(@intCast(i));
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
      
      if (text_handler.markers) |*markers| {
        var col: u32 = 0;
        var pos = offset_start;
        if (pos > markers.start and pos < markers.end) {
          try self.writeAll(COLOR_INVERT);
        }
        while (iter.nextUntil(offset_end)) |byte| {
          if (!(try self.renderCharInLineMarked(byte, &col, markers, pos))) {
            break;
          }
          pos += 1;
        }
        try self.writeAll(COLOR_DEFAULT);
      } else {
        var col: u32 = 0;
        while (iter.nextUntil(offset_end)) |byte| {
          if (!(try self.renderCharInLine(byte, &col))) {
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
  
  fn renderCharInLineMarked(
    self: *Editor, byte: u8, colref: *u32,
    markers: *const TextHandler.Markers,
    pos: u32,
  ) !bool {
    if (pos == markers.start) {
      try self.writeAll(COLOR_INVERT);
      return self.renderCharInLine(byte, colref);
    } else if (pos >= markers.end) {
      try self.writeAll(COLOR_DEFAULT);
      return self.renderCharInLine(byte, colref);
    } else {
      return self.renderCharInLine(byte, colref);
    }
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
