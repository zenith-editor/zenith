//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//

const std = @import("std");

pub fn Rc(comptime T: type) type {
  return struct {
    const Self = @This();
    
    const Inner = struct {
      count: usize,
      data: T,
      
    };
    
    inner: *Inner,
    
    pub fn create(allocr: std.mem.Allocator, data: *T) !Self {
      const inner = try allocr.create(Inner);
      inner.* = .{
        .count = 1,
        .data = data.*,
      };
      data.* = .{};
      return .{ .inner = inner, };
    }
    
    pub fn deinit(self: *Self, allocr: std.mem.Allocator) void {
      self.inner.count -= 1;
      if (self.inner.count == 0) {
        self.inner.data.deinit(allocr);
        allocr.destroy(self.inner);
      }
      self.* = undefined;
    }
    
    pub fn clone(self: *Self) Self {
      self.inner.count += 1;
      return .{
        .inner = self.inner,
      };
    }
    
    pub fn get(self: *const Self) *const T {
      return &self.inner.data;
    }
    
    pub fn getMut(self: *Self) *T {
      return &self.inner.data;
    }
  };
}