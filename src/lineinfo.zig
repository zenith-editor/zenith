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

pub const BitArrayUnmanaged = struct {
  buf: std.ArrayListUnmanaged(u8) = .{},
  bit_length: usize = 0,
  
  pub fn initCapacity(allocator: std.mem.Allocator, bits: usize) !BitArrayUnmanaged {
    return .{
      .buf = try std.ArrayListUnmanaged(u8).initCapacity(allocator, (bits >> 3) + 1),
    };
  }
  
  pub fn deinit(self: *BitArrayUnmanaged, allocator: std.mem.Allocator) void {
    self.buf.deinit(allocator);
  }
  
  pub fn get(self: *const BitArrayUnmanaged, nthbit: usize) u1 {
    const byte_index = nthbit >> 3;
    if (byte_index >= self.buf.items.len) {
      return 0;
    }
    const bit_index: u3 = @intCast(nthbit & 7);
    const bin: u8 = (self.buf.items[byte_index] >> bit_index) & 1;
    return @intCast(bin);
  }
  
  pub fn set(self: *BitArrayUnmanaged, allocator: std.mem.Allocator, nthbit: usize, b: u1) !void {
    const byte_index = nthbit >> 3;
    const bit_index: u3 = @intCast(nthbit & 7);
    if (nthbit >= self.bit_length) {
      self.bit_length = (nthbit + 1);
    }
    if (byte_index >= self.buf.items.len) {
      try self.buf.appendNTimes(allocator, 0, byte_index - self.buf.items.len + 1);
    }
    self.buf.items[byte_index] &= ~(@as(u8, 1) << bit_index);
    self.buf.items[byte_index] |= @as(u8, b) << bit_index;
  }
  
  pub fn clearRetainingCapacity(self: *BitArrayUnmanaged) void {
    self.buf.clearRetainingCapacity();
  }
  
  pub fn shrinkRetainingCapacity(self: *BitArrayUnmanaged, nbits: usize) void {
    const byte_index = nbits >> 3;
    self.buf.shrinkRetainingCapacity(byte_index + 1);
    self.bit_length = nbits;
  }
  
  pub fn remove(self: *BitArrayUnmanaged, nthbit: usize) u1 {
    const byte_index = nthbit >> 3;
    if (byte_index >= self.buf.items.len) {
      return 0;
    }
    const bit_index: u3 = @intCast(nthbit & 7);
    const removed_bit = (self.buf.items[byte_index] >> bit_index) & 1;
    
    // std.debug.print("rem: {b}\n",.{self.buf.items});
    // defer std.debug.print("rem ({}/{}/{}): {b}\n",.{byte_index,bit_index,nthbit, self.buf.items});

    // remove the bit from the byte
    const bits_after_deleted_idx = self.buf.items[byte_index] & ~((@as(u8,1) << bit_index) - 1);
    const bits_before_deleted_idx = self.buf.items[byte_index] & ((@as(u8,1) << bit_index) - 1);
    // std.debug.print("rem: {b}\n",.{self.buf.items[byte_index]});
    self.buf.items[byte_index] = (bits_after_deleted_idx >> 1) | bits_before_deleted_idx;
    //std.debug.print("rem({}): {b}\n",.{bit_index,self.buf.items[byte_index]});
    
    // shift the bit array to the left from the removed byte
    if (self.shiftBackwardsFromByteIndex(byte_index + 1)) |shift_bit| {
      // std.debug.print("shift: {}\n", .{shift_bit});
      self.buf.items[byte_index] |= (shift_bit << 7);
    }
    self.bit_length -= 1;
    
    return @intCast(removed_bit);
  }
  
  fn shiftBackwardsFromByteIndex(self: *BitArrayUnmanaged, byte_index: usize) ?u8 {
    var shift_bit: u8 = 0;
    var retval: ?u8 = null;
    var i = self.buf.items.len - 1;
    while (i >= byte_index) {
      const this_byte_shift_bit = self.buf.items[i] & 1;
      retval = this_byte_shift_bit;
      self.buf.items[i] >>= 1;
      self.buf.items[i] &= ~(@as(u8, 1) << 7);
      self.buf.items[i] |= shift_bit << 7;
      shift_bit = this_byte_shift_bit;
      i -= 1;
    }
    return retval;
  }
  
  pub fn insert(self: *BitArrayUnmanaged, allocator: std.mem.Allocator, nthbit: usize, b: u1) !void {
    const byte_index = nthbit >> 3;
    
    // std.debug.print("ins before: {b}\n",.{self.buf.items});
    // defer std.debug.print("ins({},{}): {b}\n",.{byte_index, nthbit, self.buf.items});
    
    if (byte_index >= self.buf.items.len) {
      try self.set(allocator, nthbit, b);
      return;
    }
    const bit_index: u3 = @intCast(nthbit & 7);
    const shift_bit: u1 = @intCast((self.buf.items[byte_index] >> 7) & 1);
    const bits_after_insert_idx = self.buf.items[byte_index] & ~((@as(u8,1) << bit_index) - 1);
    const bits_before_insert_idx = self.buf.items[byte_index] & ((@as(u8,1) << bit_index) - 1);
    self.buf.items[byte_index] = (
      (bits_after_insert_idx << 1) |
      (@as(u8, b) << bit_index) |
      bits_before_insert_idx
    );
    const last_shift_bit = self.shiftForwardsFromByteIndex(byte_index + 1, shift_bit);
    const byte_index_of_new_bit = (self.bit_length + 1) >> 3;
    if (byte_index_of_new_bit == self.buf.items.len) {
      // std.debug.print("append {}\n", .{byte_index_of_new_bit});
      try self.buf.append(allocator, last_shift_bit);
    }
    self.bit_length += 1;
  }
  
  fn shiftForwardsFromByteIndex(self: *BitArrayUnmanaged, byte_index: usize, init_shift_bit: u1) u8 {
    var shift_bit: u8 = @intCast(init_shift_bit);
    for (self.buf.items[byte_index..]) |*el| {
      const this_byte_shift_bit = (el.* >> 7) & 1;
      el.* <<= 1;
      el.* |= shift_bit;
      shift_bit = this_byte_shift_bit;
    }
    return shift_bit;
  }
};

pub const LineInfoList = struct {  
  alloc_gpa: std.heap.GeneralPurposeAllocator(.{}),
  
  /// Logical offsets to start of lines. These offsets are defined based on
  /// positions within the logical text buffer above.
  /// These offsets do contain the newline character.
  offsets: std.ArrayListUnmanaged(u32),
  
  /// Bit set to store whether line has multibyte characters
  multibyte_bits: BitArrayUnmanaged,
  
  pub fn init() !LineInfoList {
    var alloc_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const allocator: std.mem.Allocator = alloc_gpa.allocator();
    
    var offsets = try std.ArrayListUnmanaged(u32).initCapacity(allocator, 1);
    try offsets.append(allocator, 0);
    
    const multibyte_bits = try BitArrayUnmanaged.initCapacity(allocator, 1);
    
    return LineInfoList {
      .alloc_gpa = alloc_gpa,
      .offsets = offsets,
      .multibyte_bits = multibyte_bits,
    };
  }

  fn allocr(self: *LineInfoList) std.mem.Allocator {
    return self.alloc_gpa.allocator();
  }
  
  pub fn getLen(self: *const LineInfoList) u32 {
    return @intCast(self.offsets.items.len);
  }
  
  pub fn getOffset(self: *const LineInfoList, idx: u32) u32 {
    return self.offsets.items[idx];
  }
  
  pub fn checkIsMultibyte(self: *const LineInfoList, idx: u32) bool {
    return self.multibyte_bits.get(idx) == 1;
  }
  
  pub fn clear(self: *LineInfoList) void {
    self.offsets.clearRetainingCapacity();
    self.multibyte_bits.clearRetainingCapacity();
  }
  
  pub fn remove(self: *LineInfoList, idx: u32) void {
    _ = self.offsets.orderedRemove(idx);
    _ = self.multibyte_bits.remove(idx);
  }
  
  pub fn shrinkRetainingCapacity(self: *LineInfoList, len: u32) void {
    self.offsets.shrinkRetainingCapacity(len);
    self.multibyte_bits.shrinkRetainingCapacity(len);
  }
  
  pub fn append(self: *LineInfoList, offset: u32) !void {
    try self.offsets.append(self.allocr(), offset);
  }
  
  pub fn setMultibyte(self: *LineInfoList, idx: u32, is_multibyte: bool) !void {
    try self.multibyte_bits.set(self.allocr(), idx, if (is_multibyte) 1 else 0);
  }
  
  pub fn insert(self: *LineInfoList, idx: u32, offset: u32, is_multibyte: bool) !void {
    try self.offsets.insert(self.allocr(), idx, offset);
    try self.multibyte_bits.insert(self.allocr(), idx, if (is_multibyte) 1 else 0);
  }
  
  pub fn insertSlice(
    self: *LineInfoList,
    idx: u32,
    slice: []const u32,
  ) !void {
    try self.offsets.insertSlice(self.allocr(), idx, slice);
    for (0..slice.len) |_| {
      try self.multibyte_bits.insert(self.allocr(), idx, 0);
    }
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
  
  fn moveTail(self: *LineInfoList, line_pivot_dest: u32, line_pivot_src: u32) void {
    const new_len = self.offsets.items.len - (line_pivot_src - line_pivot_dest);
    std.mem.copyForwards(
      u32,
      self.offsets.items[line_pivot_dest..new_len],
      self.offsets.items[line_pivot_src..]
    );
    self.offsets.shrinkRetainingCapacity(new_len);
    
    const n_deleted = line_pivot_src - line_pivot_dest;
    for(0..n_deleted) |_| {
      _ = self.multibyte_bits.remove(line_pivot_dest);
    }
  }
  
  /// Remove the lines specified in range
  pub fn removeLinesInRange(
    self: *LineInfoList,
    delete_start: u32, delete_end: u32
  ) u32 {
    const line_start = self.findMinLineAfterOffset(delete_start);
    if (line_start == self.getLen()) {
      // region starts in last line
      return line_start - 1;
    }
    
    const line_end = self.findMinLineAfterOffset(delete_end);
    if (line_end == self.getLen()) {
      // region ends at last line
      self.offsets.shrinkRetainingCapacity(line_start);
      return line_start - 1;
    }
    
    std.debug.assert(self.offsets.items[line_start] > delete_start);
    std.debug.assert(self.offsets.items[line_end] > delete_end);
    
    const chars_deleted = delete_end - delete_start;
    
    for (self.offsets.items[line_end..]) |*offset| {
      offset.* -= chars_deleted;
    }
    
    // remove the line offsets between the region
    self.moveTail(line_start, line_end);
    
    return line_start - 1;
  }
};
