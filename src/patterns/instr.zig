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
  
  pub const RangeOpt = struct {
    from: u32,
    to: u32,
    inverse: bool,
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
  /// Tries to consume a char (not) in range (inline optimized ver.)
  range_opt: RangeOpt,
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
      .range, .range_inverse => |ptr| allocr.free(ptr),
      .string => |ptr| allocr.free(ptr),
      else => {},
    }
  }
  
  pub fn isSimpleMatcher(self: *const Instr) bool {
    return switch(self.*) {
      .any, .char, .char_inverse, .range, .range_inverse, .range_opt => true,
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
  
  fn modPc(
    self: *Instr,
    shifted: usize,
    from_pc: usize,
    operation: (*const fn (a: usize, b: usize) usize)
  ) void {
    switch(self.*) {
      .jmp => |*pc| {
        if (pc.* >= from_pc) {
          pc.* = operation(pc.*, shifted);
        }
      },
      .split => |*split| {
        if (split.a >= from_pc) {
          split.a = operation(split.a, shifted);
        }
        if (split.b >= from_pc) {
          split.b = operation(split.b, shifted);
        }
      },
      else => {},
    }
  }
  
  pub fn incrPc(self: *Instr, shifted: usize, from_pc: usize) void {
    return self.modPc(shifted, from_pc, (struct {
      fn operation(a: usize, b: usize) usize {
        return a + b;
      }
    }).operation);
  }
  
  pub fn decrPc(self: *Instr, shifted: usize, from_pc: usize) void {
    return self.modPc(shifted, from_pc, (struct {
      fn operation(a: usize, b: usize) usize {
        return a - b;
      }
    }).operation);
  }
};