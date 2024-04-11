//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");

fn lower_u32(context: void, lhs: u32, rhs: u32) bool {
  _ = context;
  return lhs < rhs;
}

pub const LineOffsetList = struct {  
  buf: std.ArrayListUnmanaged(u32),
  alloc_gpa: std.heap.GeneralPurposeAllocator(.{}),
  
  pub fn init() !LineOffsetList {
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
  
  pub fn getLen(self: *const LineOffsetList) u32 {
    return @intCast(self.buf.items.len);
  }
  
  pub fn get(self: *const LineOffsetList, idx: u32) u32 {
    return self.buf.items[idx];
  }
  
  pub fn clear(self: *LineOffsetList) void {
    self.buf.clearRetainingCapacity();
  }
  
  pub fn orderedRemove(self: *LineOffsetList, idx: u32) u32 {
    return self.buf.orderedRemove(idx);
  }
  
  pub fn shrinkRetainingCapacity(self: *LineOffsetList, len: u32) void {
    self.buf.shrinkRetainingCapacity(len);
  }
  
  pub fn append(self: *LineOffsetList, offset: u32) !void {
    try self.buf.append(self.allocr(), offset);
  }
  
  pub fn insert(self: *LineOffsetList, idx: u32, offset: u32) !void {
    try self.buf.insert(self.allocr(), idx, offset);
  }
  
  pub fn insertSlice(self: *LineOffsetList, idx: u32, slice: []const u32) !void {
    try self.buf.insertSlice(self.allocr(), idx, slice);
  }
  
  pub fn increaseOffsets(self: *LineOffsetList, from: u32, delta: u32) void {
    for (self.buf.items[from..]) |*offset| {
       offset.* += delta;
    }
  }
  
  pub fn decreaseOffsets(self: *LineOffsetList, from: u32, delta: u32) void {
    for (self.buf.items[from..]) |*offset| {
       offset.* -= delta;
    }
  }
  
  pub fn findMaxLineBeforeOffset(self: *const LineOffsetList, offset: u32) u32 {
    const idx = std.sort.lowerBound(
      u32,
      offset,
      self.buf.items,
      {},
      lower_u32,
    );
    if (idx >= self.buf.items.len) {
      return @intCast(idx);
    }
    if (self.buf.items[idx] > offset) {
      return @intCast(idx - 1);
    }
    return @intCast(idx);
  }
  
  pub fn findMinLineAfterOffset(self: *const LineOffsetList, offset: u32) u32 {
    return @intCast(std.sort.upperBound(
      u32,
      offset,
      self.buf.items,
      {},
      lower_u32,
    ));
  }
  
  pub fn moveTail(self: *LineOffsetList, line_pivot_dest: u32, line_pivot_src: u32) void {
    const new_len = self.buf.items.len - (line_pivot_src - line_pivot_dest);
    std.mem.copyForwards(
      u32,
      self.buf.items[line_pivot_dest..new_len],
      self.buf.items[line_pivot_src..]
    );
    self.buf.shrinkRetainingCapacity(new_len);
  }
  
  /// Remove the lines specified in range
  pub fn removeLinesInRange(
    self: *LineOffsetList,
    delete_start: u32, delete_end: u32
  ) void {
    const line_start = self.findMinLineAfterOffset(delete_start);
    if (line_start == self.getLen()) {
      // region starts in last line
      return;
    }
    
    const line_end = self.findMinLineAfterOffset(delete_end);
    if (line_end == self.getLen()) {
      // region ends at last line
      self.buf.shrinkRetainingCapacity(line_start);
      return;
    }
    
    std.debug.assert(self.buf.items[line_start] > delete_start);
    std.debug.assert(self.buf.items[line_end] > delete_end);
    
    const chars_deleted = delete_end - delete_start;
    
    for (self.buf.items[line_end..]) |*offset| {
      offset.* -= chars_deleted;
    }
    
    // remove the line offsets between the region
    self.moveTail(line_start, line_end);
  }
};
