//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//

// This file implements a virtual machine used to execute regular expressions
// as described in the following article:
//
//   https://swtch.com/~rsc/regexp/regexp2.html
//
// The virtual machine is a simple backtracking-based implementation, with a
// few optimizations to help reduce memory usage:
//
//   * Threads are stored in a run-length encoded stack, to handle the simple
//     repetitions.
//   * The thread stack can either be stored on the hardware stack, or the heap
//     depending on the number of threads being ran.

const Expr = @This();

const std = @import("std");
const builtin = @import("builtin");
const Instr = @import("./instr.zig").Instr;
const Parser = @import("./parser.zig");

pub const CreateErrorType = error {
  EmptyRegex,
  OutOfMemory,
  InvalidUtf8,
  ExpectedSimpleExpr,
  ExpectedEscapeBeforeDashInRange,
  UnbalancedGroupBrackets,
};

pub const CreateError = struct {
  type: CreateErrorType,
  pos: usize,
};

pub const CreateResult = union(enum) {
  ok: Expr,
  err: CreateError,
  
  fn asErr(self: CreateResult) !Expr {
    switch(self) {
      .ok => |expr| { return expr; },
      .err => |err| { return err.type; },
    }
  }
};

instrs: std.ArrayListUnmanaged(Instr),
num_groups: usize,

pub fn debugPrint(self: *const Expr) void {
  for (0..self.instrs.items.len) |i| {
    std.debug.print("{} {}\n", .{i, self.instrs.items[i]});
  }
}

pub fn deinit(self: *Expr, allocr: std.mem.Allocator) void {
  for (self.instrs.items) |*instr| {
    instr.deinit(allocr);
  }
  self.instrs.deinit(allocr);
}

pub const Flags = struct {
  multiline: bool = false,
};

pub fn create(
  allocr: std.mem.Allocator,
  in_pattern: []const u8,
  flags: Flags,
) CreateResult {
  if (in_pattern.len == 0) {
    return .{
      .err = .{ .type = error.EmptyRegex, .pos = 0, },
    };
  }
  var parser: Parser = .{
    .in_pattern = in_pattern,
    .flags = flags,
  };
  if (parser.parse(allocr)) |expr| {
    return .{ .ok = expr, };
  } else |err| {
    switch (err) {
      error.OutOfMemory => {
        return .{
          .err = .{
            .type = error.OutOfMemory,
            .pos = 0,
          },
        };
      },
      error.Utf8InvalidStartByte,
      error.Utf8ExpectedContinuation,
      error.Utf8OverlongEncoding,
      error.Utf8EncodesSurrogateHalf,
      error.Utf8CodepointTooLarge => {
        return .{
          .err = .{
            .type = error.InvalidUtf8,
            .pos = parser.str_idx,
          },
        };
      },
      error.ExpectedSimpleExpr,
      error.ExpectedEscapeBeforeDashInRange,
      error.UnbalancedGroupBrackets => |suberr| {
        return .{
          .err = .{
            .type = @errorCast(suberr),
            .pos = parser.str_idx,
          },
        };
      },
    }
  }
}

const VM = struct {
  const Thread = struct {
    str_idx: usize,
    pc: usize,
    str_idx_delta: u32 = 0,
    str_idx_repeats: u32 = 0,
  };
  
  const ThreadStack = struct {
    const HEAP_THRESHOLD = 16;
    
    const Internal = union(enum) {
      stackalloc: std.BoundedArray(Thread, HEAP_THRESHOLD),
      heapalloc: std.ArrayListUnmanaged(Thread),
    };
    
    internal: Internal = .{
      .stackalloc = .{},
    },
    
    fn deinit(self: *ThreadStack, allocr: std.mem.Allocator) void {
      switch (self.internal) {
        .heapalloc => |*heapalloc| { heapalloc.deinit(allocr); },
        else => {},
      }
    }
    
    fn append(
      self: *ThreadStack,
      allocr: std.mem.Allocator,
      str_idx: usize,
      pc: usize,
    ) !void {
      const thread: Thread = .{
        .str_idx = str_idx,
        .pc = pc,
      };
      var opt_new_heapalloc: ?std.ArrayListUnmanaged(Thread) = null;
      switch (self.internal) {
        .stackalloc => |*stackalloc| {
          if (stackalloc.append(thread)) {
            return;
          } else |_| {
            var heapalloc = try std.ArrayListUnmanaged(Thread)
              .initCapacity(allocr, HEAP_THRESHOLD+1);
            try heapalloc.appendSlice(allocr, stackalloc.constSlice());
            opt_new_heapalloc = heapalloc;
          }
        },
        else => {},
      }
      if (opt_new_heapalloc) |new_heapalloc| {
        self.internal = .{ .heapalloc = new_heapalloc, };
      }
      try self.internal.heapalloc.append(allocr, thread);
    }
    
    fn len(self: *ThreadStack) usize {
      switch (self.internal) {
        .stackalloc => |*stackalloc| { return stackalloc.len; },
        .heapalloc => |*heapalloc| { return heapalloc.items.len; },
      }
    }
    
    fn top(self: *ThreadStack) ?*Thread {
      switch (self.internal) {
        .stackalloc => |*stackalloc| {
          if (stackalloc.len > 0) {
            return &stackalloc.buffer[stackalloc.len - 1];
          }
        },
        .heapalloc => |*heapalloc| {
          if (heapalloc.items.len > 0) {
            return &heapalloc.items[heapalloc.items.len - 1];
          }
        },
      }
      return null;
    }
    
    fn pop(self: *ThreadStack) Thread {
      switch (self.internal) {
        .stackalloc => |*stackalloc| {
          return stackalloc.pop();
        },
        .heapalloc => |*heapalloc| {
          return heapalloc.pop();
        },
      }
    }
  };
  
  haystack: []const u8,
  instrs: []const Instr,
  options: *const MatchOptions,
  allocr: std.mem.Allocator,
  thread_stack: ThreadStack = .{},
  fully_matched: bool = false,
  
  fn deinit(self: *VM) void {
    self.thread_stack.deinit(self.allocr);
  }
  
  const NextInstrResult = enum {
    Stop,
    Continue,
    Matched,
  };
  
  fn nextInstr(self: *VM, thread: *const Thread) !void {
    // std.debug.print("{s}\n", .{self.haystack[thread.str_idx..]});
    // std.debug.print(">>> {} {}\n", .{thread.pc,self.instrs[thread.pc]});
    // std.debug.print("{any}\n", .{self.thread_stack.items});
    switch (self.instrs[thread.pc]) {
      .abort => {
        @panic("abort opcode reached");
      },
      .matched => {
        self.fully_matched = true;
        return;
      },
      .any, .char, .char_inverse, .range, .range_inverse => {
        if (thread.str_idx >= self.haystack.len) {
          return;
        }
        const seqlen = try std.unicode.utf8ByteSequenceLength(
          self.haystack[thread.str_idx]
        );
        if ((self.haystack.len - thread.str_idx) < seqlen) {
          return error.Utf8ExpectedContinuation;
        }
        const char: u32 = try std.unicode.utf8Decode(
          self.haystack[thread.str_idx..(thread.str_idx+seqlen)]
        );
        switch (self.instrs[thread.pc]) {
          .any => {},
          .char => |char1| {
            if (char != char1) {
              return;
            }
          },
          .char_inverse => |char1| {
            if (char == char1) {
              return;
            }
          },
          .range => |ranges| {
            var matches = false;
            for (ranges) |range| {
              if (range.from <= char and range.to >= char) {
                matches = true;
                break;
              }
            }
            if (!matches) {
              return;
            }
          },
          .range_inverse => |ranges| {
            for (ranges) |range| {
              if (range.from <= char and range.to >= char) {
                return;
              }
            }
          },
          else => unreachable,
        }
        try self.addThread(thread.str_idx + seqlen, thread.pc + 1);
        return;
      },
      .string => {
        // string is only here for optimizing find calls
        @panic("should be handled in exec");
      },
      .jmp => |target| {
        try self.addThread(thread.str_idx, target);
        return;
      },
      .split => |split| {
        try self.addThread(thread.str_idx, split.a);
        try self.addThread(thread.str_idx, split.b);
        return;
      },
      .group_start => |group_id| {
        if (self.options.group_out) |group_out| {
          group_out[group_id].start = thread.str_idx;
        }
        try self.addThread(thread.str_idx, thread.pc + 1);
        return;
      },
      .group_end => |group_id| {
        if (self.options.group_out) |group_out| {
          group_out[group_id].end = thread.str_idx;
        }
        try self.addThread(thread.str_idx, thread.pc + 1);
        return;
      },
    }
  }
  
  fn addThread(self: *VM, str_idx: usize, pc: usize) !void {
    if (self.thread_stack.top()) |top| {
      // run length encode the thread stack so that less memory is used
      // when greedy matching repetitive groups of characters
      if (top.pc == pc) {
        if (top.str_idx_delta == 0) {
          top.str_idx_delta = @intCast(str_idx - top.str_idx);
          top.str_idx_repeats = 1;
          return;
        } else if (
          str_idx > top.str_idx and
          (top.str_idx + top.str_idx_delta * top.str_idx_repeats) == str_idx
        ) {
          top.str_idx_repeats += 1;
          return;
        }
      }
    }
    try self.thread_stack.append(self.allocr, str_idx, pc);
  }
  
  fn popThread(self: *VM) !Thread {
    var top: *Thread = self.thread_stack.top().?;
    if (top.str_idx_delta == 0) {
      return self.thread_stack.pop();
    }
    var ret_thread: Thread = top.*;
    ret_thread.str_idx = top.str_idx + top.str_idx_delta * top.str_idx_repeats;
    if (top.str_idx_repeats > 0) {
      top.str_idx_repeats -= 1;
    } else {
      _ = self.thread_stack.pop();
    }
    return ret_thread;
  }
  
  fn exec(self: *VM) !MatchResult {
    if (self.instrs[0].getString()) |string| {
      var str_idx: usize = 0;
      for (0..string.len) |i| {
        if (str_idx == self.haystack.len) {
          return .{ .pos = str_idx, .fully_matched = false };
        }
        if (self.haystack[str_idx] == string[i]) {
          str_idx += 1;
        } else {
          return .{ .pos = str_idx, .fully_matched = false };
        }
      }
      try self.thread_stack.append(self.allocr, str_idx, 1);
    } else {
      try self.thread_stack.append(self.allocr, 0, 0);
    }
    while (true) {
      const thread = try self.popThread();
      try self.nextInstr(&thread);
      if (self.thread_stack.len() == 0 or self.fully_matched) {
        return .{
          .pos = thread.str_idx,
          .fully_matched = self.fully_matched,
        };
      }
      // _ = std.io.getStdIn().reader().readByte() catch {};
    }
  }
};

pub const MatchResult = struct {
  pos: usize,
  fully_matched: bool,
};

pub const MatchGroup = struct {
  start: usize = 0,
  end: usize = 0,
};

pub const MatchOptions = struct {
  group_out: ?[]MatchGroup = null,
};

pub const MatchError = error {
  OutOfMemory,
  InvalidGroupSize,
  InvalidUtf8,
};

pub fn checkMatch(
  self: *const Expr,
  allocr: std.mem.Allocator,
  haystack: []const u8,
  options: MatchOptions,
) MatchError!MatchResult {
  if (options.group_out) |group_out| {
    if (group_out.len != self.num_groups) {
      return error.InvalidGroupSize;
    }
  }
  var vm: VM = .{
    .haystack = haystack,
    .instrs = self.instrs.items,
    .options = &options,
    .allocr = allocr,
  };
  defer vm.deinit();
  return vm.exec() catch |err| {
    switch(err) {
      error.Utf8InvalidStartByte,
      error.Utf8ExpectedContinuation,
      error.Utf8OverlongEncoding,
      error.Utf8EncodesSurrogateHalf,
      error.Utf8CodepointTooLarge => {
        return error.InvalidUtf8;
      },
      error.OutOfMemory => |suberr| {
        return suberr;
      },
    }
  };
}

pub const FindResult = struct {
  start: usize,
  end: usize,
};

pub fn find(self: *const Expr, allocr: std.mem.Allocator, haystack: []const u8) !?FindResult {
  if (self.instrs.items[0].getString()) |string| {
    var skip: usize = 0;
    while (std.mem.indexOf(u8, haystack[skip..], string)) |rel_skip| {
      skip += rel_skip;
      const match = try self.checkMatch(allocr, haystack[skip..], .{});
      if (match.fully_matched) {
        return .{
          .start = skip,
          .end = skip + match.pos,
        };
      }
      skip += string.len;
    }
    return null;
  }
  
  for (0..haystack.len-1) |skip| {
    const match = try self.checkMatch(allocr, haystack[skip..], .{});
    if (match.fully_matched) {
      return .{
        .start = skip,
        .end = skip + match.pos,
      };
    }
  }
  return null;
}

pub fn findBackwards(self: *const Expr, allocr: std.mem.Allocator, haystack: []const u8) !?FindResult {
  if (self.instrs.items[0].getString()) |string| {
    var limit: usize = haystack.len;
    while (std.mem.lastIndexOf(u8, haystack[0..limit], string)) |rel_limit| {
      limit = rel_limit;
      const match = try self.checkMatch(allocr, haystack[rel_limit..], .{});
      if (match.fully_matched) {
        return .{
          .start = rel_limit,
          .end = rel_limit + match.pos,
        };
      }
      limit -= 1;
    }
    return null;
  }
  
  var skip_it: usize = haystack.len;
  while (skip_it > 0) {
    const skip = skip_it - 1;
    const match = try self.checkMatch(allocr, haystack[skip..], .{});
    if (match.fully_matched) {
      return .{
        .start = skip,
        .end = skip + match.pos,
      };
    }
    skip_it -= 1;
  }
  return null;
}

test "simple one" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "asdf", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(4, (try expr.checkMatch(allocr, "asdf", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "as", .{})).pos);
}

test "any" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "..", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "a", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "as", .{})).pos);
}

test "simple more than one" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "a+", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "a", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "aa", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "aba", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "aad", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "daa", .{})).pos);
}

test "group more than one" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(ab)+", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "ab", .{})).pos);
  try std.testing.expectEqual(4, (try expr.checkMatch(allocr, "abab", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "dab", .{})).pos);
}

test "group nested more than one" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(ax+b)+", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "axb", .{})).pos);
  try std.testing.expectEqual(6, (try expr.checkMatch(allocr, "axbaxb", .{})).pos);
  try std.testing.expectEqual(7, (try expr.checkMatch(allocr, "axxbaxb", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "ab", .{})).pos);
}

test "simple zero or more" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "a*b", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "ab", .{})).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "aab", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "aba", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "aad", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "daa", .{})).pos);
}

test "simple greedy zero or more" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "x.*b", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "xb", .{})).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "xab", .{})).pos);
  try std.testing.expectEqual(4, (try expr.checkMatch(allocr, "xaab", .{})).pos);
  try std.testing.expectEqual(8, (try expr.checkMatch(allocr, "xaabxaab", .{})).pos);
}

test "group zero or more" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(ab)*c", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "c", .{})).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "abc", .{})).pos);
  try std.testing.expectEqual(5, (try expr.checkMatch(allocr, "ababc", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "xab", .{})).pos);
}

test "group nested zero or more" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(a(xy)*b)*c", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "c", .{})).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "abc", .{})).pos);
  try std.testing.expectEqual(5, (try expr.checkMatch(allocr, "ababc", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "xab", .{})).pos);
  try std.testing.expectEqual(7, (try expr.checkMatch(allocr, "axybabc", .{})).pos);
  try std.testing.expectEqual(9, (try expr.checkMatch(allocr, "axybaxybc", .{})).pos);
}

test "simple optional" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "a?b", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "ab", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "aba", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "db", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "b", .{})).pos);
}

test "group optional" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(ab)?c", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "abc", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "c", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "b", .{})).pos);
}

test "group nested optional" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(a(xy)?b)?c", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "abc", .{})).pos);
  try std.testing.expectEqual(5, (try expr.checkMatch(allocr, "axybc", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "axbc", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "c", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "b", .{})).pos);
}

test "simple lazy zero or more" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "x.-b", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "xb", .{})).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "xab", .{})).pos);
  try std.testing.expectEqual(4, (try expr.checkMatch(allocr, "xaab", .{})).pos);
  try std.testing.expectEqual(4, (try expr.checkMatch(allocr, "xaabxaab", .{})).pos);
}

test "simple range" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "[a-z]+", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "ab0", .{})).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "aba0", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "db0", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "x0", .{})).pos);
}

test "simple range inverse" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "[^b]", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "0", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "b", .{})).pos);
}

test "group" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "([a-z]*)([A-Z]+)", .{}).asErr();
  defer expr.deinit(allocr);
  var groups = [1]MatchGroup{.{}} ** 2;
  const opts: MatchOptions = .{ .group_out = &groups, };
  try std.testing.expectEqual(4, (try expr.checkMatch(allocr, "abAB0", opts)).pos);
  try std.testing.expectEqual(0, groups[0].start);
  try std.testing.expectEqual(2, groups[0].end);
  try std.testing.expectEqual(2, groups[1].start);
  try std.testing.expectEqual(4, groups[1].end);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "AB0", opts)).pos);
  try std.testing.expectEqual(0, groups[0].start);
  try std.testing.expectEqual(0, groups[0].end);
  try std.testing.expectEqual(0, groups[1].start);
  try std.testing.expectEqual(2, groups[1].end);
}

test "simple alternate" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "[a-z]+|[A-Z]+", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "ab", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "AB", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "aB", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "00", .{})).pos);
}

test "group alternate" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(a|z)(b|c)", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "ab", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "az", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "zc", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "c", .{})).pos);
}

test "integrate: string" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(
    allocr,
    \\"([^"]|\\.)*"
    , .{}
  ).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, \\"a"
                                                      , .{})).pos);
  try std.testing.expectEqual(4, (try expr.checkMatch(allocr, \\"\\"
                                                      , .{})).pos);
  try std.testing.expectEqual(4, (try expr.checkMatch(allocr, \\"ab"
                                                      , .{})).pos);
  try std.testing.expectEqual(6, (try expr.checkMatch(allocr, \\"\"\""
                                                      , .{})).pos);
}

test "integrate: huge simple" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "a+", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1000, (try expr.checkMatch(allocr, 
    &([_]u8{'a'}**1000), .{}
  )).pos);
}

test "integrate: huge group" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(ab)+", .{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1000, (try expr.checkMatch(allocr, 
    &([_]u8{'a','b'}**500), .{}
  )).pos);
}

test "find (1st pat el is string)" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "asdf?b", .{}).asErr();
  defer expr.deinit(allocr);
  {
    const res = (try expr.find(allocr, "000asdfbasdfb")).?;
    try std.testing.expectEqual(3, res.start);
    try std.testing.expectEqual(8, res.end);
  }
  {
    const res = (try expr.find(allocr, "000asdbasdfb")).?;
    try std.testing.expectEqual(3, res.start);
    try std.testing.expectEqual(7, res.end);
  }
}

test "find (1st pat el is char, more than one)" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "xab+", .{}).asErr();
  defer expr.deinit(allocr);
  {
    const res = (try expr.find(allocr, "xabb")).?;
    try std.testing.expectEqual(0, res.start);
    try std.testing.expectEqual(4, res.end);
  }
}

test "find (1st pat el is char)" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "x+asdf?b", .{}).asErr();
  defer expr.deinit(allocr);
  {
    const res = (try expr.find(allocr, "000xxxasdfbasdfb")).?;
    try std.testing.expectEqual(3, res.start);
    try std.testing.expectEqual(11, res.end);
  }
  {
    const res = (try expr.find(allocr, "000xxxasdbasdfb")).?;
    try std.testing.expectEqual(3, res.start);
    try std.testing.expectEqual(10, res.end);
  }
}

test "find reverse (1st pat el is string)" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "asdf?b", .{}).asErr();
  defer expr.deinit(allocr);
  {
    const res = (try expr.findBackwards(allocr, "000asdfbasdfb")).?;
    try std.testing.expectEqual(8, res.start);
    try std.testing.expectEqual(13, res.end);
  }
}

test "find reverse (1st pat el is char)" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "x+asdf?b", .{}).asErr();
  defer expr.deinit(allocr);
  {
    const res = (try expr.findBackwards(allocr, "000xxxasdfbasdfbxxxasdfb")).?;
    try std.testing.expectEqual(18, res.start);
    try std.testing.expectEqual(24, res.end);
  }
}