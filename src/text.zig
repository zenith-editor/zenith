//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");
const builtin = @import("builtin");

const str = @import("./str.zig");
const undo = @import("./undo.zig");
const line_offsets = @import("./line_offsets.zig");

const Editor = @import("./editor.zig").Editor;

pub const TextPos = struct {
  row: u32 = 0,
  col: u32 = 0,
};

pub const TextHandler = struct {
  const GAP_SIZE = 512;
  
  pub const TextIterator = struct {
    text_handler: *const TextHandler,
    pos: u32 = 0,
    
    pub fn next(self: *TextIterator) ?u8 {
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
    
    pub fn nextUntil(self: *TextIterator, offset_end: u32) ?u8 {
      if (self.pos == offset_end) {
        return null;
      }
      return self.next();
    }
  };
  
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
  
  /// Logical offsets to start of lines. These offsets are defined based on
  /// positions within the logical text buffer above.
  /// These offsets do contain the newline character.
  line_offsets: line_offsets.LineOffsetList,
  
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
      .line_offsets = try line_offsets.LineOffsetList.init(),
    };
  }
  
  // io
  
  pub fn open(self: *TextHandler, E: *Editor, file: std.fs.File, flush_buffer: bool) !void {
    if (self.file != null) {
      self.file.?.close();
    }
    self.file = file;
    if (flush_buffer) {
      self.cursor = TextPos {};
      self.scroll = TextPos {};
      self.buffer.clearAndFree(E.allocr());
      self.line_offsets.clear();
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
  
  pub fn iterate(self: *const TextHandler, pos: u32) TextIterator {
    return TextIterator { .text_handler = self, .pos = pos, };
  }
  
  pub fn getLogicalLen(self: *const TextHandler) u32 {
    return @intCast(self.head_end + self.gap.len + (self.buffer.items.len - self.tail_start));
  }
  
  fn calcLineDigits(self: *TextHandler) void {
    self.line_digits = std.math.log10(self.line_offsets.getLen() + 1) + 1;
  }
  
  pub fn getRowOffsetEnd(self: *const TextHandler, row: u32) u32 {
    // The newline character of the current line is not counted
    return if ((row + 1) < self.line_offsets.getLen())
      (self.line_offsets.get(row + 1) - 1)
    else
      self.getLogicalLen();
  }
  
  pub fn getRowLen(self: *const TextHandler, row: u32) u32 {
    const offset_start: u32 = self.line_offsets.get(row);
    const offset_end: u32 = self.getRowOffsetEnd(row);
    return offset_end - offset_start;
  }
  
  pub fn calcOffsetFromCursor(self: *const TextHandler) u32 {
    return self.line_offsets.get(self.cursor.row) + self.cursor.col;
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
    const rowlen: u32 = self.getRowLen(self.cursor.row);
    const oldScrollCol = self.scroll.col;
    if (rowlen == 0) {
      self.cursor.col = 0;
      self.scroll.col = 0;
    } else {
      if (self.cursor.col <= rowlen) {
        return;
      }
      self.cursor.col = rowlen;
      if (self.cursor.col > E.getTextWidth()) {
        self.scroll.col = self.cursor.col - E.getTextWidth();
      } else {
        self.scroll.col = 0;
      }
    }
    if (oldScrollCol != self.scroll.col) {
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
  
  pub fn goLeft(self: *TextHandler, E: *Editor) void {
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
  
  pub fn goRight(self: *TextHandler, E: *Editor) void {
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
  
  pub fn goHead(self: *TextHandler, E: *Editor) void {
    self.cursor.col = 0;
    if (self.scroll.col != 0) {
      E.needs_redraw = true;
    }
    self.scroll.col = 0;
    E.needs_update_cursor = true;
  }
  
  pub fn goTail(self: *TextHandler, E: *Editor) void {
    const rowlen: u32 = self.getRowLen(self.cursor.row);
    self.cursor.col = rowlen;
    self.syncColumnScroll(E);
    E.needs_redraw = true;
  }
  
  pub fn gotoLine(self: *TextHandler, E: *Editor, row: u32) !void {
    if (row >= self.line_offsets.getLen()) {
      return error.Overflow;
    }
    self.cursor.row = row;
    self.syncRowScroll(E);
    self.cursor.col = 0;
    self.scroll.col = 0;
    E.needs_redraw = true;
  }
  
  pub fn gotoPos(self: *TextHandler, E: *Editor, pos: u32) !void {
    if (pos >= self.getLogicalLen()) {
      return error.Overflow;
    }
    self.cursor.row = self.line_offsets.findMaxLineBeforeOffset(pos);
    self.cursor.col = pos - self.line_offsets.get(self.cursor.row);
    self.syncColumnScroll(E);
    self.syncRowScroll(E);
    E.needs_redraw = true;
  }
  
  pub fn syncColumnScroll(self: *TextHandler, E: *Editor) void {
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
  
  pub fn syncRowScroll(self: *TextHandler, E: *Editor) void {
    if (self.scroll.row > self.cursor.row) {
      if (E.getTextHeight() < self.cursor.row) {
        self.scroll.row = self.cursor.row - E.getTextHeight() + 1;
      } else if (self.cursor.row == 0) {
        self.scroll.row = 0;
      } else {
        self.scroll.row = self.cursor.row - 1;
      }
    } else if ((self.scroll.row + self.cursor.row) >= E.getTextHeight()) {
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
  
  pub fn insertChar(self: *TextHandler, E: *Editor, char: u8) !void {
    self.buffer_changed = true;
    
    const insidx: u32 = self.calcOffsetFromCursor();
    
    try self.undo_mgr.doAppend(insidx, 1);
    
    if (insidx > self.head_end and insidx <= self.head_end + self.gap.len) {
      // insertion within gap
      const gap_relidx = insidx - self.head_end;
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
      self.head_end = insidx;
      self.tail_start = insidx;
      try self.gap.append(char);
    }
    if (char == '\n') {
      self.line_offsets.increaseOffsets(self.cursor.row + 1, 1);
      try self.line_offsets.insert(self.cursor.row + 1, insidx + 1);
      self.calcLineDigits();
      
      self.cursor.row += 1;
      self.cursor.col = 0;
      if ((self.scroll.row + E.getTextHeight()) <= self.cursor.row) {
        self.scroll.row += 1;
      }
      self.scroll.col = 0;
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
  
  pub fn insertSlice(self: *TextHandler, E: *Editor, slice: []const u8) !void {
    self.buffer_changed = true;
    
    const insidx: u32 = self.calcOffsetFromCursor();
    try self.undo_mgr.doAppend(insidx, @intCast(slice.len));
    
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
    self.syncColumnScroll(E);
    self.syncRowScroll(E);
    E.needs_redraw = true;
  }
  
  /// Inserts slice at specified position. Used by UndoManager.
  pub fn insertSliceAtPos(self: *TextHandler, E: *Editor, insidx: u32, slice: []const u8) !void {
    self.buffer_changed = true;
    
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
    self.syncColumnScroll(E);
    self.syncRowScroll(E);
    E.needs_redraw = true;
  }
  
  // deletion
  pub fn deleteChar(self: *TextHandler, E: *Editor, deleteNextChar: bool) !void {
    self.buffer_changed = true;
    
    var delidx: u32 = self.calcOffsetFromCursor();
    
    if (deleteNextChar) {
      delidx += 1;
      if (delidx > self.getLogicalLen()) {
        return;
      }
    }
    if (delidx == 0) {
      return;
    }
    delidx -= 1;
    
    const logical_tail_start = self.head_end + self.gap.len;

    var deletedChar: u8 = undefined;
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
    
    try self.undo_mgr.doDelete(delidx, &[1]u8{deletedChar});
    
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
        self.line_offsets.decreaseOffsets(self.cursor.row + 1, 1);
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
        self.line_offsets.decreaseOffsets(self.cursor.row + 1, 1);
        self.goLeft(E);
      }
    }

    E.needs_redraw = true;
  }
  
  /// Delete region at specified position. Used by UndoManager.
  pub fn deleteRegionAtPos(
    self: *TextHandler,
    E: *Editor,
    delete_start: u32, delete_end: u32,
    record_as_undo: bool,
  ) !void {
    self.buffer_changed = true;
    
    // assume that the gap buffer is flushed to make it easier
    // for us to delete the region
    try self.flushGapBuffer(E);
    
    if (record_as_undo) {
      try self.undo_mgr.doDelete(delete_start, self.buffer.items[delete_start..delete_end]);
    }
    
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
    
    self.line_offsets.removeLinesInRange(delete_start, delete_end);
    
    const first_row_after_delete: u32 = self.line_offsets.findMinLineAfterOffset(delete_start);
    
    self.cursor.row = first_row_after_delete - 1;
    self.cursor.col = delete_start - self.line_offsets.get(self.cursor.row);
    
    E.needs_redraw = true;
  }
  
  pub fn deleteMarked(self: *TextHandler, E: *Editor) !void {
    if (self.markers) |markers| {
      try self.deleteRegionAtPos(E, markers.start, markers.end, true);
      
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
  
  // clipboard
  
  pub fn copy(self: *TextHandler, E: *Editor) !void {
    if (self.markers) |*markers| {
      try self.flushGapBuffer(E);
      
      const n_copied = markers.end - markers.start;
      try self.clipboard.resize(E.allocr(), n_copied);
      @memcpy(self.clipboard.items, self.buffer.items[markers.start..markers.end]);
    }
  }
  
  pub fn paste(self: *TextHandler, E: *Editor) !void {
    if (self.clipboard.items.len > 0) {
      try self.insertSlice(E, self.clipboard.items);
    }
  }

};
