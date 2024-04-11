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

pub const LineInfoList = struct {  
  alloc_gpa: std.heap.GeneralPurposeAllocator(.{}),
  
  /// Logical offsets to start of lines. These offsets are defined based on
  /// positions within the logical text buffer above.
  /// These offsets do contain the newline character.
  offsets: std.ArrayListUnmanaged(u32),
  
  
  pub fn init() !LineInfoList {
    var alloc_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    var offsets = try std.ArrayListUnmanaged(u32).initCapacity(alloc_gpa.allocator(), 1);
    try offsets.append(alloc_gpa.allocator(), 0);
    return LineInfoList {
      .alloc_gpa = alloc_gpa,
      .offsets = offsets,
    };
  }

  fn allocr(self: *LineInfoList) std.mem.Allocator {
    return self.alloc_gpa.allocator();
  }
  
  pub fn getLen(self: *const LineInfoList) u32 {
    return @intCast(self.offsets.items.len);
  }
  
  pub fn get(self: *const LineInfoList, idx: u32) u32 {
    return self.offsets.items[idx];
  }
  
  pub fn clear(self: *LineInfoList) void {
    self.offsets.clearRetainingCapacity();
  }
  
  pub fn remove (self: *LineInfoList, idx: u32) void {
    _ = self.offsets.orderedRemove(idx);
  }
  
  pub fn shrinkRetainingCapacity(self: *LineInfoList, len: u32) void {
    self.offsets.shrinkRetainingCapacity(len);
  }
  
  pub fn append(self: *LineInfoList, offset: u32) !void {
    try self.offsets.append(self.allocr(), offset);
  }
  
  pub fn insert(self: *LineInfoList, idx: u32, offset: u32) !void {
    try self.offsets.insert(self.allocr(), idx, offset);
  }
  
  pub fn insertSlice(self: *LineInfoList, idx: u32, slice: []const u32) !void {
    try self.offsets.insertSlice(self.allocr(), idx, slice);
  }
  
  pub fn increaseOffsets(self: *LineInfoList, from: u32, delta: u32) void {
    for (self.offsets.items[from..]) |*offset| {
       offset.* += delta;
    }
  }
  
  pub fn decreaseOffsets(self: *LineInfoList, from: u32, delta: u32) void {
    for (self.offsets.items[from..]) |*offset| {
       offset.* -= delta;
    }
  }
  
  pub fn findMaxLineBeforeOffset(self: *const LineInfoList, offset: u32) u32 {
    const idx = std.sort.lowerBound(
      u32,
      offset,
      self.offsets.items,
      {},
      lower_u32,
    );
    if (idx >= self.offsets.items.len) {
      return @intCast(idx);
    }
    if (self.offsets.items[idx] > offset) {
      return @intCast(idx - 1);
    }
    return @intCast(idx);
  }
  
  pub fn findMinLineAfterOffset(self: *const LineInfoList, offset: u32) u32 {
    return @intCast(std.sort.upperBound(
      u32,
      offset,
      self.offsets.items,
      {},
      lower_u32,
    ));
  }
  
  pub fn moveTail(self: *LineInfoList, line_pivot_dest: u32, line_pivot_src: u32) void {
    const new_len = self.offsets.items.len - (line_pivot_src - line_pivot_dest);
    std.mem.copyForwards(
      u32,
      self.offsets.items[line_pivot_dest..new_len],
      self.offsets.items[line_pivot_src..]
    );
    self.offsets.shrinkRetainingCapacity(new_len);
  }
  
  /// Remove the lines specified in range
  pub fn removeLinesInRange(
    self: *LineInfoList,
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
      self.offsets.shrinkRetainingCapacity(line_start);
      return;
    }
    
    std.debug.assert(self.offsets.items[line_start] > delete_start);
    std.debug.assert(self.offsets.items[line_end] > delete_end);
    
    const chars_deleted = delete_end - delete_start;
    
    for (self.offsets.items[line_end..]) |*offset| {
      offset.* -= chars_deleted;
    }
    
    // remove the line offsets between the region
    self.moveTail(line_start, line_end);
  }
};
