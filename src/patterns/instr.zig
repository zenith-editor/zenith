const std = @import("std");

pub const Instr = union(enum) {
  pub const Range = struct {
    from: u32,
    to: u32,
  };
  
  /// Finish matching
  matched: void,
  /// Tries to consume a char, backtracks if fails
  char: u32,
  /// Tries to consume a char in range, backtracks if fails
  range: []Range,
  /// Tries to consume a string, exit if fails
  string: []u8,
  /// Sets the program counter
  jmp: usize,
  /// Pushes backtrack target to stack
  backtrack_target: usize,
  /// Consumes backtrack target from the top of the stack
  consume_backtrack: void,
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
      .char, .range => true,
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
  
  pub fn getPcPtr(self: *Instr) ?*usize {
    return switch(self.*) {
      .jmp => |*pc| pc,
      .backtrack_target => |*pc| pc,
      else => null,
    };
  }
  
  pub fn incrPc(self: *Instr, shifted: usize) void {
    if (self.getPcPtr()) |pc| {
      pc.* += shifted;
    }
  }
  
  pub fn decrPc(self: *Instr, shifted: usize) void {
    if (self.getPcPtr()) |pc| {
      pc.* -= shifted;
    }
  }
};