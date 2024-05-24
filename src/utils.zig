//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");

/// Find the last element whose field <= value
pub fn findLastNearestElement(
  comptime T: type,
  comptime field: []const u8,
  items: []const T,
  value: anytype,
  from: usize,
) ?usize {
  if (items.len == 0) {
    return null;
  }
  
  var left: usize = from;
  var right: usize = items.len;
  
  while (left < right) {
    const mid = left + (right - left) / 2;
    if (@field(items[mid], field) < value) {
      left = mid + 1;
    } else {
      right = mid;
    }
  }
  
  if (left == items.len) {
    return items.len - 1;
  }
  
  if (@field(items[left], field) > value) {
    if (left == 0) {
      return null;
    }
    return left - 1;
  }
  
  return left;
}

test findLastNearestElement {
  const S = struct {
    const Self = @This();
    
    pos: usize,
    
    fn findLastNearest(items: []const Self, value: usize, from: usize) ?usize {
      return findLastNearestElement(Self, "pos", items, value, from);
    }
  };
  
  const items = [_]S{
    .{ .pos = 1, },
    .{ .pos = 3, },
    .{ .pos = 4, },
    .{ .pos = 6, },
    .{ .pos = 8, },
  };
  
  try std.testing.expectEqual(null, S.findLastNearest(&items, 0, 0));
  try std.testing.expectEqual(0, S.findLastNearest(&items, 1, 0));
  try std.testing.expectEqual(0, S.findLastNearest(&items, 2, 0));
  try std.testing.expectEqual(2, S.findLastNearest(&items, 4, 0));
  try std.testing.expectEqual(3, S.findLastNearest(&items, 7, 0));
  try std.testing.expectEqual(4, S.findLastNearest(&items, 10, 0));
  
  try std.testing.expectEqual(0, S.findLastNearest(&items, 2, 1));
  try std.testing.expectEqual(2, S.findLastNearest(&items, 5, 1));
  try std.testing.expectEqual(3, S.findLastNearest(&items, 7, 1));
  try std.testing.expectEqual(4, S.findLastNearest(&items, 8, 1));
  try std.testing.expectEqual(4, S.findLastNearest(&items, 10, 1));
}

/// Find the next element whose field > value
pub fn findNextNearestElement(
  comptime T: type,
  comptime field: []const u8,
  items: []const T,
  value: anytype,
  from: usize,
) usize {
  var left: usize = from;
  var right: usize = items.len;
  
  while (left < right) {
    const mid = left + (right - left) / 2;
    if (@field(items[mid], field) > value) {
      right = mid;
    } else {
      left = mid + 1;
    }
  }
  
  return right;
}

test findNextNearestElement {
  const S = struct {
    const Self = @This();
    
    pos: usize,
    
    fn findNextNearest(items: []const Self, value: usize, from: usize) ?usize {
      return findNextNearestElement(Self, "pos", items, value, from);
    }
  };
  
  const items = [_]S{
    .{ .pos = 1, },
    .{ .pos = 3, },
    .{ .pos = 4, },
    .{ .pos = 6, },
    .{ .pos = 8, },
  };
  
  try std.testing.expectEqual(0, S.findNextNearest(&items, 0, 0));
  try std.testing.expectEqual(1, S.findNextNearest(&items, 1, 0));
  try std.testing.expectEqual(1, S.findNextNearest(&items, 2, 0));
  try std.testing.expectEqual(3, S.findNextNearest(&items, 4, 0));
  try std.testing.expectEqual(4, S.findNextNearest(&items, 7, 0));
  try std.testing.expectEqual(5, S.findNextNearest(&items, 10, 0));
  
  try std.testing.expectEqual(1, S.findNextNearest(&items, 2, 1));
  try std.testing.expectEqual(3, S.findNextNearest(&items, 4, 1));
  try std.testing.expectEqual(4, S.findNextNearest(&items, 7, 1));
  try std.testing.expectEqual(5, S.findNextNearest(&items, 10, 1));
}

pub fn lessThanStr(_: void, lhs: []const u8, rhs: []const u8) bool {
  return std.mem.order(u8, lhs, rhs) == .lt;
}
