//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");

pub const Instr = union(enum) {
  pub const Range = struct {
    from: u32,
    to: u32,
  };
  
  pub const Split = struct {
    a: usize,
    b: usize,
  };
  
  /// Abort. Functions as a filler instruction for codegen.
  abort: void,
  /// Finish matching
  matched: void,
  /// Tries to consume any char
  any: void,
  /// Tries to consume a char
  char: u32,
  /// Tries to consume any char, except for specified one
  char_inverse: u32,
  /// Tries to consume a char in range
  range: []Range,
  /// Tries to consume a char not in range
  range_inverse: []Range,
  /// Tries to consume a string, exit if fails
  string: []u8,
  /// Sets the program counter
  jmp: usize,
  /// Splits execution
  split: Split,
  /// Record start of the captured slice into specified group
  group_start: usize,
  /// Record end of the captured slice into specified group
  group_end: usize,
  
  pub fn deinit(self: *Instr, allocr: std.mem.Allocator) void {
    switch(self.*) {
      .range => |ptr| allocr.free(ptr),
      .string => |ptr| allocr.free(ptr),
      else => {},
    }
  }
  
  pub fn isSimpleMatcher(self: *const Instr) bool {
    return switch(self.*) {
      .char, .range, .range_inverse => true,
      else => false,
    };
  }
  
  pub fn isChar(self: *const Instr) bool {
    return switch(self.*) {
      .char => true,
      else => false,
    };
  }
  
  pub fn getString(self: *const Instr) ?[]u8 {
    return switch(self.*) {
      .string => |string| string,
      else => null,
    };
  }
  
  pub fn incrPc(self: *Instr, shifted: usize, from_pc: usize) void {
    switch(self.*) {
      .jmp => |*pc| {
        if (pc.* >= from_pc) {
          pc.* += shifted;
        }
      },
      .split => |*split| {
        if (split.a >= from_pc) {
          split.a += shifted;
        }
        if (split.b >= from_pc) {
          split.b += shifted;
        }
      },
      else => {},
    }
  }
};