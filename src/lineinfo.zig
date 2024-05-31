//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");

const utils = @import("./utils.zig");
const text = @import("./text.zig");
const encoding = @import("./encoding.zig");
const Editor = @import("./editor.zig").Editor;

const LineData = packed struct {
  const Flags = packed struct {
    is_multibyte: bool = false,
    /// True for if line is continuation of the previous
    /// line, used for line wrapping
    is_cont_line: bool = false,
    _padding: u30 = 0,
    
    comptime {
      std.debug.assert(@bitSizeOf(@This()) == @bitSizeOf(u32));
    }
  };
  
  offset: u32,
  /// Cont-lines must have the same line_no as parent
  line_no: u32,
  _padding: u32 = 0,
  flags: Flags,
  
  comptime {
    std.debug.assert(@sizeOf(LineData) == 16);
  }
  
  fn debugPrint(self: *const LineData) void {
    std.debug.print("{}: {} {}\n", .{
      self.line_no, self.offset, self.flags
    });
  }
};


pub const LineInfoList = struct {
  const MAX_LINES = std.math.maxInt(u32);
  
  arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
  
  line_data: std.ArrayListUnmanaged(LineData) = .{},

  fn allocr(self: *LineInfoList) std.mem.Allocator {
    return self.arena.allocator();
  }
  
  pub fn create() !LineInfoList {
    var list = LineInfoList {};
    try list.append(0);
    return list;
  }
  
  pub fn debugPrint(self: *const LineInfoList) void {
    for (self.line_data.items) |*line_data| {
      line_data.debugPrint();
    }
  }
  
  // General manipiulation
  
  pub fn getLen(self: *const LineInfoList) u32 {
    return @intCast(self.line_data.items.len);
  }
  
  pub fn reset(self: *LineInfoList) void {
    const len = self.line_data.items.len;
    self.line_data.replaceRangeAssumeCapacity(
      0,
      len,
      &[_]LineData{
        .{
          .offset = 0,
          .line_no = 1,
          .flags = .{},
        },
      },
    );
  }
  
  pub fn remove(self: *LineInfoList, idx: u32) void {
    const line_data = self.line_data.orderedRemove(idx);
    if (!line_data.flags.is_cont_line) {
      self.recalcLineNosFrom(idx);
    }
  }
  
  pub fn append(self: *LineInfoList, offset: u32) !void {
    if (self.line_data.items.len + 1 >= MAX_LINES) {
      return error.OutOfMemory;
    }
    
    var line_no: u32 = undefined;
    if (self.line_data.items.len == 0) {
      line_no = 1;
    } else {
      line_no = self.line_data.items[self.line_data.items.len - 1].line_no + 1;
    }
    try self.line_data.append(self.allocr(), .{
      .offset = offset,
      .line_no = line_no,
      .flags = .{},
    });
  }
  
  pub fn ensureTotalCapacity(self: *LineInfoList, cap: u32) !void {
    if (cap > MAX_LINES) {
      return error.OutOfMemory;
    }
    return self.line_data.ensureTotalCapacity(
      self.allocr(),
      @intCast(cap)
    );
  }
  
  /// Returns true if a new line has actually been added
  pub fn insert(self: *LineInfoList, idx: u32, offset: u32, is_multibyte: bool) !bool {
    if (self.line_data.items.len + 1 >= MAX_LINES) {
      return error.OutOfMemory;
    }
    
    var line_no: u32 = undefined;
    if (idx == 0) {
      line_no = 1;
    } else {
      line_no = self.line_data.items[idx - 1].line_no + 1;
    }
    
    const line_data: LineData = .{
      .offset = offset,
      .line_no = line_no,
      .flags = .{
        .is_multibyte = is_multibyte,
      },
    };
    
    if (idx == self.line_data.items.len) { 
      try self.line_data.append(self.allocr(), line_data);
      return true;
    }
    
    if (
      idx > 0 and
      self.line_data.items[idx - 1].flags.is_cont_line and
      self.line_data.items[idx - 1].offset + 1 == offset
    ) {
      self.line_data.items[idx - 1] = line_data;
      self.recalcLineNosFrom(idx);
      return false;
    }
    else if (
      idx > 0 and
      self.line_data.items[idx - 1].flags.is_cont_line and
      self.line_data.items[idx].flags.is_cont_line
    ) {
      self.line_data.items[idx] = line_data;
      self.recalcLineNosFrom(idx+1);
    } else {
      try self.line_data.insert(self.allocr(), idx, line_data);
      self.recalcLineNosFrom(idx+1);
    }
    
    return true;
  }
  
  pub fn insertSlice(
    self: *LineInfoList,
    idx: u32,
    offsets: []const u32,
  ) !void {
    if (self.line_data.items.len + offsets.len >= MAX_LINES) {
      return error.OutOfMemory;
    }
    
    var line_no: u32 = undefined;
    if (idx == 0) {
      line_no = 1;
    } else {
      line_no = self.line_data.items[idx - 1].line_no + 1;
    }
    const new_line_data: []LineData =
      try self.line_data.addManyAt(self.allocr(), idx, offsets.len);
    for (new_line_data, offsets) |*line_data, offset| {
      line_data.* = .{
        .offset = offset,
        .line_no = line_no,
        .flags = .{},
      };
      line_no += 1;
    }
    self.recalcLineNosFrom(idx+1);
  }
  
  // Offsets
  
  pub fn findMaxLineBeforeOffset(self: *const LineInfoList, offset: u32, from_line: u32) u32 {
    return @intCast(
      utils.findLastNearestElement(
        LineData, "offset",
        self.line_data.items, offset, @intCast(from_line)
      ).?
    );
  }
  
  pub fn findMinLineAfterOffset(self: *const LineInfoList, offset: u32, from_line: u32) u32 {
    return @intCast(
      utils.findNextNearestElement(
        LineData, "offset",
        self.line_data.items, offset, @intCast(from_line)
      )
    );
  }
  
  pub fn findLineWithLineNo(self: *const LineInfoList, line_no: u32) ?u32 {
    var left: u32 = 0;
    var right: u32 = @intCast(self.line_data.items.len);
    
    while (left < right) {
      const mid = left + (right - left) / 2;
      const line_data = &self.line_data.items[mid];
      switch (std.math.order(line_no, line_data.line_no)) {
        .eq => {
          if (line_data.flags.is_cont_line) {
            right = mid;
            continue;
          }
          return mid;
        },
        .gt => left = mid + 1,
        .lt => right = mid,
      }
    }
    
    return null;
  }
  
  pub fn getOffset(self: *const LineInfoList, idx: u32) u32 {
    return self.line_data.items[idx].offset;
  }
  
  fn modifyOffsets(
    self: *LineInfoList, from: u32, delta: u32, comptime increase: bool
  ) void {
    for (self.line_data.items[from..]) |*line_data| {
      if (comptime increase) {
        line_data.offset += delta;
      } else {
        line_data.offset -= delta;
      }
    }
  }
  
  pub fn increaseOffsets(self: *LineInfoList, from: u32, delta: u32) void {
    return self.modifyOffsets(from, delta, true);
  }
  
  pub fn decreaseOffsets(self: *LineInfoList, from: u32, delta: u32) void {
    return self.modifyOffsets(from, delta, false);
  }
  
  // Line numbers
  
  fn recalcLineNosFrom(self: *LineInfoList, from: u32) void {
    // std.debug.print("recalc line from {}\n", .{from});
    var i = from;
    while (i < self.line_data.items.len) {
      if (i == 0) {
        self.line_data.items[i].line_no = 1;
      } else if (self.line_data.items[i].flags.is_cont_line) {
        self.line_data.items[i].line_no = self.line_data.items[i - 1].line_no;
      } else {
        self.line_data.items[i].line_no = self.line_data.items[i - 1].line_no + 1;
      }
      i += 1;
    }
  }
  
  pub fn getLineNo(self: *const LineInfoList, idx: u32) u32 {
    return self.line_data.items[idx].line_no;
  }
  
  pub fn getMaxLineNo(self: *const LineInfoList) u32 {
    return self.line_data.items[self.line_data.items.len - 1].line_no;
  }
  
  // Multibyte
  
  pub fn isMultibyte(self: *const LineInfoList, idx: u32) bool {
    return self.line_data.items[idx].flags.is_multibyte;
  }
  
  pub fn setMultibyte(self: *LineInfoList, idx: u32, is_multibyte: bool) void {
    self.line_data.items[idx].flags.is_multibyte = is_multibyte;
  }
  
  // Cont line
  
  pub fn isContLine(self: *const LineInfoList, idx: u32) bool {
    return self.line_data.items[idx].flags.is_cont_line;
  }
  
  pub const UpdateLineWrapResult = struct {
    len_change: i64,
    next_line: u32
  };
  
  pub fn findNextNonContLine(self: *const LineInfoList, line: u32) ?u32 {
    for ((line+1)..self.line_data.items.len) |cur_line| {
      const line_data = &self.line_data.items[cur_line];
      if (!line_data.flags.is_cont_line) {
        // - 1 to account for new line
        return @intCast(cur_line);
      }
    }
    return null;
  }
  
  pub fn updateLineWrap(
    self: *LineInfoList,
    text_handler: *const text.TextHandler,
    E: *const Editor,
    start_line_idx: u32,
  ) !UpdateLineWrapResult {
    const columns = E.getTextWidth() - 1;
    var next_line_offset: u32 = text_handler.getLogicalLen();
    var next_line_idx: u32 = self.getLen();
    if (self.findNextNonContLine(start_line_idx)) |idx| {
      // - 1 to account for new line
      next_line_offset = self.getOffset(idx) - 1;
      next_line_idx = idx;
    }
    
    const start_line_offset: u32 = self.line_data.items[start_line_idx].offset;
    const start_line_is_mb =
      self.line_data.items[start_line_idx].flags.is_multibyte;
    
    var stack_allocr = std.heap.stackFallback(16, std.heap.page_allocator);
    var new_cont_lines = std.ArrayList(u32).init(stack_allocr.get());
    defer new_cont_lines.deinit();
    
    if (start_line_is_mb) {
      var iter = text_handler.iterate(start_line_offset);
      
      var cur_line_cols: u32 = 0;
      var last_iter_pos: u32 = 0;
      
      while (iter.nextCodepointSliceUntil(next_line_offset)) |bytes| {
        const ccols = encoding.countCharCols(
          std.unicode.utf8Decode(bytes) catch unreachable
        );
        if ((cur_line_cols + ccols) > columns) {
          try new_cont_lines.append(last_iter_pos);
          cur_line_cols = ccols;
          continue;
        }
        cur_line_cols += ccols;
        last_iter_pos = iter.pos;
      }
    } else {
      // add column to offset to account for first non-cont line
      var offset = start_line_offset + columns;
      while (offset < next_line_offset) {
        try new_cont_lines.append(offset);
        offset += columns;
      }
    }
    
    const next_line_idx_new: u32 =
      @intCast(start_line_idx + 1 + new_cont_lines.items.len);
      
    // Reserve/delete space for new cont-lines
    
    if (next_line_idx_new < next_line_idx) {
      const new_len = self.line_data.items.len - (next_line_idx - next_line_idx_new);
      std.mem.copyForwards(
        LineData,
        self.line_data.items[next_line_idx_new..new_len],
        self.line_data.items[next_line_idx..]
      );
      self.line_data.shrinkRetainingCapacity(new_len);
    } else if (next_line_idx_new > next_line_idx) {
      const old_len = self.line_data.items.len;
      const new_len = self.line_data.items.len + (next_line_idx_new - next_line_idx);
      try self.line_data.resize(self.allocr(), new_len);
      std.mem.copyBackwards(
        LineData,
        self.line_data.items[next_line_idx_new..],
        self.line_data.items[next_line_idx..old_len]
      );
    }
    
    if (new_cont_lines.items.len > 0) {
      // Fill in line info
      const line_no: u32 = self.line_data.items[start_line_idx].line_no;
      
      std.debug.assert(
        self.line_data.items[(start_line_idx+1)..next_line_idx_new].len ==
        new_cont_lines.items.len
      );
      
      for (
        self.line_data.items[(start_line_idx+1)..next_line_idx_new],
        new_cont_lines.items
      ) |*line_data, cont_line_offset| {
        line_data.* = .{
          .offset = cont_line_offset,
          .line_no = line_no,
          .flags = .{
            .is_cont_line = true,
            .is_multibyte = start_line_is_mb
          },
        };
      }
    }
    
    return .{
      .len_change = @as(i64, next_line_idx_new) - @as(i64, next_line_idx),
      .next_line = next_line_idx_new,
    };
  }
  
  /// Remove the lines specified in range
  pub fn removeLinesInRange(
    self: *LineInfoList,
    delete_start: u32, delete_end: u32
  ) u32 {
    std.debug.assert(delete_end > delete_start);
    
    const line_start = self.findMinLineAfterOffset(delete_start, 0);
    if (line_start == self.getLen()) {
      // region starts in last line
      return line_start - 1;
    }
    
    const line_end = self.findMinLineAfterOffset(delete_end, line_start);
    if (line_end == self.getLen()) {
      // region ends at last line
      self.line_data.shrinkRetainingCapacity(line_start);
      return line_start - 1;
    }
    
    std.debug.assert(self.line_data.items[line_start].offset > delete_start);
    std.debug.assert(self.line_data.items[line_end].offset > delete_end);
    
    const chars_deleted = delete_end - delete_start;
    self.decreaseOffsets(line_end, chars_deleted);
    
    // remove the line offsets between the region
    self.line_data.replaceRangeAssumeCapacity(
      line_start,
      line_end - line_start,
      &[_]LineData{},
    );
    
    // Line number must be recalculated here
    self.recalcLineNosFrom(line_start - 1);
    
    return line_start - 1;
  }
};
