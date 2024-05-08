//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");

const str = @import("./str.zig");
const undo = @import("./undo.zig");
const conf = @import("./config.zig");
const lineinfo = @import("./lineinfo.zig");
const clipboard = @import("./clipboard.zig");

const Editor = @import("./editor.zig").Editor;

pub const Encoding = struct {
  pub fn isContByte(byte: u8) bool {
    return switch(byte) {
      0b1000_0000...0b1011_1111 => true,
      else => false,
    };
  }
  
  pub fn isMultibyte(byte: u8) bool {
    return byte >= 0x80;
  }
  
  pub fn sequenceLen(first_byte: u8) ?u3 {
    return switch (first_byte) {
      0b0000_0000...0b0111_1111 => 1,
      0b1100_0000...0b1101_1111 => 2,
      0b1110_0000...0b1110_1111 => 3,
      0b1111_0000...0b1111_0111 => 4,
      else => null,
    };
  }
  
  pub fn countChars(buf: []const u8) !usize {
    return std.unicode.utf8CountCodepoints(buf);
  }
};

pub const TextPos = struct {
  /// Row
  row: u32 = 0,
  /// Column as measured by byte offsets into the row
  col: u32 = 0,
  /// Column as measured in characters
  gfx_col: u32 = 0,
};

pub const RecordAction = enum {
  record_action,
  record_by_undo_mgr,
};

pub const TextIterator = struct {
  text_handler: *const TextHandler,
  pos: u32 = 0,
  
  pub fn nextChar(self: *TextIterator) ?[]const u8 {
    if (self.text_handler.getBytesStartingAt(self.pos)) |bytes| {
      const seqlen = Encoding.sequenceLen(bytes[0]) orelse unreachable;
      self.pos += seqlen;
      return bytes[0..seqlen];
    }
    return null;
  }
  
  pub fn nextCharUntil(self: *TextIterator, offset_end: u32) ?[]const u8 {
    if (self.pos >= offset_end) {
      return null;
    }
    return self.nextChar();
  }
};

pub const TextHandler = struct {
  const GAP_SIZE = 512;
  
  pub const Markers = struct {
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
  buffer: str.String = .{},
  
  /// Real position where the head of the text ends (excluding the last
  /// character)
  head_end: u32 = 0,
  
  /// Real position where the tail of the text starts
  tail_start: u32 = 0,
  
  /// Gap buffer
  gap: std.BoundedArray(u8, GAP_SIZE) = .{},
  
  /// Line information
  lineinfo: lineinfo.LineInfoList,
  
  /// Maximum number of digits needed to print line position (starting from 1)
  line_digits: u32 = 1,
  
  cursor: TextPos = .{},
  scroll: TextPos = .{},
  
  markers: ?Markers = null,
  
  clipboard: str.String = .{},
  
  undo_mgr: undo.UndoManager = .{},
  
  buffer_changed: bool = false,
  
  pub fn init() !TextHandler {
    return TextHandler {
      .lineinfo = try lineinfo.LineInfoList.init(),
    };
  }
  
  // io
  
  pub fn open(self: *TextHandler, E: *Editor, file: std.fs.File, flush_buffer: bool) !void {
    if (self.file != null) {
      self.file.?.close();
    }
    self.file = file;
    if (flush_buffer) {
      self.cursor = .{};
      self.scroll = .{};
      self.markers = null;
      self.buffer.clearAndFree(E.allocr());
      self.lineinfo.clear();
      self.head_end = 0;
      self.tail_start = 0;
      self.gap.resize(0) catch unreachable;
      self.undo_mgr.clear();
      self.buffer_changed = false;
      try self.readLines(E);
    }
  }
  
  pub fn save(self: *TextHandler, E: *Editor) !void {
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
    self.buffer_changed = false;
    // buffer save status is handled by status bar
    E.needs_update_cursor = true;
  }
  
  pub fn readLines(self: *TextHandler, E: *Editor) !void {
    var file: std.fs.File = self.file.?;
    const allocr: std.mem.Allocator = E.allocr();
    self.buffer = str.String.fromOwnedSlice(try file.readToEndAlloc(allocr, std.math.maxInt(u32)));
    
    // first line
    try self.lineinfo.append(0);
    
    // tail lines
    {
      var i: u32 = 0;
      for (self.buffer.items) |byte| {
        if (byte == '\n') {
          try self.lineinfo.append(i + 1);
        }
        i += 1;
      }
    }
    
    for (0..self.lineinfo.getLen()) |row| {
      const offset_start: u32 = self.lineinfo.getOffset(@intCast(row));
      const offset_end: u32 = self.getRowOffsetEnd(@intCast(row));
      for (self.buffer.items[offset_start..offset_end]) |byte| {
        if (Encoding.isMultibyte(byte)) {
          try self.lineinfo.setMultibyte(@intCast(row), true);
          break;
        }
      }
    }
    
    self.calcLineDigits(E);
  }
  
  // general manip
  
  pub fn iterate(self: *const TextHandler, pos: u32) TextIterator {
    return TextIterator { .text_handler = self, .pos = pos, };
  }
  
  pub fn getLogicalLen(self: *const TextHandler) u32 {
    return @intCast(self.head_end + self.gap.len + (self.buffer.items.len - self.tail_start));
  }
  
  fn calcLineDigits(self: *TextHandler, E: *const Editor) void {
    if (E.conf.show_line_numbers) {
      self.line_digits = std.math.log10(self.lineinfo.getLen()) + 1;
    }
  }
  
  pub fn getRowOffsetEnd(self: *const TextHandler, row: u32) u32 {
    // The newline character of the current line is not counted
    return if ((row + 1) < self.lineinfo.getLen())
      (self.lineinfo.getOffset(row + 1) - 1)
    else
      self.getLogicalLen();
  }
  
  pub fn getRowLen(self: *const TextHandler, row: u32) u32 {
    const offset_start: u32 = self.lineinfo.getOffset(row);
    const offset_end: u32 = self.getRowOffsetEnd(row);
    return offset_end - offset_start;
  }
  
  pub fn calcOffsetFromCursor(self: *const TextHandler) u32 {
    return self.lineinfo.getOffset(self.cursor.row) + self.cursor.col;
  }
  
  fn getBytesStartingAt(self: *const TextHandler, offset: u32) ?[]const u8 {
    const logical_tail_start = self.head_end + self.gap.len;
    if (offset < self.head_end) {
      return self.buffer.items[offset..];
    } else if (offset >= self.head_end and offset < logical_tail_start) {
      const gap_relidx = offset - self.head_end;
      return self.gap.slice()[gap_relidx..];
    } else {
      const real_tailidx = self.tail_start + (offset - logical_tail_start);
      if (real_tailidx >= self.buffer.items.len) {
        return null;
      }
      return self.buffer.items[real_tailidx..];
    }
  }
  
  fn getByte(self: *const TextHandler, offset: u32) ?u8 {
    if (self.getBytesStartingAt(offset)) |bytes| {
      return bytes[0];
    }
    return null;
  }
  
  fn recheckIsMultibyte(self: *TextHandler, row: u32) !void {
    const offset_start: u32 = self.lineinfo.getOffset(row);
    const offset_end: u32 = self.getRowOffsetEnd(row);
    var is_mb = false;
    var iter = self.iterate(offset_start);
    while (iter.nextCharUntil(offset_end)) |char| {
      if (char.len > 1) {
        is_mb = true;
        break;
      }
    }
    try self.lineinfo.setMultibyte(row, is_mb);
  }
  
  fn recheckIsMultibyteAfterDelete(self: *TextHandler, row: u32, deleted_char_is_mb: bool) !void {
    if (!self.lineinfo.checkIsMultibyte(row) and !deleted_char_is_mb) {
      // fast path to avoid looping through the string
      return;
    }
    return self.recheckIsMultibyte(row);
  }
  
  // gap
  
  pub fn flushGapBuffer(self: *TextHandler, E: *Editor) !void {
    if (self.tail_start > self.head_end) {
      // buffer contains deleted characters
      const deleted_chars = self.tail_start - self.head_end;
      const logical_tail_start = self.head_end + self.gap.len;
      const logical_len = self.getLogicalLen();
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
    const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
    const offset_end: u32 = self.getRowOffsetEnd(self.cursor.row);
    const rowlen: u32 = offset_end - offset_start;
    const old_gfx_col = self.cursor.gfx_col;
    const old_scroll_gfx_col = self.scroll.gfx_col;
    if (rowlen == 0) {
      self.cursor.col = 0;
      self.cursor.gfx_col = 0;
      self.scroll.col = 0;
      self.scroll.gfx_col = 0;
    } else {
      if (!self.lineinfo.checkIsMultibyte(self.cursor.row)) {
        if (old_gfx_col >= rowlen) {
          self.cursor.col = rowlen;
          self.cursor.gfx_col = rowlen;
        } else {
          self.cursor.col = old_gfx_col;
          self.cursor.gfx_col = old_gfx_col;
        }
        if (self.cursor.col > E.getTextWidth()) {
          self.scroll.col = self.cursor.col - E.getTextWidth();
        } else {
          self.scroll.col = 0;
        }
        self.scroll.gfx_col = self.scroll.col;
      } else {
        self.cursor.col = 0;
        self.cursor.gfx_col = 0;
        var iter = self.iterate(offset_start);
        while (iter.nextCharUntil(offset_end)) |char| {
          if (self.cursor.gfx_col == old_gfx_col) {
            break;
          }
          self.cursor.col += @intCast(char.len);
          self.cursor.gfx_col += 1;
        }
        self.scroll.col = 0;
        self.scroll.gfx_col = 0;
        self.syncColumnScroll(E);
      }
    }
    if (old_scroll_gfx_col != self.scroll.gfx_col) {
      E.needs_redraw = true;
    }
  }
  
  pub fn goUp(self: *TextHandler, E: *Editor) void {
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
  
  pub fn goDown(self: *TextHandler, E: *Editor) void {
    if (self.cursor.row == self.lineinfo.getLen() - 1) {
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
  
  pub fn goPgUp(self: *TextHandler, E: *Editor) void {
    if (self.cursor.row < E.getTextHeight()) {
      self.cursor.row = 0;
    } else {
      self.cursor.row -= E.getTextHeight() + 1;
    }
    self.syncColumnAfterCursor(E);
    self.syncRowScroll(E);
    E.needs_redraw = true;
    E.needs_update_cursor = true;
  }
  
  pub fn goPgDown(self: *TextHandler, E: *Editor) void {
    self.cursor.row += E.getTextHeight() + 1;
    if (self.cursor.row >= self.lineinfo.getLen()) {
      self.cursor.row = self.lineinfo.getLen() - 1;
    }
    self.syncColumnAfterCursor(E);
    self.syncRowScroll(E);
    E.needs_redraw = true;
    E.needs_update_cursor = true;
  }
  
  fn goLeftTextPos(self: *const TextHandler, pos_in: TextPos, row_start: u32) TextPos {
    var pos = pos_in;
    pos.col -= 1;
    var new_offset = row_start + pos.col;
    const start_byte = self.getByte(new_offset) orelse unreachable;
    if (Encoding.isContByte(start_byte)) {
      // prev char is multi byte
      while (new_offset > row_start) {
        const maybe_cont_byte = self.getByte(new_offset) orelse unreachable;
        if (Encoding.isContByte(maybe_cont_byte)) {
          pos.col -= 1;
          new_offset -= 1;
        } else {
          break;
        }
      }
    }
    pos.gfx_col -= 1;
    return pos;
  }
  
  pub fn goLeft(self: *TextHandler, E: *Editor) void {
    if (self.cursor.col == 0) {
      return;
    }
    const row_start: u32 = self.lineinfo.getOffset(self.cursor.row);
    self.cursor = self.goLeftTextPos(self.cursor, row_start);
    if (self.cursor.gfx_col < self.scroll.gfx_col) {
      self.scroll = self.goLeftTextPos(self.scroll, row_start);
      E.needs_redraw = true;
    }
    E.needs_update_cursor = true;
  }
  
  fn goRightTextPos(self: *const TextHandler, pos_in: TextPos, row_start: u32) TextPos {
    var pos = pos_in;
    const start_byte = self.getByte(row_start + pos.col) orelse unreachable;
    const seqlen = Encoding.sequenceLen(start_byte) orelse unreachable;
    pos.col += seqlen;
    pos.gfx_col += 1;
    return pos;
  }
  
  pub fn goRight(self: *TextHandler, E: *Editor) void {
    if (self.cursor.col >= self.getRowLen(self.cursor.row)) {
      return;
    }
    const row_start: u32 = self.lineinfo.getOffset(self.cursor.row);
    self.cursor = self.goRightTextPos(self.cursor, row_start);
    if ((self.scroll.gfx_col + E.getTextWidth()) <= self.cursor.gfx_col) {
      self.scroll = self.goRightTextPos(self.scroll, row_start);
      E.needs_redraw = true;
    }
    E.needs_update_cursor = true;
  }
  
  pub fn goHead(self: *TextHandler, E: *Editor) void {
    self.cursor.col = 0;
    self.cursor.gfx_col = 0;
    if (self.scroll.col != 0) {
      E.needs_redraw = true;
    }
    self.scroll.col = 0;
    self.scroll.gfx_col = 0;
    E.needs_update_cursor = true;
  }
  
  pub fn goTail(self: *TextHandler, E: *Editor) !void {
    const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
    const offset_end: u32 = self.getRowOffsetEnd(self.cursor.row);
    
    if (!self.lineinfo.checkIsMultibyte(self.cursor.row)) {
      const rowlen = offset_end - offset_start;
      self.cursor.col = rowlen;
      self.cursor.gfx_col = rowlen;
    } else {
      self.cursor.col = 0;
      self.cursor.gfx_col = 0;
      
      var iter = self.iterate(offset_start);
      while (iter.nextCharUntil(offset_end)) |char| {
        self.cursor.col += @intCast(char.len);
        self.cursor.gfx_col += 1;
      }
    }
    
    self.syncColumnScroll(E);
    E.needs_redraw = true;
  }
  
  pub fn gotoLine(self: *TextHandler, E: *Editor, row: u32) !void {
    if (row >= self.lineinfo.getLen()) {
      return error.Overflow;
    }
    self.cursor.row = row;
    self.syncRowScroll(E);
    self.cursor.col = 0;
    self.cursor.gfx_col = 0;
    self.scroll.col = 0;
    self.cursor.gfx_col = 0;
    E.needs_redraw = true;
  }
  
  pub fn gotoPos(self: *TextHandler, E: *Editor, pos: u32) !void {
    if (pos >= self.getLogicalLen()) {
      return error.Overflow;
    }
    self.cursor.row = self.lineinfo.findMaxLineBeforeOffset(pos);
    self.cursor.col = pos - self.lineinfo.getOffset(self.cursor.row);
    if (!self.lineinfo.checkIsMultibyte(self.cursor.row)) {
      self.cursor.gfx_col = self.cursor.col;
    } else {
      const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
      self.cursor.gfx_col = 0;
      var iter = self.iterate(offset_start);
      while (iter.nextCharUntil(pos) != null) {
        self.cursor.gfx_col += 1;
      }
    }
    self.syncColumnScroll(E);
    self.syncRowScroll(E);
    E.needs_redraw = true;
  }
  
  pub fn syncColumnScroll(self: *TextHandler, E: *Editor) void {
    if (self.scroll.gfx_col > self.cursor.gfx_col) {
      if (E.getTextWidth() < self.cursor.gfx_col) {
        self.scroll.gfx_col = self.cursor.gfx_col - E.getTextWidth() + 1;
      } else if (self.cursor.gfx_col == 0) {
        self.scroll.gfx_col = 0;
      } else {
        self.scroll.gfx_col = self.cursor.gfx_col - 1;
      }
    } else if ((self.scroll.gfx_col + self.cursor.gfx_col) > E.getTextWidth()) {
      if (E.getTextWidth() > self.cursor.gfx_col) {
        self.scroll.gfx_col = E.getTextWidth() - self.cursor.gfx_col + 1;
      } else {
        self.scroll.gfx_col = self.cursor.gfx_col - E.getTextWidth() + 1;
      }
    }
    
    if (!self.lineinfo.checkIsMultibyte(self.cursor.row)) {
      self.scroll.col = self.scroll.gfx_col;
    } else {
      self.scroll.col = 0;
      if (self.scroll.gfx_col != 0) {
        const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
        const offset_end: u32 = self.getRowOffsetEnd(self.cursor.row);
        var gfx_col: u32 = 0;
        var iter = self.iterate(offset_start);
        while (iter.nextCharUntil(offset_end)) |char| {
          if (gfx_col == self.scroll.gfx_col) {
            break;
          }
          self.scroll.col += @intCast(char.len);
          gfx_col += 1;
        }
      }
    }
  }
  
  pub fn syncRowScroll(self: *TextHandler, E: *Editor) void {
    if (self.scroll.row > self.cursor.row) {
      if (E.getTextHeight() < self.cursor.row) {
        self.scroll.row = self.cursor.row - E.getTextHeight() + 1;
      } else if (self.cursor.row == 0) {
        self.scroll.row = 0;
      } else {
        self.scroll.row = self.cursor.row - 1;
      }
    } else if ((self.cursor.row - self.scroll.row) >= E.getTextHeight()) {
      if (E.getTextHeight() > self.cursor.row) {
        self.scroll.row = E.getTextHeight() - self.cursor.row + 1;
      } else {
        self.scroll.row = self.cursor.row - E.getTextHeight() + 1;
      }
    }
  }
  
  // append
  
  pub fn insertChar(self: *TextHandler, E: *Editor, char: []const u8, advance_right_after_ins: bool) !void {
    self.buffer_changed = true;
    
    const line_is_multibyte = self.lineinfo.checkIsMultibyte(self.cursor.row);
    const insidx: u32 = self.calcOffsetFromCursor();
    
    try self.undo_mgr.doAppend(insidx, @intCast(char.len));
    
    if (insidx > self.head_end and insidx <= self.head_end + self.gap.len) {
      // insertion within gap
      if ((self.gap.len + char.len) >= self.gap.buffer.len) {
        // overflow if inserted
        try self.flushGapBuffer(E);
        self.head_end = insidx;
        self.tail_start = insidx;
        self.gap.appendSlice(char) catch unreachable;
      } else {
        const gap_relidx = insidx - self.head_end;
        if (gap_relidx == self.gap.len) {
          self.gap.appendSlice(char) catch unreachable;
        } else {
          self.gap.insertSlice(gap_relidx, char) catch unreachable;
        }
      }
    } else {
      // insertion outside of gap
      try self.flushGapBuffer(E);
      self.head_end = insidx;
      self.tail_start = insidx;
      self.gap.appendSlice(char) catch unreachable;
    }
    if (char[0] == '\n') {
      self.lineinfo.increaseOffsets(self.cursor.row + 1, 1);
      try self.lineinfo.insert(self.cursor.row + 1, insidx + 1, false);
      if (line_is_multibyte) {
        try self.recheckIsMultibyte(self.cursor.row);
        try self.recheckIsMultibyte(self.cursor.row + 1);
      }
      self.calcLineDigits(E);
      
      self.cursor.row += 1;
      self.cursor.col = 0;
      self.cursor.gfx_col = 0;
      if ((self.scroll.row + E.getTextHeight()) <= self.cursor.row) {
        self.scroll.row += 1;
      }
      self.scroll.col = 0;
      self.scroll.gfx_col = 0;
      E.needs_redraw = true;
    } else {
      if (char.len > 1) {
        try self.lineinfo.setMultibyte(self.cursor.row, true);
      }
      self.lineinfo.increaseOffsets(self.cursor.row + 1, @intCast(char.len));
      E.needs_redraw = true;
      if (advance_right_after_ins) {
        self.goRight(E);
      }
    }
  }
  
  pub fn insertCharPair(self: *TextHandler, E: *Editor,
                        char1: []const u8,
                        char2: []const u8) !void {
    try self.insertChar(E, char1, true);
    try self.insertChar(E, char2, false);
  }
  
  pub fn insertTab(self: *TextHandler, E: *Editor) !void {
    var indent: std.BoundedArray(u8, conf.MAX_TAB_SIZE) = .{};
    for (0..@intCast(E.conf.tab_size)) |_| {
      indent.append(' ') catch break;
    }
    const insidx: u32 = self.calcOffsetFromCursor();
    try self.undo_mgr.doAppend(insidx, @intCast(indent.len));
    return self.insertSliceAtPosWithHints(E, insidx, indent.slice(), true, false);
  }
  
  pub fn indentMarked(self: *TextHandler, E: *Editor) !void {
    if (self.markers == null) {
      return;
    }
    
    var markers = &self.markers.?;
    if (markers.start_cur.col != 0) {
      markers.start_cur.col = 0;
      markers.start_cur.gfx_col = 0;
      markers.start = self.lineinfo.getOffset(markers.start_cur.row);
    }
    
    if (markers.start == markers.end) {
      markers.end = self.getRowOffsetEnd(markers.start_cur.row);
    }
    
    var indented: str.String = .{};
    defer indented.deinit(E.allocr());
    for (0..@intCast(E.conf.tab_size)) |_| {
      try indented.append(E.allocr(), ' ');
    }
    
    var iter = self.iterate(self.lineinfo.getOffset(markers.start_cur.row));
    while (iter.nextCharUntil(markers.end)) |char| {
      try indented.appendSlice(E.allocr(), char);
      if (char[0] == '\n') {
        for (0..@intCast(E.conf.tab_size)) |_| {
          try indented.append(E.allocr(), ' ');
        }
      }
    }
    
    try self.replaceMarked(E, indented.items);
  }
  
  fn startsWithIndent(E: *Editor, slice: []const u8) bool {
    if (slice.len < E.conf.tab_size) {
      return false;
    }
    for (0..@intCast(E.conf.tab_size)) |i| {
      if (slice[i] != ' ') {
        return false;
      }
    }
    return true;
  }
  
  pub fn dedentMarked(self: *TextHandler, E: *Editor) !void {
    if (self.markers == null) {
      return;
    }
  
    var markers = &self.markers.?;
    
    if (markers.start_cur.col != 0) {
      markers.start_cur.col = 0;
      markers.start_cur.gfx_col = 0;
      markers.start = self.lineinfo.getOffset(markers.start_cur.row);
    }
    
    if (markers.start == markers.end) {
      markers.end = self.getRowOffsetEnd(markers.start_cur.row);
    }
    
    // TODO tab settings
    var dedented: str.String = .{};
    defer dedented.deinit(E.allocr());
    
    var iter = self.iterate(self.lineinfo.getOffset(markers.start_cur.row));
    while (iter.nextCharUntil(markers.end)) |char| {
      try dedented.appendSlice(E.allocr(), char);
    }
    
    var dest: usize = 0;
    var src: usize = 0;
    var newlen: usize = dedented.items.len;
    
    if (TextHandler.startsWithIndent(E, dedented.items)) {
      src += @intCast(E.conf.tab_size);
      newlen -= @intCast(E.conf.tab_size);
    }
    
    while (src < dedented.items.len) {
      if (dedented.items[src] == '\n' and TextHandler.startsWithIndent(E, dedented.items[(src+1)..])) {
        dedented.items[dest] = '\n';
        dest += 1;
        src += @intCast(E.conf.tab_size + 1);
        newlen -= @intCast(E.conf.tab_size);
      } else {
        dedented.items[dest] = dedented.items[src];
        dest += 1;
        src += 1;
      }
    }
    dedented.shrinkRetainingCapacity(newlen);
    
    try self.replaceMarked(E, dedented.items);
  }
  
  pub fn insertNewline(self: *TextHandler, E: *Editor) !void {
    var indent: str.String = .{};
    defer indent.deinit(E.allocr());
    
    var iter = self.iterate(self.lineinfo.getOffset(self.cursor.row));
    while (iter.nextCharUntil(self.getRowOffsetEnd(self.cursor.row))) |char| {
      if (std.mem.eql(u8, char, " ")) {
        try indent.appendSlice(E.allocr(), char);
      } else {
        break;
      }
    }
    
    try self.insertChar(E, "\n", true);
    
    if (indent.items.len > 0) {
      const insidx: u32 = self.calcOffsetFromCursor();
      try self.undo_mgr.doAppend(insidx, @intCast(indent.items.len));
      try self.insertSliceAtPosWithHints(E, insidx, indent.items, false, false);
    }
  }
  
  fn shiftAndInsertNewLines(
    self: *TextHandler, E: *Editor,
    slice: []const u8,
    insidx: u32,
    first_row_after_insidx: u32,
    is_slice_always_inline: bool,
  ) !u32 {
    const allocr: std.mem.Allocator = E.allocr();
    
    if (first_row_after_insidx < self.lineinfo.getLen()) {
      self.lineinfo.increaseOffsets(first_row_after_insidx, @intCast(slice.len));
    }
    
    var newlines: std.ArrayListUnmanaged(u32) = .{};
    defer newlines.deinit(allocr);
    
    if (!is_slice_always_inline) {
      var absidx: u32 = insidx;
      for (slice) |byte| {
        if (byte == '\n') {
          try newlines.append(allocr, absidx + 1);
        }
        absidx += 1;
      }
    }
    
    if (insidx > self.head_end and insidx <= self.head_end + self.gap.len) {
      // insertion within gap
      if ((slice.len + self.gap.len) < self.gap.buffer.len) {
        const gap_relidx = insidx - self.head_end;
        self.gap.insertSlice(gap_relidx, slice) catch unreachable;
      } else {
        // overflow if inserted
        try self.flushGapBuffer(E);
        try self.buffer.insertSlice(allocr, insidx, slice);
      }
    } else {
      try self.flushGapBuffer(E);
      try self.buffer.insertSlice(allocr, insidx, slice);
    }
    
    if (newlines.items.len > 0) {
      try self.lineinfo.insertSlice(first_row_after_insidx, newlines.items);
      self.calcLineDigits(E);
    }
    
    for ((first_row_after_insidx - 1)..(first_row_after_insidx + newlines.items.len)) |i| {
      try self.recheckIsMultibyte(@intCast(i));
    }
    return @intCast(newlines.items.len);
  }
  
  pub fn insertSlice(self: *TextHandler, E: *Editor, slice: []const u8) !void {
    const insidx: u32 = self.calcOffsetFromCursor();
    try self.undo_mgr.doAppend(insidx, @intCast(slice.len));
    return self.insertSliceAtPosWithHints(E, insidx, slice, true, false);
  }
  
  fn insertSliceAtPosWithHints(
    self: *TextHandler,
    E: *Editor,
    insidx: u32,
    slice: []const u8,
    use_cursor_line_hint: bool,
    is_slice_always_inline: bool,
  ) !void {
    self.buffer_changed = true;
    
    const first_row_after_insidx: u32 = if (use_cursor_line_hint)
      self.cursor.row + 1
    else
      self.lineinfo.findMinLineAfterOffset(insidx);
    
    const num_newlines = try self.shiftAndInsertNewLines(E, slice, insidx, first_row_after_insidx, is_slice_always_inline);
    
    const row_at_end_of_slice: u32 = @intCast(first_row_after_insidx - 1 + num_newlines);
    self.cursor.row = row_at_end_of_slice;
    
    const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
    const insidx_end: u32 = @intCast(insidx + slice.len);
    self.cursor.col = insidx_end - offset_start;
    
    if (!self.lineinfo.checkIsMultibyte(self.cursor.row)) {
      self.cursor.gfx_col = self.cursor.col;
    } else {
      self.cursor.gfx_col = 0;
      var i: u32 = offset_start;
      while (i < insidx_end) {
        const seqlen = Encoding.sequenceLen(self.buffer.items[i]);
        i += @intCast(seqlen.?);
        self.cursor.gfx_col += 1;
      }
    }
    
    self.syncColumnScroll(E);
    self.syncRowScroll(E);
    E.needs_redraw = true;
  }
  
  /// Inserts slice at specified position. Used by UndoManager.
  pub fn insertSliceAtPos(self: *TextHandler, E: *Editor, insidx: u32, slice: []const u8) !void {
    return self.insertSliceAtPosWithHints(E, insidx, slice, false, false);
  }
  
  // deletion
  pub fn deleteChar(self: *TextHandler, E: *Editor, delete_next_char: bool) !void {
    var delidx: u32 = self.calcOffsetFromCursor();
    
    if (delete_next_char and delidx == self.getLogicalLen()) {
      return;
    } else if (!delete_next_char and delidx == 0) {
      return;
    }
    
    self.buffer_changed = true;
    var deleted_char = [_]u8{0} ** 4;
    var seqlen: u32 = 0;
    
    // Delete the character and record the deleted char
    
    if (delete_next_char) {
      const bytes_starting = self.getBytesStartingAt(delidx).?;
      seqlen = @intCast(Encoding.sequenceLen(bytes_starting[0]).?);
      @memcpy(deleted_char[0..seqlen], bytes_starting[0..seqlen]);
    } else {
      delidx -= 1;
      while (true) {
        const byte = self.getByte(delidx).?;
        if (Encoding.isContByte(byte)) {
          seqlen += 1;
          delidx -= 1;
          // shift to right
          std.mem.copyBackwards(u8, deleted_char[1..], deleted_char[0..3]);
          deleted_char[0] = byte;
        } else {
          seqlen += 1;
          std.mem.copyBackwards(u8, deleted_char[1..], deleted_char[0..3]);
          deleted_char[0] = byte;
          break;
        }
      }
    }
    
    // Move the cursor to the previous char, if we are backspacing
    
    const cur_at_deleted_char = self.cursor;
    if (!delete_next_char) {
      if (self.cursor.col == 0) {
        self.cursor.row -= 1;
        try self.goTail(E);
      } else {
        self.goLeft(E);
      }
    }
    
    // Perform deletion
    
    const logical_tail_start = self.head_end + self.gap.len;

    if (delidx < self.head_end) {
      if (delidx == (self.head_end - seqlen)) {
        // deletion exactly before gap
        self.head_end -= seqlen;
      } else {
        // deletion before gap
        const dest: []u8 = self.buffer.items[delidx..(self.head_end-seqlen)];
        const src: []const u8 = self.buffer.items[(delidx+seqlen)..self.head_end];
        std.mem.copyForwards(u8, dest, src);
        self.head_end -= seqlen;
      }
    } else if (delidx >= logical_tail_start) {
      const real_tailidx = self.tail_start + (delidx - logical_tail_start);
      if (delidx == logical_tail_start) {
        // deletion one char after gap
        self.tail_start += seqlen;
      } else {
        // deletion after gap
        const newlen = self.buffer.items.len - seqlen;
        const dest: []u8 = self.buffer.items[real_tailidx..newlen];
        const src: []const u8 = self.buffer.items[(real_tailidx+seqlen)..];
        std.mem.copyForwards(u8, dest, src);
        self.buffer.shrinkRetainingCapacity(newlen);
      }
    } else {
      // deletion within gap
      const gap: []u8 = self.gap.slice();
      const newlen = gap.len - seqlen;
      const gap_relidx = delidx - self.head_end;
      const dest: []u8 = gap[gap_relidx..newlen];
      const src: []const u8 = gap[(gap_relidx+seqlen)..];
      std.mem.copyForwards(u8, dest, src);
      try self.gap.resize(newlen);
    }
    
    try self.undo_mgr.doDelete(delidx, deleted_char[0..seqlen]);
    
    // Update line offset info
    
    const deleted_char_is_mb = seqlen > 1;
    
    // checkIsMultibyte is done after decreaseOffsets
    // because if not then the bounds of the line would not be updated
    
    if (delete_next_char) {
      if (cur_at_deleted_char.row == self.lineinfo.getLen() - 1) {
        // do nothing if deleting character of last line
      } else if (cur_at_deleted_char.col == self.getRowLen(cur_at_deleted_char.row)) {
        // deleting next line
        std.debug.assert(deleted_char[0] == '\n');
        const deletedrowidx = cur_at_deleted_char.row + 1;
        if (deletedrowidx == self.lineinfo.getLen()) {
          // do nothing if deleting last line
        } else {
          self.lineinfo.decreaseOffsets(deletedrowidx, 1);
          self.lineinfo.remove(deletedrowidx);
          try self.recheckIsMultibyteAfterDelete(cur_at_deleted_char.row, deleted_char_is_mb);
        }
        self.calcLineDigits(E);
      } else {
        self.lineinfo.decreaseOffsets(cur_at_deleted_char.row + 1, seqlen);
        try self.recheckIsMultibyteAfterDelete(cur_at_deleted_char.row, deleted_char_is_mb);
      }
    } else {
      if (cur_at_deleted_char.col == 0) {
        std.debug.assert(deleted_char[0] == '\n');
        self.lineinfo.decreaseOffsets(cur_at_deleted_char.row, 1);
        self.lineinfo.remove(cur_at_deleted_char.row);
        try self.recheckIsMultibyteAfterDelete(cur_at_deleted_char.row - 1, deleted_char_is_mb);
        self.calcLineDigits(E);
      } else {
        self.lineinfo.decreaseOffsets(cur_at_deleted_char.row + 1, seqlen);
        try self.recheckIsMultibyteAfterDelete(cur_at_deleted_char.row, deleted_char_is_mb);
      }
    }

    E.needs_redraw = true;
  }
  
  /// Delete region at specified position. Used by UndoManager.
  pub fn deleteRegionAtPos(
    self: *TextHandler,
    E: *Editor,
    delete_start: u32, delete_end: u32,
    record_undoable_action: bool,
    copy_orig_slice_to_undo_heap: bool,
  ) !?[]const u8 {
    self.buffer_changed = true;
    
    const logical_tail_start = self.head_end + self.gap.len;
    
    var retval: ?[]const u8 = null;
    
    if (delete_start >= self.head_end and delete_end < logical_tail_start) {
      // deletion within gap buffer
      const gap_delete_start = delete_start - self.head_end;
      const gap_delete_end = delete_end - self.head_end;
      
      if (record_undoable_action) {
        try self.undo_mgr.doDelete(
          delete_start, self.gap.slice()[gap_delete_start..gap_delete_end]
        );
      }
      
      retval = if (copy_orig_slice_to_undo_heap)
        try self.undo_mgr.copySlice(self.gap.slice()[gap_delete_start..gap_delete_end])
      else
        null;
      
      const n_deleted = gap_delete_end - gap_delete_start;
      
      // Remove chars from gap
      const new_len = self.gap.len - n_deleted;
      std.mem.copyForwards(
        u8,
        self.gap.slice()[gap_delete_start..new_len],
        self.gap.slice()[gap_delete_end..]
      );
      try self.gap.resize(new_len);
    } else {
      // deletion outside, or between gap buffer
      
      // assume that the gap buffer is flushed to make it easier
      // for us to delete the region
      try self.flushGapBuffer(E);
      
      if (record_undoable_action) {
        try self.undo_mgr.doDelete(
          delete_start, self.buffer.items[delete_start..delete_end]
        );
      }
      
      retval = if (copy_orig_slice_to_undo_heap)
        try self.undo_mgr.copySlice(self.buffer.items[delete_start..delete_end])
      else
        null;
      
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
    }
    
    const old_no_lines = self.lineinfo.getLen();
    const removed_line_start = self.lineinfo.removeLinesInRange(delete_start, delete_end);
    
    try self.recheckIsMultibyte(removed_line_start);
    if ((removed_line_start + 1) < self.lineinfo.getLen()) {
      try self.recheckIsMultibyte(removed_line_start + 1);
    }
    
    if (old_no_lines != self.lineinfo.getLen()) {
      self.calcLineDigits(E);
    }
    
    self.cursor.row = removed_line_start;
    const row_start = self.lineinfo.getOffset(self.cursor.row);
    self.cursor.col = delete_start - row_start;
    
    if (!self.lineinfo.checkIsMultibyte(self.cursor.row)) {
      self.cursor.gfx_col = self.cursor.col;
    } else {
      self.cursor.gfx_col = 0;
      var iter = self.iterate(row_start);
      while (iter.nextCharUntil(delete_start) != null) {
        self.cursor.gfx_col += 1;
      }
    }
    
    self.syncColumnScroll(E);
    self.syncRowScroll(E);
    
    E.needs_redraw = true;
    
    return retval;
  }
  
  pub fn deleteMarked(self: *TextHandler, E: *Editor) !void {
    if (self.markers == null) {
      return;
    }
    
    const markers = self.markers.?;
    
    if (markers.start == markers.end) {
      return;
    }
    
    _ = try self.deleteRegionAtPos(E, markers.start, markers.end, true, false);
    
    self.cursor = markers.start_cur;
    if (self.cursor.row >= self.lineinfo.getLen()) {
      self.cursor.row = self.lineinfo.getLen() - 1;
      try self.goTail(E);
      self.syncRowScroll(E);
    } else {
      self.syncColumnScroll(E);
      self.syncRowScroll(E);
    }
    
    self.markers = null;
  }
  
  /// Replacement
  pub fn replaceRegion(
    self: *TextHandler,
    E: *Editor,
    replace_start: u32, replace_end: u32,
    new_buffer: []const u8,
    record_undoable_action: bool,
  ) !void {
    if (replace_start == replace_end) {
      if (record_undoable_action) {
        try self.undo_mgr.doAppend(replace_start, @intCast(new_buffer.len));
      }
      return self.insertSliceAtPos(
        E,
        replace_start,
        new_buffer,
      );
    }
  
    try self.flushGapBuffer(E);
    
    // TODO: replace within gap buffer
    
    if (record_undoable_action) {
      try self.undo_mgr.doReplace(
        replace_start,
        self.buffer.items[replace_start..replace_end],
        new_buffer,
      );
    }
    
    const old_buffer_len = replace_end - replace_start;
    
    try self.buffer.replaceRange(
      E.allocr(),
      replace_start,
      old_buffer_len,
      new_buffer,
    );
    
    var newlines: std.ArrayListUnmanaged(u32) = .{};
    defer newlines.deinit(E.allocr());
    
    for (new_buffer,0..new_buffer.len) |item, idx| {
      if (item == '\n') {
        try newlines.append(E.allocr(), @intCast(replace_start + idx + 1));
      }
    }
    
    // TODO: this is a very inefficient way to handle multi-line replacements
    // which needs a rewrite
    const replace_line_start = self.lineinfo.removeLinesInRange(replace_start, replace_end);
    
    const row_at_end_of_slice: u32 = @intCast(replace_line_start + 1 + newlines.items.len);
      
    try self.lineinfo.insertSlice(replace_line_start + 1, newlines.items);
    self.lineinfo.increaseOffsets(row_at_end_of_slice, @intCast(new_buffer.len));
    self.calcLineDigits(E);
    
    for (replace_line_start..row_at_end_of_slice) |i| {
      try self.recheckIsMultibyte(@intCast(i));
    }
    
    self.cursor.row = row_at_end_of_slice - 1;
    
    const new_replace_end: u32 = @intCast(replace_start + new_buffer.len);
    self.cursor.col = 0;
    self.cursor.gfx_col = 0;
    var iter = self.iterate(self.lineinfo.getOffset(self.cursor.row));
    while (iter.nextCharUntil(new_replace_end)) |char| {
      self.cursor.col += @intCast(char.len);
      self.cursor.gfx_col += 1;
    }
    
    self.syncColumnScroll(E);
    self.syncRowScroll(E);
    
    E.needs_redraw = true;
  }
  
  pub fn replaceMarked(
    self: *TextHandler,
    E: *Editor,
    new_buffer: []const u8
  ) !void {
    var markers = &self.markers.?;
    const new_end: u32 = @intCast(markers.start + new_buffer.len);
    try self.replaceRegion(E, markers.start, markers.end, new_buffer, true);
    markers.end = new_end;
  }
  
  pub fn replaceAllMarked(
    self: *TextHandler,
    E: *Editor,
    needle: []const u8,
    replacement: []const u8
  ) !void {
    var markers = &self.markers.?;
    var replaced: str.String = .{};
    defer replaced.deinit(E.allocr());
    
    // TODO: replace all within gap buffer
    try self.flushGapBuffer(E);
    
    const src_text = self.buffer.items[markers.start..markers.end];
    
    var slide: usize = 0;
    var replacements: usize = 0;
    while (slide < src_text.len) {
      if (std.mem.startsWith(u8, src_text[slide..], needle)) {
        try replaced.appendSlice(E.allocr(), replacement);
        slide += needle.len;
        replacements += 1;
      } else {
        try replaced.append(E.allocr(), src_text[slide]);
        slide += 1;
      }
    }
    
    const new_end: u32 = @intCast(markers.start + replaced.items.len);
    try self.replaceRegion(E, markers.start, markers.end, replaced.items, true);
    markers.end = new_end;
  }
  
  // markers
  
  pub fn markStart(self: *TextHandler, E: *Editor) void {
    var markidx: u32 = self.calcOffsetFromCursor();
    const logical_len = self.getLogicalLen();
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
  
  pub fn markEnd(self: *TextHandler, E: *Editor) void {
    var markidx: u32 = self.calcOffsetFromCursor();
    const logical_len = self.getLogicalLen();
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
  
  pub fn markAll(self: *TextHandler, E: *Editor) void {
    self.markers = .{
      .start = 0,
      .end = self.getLogicalLen(),
      .start_cur = .{
        .row = 0,
        .col = 0,
        .gfx_col = 0,
      },
    };
    E.needs_redraw = true;
  }
  
  pub fn markLine(self: *TextHandler, E: *Editor) void {
    self.markers = .{
      .start = self.lineinfo.getOffset(self.cursor.row),
      .end = self.getRowOffsetEnd(self.cursor.row),
      .start_cur = .{
        .row = self.cursor.row,
        .col = 0,
        .gfx_col = 0,
      },
    };
    E.needs_redraw = true;
  }
  
  // clipboard
  
  pub fn copy(self: *TextHandler, E: *Editor) !void {
    if (self.markers == null) {
      return;
    }
    const markers = self.markers.?;
    
    try self.flushGapBuffer(E);
    
    const n_copied = markers.end - markers.start;
    if (n_copied > 0) {
      if (E.conf.use_native_clipboard) {
        if (clipboard.write(
          E.allocr(),
          self.buffer.items[markers.start..markers.end]
        )) |_| {
          return;
        } else |_| {}
      }
      try self.clipboard.resize(E.allocr(), n_copied);
      @memcpy(self.clipboard.items, self.buffer.items[markers.start..markers.end]);
    }
  }
  
  pub fn paste(self: *TextHandler, E: *Editor) !void {
    if (E.conf.use_native_clipboard) {
      if (try clipboard.read(E.allocr())) |native_clip| {
        defer E.allocr().free(native_clip);
        try self.insertSlice(E, native_clip);
        return;
      }
    }
    if (self.clipboard.items.len > 0) {
      try self.insertSlice(E, self.clipboard.items);
    }
  }
  
  pub fn duplicateLine(self: *TextHandler, E: *Editor) !void {
    var line: str.String = .{};
    defer line.deinit(E.allocr());
    try line.append(E.allocr(), '\n');
    const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
    const offset_end: u32 = self.getRowOffsetEnd(self.cursor.row);
    var iter = self.iterate(offset_start);
    while (iter.nextCharUntil(offset_end)) |char| {
      try line.appendSlice(E.allocr(), char);
    }
    try self.goTail(E);
    try self.insertSlice(E, line.items);
  }

};
