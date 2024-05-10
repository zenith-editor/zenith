//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//

// This file implements a virtual machine used to execute regular expressions
// as described in the following article:
//
//   https://swtch.com/~rsc/regexp/regexp2.html

const Expr = @This();

const std = @import("std");
const builtin = @import("builtin");
const Instr = @import("./instr.zig").Instr;
const Parser = @import("./parser.zig");

pub const CreateErrorType = error {
  EmptyRegex,
  OutOfMemory,
  InvalidUnicode,
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

pub fn create(allocr: std.mem.Allocator, in_pattern: []const u8) CreateResult {
  if (in_pattern.len == 0) {
    return .{
      .err = .{ .type = error.EmptyRegex, .pos = 0, },
    };
  }
  var parser: Parser = .{
    .in_pattern = in_pattern,
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
            .type = error.InvalidUnicode,
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
    fully_matched: bool = false,
  };
  
  haystack: []const u8,
  instrs: []const Instr,
  options: *const MatchOptions,
  thread_stack: std.BoundedArray(Thread, 128) = .{},
  
  fn nextInstr(self: *VM, thread: *Thread) !bool {
    // std.debug.print("{s}\n", .{self.haystack[thread.str_idx..]});
    // std.debug.print(">>> {} {}\n", .{thread.pc,self.instrs[thread.pc]});
    // std.debug.print("{any}\n", .{self.thread_stack.slice()});
    switch (self.instrs[thread.pc]) {
      .abort => {
        @panic("abort opcode reached");
      },
      .matched => {
        thread.fully_matched = true;
        return false;
      },
      .any => {
        if (thread.str_idx >= self.haystack.len) {
          return false;
        }
        const seqlen = try std.unicode.utf8ByteSequenceLength(
          self.haystack[thread.str_idx]
        );
        if ((self.haystack.len - thread.str_idx) < seqlen) {
          return error.Utf8ExpectedContinuation;
        }
        thread.pc += 1;
        thread.str_idx += seqlen;
        return true;
      },
      .char => |char1| {
        if (thread.str_idx >= self.haystack.len) {
          return false;
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
        if (char != char1) {
          return false;
        }
        thread.pc += 1;
        thread.str_idx += seqlen;
        return true;
      },
      .range => |ranges| {
        if (thread.str_idx >= self.haystack.len) {
          return false;
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
        var matches = false;
        for (ranges) |range| {
          if (range.from <= char and range.to >= char) {
            matches = true;
            break;
          }
        }
        if (!matches) {
          return false;
        }
        thread.pc += 1;
        thread.str_idx += seqlen;
        return true;
      },
      .range_inverse => |ranges| {
        if (thread.str_idx >= self.haystack.len) {
          return false;
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
        var matches = false;
        for (ranges) |range| {
          if (range.from <= char and range.to >= char) {
            matches = true;
            break;
          }
        }
        if (matches) {
          return false;
        }
        thread.pc += 1;
        thread.str_idx += seqlen;
        return true;
      },
      .string => |string| {
        // string is only here for optimizing find calls
        std.debug.assert(thread.pc == 0);
        
        for (0..string.len) |i| {
          if (thread.str_idx == self.haystack.len) {
            return false;
          }
          if (self.haystack[thread.str_idx] == string[i]) {
            thread.str_idx += 1;
          } else {
            return false;
          }
        }
        
        thread.pc += 1;
        return true;
      },
      .jmp => |target| {
        thread.pc = target;
        return true;
      },
      .split => |split| {
        self.thread_stack.append(.{
          .pc = split.b,
          .str_idx = thread.str_idx,
        }) catch return error.BacktrackOverflow;
        thread.pc = split.a;
        return true;
      },
      .group_start => |group_id| {
        if (self.options.group_out) |group_out| {
          group_out[group_id].start = thread.str_idx;
        }
        thread.pc += 1;
        return true;
      },
      .group_end => |group_id| {
        if (self.options.group_out) |group_out| {
          group_out[group_id].end = thread.str_idx;
        }
        thread.pc += 1;
        return true;
      },
    }
  }
  
  fn exec(self: *VM) !MatchResult {
    self.thread_stack.append(.{
      .str_idx = 0,
      .pc = 0,
    }) catch unreachable;
    while (self.thread_stack.len > 0) {
      const thread_top: *Thread = &self.thread_stack.buffer[self.thread_stack.len - 1];
      const thread_exec = try self.nextInstr(thread_top);
      if (!thread_exec) {
        const exitted_thread = self.thread_stack.pop();
        if (self.thread_stack.len == 0 or exitted_thread.fully_matched) {
          return .{
            .pos = exitted_thread.str_idx,
            .fully_matched = exitted_thread.fully_matched,
          };
        }
      }
      // _ = std.io.getStdIn().reader().readByte() catch {};
    }
    unreachable;
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
  InvalidGroupSize,
  InvalidUnicode,
  BacktrackOverflow,
};

pub fn checkMatch(
  self: *const Expr,
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
  };
  return vm.exec() catch |err| {
    switch(err) {
      error.Utf8InvalidStartByte,
      error.Utf8ExpectedContinuation,
      error.Utf8OverlongEncoding,
      error.Utf8EncodesSurrogateHalf,
      error.Utf8CodepointTooLarge => {
        return error.InvalidUnicode;
      },
      error.BacktrackOverflow => |suberr| {
        return suberr;
      },
    }
  };
}

pub const FindResult = struct {
  start: usize,
  end: usize,
};

pub fn find(self: *const Expr, haystack: []const u8) !?FindResult {
  if (self.instrs.items[0].getString()) |string| {
    var skip: usize = 0;
    while (std.mem.indexOf(u8, haystack[skip..], string)) |rel_skip| {
      skip += rel_skip;
      const match = try self.checkMatch(haystack[skip..], .{});
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
    const match = try self.checkMatch(haystack[skip..], .{});
    if (match.fully_matched) {
      return .{
        .start = skip,
        .end = skip + match.pos,
      };
    }
  }
  return null;
}

test "simple one" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "asdf").asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(4, (try expr.checkMatch("asdf", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("as", .{})).pos);
}

test "any" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "..").asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1, (try expr.checkMatch("a", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("as", .{})).pos);
}

test "simple more than one" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "a+").asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1, (try expr.checkMatch("a", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("aa", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch("aba", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("aad", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("daa", .{})).pos);
}

test "group more than one" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(ab)+").asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch("ab", .{})).pos);
  try std.testing.expectEqual(4, (try expr.checkMatch("abab", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("dab", .{})).pos);
}

test "simple zero or more" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "a*b").asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch("ab", .{})).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch("aab", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("aba", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("aad", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("daa", .{})).pos);
}

test "group zero or more" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(ab)*c").asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1, (try expr.checkMatch("c", .{})).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch("abc", .{})).pos);
  try std.testing.expectEqual(5, (try expr.checkMatch("ababc", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("xab", .{})).pos);
}

test "simple optional" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "a?b").asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch("ab", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("aba", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("db", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch("b", .{})).pos);
}

test "group optional" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(ab)?c").asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(3, (try expr.checkMatch("abc", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch("c", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("b", .{})).pos);
}

test "simple range" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "[a-z]+").asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch("ab0", .{})).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch("aba0", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("db0", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch("x0", .{})).pos);
}

test "simple range inverse" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "[^b]").asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1, (try expr.checkMatch("0", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("b", .{})).pos);
}

test "group" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "([a-z]*)([A-Z]+)").asErr();
  defer expr.deinit(allocr);
  var groups = [1]MatchGroup{.{}} ** 2;
  const opts: MatchOptions = .{ .group_out = &groups, };
  try std.testing.expectEqual(4, (try expr.checkMatch("abAB0", opts)).pos);
  try std.testing.expectEqual(0, groups[0].start);
  try std.testing.expectEqual(2, groups[0].end);
  try std.testing.expectEqual(2, groups[1].start);
  try std.testing.expectEqual(4, groups[1].end);
  try std.testing.expectEqual(2, (try expr.checkMatch("AB0", opts)).pos);
  try std.testing.expectEqual(0, groups[0].start);
  try std.testing.expectEqual(0, groups[0].end);
  try std.testing.expectEqual(0, groups[1].start);
  try std.testing.expectEqual(2, groups[1].end);
}

test "simple alternate" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "[a-z]+|[A-Z]+").asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch("ab", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("AB", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch("aB", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("00", .{})).pos);
}

test "group alternate" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(a|z)(b|c)").asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch("ab", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch("az", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("zc", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("c", .{})).pos);
}

test "integrate: string" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(
    allocr,
    \\"([^"]|\\.)*"
  ).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(3, (try expr.checkMatch(
    \\"a"
  , .{})).pos);
  try std.testing.expectEqual(4, (try expr.checkMatch(
    \\"\\"
  , .{})).pos);
  try std.testing.expectEqual(4, (try expr.checkMatch(
    \\"ab"
  , .{})).pos);
  try std.testing.expectEqual(6, (try expr.checkMatch(
    \\"\"\""
  , .{})).pos);
}

test "find (1st pat el is string)" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "asdf?b").asErr();
  defer expr.deinit(allocr);
  {
    const res = (try expr.find("000asdfbasdfb")).?;
    try std.testing.expectEqual(3, res.start);
    try std.testing.expectEqual(8, res.end);
  }
  {
    const res = (try expr.find("000asdbasdfb")).?;
    try std.testing.expectEqual(3, res.start);
    try std.testing.expectEqual(7, res.end);
  }
}

test "find (1st pat el is char)" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "x+asdf?b").asErr();
  defer expr.deinit(allocr);
  {
    const res = (try expr.find("000xxxasdfbasdfb")).?;
    try std.testing.expectEqual(3, res.start);
    try std.testing.expectEqual(11, res.end);
  }
  {
    const res = (try expr.find("000xxxasdbasdfb")).?;
    try std.testing.expectEqual(3, res.start);
    try std.testing.expectEqual(10, res.end);
  }
}