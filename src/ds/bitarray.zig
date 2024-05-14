//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//

const std = @import("std");

/// Custom implementation of a dynamically backed bit set.
/// This is used to store whether a line in a document
/// contains multi-byte strings.
/// The class contains a few special insertion/bit shift functions
/// which are not present in DynamicBitSet in the standard library.
pub const BitArray = struct {
  const Self = @This();
  
  buf: std.ArrayListUnmanaged(u8) = .{},
  bit_length: usize = 0,

  pub fn initCapacity(allocator: std.mem.Allocator, bits: usize) !Self {
    return .{
      .buf = try std.ArrayListUnmanaged(u8).initCapacity(allocator, (bits >> 3) + 1),
    };
  }

  pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.buf.deinit(allocator);
  }

  pub fn get(self: *const Self, nthbit: usize) u1 {
    const byte_index = nthbit >> 3;
    if (byte_index >= self.buf.items.len) {
      return 0;
    }
    const bit_index: u3 = @intCast(nthbit & 7);
    const bin: u8 = (self.buf.items[byte_index] >> bit_index) & 1;
    return @intCast(bin);
  }

  pub fn set(self: *Self, allocator: std.mem.Allocator, nthbit: usize, b: u1) !void {
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

  pub fn clearRetainingCapacity(self: *Self) void {
    self.buf.clearRetainingCapacity();
  }

  pub fn shrinkRetainingCapacity(self: *Self, nbits: usize) void {
    const byte_index = nbits >> 3;
    self.buf.shrinkRetainingCapacity(byte_index + 1);
    self.bit_length = nbits;
  }

  pub fn remove(self: *Self, nthbit: usize) u1 {
    const byte_index = nthbit >> 3;
    if (byte_index >= self.buf.items.len) {
      return 0;
    }
    const bit_index: u3 = @intCast(nthbit & 7);
    const removed_bit = (self.buf.items[byte_index] >> bit_index) & 1;
    
    // remove the bit from the byte
    const bits_after_deleted_idx = self.buf.items[byte_index] & ~((@as(u8,1) << bit_index) - 1);
    const bits_before_deleted_idx = self.buf.items[byte_index] & ((@as(u8,1) << bit_index) - 1);
    self.buf.items[byte_index] = (bits_after_deleted_idx >> 1) | bits_before_deleted_idx;
    
    // shift the bit array to the left from the removed byte
    if (self.shiftBackwardsFromByteIndex(byte_index + 1)) |shift_bit| {
      self.buf.items[byte_index] |= (shift_bit << 7);
    }
    self.bit_length -= 1;
    
    return @intCast(removed_bit);
  }

  fn shiftBackwardsFromByteIndex(self: *Self, byte_index: usize) ?u8 {
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

  pub fn insert(self: *Self, allocator: std.mem.Allocator, nthbit: usize, b: u1) !void {
    const byte_index = nthbit >> 3;
    
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
      try self.buf.append(allocator, last_shift_bit);
    }
    self.bit_length += 1;
  }

  fn shiftForwardsFromByteIndex(self: *Self, byte_index: usize, init_shift_bit: u1) u8 {
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