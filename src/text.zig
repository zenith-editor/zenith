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
const encoding = @import("./encoding.zig");
const heap = @import("./ds/heap.zig");

const Editor = @import("./editor.zig").Editor;
const Expr = @import("./patterns.zig").Expr;
const Highlight = @import("./highlight.zig");

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
  
  pub fn nextCodepointSlice(self: *TextIterator) ?[]const u8 {
    if (self.text_handler.bytesStartingAt(self.pos)) |bytes| {
      const seqlen = encoding.sequenceLen(bytes[0]) catch unreachable;
      self.pos += seqlen;
      return bytes[0..seqlen];
    }
    return null;
  }
  
  pub fn nextCodepointSliceUntil(self: *TextIterator, offset_end: u32) ?[]const u8 {
    if (self.pos >= offset_end) {
      return null;
    }
    return self.nextCodepointSlice();
  }
  
  pub const SliceWithCurPos = struct {
    bytes: []const u8,
    pos: usize,
  };
  
  pub fn nextCodepointSliceUntilWithCurPos(self: *TextIterator, offset_end: u32) ?SliceWithCurPos {
    if (self.pos >= offset_end) {
      return null;
    }
    const cur_pos = self.pos;
    if (self.nextCodepointSlice()) |bytes| {
      return .{
        .bytes = bytes,
        .pos = cur_pos,
      };
    }
    return null;
  }
  
  pub fn prevCodepointSlice(self: *TextIterator) ?[]const u8 {
    if (self.pos == 0) {
      return null;
    }
    self.pos -= 1;
    var seqlen: usize = 1;
    while (true) {
      const bytes = self.text_handler.bytesStartingAt(self.pos).?;
      if (encoding.isContByte(bytes[0])) {
        self.pos -= 1;
        seqlen += 1;
        continue;
      }
      return bytes[0..seqlen];
    }
  }
};

pub const TextHandler = struct {
  pub const Markers = struct {
    /// Logical position of starting marker
    start: u32,
    /// Logical position of ending marker
    end: u32,
    /// Cursor at starting marker
    start_cur: TextPos,
  };
  
  const BufferAllocator = std.heap.page_allocator;
  
  file: ?std.fs.File = null,
  
  /// Allocated by E.allocr
  file_path: str.StringUnmanaged = .{},
  
  /// Buffer of characters. Logical text buffer is then:
  ///   text = buffer[0..(head_end)] ++ gap ++ buffer[tail_start..]
  buffer: str.String,
  
  /// Real position where the head of the text ends (excluding the last
  /// character)
  head_end: u32 = 0,
  
  /// Real position where the tail of the text starts
  tail_start: u32 = 0,
  
  /// Gap buffer, allocated by PageAllocator
  gap: str.String,
  
  /// Line information
  lineinfo: lineinfo.LineInfoList,
  
  /// Maximum number of digits needed to print line position (starting from 1)
  line_digits: u32 = 1,
  
  highlight: Highlight = .{},
  
  cursor: TextPos = .{},
  scroll: TextPos = .{},
  
  markers: ?Markers = null,
  
  /// Allocated by PageAllocator
  clipboard: str.String,
  
  undo_mgr: undo.UndoManager = .{},
  
  buffer_changed: bool = false,
  
  pub fn create() !TextHandler {
    return TextHandler {
      .lineinfo = try lineinfo.LineInfoList.create(),
      .buffer = str.String.init(BufferAllocator),
      .gap = .{
        // get the range 0..0 to set the length to zero
        .items = (try BufferAllocator.alloc(u8, std.mem.page_size))[0..0],
        .capacity = std.mem.page_size,
        .allocator = heap.null_allocator,
      },
      .clipboard = str.String.init(BufferAllocator),
    };
  }
  
  // events
  
  pub fn onResize(self: *TextHandler, E: *Editor) !void {
    if (E.conf.wrap_text) {
      try self.wrapText(E);
    }
  }
  
  // io
  
  pub const OpenFileArgs = struct {
    file: ?std.fs.File,
    file_path: []const u8,
  };
  
  pub fn open(self: *TextHandler, E: *Editor, args: OpenFileArgs, flush_buffer: bool) !void {
    if (args.file == null) {
      if (self.file != null) {
        self.file.?.close();
      }
      self.file_path.clearAndFree(E.allocr);
      try self.file_path.appendSlice(E.allocr, args.file_path);
      try self.highlight.loadTokenTypesForFile(self, E.allocr, &E.conf);
      return;
    }
    
    const file = args.file.?;
    const stat = try file.stat();
    const size = stat.size;
    if (size > std.math.maxInt(u32)) {
      return error.FileTooBig;
    }
    
    var new_buffer = str.String.init(BufferAllocator);
    errdefer new_buffer.deinit();
    const new_buffer_slice = try new_buffer.addManyAsSlice(size);
    _ = try file.readAll(new_buffer_slice);
    if (!std.unicode.utf8ValidateSlice(new_buffer.items)) {
      return error.InvalidUtf8;
    }
    
    if (self.file != null) {
      self.file.?.close();
    }
    self.file = file;
    
    self.file_path.clearAndFree(E.allocr);
    try self.file_path.appendSlice(E.allocr, args.file_path);
    
    if (flush_buffer) {
      self.clearBuffersForFile(E.allocr);
      self.readLines(E, new_buffer) catch |err| {
        self.clearBuffersForFile(E.allocr);
        return err;
      };
      try self.highlight.loadTokenTypesForFile(self, E.allocr, &E.conf);
      try self.highlightText(E);
    }
  }
  
  fn clearBuffersForFile(self: *TextHandler, allocr: std.mem.Allocator) void {
    self.highlight.clear(allocr);
    self.cursor = .{};
    self.scroll = .{};
    self.markers = null;
    self.buffer.clearAndFree();
    self.lineinfo.clear();
    self.head_end = 0;
    self.tail_start = 0;
    self.gap.shrinkRetainingCapacity(0);
    self.undo_mgr.clear();
    self.buffer_changed = false;
  }
  
  pub fn save(self: *TextHandler, E: *Editor) !void {
    if (self.file == null) {
      self.file = std.fs.cwd().createFile(self.file_path.items, .{
        .read = true,
        .truncate = true,
      }) catch |err| { return err; };
    }
    const file: std.fs.File = self.file.?;
    try file.seekTo(0);
    try file.setEndPos(0);
    const writer: std.fs.File.Writer = file.writer();
    try writer.writeAll(self.buffer.items[0..self.head_end]);
    try writer.writeAll(self.gap.items);
    try writer.writeAll(self.buffer.items[self.tail_start..]);
    self.buffer_changed = false;
    // buffer save status is handled by status bar
    E.needs_update_cursor = true;
  }
  
  const ReadLineError = error {
    OutOfMemory,
  };
  
  /// Read lines from new_buffer
  fn readLines(self: *TextHandler, E: *Editor, new_buffer: str.String) ReadLineError!void {
    self.buffer = new_buffer;
    
    // first line
    try self.lineinfo.append(0);
    
    // tail lines
    var is_mb = false;
    for (self.buffer.items, 0..self.buffer.items.len) |byte, offset| {
      if (encoding.isMultibyte(byte)) {
        is_mb = true;
      }
      if (byte == '\n') {
        const prev_row: u32 = self.lineinfo.getLen() - 1;
        // next line must be appended first so that the prev_row
        // has corrects bounds needed for wrapLineWithCols
        try self.lineinfo.append(@intCast(offset + 1));
        
        self.lineinfo.setMultibyte(prev_row, is_mb);
        is_mb = false;
      }
    }
    
    const last_row: u32 = self.lineinfo.getLen() - 1;
    self.lineinfo.setMultibyte(last_row, is_mb);
    
    self.calcLineDigits(E);
    
    if (E.conf.wrap_text) {
      // wrap text must be done after calcLineDigits
      try self.wrapText(E);
    }
  }
  
  // general manip
  
  pub fn iterate(self: *const TextHandler, pos: u32) TextIterator {
    return TextIterator { .text_handler = self, .pos = pos, };
  }
  
  pub fn getLogicalLen(self: *const TextHandler) u32 {
    return @intCast(self.head_end + self.gap.items.len + (self.buffer.items.len - self.tail_start));
  }
  
  fn calcLineDigits(self: *TextHandler, E: *const Editor) void {
    if (E.conf.show_line_numbers) {
      self.line_digits = std.math.log10(self.lineinfo.getMaxLineNo()) + 1;
    }
    return;
  }
  
  pub fn getRowOffsetEnd(self: *const TextHandler, row: u32) u32 {
    // The newline character of the current line is not counted
    if ((row + 1) < self.lineinfo.getLen()) {
      const offset = self.lineinfo.getOffset(row + 1);
      if (self.lineinfo.isContLine(row + 1)) {
        // cont lines do not have newlines
        return offset;
      }
      return offset - 1;
    } else {
      return self.getLogicalLen();
    }
  }
  
  pub fn getRowLen(self: *const TextHandler, row: u32) u32 {
    const offset_start: u32 = self.lineinfo.getOffset(row);
    const offset_end: u32 = self.getRowOffsetEnd(row);
    return offset_end - offset_start;
  }
  
  pub fn calcOffsetFromCursor(self: *const TextHandler) u32 {
    return self.lineinfo.getOffset(self.cursor.row) + self.cursor.col;
  }
  
  fn bytesStartingAt(self: *const TextHandler, offset: u32) ?[]const u8 {
    const logical_tail_start = self.head_end + self.gap.items.len;
    if (offset < self.head_end) {
      return self.buffer.items[offset..];
    } else if (offset >= self.head_end and offset < logical_tail_start) {
      const gap_relidx = offset - self.head_end;
      return self.gap.items[gap_relidx..];
    } else {
      const real_tailidx = self.tail_start + (offset - logical_tail_start);
      if (real_tailidx >= self.buffer.items.len) {
        return null;
      }
      return self.buffer.items[real_tailidx..];
    }
  }
  
  fn recheckIsMultibyte(self: *TextHandler, from_line: u32) !void {
    const offset_start: u32 = self.lineinfo.getOffset(from_line);
    const opt_next_real_line = self.lineinfo.findNextNonContLine(from_line);
    const offset_end: u32 = self.getRowOffsetEnd(
      if (opt_next_real_line) |next_real_line| next_real_line - 1
      else from_line
    );
    var is_mb = false;
    var iter = self.iterate(offset_start);
    while (iter.nextCodepointSliceUntil(offset_end)) |bytes| {
      if (encoding.isMultibyte(bytes[0])) {
        is_mb = true;
        break;
      }
    }
    self.lineinfo.setMultibyte(from_line, is_mb);
    
    if (opt_next_real_line) |next_real_line| {
      for ((from_line+1)..next_real_line) |line| {
        self.lineinfo.setMultibyte(@intCast(line), is_mb);
      }
    }
  }
  
  fn recheckIsMultibyteAfterDelete(self: *TextHandler, line: u32, deleted_char_is_mb: bool) !void {
    if (!self.lineinfo.checkIsMultibyte(line) and !deleted_char_is_mb) {
      // fast path to avoid looping through the string
      return;
    }
    return self.recheckIsMultibyte(line);
  }
  
  pub fn srcView(self: *const TextHandler) Expr.SrcView {
    const Funcs = struct {
      fn codepointSliceAt(ctx: *const anyopaque, pos: usize)
        error{ InvalidUtf8 }!?[]const u8 {
        const self_: *const TextHandler = @ptrCast(@alignCast(ctx));
        if (self_.bytesStartingAt(@intCast(pos))) |bytes| {
          const seqlen = encoding.sequenceLen(bytes[0]) catch unreachable;
          return bytes[0..seqlen];
        }
        return null;
      }
    };
    return .{
      .ptr = self,
      .vtable = &.{
        .codepointSliceAt = Funcs.codepointSliceAt,
      },
    };
  }
  
  // gap
  
  pub fn flushGapBuffer(self: *TextHandler) !void {
    if (self.tail_start > self.head_end) {
      // buffer contains deleted characters
      const deleted_chars = self.tail_start - self.head_end;
      const logical_tail_start = self.head_end + self.gap.items.len;
      const logical_len = self.getLogicalLen();
      if (deleted_chars > self.gap.items.len) {
        const gapdest: []u8 = self.buffer.items[self.head_end..logical_tail_start];
        @memcpy(gapdest, self.gap.items);
        const taildest: []u8 = self.buffer.items[logical_tail_start..logical_len];
        std.mem.copyForwards(u8, taildest, self.buffer.items[self.tail_start..]);
      } else {
        const reserved_chars = self.gap.items.len - deleted_chars;
        _ = try self.buffer.addManyAt(self.head_end, reserved_chars);
        const dest: []u8 = self.buffer.items[self.head_end..logical_tail_start];
        @memcpy(dest, self.gap.items);
      }
      self.buffer.shrinkRetainingCapacity(logical_len);
    } else {
      try self.buffer.insertSlice(self.head_end, self.gap.items);
    }
    self.head_end = 0;
    self.tail_start = 0;
    self.gap.shrinkRetainingCapacity(0);
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
        while (iter.nextCodepointSliceUntil(offset_end)) |bytes| {
          if (self.cursor.gfx_col == old_gfx_col) {
            break;
          }
          self.cursor.col += @intCast(bytes.len);
          self.cursor.gfx_col += encoding.countCharCols(
            std.unicode.utf8Decode(bytes) catch unreachable
          );
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
    const scroll_delta = E.getTextHeight() + 1;
    if (self.cursor.row < scroll_delta) {
      self.cursor.row = 0;
    } else {
      self.cursor.row -= scroll_delta;
    }
    self.syncColumnAfterCursor(E);
    self.syncRowScroll(E);
    E.needs_redraw = true;
    E.needs_update_cursor = true;
  }
  
  pub fn goPgDown(self: *TextHandler, E: *Editor) void {
    const scroll_delta = E.getTextHeight() + 1;
    self.cursor.row += scroll_delta;
    if (self.cursor.row >= self.lineinfo.getLen()) {
      self.cursor.row = self.lineinfo.getLen() - 1;
    }
    self.syncColumnAfterCursor(E);
    self.syncRowScroll(E);
    E.needs_redraw = true;
    E.needs_update_cursor = true;
  }
  
  fn goLeftTextPos(self: *const TextHandler,
                   pos_in: TextPos,
                   row_start: u32,
                   opt_char_under_cursor: ?*u32) TextPos {
    var iter = self.iterate(row_start + pos_in.col);
    const bytes = iter.prevCodepointSlice().?;
    
    const char = std.unicode.utf8Decode(bytes) catch unreachable;
    if (opt_char_under_cursor) |char_under_cursor| {
      char_under_cursor.* = char;
    }
    
    var pos = pos_in;
    pos.col -= @intCast(bytes.len);
    pos.gfx_col -= encoding.countCharCols(char);
    return pos;
  }
  
  pub fn goLeft(self: *TextHandler, E: *Editor) void {
    if (self.cursor.col == 0) {
      return;
    }
    const row_start: u32 = self.lineinfo.getOffset(self.cursor.row);
    self.cursor = self.goLeftTextPos(self.cursor, row_start, null);
    if (self.cursor.gfx_col < self.scroll.gfx_col) {
      self.scroll = self.goLeftTextPos(self.scroll, row_start, null);
      E.needs_redraw = true;
    }
    E.needs_update_cursor = true;
  }
  
  pub fn goLeftWord(self: *TextHandler, E: *Editor) void {
    if (self.cursor.col == 0) {
      return;
    }
    self.goLeft(E);
    const row_start: u32 = self.lineinfo.getOffset(self.cursor.row);
    while (self.cursor.col > 0) {
      var char: u32 = 0;
      const new_cursor = self.goLeftTextPos(self.cursor, row_start, &char);
      if (!encoding.isKeywordChar(char)) {
        break;
      }
      self.cursor = new_cursor;
      if (self.cursor.gfx_col < self.scroll.gfx_col) {
        self.scroll = self.goLeftTextPos(self.scroll, row_start, null);
        E.needs_redraw = true;
      }
    }
    E.needs_update_cursor = true;
  }
  
  fn goRightTextPos(self: *const TextHandler,
                    pos_in: TextPos,
                    row_start: u32,
                    opt_char_under_cursor: ?*u32) TextPos {
    var pos = pos_in;
    const bytes = self.bytesStartingAt(row_start + pos.col).?;
    const seqlen = encoding.sequenceLen(bytes[0]) catch unreachable;
    const char = std.unicode.utf8Decode(bytes[0..seqlen]) catch unreachable;
    if (opt_char_under_cursor) |char_under_cursor| {
      char_under_cursor.* = char;
    }
    pos.col += seqlen;
    pos.gfx_col += encoding.countCharCols(char);
    return pos;
  }
  
  pub fn goRight(self: *TextHandler, E: *Editor) void {
    if (self.cursor.col >= self.getRowLen(self.cursor.row)) {
      return;
    }
    const row_start: u32 = self.lineinfo.getOffset(self.cursor.row);
    self.cursor = self.goRightTextPos(self.cursor, row_start, null);
    if ((self.scroll.gfx_col + E.getTextWidth()) <= self.cursor.gfx_col) {
      self.scroll = self.goRightTextPos(self.scroll, row_start, null);
      E.needs_redraw = true;
    }
    E.needs_update_cursor = true;
  }
  
  pub fn goRightWord(self: *TextHandler, E: *Editor) void {
    const rowlen = self.getRowLen(self.cursor.row);
    if (self.cursor.col >= rowlen) {
      return;
    }
    self.goRight(E);
    const row_start: u32 = self.lineinfo.getOffset(self.cursor.row);
    while (self.cursor.col < rowlen) {
      var char: u32 = 0;
      const new_cursor = self.goRightTextPos(self.cursor, row_start, &char);
      if (!encoding.isKeywordChar(char)) {
        break;
      }
      self.cursor = new_cursor;
      if ((self.scroll.gfx_col + E.getTextWidth()) <= self.cursor.gfx_col) {
        self.scroll = self.goRightTextPos(self.scroll, row_start, null);
        E.needs_redraw = true;
      }
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
      while (iter.nextCodepointSliceUntil(offset_end)) |bytes| {
        self.cursor.col += @intCast(bytes.len);
        self.cursor.gfx_col += encoding.countCharCols(
          std.unicode.utf8Decode(bytes) catch unreachable
        );
      }
    }
    
    self.syncColumnScroll(E);
    E.needs_redraw = true;
  }
  
  pub fn goDownHead(self: *TextHandler, E: *Editor) void {
    self.cursor.row += 1;
    self.cursor.col = 0;
    self.cursor.gfx_col = 0;
    if ((self.scroll.row + E.getTextHeight()) <= self.cursor.row) {
      self.scroll.row += 1;
    }
    self.scroll.col = 0;
    self.scroll.gfx_col = 0;
    E.needs_redraw = true;
  }
  
  pub fn gotoFirstLine(self: *TextHandler, E: *Editor) void {
    self.cursor.row = 0;
    self.syncRowScroll(E);
    self.cursor.col = 0;
    self.cursor.gfx_col = 0;
    self.scroll.col = 0;
    self.scroll.gfx_col = 0;
    E.needs_redraw = true;
  }
  
  pub fn gotoLastLine(self: *TextHandler, E: *Editor) void {
    self.cursor.row = self.lineinfo.getLen();
    while(self.cursor.row > 0) {
      self.cursor.row -= 1;
      if (!self.lineinfo.isContLine(self.cursor.row)) {
        break;
      }
    }
    self.syncRowScroll(E);
    self.cursor.col = 0;
    self.cursor.gfx_col = 0;
    self.scroll.col = 0;
    self.scroll.gfx_col = 0;
    E.needs_redraw = true;
  }
  
  pub fn gotoLineNo(self: *TextHandler, E: *Editor, line: u32)
    error{Overflow}!void {
    self.cursor.row = self.lineinfo.findLineWithLineNo(line) orelse {
      return error.Overflow;
    };
    self.syncRowScroll(E);
    self.cursor.col = 0;
    self.cursor.gfx_col = 0;
    self.scroll.col = 0;
    self.scroll.gfx_col = 0;
    E.needs_redraw = true;
  }
  
  pub fn gotoPos(self: *TextHandler, E: *Editor, pos: u32) !void {
    if (pos >= self.getLogicalLen()) {
      return error.Overflow;
    }
    self.cursor.row = self.lineinfo.findMaxLineBeforeOffset(pos, 0);
    self.cursor.col = pos - self.lineinfo.getOffset(self.cursor.row);
    if (!self.lineinfo.checkIsMultibyte(self.cursor.row)) {
      self.cursor.gfx_col = self.cursor.col;
    } else {
      const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
      self.cursor.gfx_col = 0;
      var iter = self.iterate(offset_start);
      while (iter.nextCodepointSliceUntil(pos)) |char| {
        self.cursor.gfx_col += encoding.countCharCols(try std.unicode.utf8Decode(char));
      }
    }
    self.scroll.col = 0;
    self.scroll.gfx_col = 0;
    self.syncColumnScroll(E);
    self.syncRowScroll(E);
    E.needs_redraw = true;
  }
  
  pub fn syncColumnScroll(self: *TextHandler, E: *Editor) void {
    const text_width = E.getTextWidth();
    
    var target_gfx_col: u32 = self.scroll.gfx_col;
    
    if (self.lineinfo.isContLine(self.cursor.row)) {
      std.debug.assert(self.cursor.gfx_col < text_width);
      target_gfx_col = 0;
    } else if (target_gfx_col > self.cursor.gfx_col) {
      if (text_width < self.cursor.gfx_col) {
        target_gfx_col = self.cursor.gfx_col - text_width + 1;
      } else if (self.cursor.gfx_col == 0) {
        target_gfx_col = 0;
      } else {
        target_gfx_col = self.cursor.gfx_col - 1;
      }
    } else if ((target_gfx_col + self.cursor.gfx_col) > text_width) {
      // cursor is farther than horizontal edge
      if (text_width > self.cursor.gfx_col) {
        target_gfx_col = text_width - self.cursor.gfx_col + 1;
      } else {
        target_gfx_col = self.cursor.gfx_col - text_width + 1;
      }
    }
    
    if (!self.lineinfo.checkIsMultibyte(self.cursor.row)) {
      self.scroll.col = target_gfx_col;
      self.scroll.gfx_col = target_gfx_col;
    } else {
      if (target_gfx_col == 0) {
        self.scroll.col = 0;
        self.scroll.gfx_col = 0;
      } else {
        const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
        const offset_end: u32 = self.getRowOffsetEnd(self.cursor.row);
        var count_cols_from: u32 = offset_start;
        if (target_gfx_col > self.scroll.gfx_col) {
          count_cols_from += self.scroll.col;
        } else {
          count_cols_from += 0;
          self.scroll.col = 0;
          self.scroll.gfx_col = 0;
        }
        var iter = self.iterate(count_cols_from);
        while (iter.nextCodepointSliceUntil(offset_end)) |bytes| {
          const ccol = encoding.countCharCols(
            std.unicode.utf8Decode(bytes) catch unreachable
          );
          self.scroll.col += @intCast(bytes.len);
          self.scroll.gfx_col += ccol;
          if (self.scroll.gfx_col >= target_gfx_col) {
            break;
          }
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
    E.needs_redraw = true;
    
    // Perform insertion
    
    const line_is_multibyte = self.lineinfo.checkIsMultibyte(self.cursor.row);
    const insidx: u32 = self.calcOffsetFromCursor();
    
    self.undo_mgr.doAppend(insidx, @intCast(char.len)) catch |err| {
      if (err == error.OutOfMemoryUndo) {
        try self.handleUndoOOM(E);
      } else {
        return err;
      }
    };
    
    if (insidx > self.head_end and insidx <= self.head_end + self.gap.items.len) {
      // insertion within gap
      if ((self.gap.items.len + char.len) >= self.gap.capacity) {
        // overflow if inserted
        try self.flushGapBuffer();
        self.head_end = insidx;
        self.tail_start = insidx;
        self.gap.appendSliceAssumeCapacity(char);
      } else {
        const gap_relidx = insidx - self.head_end;
        if (gap_relidx == self.gap.items.len) {
          self.gap.appendSliceAssumeCapacity(char);
        } else {
          // TODO: there is no insertSliceAssumeCapacity?
          self.gap.replaceRangeAssumeCapacity(gap_relidx, 0, char);
        }
      }
    } else {
      // insertion outside of gap
      try self.flushGapBuffer();
      self.head_end = insidx;
      self.tail_start = insidx;
      self.gap.appendSliceAssumeCapacity(char);
    }
    
    // Highlighting
    
    try self.rehighlight(
      E,
      insidx, // changed_region_start_in
      @intCast(insidx + char.len), // changed_region_end
      @intCast(char.len), // shift
      true, // is_insert
      self.cursor.row // line_start
    );
    
    // Move cursor
    
    if (char[0] == '\n') {
      self.lineinfo.increaseOffsets(self.cursor.row + 1, 1);
      const line_inserted =
        try self.lineinfo.insert(self.cursor.row + 1, insidx + 1, false);
      if (line_is_multibyte) {
        try self.recheckIsMultibyte(self.cursor.row);
        try self.recheckIsMultibyte(self.cursor.row + 1);
      }
      if (line_inserted and E.conf.wrap_text) {
        try self.wrapLine(E, self.cursor.row+1);
      }
      self.goDownHead(E);
      self.calcLineDigits(E);
    } else {
      if (char.len > 1) {
        self.lineinfo.setMultibyte(self.cursor.row, true);
      }
      self.lineinfo.increaseOffsets(self.cursor.row + 1, @intCast(char.len));
      if (E.conf.wrap_text) {
        try self.wrapLine(E, self.cursor.row);
        if (
          self.cursor.col == self.getRowLen(self.cursor.row) and
          (self.cursor.row+1) < self.lineinfo.getLen() and
          self.lineinfo.isContLine(self.cursor.row+1)
        ) {
          self.goDownHead(E);
        }
        if (advance_right_after_ins) {
          self.goRight(E);
        }
      } else {
        if (advance_right_after_ins) {
          self.goRight(E);
        }
      }
    }
  }
  
  pub fn insertCharPair(self: *TextHandler, E: *Editor,
                        char1: []const u8,
                        char2: []const u8) !void {
    try self.insertChar(E, char1, true);
    try self.insertChar(E, char2, false);
  }
  
  pub fn insertCharUnlessOverwrite(
    self: *TextHandler, E: *Editor, char: []const u8
  ) !void {
    const insidx: u32 = self.calcOffsetFromCursor();
    const bytes_starting = self.bytesStartingAt(insidx) orelse {
      return self.insertChar(E, char, true);
    };
    if (std.mem.startsWith(u8, bytes_starting, char)) {
      self.goRight(E);
      return;
    }
    try self.insertChar(E, char, true);
  }
  
  pub fn insertTab(self: *TextHandler, E: *Editor) !void {
    var indent: std.BoundedArray(u8, conf.MAX_TAB_SIZE) = .{};
    if (E.conf.use_tabs) {
      indent.append('\t') catch unreachable;
    } else {
      for (0..@intCast(E.conf.tab_size)) |_| {
        indent.append(' ') catch break;
      }
    }
    const insidx: u32 = self.calcOffsetFromCursor();
    self.undo_mgr.doAppend(insidx, @intCast(indent.len)) catch |err| {
      if (err == error.OutOfMemoryUndo) {
        try self.handleUndoOOM(E);
      } else {
        return err;
      }
    };
    return self.insertSliceAtPosWithHints(E, insidx, indent.slice(), true, false);
  }
  
  pub fn insertNewline(self: *TextHandler, E: *Editor) !void {
    var indent: std.BoundedArray(u8, 32) = .{};
    
    var iter = self.iterate(self.lineinfo.getOffset(self.cursor.row));
    while (iter.nextCodepointSliceUntil(self.calcOffsetFromCursor())) |char| {
      if (std.mem.eql(u8, char, " ")) {
        indent.appendSlice(char) catch break;
      } else {
        break;
      }
    }
    
    try self.insertChar(E, "\n", true);
    
    if (indent.len > 0) {
      const insidx: u32 = self.calcOffsetFromCursor();
      self.undo_mgr.doAppend(insidx, @intCast(indent.len)) catch |err| {
        if (err == error.OutOfMemoryUndo) {
          try self.handleUndoOOM(E);
        } else {
          return err;
        }
      };
      try self.insertSliceAtPosWithHints(E, insidx, indent.constSlice(), false, false);
    }
  }
  
  fn shiftAndInsertNewLines(
    self: *TextHandler, E: *Editor,
    slice: []const u8,
    insidx: u32,
    first_row_after_insidx: u32,
    is_slice_always_inline: bool,
  ) !u32 {
    if (first_row_after_insidx < self.lineinfo.getLen()) {
      self.lineinfo.increaseOffsets(first_row_after_insidx, @intCast(slice.len));
    }
    
    var newlines_allocr = std.heap.stackFallback(16, E.allocr);
    var newlines = std.ArrayList(u32).init(newlines_allocr.get());
    defer newlines.deinit();
    
    if (!is_slice_always_inline) {
      var absidx: u32 = insidx;
      for (slice) |byte| {
        if (byte == '\n') {
          try newlines.append(absidx + 1);
        }
        absidx += 1;
      }
    }
    
    if (insidx > self.head_end and insidx <= self.head_end + self.gap.items.len) {
      // insertion within gap
      if ((self.gap.items.len + slice.len) < self.gap.capacity) {
        const gap_relidx = insidx - self.head_end;
        // TODO: there is no insertSliceAssumeCapacity?
        self.gap.replaceRangeAssumeCapacity(gap_relidx, 0, slice);
      } else {
        // overflow if inserted
        try self.flushGapBuffer();
        try self.buffer.insertSlice(insidx, slice);
      }
    } else {
      try self.flushGapBuffer();
      try self.buffer.insertSlice(insidx, slice);
    }
    
    if (newlines.items.len > 0) {
      try self.lineinfo.insertSlice(first_row_after_insidx, newlines.items);
      self.calcLineDigits(E);
    }
    
    for ((first_row_after_insidx - 1)..(first_row_after_insidx + newlines.items.len)) |i| {
      try self.recheckIsMultibyte(@intCast(i));
    }
    if (E.conf.wrap_text) {
      return (try self.wrapTextFrom(
        E,
        @intCast(first_row_after_insidx - 1),
        @intCast(first_row_after_insidx + newlines.items.len)
      )) - 1;
    } else {
      return @intCast(first_row_after_insidx - 1 + newlines.items.len);
    }
  }
  
  pub fn insertSlice(self: *TextHandler, E: *Editor, slice: []const u8) !void {
    const insidx: u32 = self.calcOffsetFromCursor();
    self.undo_mgr.doAppend(insidx, @intCast(slice.len)) catch |err| {
      if (err == error.OutOfMemoryUndo) {
        try self.handleUndoOOM(E);
      } else {
        return err;
      }
    };
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
    E.needs_redraw = true;
    
    // Perform insertion
    
    const first_row_after_insidx: u32 = if (use_cursor_line_hint)
      self.cursor.row + 1
    else
      self.lineinfo.findMinLineAfterOffset(insidx, 0);
    
    const row_at_end_of_slice: u32 =
      try self.shiftAndInsertNewLines(E, slice, insidx, first_row_after_insidx, is_slice_always_inline);

    // Highlighting
      
    try self.rehighlight(
      E,
      insidx, // changed_region_start_in
      @intCast(insidx + slice.len), // changed_region_end
      @intCast(slice.len), // shift
      true, // is_insert
      self.cursor.row // line_start
    );
    
    // Move the cursor to end of entered slice
      
    self.cursor.row = row_at_end_of_slice;
    
    const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
    const insidx_end: u32 = @intCast(insidx + slice.len);
    self.cursor.col = insidx_end - offset_start;
    
    if (!self.lineinfo.checkIsMultibyte(self.cursor.row)) {
      self.cursor.gfx_col = self.cursor.col;
    } else {
      self.cursor.gfx_col = 0;
      var iter = self.iterate(offset_start);
      while (iter.nextCodepointSliceUntil(insidx_end)) |bytes| {
        const char = std.unicode.utf8Decode(bytes) catch unreachable;
        self.cursor.gfx_col += encoding.countCharCols(char);
      }
    }
    
    self.syncColumnScroll(E);
    self.syncRowScroll(E);
  }
  
  /// Inserts slice at specified position. Used by UndoManager.
  pub fn insertSliceAtPos(self: *TextHandler, E: *Editor, insidx: u32, slice: []const u8) !void {
    return self.insertSliceAtPosWithHints(E, insidx, slice, false, false);
  }
  
  // deletion
  
  /// delete_next_char is true when pressing Delete, false when backspacing
  pub fn deleteChar(self: *TextHandler, E: *Editor, delete_next_char: bool) !void {
    var delidx: u32 = self.calcOffsetFromCursor();
    
    if (delete_next_char and delidx == self.getLogicalLen()) {
      return;
    } else if (!delete_next_char and delidx == 0) {
      return;
    }
    
    self.buffer_changed = true;
    var deleted_char = [_]u8{0} ** 4;
    var seqlen: u32 = undefined;
    
    // Delete the character and record the deleted char
    
    if (delete_next_char) {
      const bytes_starting = self.bytesStartingAt(delidx).?;
      seqlen = @intCast(encoding.sequenceLen(bytes_starting[0]) catch unreachable);
      @memcpy(deleted_char[0..seqlen], bytes_starting[0..seqlen]);
    } else {
      var iter = self.iterate(delidx);
      const bytes = iter.prevCodepointSlice().?;
      seqlen = @intCast(bytes.len);
      delidx -= @intCast(bytes.len);
      @memcpy(deleted_char[0..seqlen], bytes);
    }
    
    // Move the cursor to the previous char, if we are backspacing
    
    const cur_at_deleted_char = self.cursor;
    const delete_first_col_in_cont = blk: {
      if (self.lineinfo.isContLine(cur_at_deleted_char.row) and cur_at_deleted_char.gfx_col == 1) {
        const rowlen = self.getRowLen(cur_at_deleted_char.row);
        if (self.lineinfo.checkIsMultibyte(cur_at_deleted_char.row)) {
          const bytes = self.bytesStartingAt(self.lineinfo.getOffset(cur_at_deleted_char.row)).?;
          const seqlen1 = encoding.sequenceLen(bytes[0]) catch unreachable;
          break :blk (rowlen == seqlen1);
        } else {
          break :blk (rowlen == 1);
        }
      }
      break :blk false;
    };
    if (!delete_next_char) {
      if (self.cursor.gfx_col == 0 or delete_first_col_in_cont) {
        self.cursor.row -= 1;
        try self.goTail(E);
      } else {
        self.goLeft(E);
      }
    }
    
    // Perform deletion
    
    const logical_tail_start = self.head_end + self.gap.items.len;

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
        self.buffer.replaceRangeAssumeCapacity(real_tailidx, seqlen, &[_]u8{});
      }
    } else {
      // deletion within gap
      const gap_relidx = delidx - self.head_end;
      self.gap.replaceRangeAssumeCapacity(gap_relidx, seqlen, &[_]u8{});
    }
    
    self.undo_mgr.doDelete(delidx, deleted_char[0..seqlen]) catch |err| {
      if (err == error.OutOfMemoryUndo) {
        try self.handleUndoOOM(E);
      } else {
        return err;
      }
    };
    
    // Highlighting
    
    try self.rehighlight(
      E,
      delidx, // changed_region_start_in
      delidx, // changed_region_end
      @intCast(seqlen), // shift
      false, // is_insert
      cur_at_deleted_char.row // line_start
    );
    
    // Update line offset info
    
    const deleted_char_is_mb = seqlen > 1;
    
    // checkIsMultibyte is done after decreaseOffsets
    // because if not then the bounds of the line would not be updated
    
    if (delete_next_char) {
      if (cur_at_deleted_char.row == self.lineinfo.getLen() - 1) {
        // do nothing if deleting character of last line
      } else if (cur_at_deleted_char.col == self.getRowLen(cur_at_deleted_char.row)) {
        // deleting next line
        self.lineinfo.decreaseOffsets(cur_at_deleted_char.row+1, 1);
        self.lineinfo.remove(cur_at_deleted_char.row+1);
        try self.recheckIsMultibyteAfterDelete(cur_at_deleted_char.row, deleted_char_is_mb);
        if (E.conf.wrap_text) {
          try self.wrapLine(E, cur_at_deleted_char.row);
        }
        self.calcLineDigits(E);
      } else {
        self.lineinfo.decreaseOffsets(cur_at_deleted_char.row + 1, seqlen);
        try self.recheckIsMultibyteAfterDelete(cur_at_deleted_char.row, deleted_char_is_mb);
        if (E.conf.wrap_text) {
          try self.wrapLine(E, cur_at_deleted_char.row);
        }
      }
    } else {
      if (self.lineinfo.isContLine(cur_at_deleted_char.row)) {
        if (delete_first_col_in_cont) {
          self.lineinfo.decreaseOffsets(cur_at_deleted_char.row+1, seqlen);
          self.lineinfo.remove(cur_at_deleted_char.row);
          try self.recheckIsMultibyteAfterDelete(cur_at_deleted_char.row - 1, deleted_char_is_mb);
        } else {
          self.lineinfo.decreaseOffsets(cur_at_deleted_char.row+1, seqlen);
          try self.recheckIsMultibyteAfterDelete(cur_at_deleted_char.row, deleted_char_is_mb);
          if (E.conf.wrap_text) {
            try self.wrapLine(E, cur_at_deleted_char.row);
          }
        }
      } else if (cur_at_deleted_char.col == 0) {
        std.debug.assert(deleted_char[0] == '\n');
        self.lineinfo.decreaseOffsets(cur_at_deleted_char.row+1, 1);
        self.lineinfo.remove(cur_at_deleted_char.row);
        // newlines may fuse an ascii line and a unicode line together,
        // so the generic function should be used
        try self.recheckIsMultibyte(cur_at_deleted_char.row - 1);
        self.calcLineDigits(E);
      } else {
        self.lineinfo.decreaseOffsets(cur_at_deleted_char.row + 1, seqlen);
        try self.recheckIsMultibyteAfterDelete(cur_at_deleted_char.row, deleted_char_is_mb);
        if (E.conf.wrap_text) {
          try self.wrapLine(E, cur_at_deleted_char.row);
        }
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
    E.needs_redraw = true;
    
    const logical_tail_start = self.head_end + self.gap.items.len;
    
    var retval: ?[]const u8 = null;
    
    if (delete_start >= self.head_end and delete_end < logical_tail_start) {
      // deletion within gap buffer
      const gap_delete_start = delete_start - self.head_end;
      const gap_delete_end = delete_end - self.head_end;
      
      if (record_undoable_action) {
        self.undo_mgr.doDelete(
          delete_start, self.gap.items[gap_delete_start..gap_delete_end]
        ) catch |err| {
          if (err == error.OutOfMemoryUndo) {
            try self.handleUndoOOM(E);
            return null;
          } else {
            return err;
          }
        };
      }
      
      retval = if (copy_orig_slice_to_undo_heap)
        try self.undo_mgr.copySlice(self.gap.items[gap_delete_start..gap_delete_end])
      else
        null;
      
      const n_deleted = gap_delete_end - gap_delete_start;
      
      // Remove chars from gap
      self.gap.replaceRangeAssumeCapacity(gap_delete_start, n_deleted, &[_]u8{});
    } else {
      // deletion outside, or between gap buffer
      
      // assume that the gap buffer is flushed to make it easier
      // for us to delete the region
      try self.flushGapBuffer();
      
      if (record_undoable_action) {
        self.undo_mgr.doDelete(
          delete_start, self.buffer.items[delete_start..delete_end]
        ) catch |err| {
          if (err == error.OutOfMemoryUndo) {
            try self.handleUndoOOM(E);
            return null;
          } else {
            return err;
          }
        };
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
    
    // Update line info
    
    const removed_line_start = self.lineinfo.removeLinesInRange(delete_start, delete_end);
    
    // Highlighting
    
    try self.rehighlight(
      E,
      delete_start, // changed_region_start_in
      delete_start, // changed_region_end
      delete_end - delete_start, // shift
      false, // is_insert
      removed_line_start // line_start
    );

    try self.recheckIsMultibyte(removed_line_start);
    if ((removed_line_start + 1) < self.lineinfo.getLen()) {
      try self.recheckIsMultibyte(removed_line_start + 1);
    }
    
    if (E.conf.wrap_text) {
      _ = try self.wrapTextFrom(E, removed_line_start, removed_line_start+1);
    }
    
    if (
      self.lineinfo.isContLine(removed_line_start) and
      self.getRowLen(removed_line_start) == 0
    ) {
      self.lineinfo.remove(removed_line_start);
      self.cursor.row = removed_line_start - 1;
      try self.goTail(E);
    } else {
      self.cursor.row = removed_line_start;
      const row_start = self.lineinfo.getOffset(self.cursor.row);
      self.cursor.col = delete_start - row_start;
      
      if (!self.lineinfo.checkIsMultibyte(self.cursor.row)) {
        self.cursor.gfx_col = self.cursor.col;
      } else {
        self.cursor.gfx_col = 0;
        var iter = self.iterate(row_start);
        while (iter.nextCodepointSliceUntil(delete_start)) |char| {
          self.cursor.gfx_col += encoding.countCharCols(try std.unicode.utf8Decode(char));
        }
      }
    }
    
    self.calcLineDigits(E);
    self.syncColumnScroll(E);
    self.syncRowScroll(E);
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
  
  pub fn deleteLine(self: *TextHandler, E: *Editor) !void {
    const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
    var offset_end: u32 = self.getRowOffsetEnd(self.cursor.row);
    if (self.cursor.row < self.lineinfo.getLen() - 1) {
      offset_end += 1; // include newline
    }
    if (offset_start == offset_end) {
      return;
    }
    _ = try self.deleteRegionAtPos(E, offset_start, offset_end, true, false);
  }
  
  pub fn deleteWord(self: *TextHandler, E: *Editor) !void {
    if (self.cursor.col == 0) {
      return;
    }
    const delete_end = self.calcOffsetFromCursor();
    self.goLeftWord(E);
    const delete_start = self.calcOffsetFromCursor();
    _ = try self.deleteRegionAtPos(E, delete_start, delete_end, true, false);
  }
  
  // Replacement
  
  pub fn replaceRegion(
    self: *TextHandler,
    E: *Editor,
    replace_start: u32, replace_end: u32,
    new_buffer: []const u8,
    record_undoable_action: bool,
  ) !void {
    E.needs_redraw = true;
    
    if (replace_start == replace_end) {
      if (record_undoable_action) {
        self.undo_mgr.doAppend(replace_start, @intCast(new_buffer.len)) catch |err| {
          if (err == error.OutOfMemoryUndo) {
            try self.handleUndoOOM(E);
          } else {
            return err;
          }
        };
      }
      return self.insertSliceAtPos(
        E,
        replace_start,
        new_buffer,
      );
    }
  
    try self.flushGapBuffer();
    
    // TODO: replace within gap buffer
    
    if (record_undoable_action) {
      self.undo_mgr.doReplace(
        replace_start,
        self.buffer.items[replace_start..replace_end],
        new_buffer,
      ) catch |err| {
        if (err == error.OutOfMemoryUndo) {
          try self.handleUndoOOM(E);
        } else {
          return err;
        }
      };
    }
    
    const old_buffer_len = replace_end - replace_start;
    
    try self.buffer.replaceRange(
      replace_start,
      old_buffer_len,
      new_buffer,
    );
    
    var newlines: std.ArrayListUnmanaged(u32) = .{};
    defer newlines.deinit(E.allocr);
    
    for (new_buffer,0..new_buffer.len) |item, idx| {
      if (item == '\n') {
        try newlines.append(E.allocr, @intCast(replace_start + idx + 1));
      }
    }
    
    // line info
    
    const replace_line_start = self.lineinfo.removeLinesInRange(replace_start, replace_end);
    
    // Highlighting
    if (new_buffer.len < old_buffer_len) {
      // decrease
      try self.rehighlight(
        E,
        replace_start, // changed_region_start_in
        replace_end, // changed_region_end
        @intCast(old_buffer_len - new_buffer.len), // shift
        false,
        replace_line_start
      );
    } else {
      // increase
      try self.rehighlight(
        E,
        replace_start, // changed_region_start_in
        replace_end, // changed_region_end
        @intCast(new_buffer.len - old_buffer_len), // shift
        true,
        replace_line_start
      );
    }
    
    const row_at_end_of_slice: u32 = @intCast(replace_line_start + 1 + newlines.items.len);
      
    try self.lineinfo.insertSlice(replace_line_start + 1, newlines.items);
    self.lineinfo.increaseOffsets(row_at_end_of_slice, @intCast(new_buffer.len));
    self.calcLineDigits(E);
    
    for (replace_line_start..row_at_end_of_slice) |i| {
      try self.recheckIsMultibyte(@intCast(i));
    }
    
    // cursor
    
    self.cursor.row = row_at_end_of_slice - 1;
    
    const new_replace_end: u32 = @intCast(replace_start + new_buffer.len);
    self.cursor.col = 0;
    self.cursor.gfx_col = 0;
    var iter = self.iterate(self.lineinfo.getOffset(self.cursor.row));
    while (iter.nextCodepointSliceUntil(new_replace_end)) |char| {
      self.cursor.col += @intCast(char.len);
      self.cursor.gfx_col += encoding.countCharCols(try std.unicode.utf8Decode(char));
    }
    
    self.syncColumnScroll(E);
    self.syncRowScroll(E);
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
  
  pub const ReplaceNeedle = union(enum) {
    string: []const u8,
    regex: Expr,
    
    pub fn deinit(self: *ReplaceNeedle, allocr: std.mem.Allocator) void {
      switch (self.*) {
        .string => |needle| {
          allocr.free(needle);
        },
        .regex => |*regex| {
          regex.deinit(allocr);
        }
      }
    }
    
    fn checkMatch(self: *const ReplaceNeedle, haystack: []const u8) ?usize {
      switch (self.*) {
        .string => |needle| {
          if (std.mem.startsWith(u8, haystack, needle)) {
            return needle.len;
          } else {
            return null;
          }
        },
        .regex => |*regex| {
          const match = regex.checkMatch(haystack, &.{}) catch {
            return null;
          };
          if (match.pos > 0) {
            return match.pos;
          } else {
            return null;
          }
        }
      }
    }
  };
  
  pub fn replaceAllMarked(
    self: *TextHandler,
    E: *Editor,
    needle: ReplaceNeedle,
    replacement: []const u8
  ) !usize {
    var markers = &self.markers.?;
    var replaced = str.String.init(E.allocr);
    defer replaced.deinit();
    
    // TODO: replace all within gap buffer
    try self.flushGapBuffer();
    
    const src_text = self.buffer.items[markers.start..markers.end];
    
    var slide: usize = 0;
    var replacements: usize = 0;
    while (slide < src_text.len) {
      if (needle.checkMatch(src_text[slide..])) |len| {
        try replaced.appendSlice(replacement);
        slide += len;
        replacements += 1;
      } else {
        try replaced.append(src_text[slide]);
        slide += 1;
      }
    }
    
    const new_end: u32 = @intCast(markers.start + replaced.items.len);
    try self.replaceRegion(E, markers.start, markers.end, replaced.items, true);
    markers.end = new_end;
    
    return replacements;
  }
  
  // Indentation
  
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
    
    var indented = str.String.init(E.allocr);
    defer indented.deinit();
    for (0..@intCast(E.conf.tab_size)) |_| {
      try indented.append(' ');
    }
    
    var iter = self.iterate(self.lineinfo.getOffset(markers.start_cur.row));
    while (iter.nextCodepointSliceUntil(markers.end)) |char| {
      try indented.appendSlice(char);
      if (char[0] == '\n') {
        for (0..@intCast(E.conf.tab_size)) |_| {
          try indented.append(' ');
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
    
    var dedented = str.String.init(E.allocr);
    defer dedented.deinit();
    
    var iter = self.iterate(self.lineinfo.getOffset(markers.start_cur.row));
    while (iter.nextCodepointSliceUntil(markers.end)) |char| {
      try dedented.appendSlice(char);
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
      @panic("markEnd called without markers");
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
    
    try self.flushGapBuffer();
    
    const n_copied = markers.end - markers.start;
    if (n_copied > 0) {
      if (E.conf.use_native_clipboard) {
        if (clipboard.write(
          E.allocr,
          self.buffer.items[markers.start..markers.end]
        )) |_| {
          return;
        } else |_| {}
      }
      self.clipboard.shrinkRetainingCapacity(0);
      try self.clipboard.appendSlice(
        self.buffer.items[markers.start..markers.end]
      );
    }
  }
  
  pub fn paste(self: *TextHandler, E: *Editor) !void {
    if (E.conf.use_native_clipboard) {
      if (try clipboard.read(E.allocr)) |native_clip| {
        defer E.allocr.free(native_clip);
        try self.insertSlice(E, native_clip);
        return;
      }
    }
    if (self.clipboard.items.len > 0) {
      try self.insertSlice(E, self.clipboard.items);
    }
  }
  
  pub fn duplicateLine(self: *TextHandler, E: *Editor) !void {
    var line = str.String.init(E.allocr);
    defer line.deinit();
    try line.append('\n');
    const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
    const offset_end: u32 = self.getRowOffsetEnd(self.cursor.row);
    var iter = self.iterate(offset_start);
    while (iter.nextCodepointSliceUntil(offset_end)) |bytes| {
      try line.appendSlice(bytes);
    }
    try self.goTail(E);
    try self.insertSlice(E, line.items);
  }
  
  // line wrapping
  
  pub fn wrapText(self: *TextHandler, E: *Editor) !void {
    var line: u32 = 0;
    while (line < self.lineinfo.getLen()) {
      const result = try self.lineinfo.updateLineWrap(self, E, line);
      line = result.next_line;
    }
  }
  
  /// Returns the final line after the wrapped text
  pub fn wrapTextFrom(
    self: *TextHandler, E: *Editor,
    from_line: u32, to_line: u32,
  ) !u32 {
    var line = from_line;
    var to = to_line;
    while (line < to) {
      const result = try self.lineinfo.updateLineWrap(self, E, line);
      to = @intCast(to + result.len_change);
      line = @intCast(result.next_line);
    }
    return line;
  }
  
  fn wrapLine(self: *TextHandler, E: *Editor, line: u32) !void {
    _ = try self.lineinfo.updateLineWrap(self, E, line);
  }
  
  // Highlighting
  
  pub fn highlightText(self: *TextHandler, E: *Editor) !void {
    return self.highlight.runFromStart(self, E.allocr);
  }
  
  pub fn rehighlight(
    self: *TextHandler, E: *Editor,
    changed_region_start: u32,
    changed_region_end: u32,
    shift: u32,
    is_insert: bool,
    line_start: u32,
  ) !void {
    return self.highlight.run(
      self,
      E.allocr,
      changed_region_start,
      changed_region_end,
      shift,
      is_insert,
      line_start
    );
  }
  
  // Undo
  
  pub fn handleUndoOOM(self: *TextHandler, E: *Editor) !void {
    _ = self;
    E.setHideableMsgConst("Unable to allocate undo action");
  }
  
};
