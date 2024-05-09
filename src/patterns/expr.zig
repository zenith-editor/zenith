const Expr = @This();

const std = @import("std");
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
  
  fn asOpt(self: CreateResult) ?Expr {
    switch(self) {
      .ok => |expr| { return expr; },
      .err => { return null; },
    }
  }
};

instrs: std.ArrayListUnmanaged(Instr),
num_groups: usize,

fn debugPrint(self: *const Expr) void {
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
  var parser: Parser = .{};
  if (parser.parse(allocr, in_pattern)) |expr| {
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
  const Backtrack = struct {
    str_idx: usize,
    pc: usize,
  };
  
  haystack: []const u8,
  instrs: []const Instr,
  options: *const MatchOptions,
  pc: usize = 0,
  str_idx: usize = 0,
  backtrack_stack: std.BoundedArray(Backtrack, 128) = .{},
  fully_matched: bool = false,
  
  fn stopOrBacktrack(self: *VM) bool {
    if (self.backtrack_stack.popOrNull()) |bt| {
      // std.debug.print("BT\n",.{});
      self.pc = bt.pc;
      self.str_idx = bt.str_idx;
      return true;
    }
    return false;
  }
  
  fn nextInstr(self: *VM) !bool {
    // std.debug.print(">>> {} {}\n", .{self.pc,self.instrs[self.pc]});
    switch (self.instrs[self.pc]) {
      .matched => {
        self.fully_matched = true;
        return false;
      },
      .char => |char1| {
        if (self.str_idx >= self.haystack.len) {
          return self.stopOrBacktrack();
        }
        const seqlen = try std.unicode.utf8ByteSequenceLength(
          self.haystack[self.str_idx]
        );
        if ((self.haystack.len - self.str_idx) < seqlen) {
          return error.Utf8ExpectedContinuation;
        }
        const char: u32 = try std.unicode.utf8Decode(
          self.haystack[self.str_idx..(self.str_idx+seqlen)]
        );
        if (char != char1) {
          return self.stopOrBacktrack();
        }
        self.pc += 1;
        self.str_idx += seqlen;
        return true;
      },
      .range => |ranges| {
        if (self.str_idx >= self.haystack.len) {
          return self.stopOrBacktrack();
        }
        const seqlen = try std.unicode.utf8ByteSequenceLength(
          self.haystack[self.str_idx]
        );
        if ((self.haystack.len - self.str_idx) < seqlen) {
          return error.Utf8ExpectedContinuation;
        }
        const char: u32 = try std.unicode.utf8Decode(
          self.haystack[self.str_idx..(self.str_idx+seqlen)]
        );
        var matches = false;
        for (ranges) |range| {
          if (range.from <= char and range.to >= char) {
            matches = true;
            break;
          }
        }
        if (!matches) {
          return self.stopOrBacktrack();
        }
        self.pc += 1;
        self.str_idx += seqlen;
        return true;
      },
      .string => |string| {
        // string is only here for optimizing find calls
        std.debug.assert(self.pc == 0);
        
        for (0..string.len) |i| {
          if (self.str_idx == self.haystack.len) {
            return false;
          }
          if (self.haystack[self.str_idx] == string[i]) {
            self.str_idx += 1;
          } else {
            return false;
          }
        }
        
        self.pc += 1;
        return true;
      },
      .jmp => |target| {
        self.pc = target;
        return true;
      },
      .backtrack_target => |backtrack_target| {
        self.backtrack_stack.append(.{
          .pc = backtrack_target,
          .str_idx = self.str_idx,
        }) catch return error.BacktrackOverflow;
        self.pc += 1;
        return true;
      },
      .consume_backtrack => {
        _ = self.backtrack_stack.pop();
        self.pc += 1;
        return true;
      },
      .group_start => |group_id| {
        if (self.options.group_out) |group_out| {
          group_out[group_id].start = self.str_idx;
        }
        self.pc += 1;
        return true;
      },
      .group_end => |group_id| {
        if (self.options.group_out) |group_out| {
          group_out[group_id].end = self.str_idx;
        }
        self.pc += 1;
        return true;
      },
    }
  }
  
  fn exec(self: *VM) !MatchResult {
    // std.debug.print("---\n",.{});
    while (try self.nextInstr()) {}
    return .{
      .pos = self.str_idx,
      .fully_matched = self.fully_matched,
    };
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
  var expr = Expr.create(allocr, "asdf").asOpt().?;
  defer expr.deinit(allocr);
  try std.testing.expectEqual(4, (try expr.checkMatch("asdf", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("as", .{})).pos);
}

test "simple more than one" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = Expr.create(allocr, "a+").asOpt().?;
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
  var expr = Expr.create(allocr, "(ab)+").asOpt().?;
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch("ab", .{})).pos);
  try std.testing.expectEqual(4, (try expr.checkMatch("abab", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("dab", .{})).pos);
}

test "simple zero or more" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = Expr.create(allocr, "a*b").asOpt().?;
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
  var expr = Expr.create(allocr, "(ab)*c").asOpt().?;
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1, (try expr.checkMatch("c", .{})).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch("abc", .{})).pos);
  try std.testing.expectEqual(5, (try expr.checkMatch("ababc", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("xab", .{})).pos);
}

test "simple optional" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = Expr.create(allocr, "a?b").asOpt().?;
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch("ab", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("aba", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("db", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch("b", .{})).pos);
}

test "group optional" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = Expr.create(allocr, "(ab)?c").asOpt().?;
  defer expr.deinit(allocr);
  try std.testing.expectEqual(3, (try expr.checkMatch("abc", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch("c", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("a", .{})).pos);
}

test "simple range" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = Expr.create(allocr, "[a-z]+").asOpt().?;
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch("ab0", .{})).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch("aba0", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("db0", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch("x0", .{})).pos);
}

test "group" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = Expr.create(allocr, "([a-z]*)([A-Z]+)").asOpt().?;
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
  var expr = Expr.create(allocr, "[a-z]+|[A-Z]+").asOpt().?;
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch("ab", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("AB", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch("aB", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("00", .{})).pos);
}

test "group alternate" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = Expr.create(allocr, "(a|z)(b|c)").asOpt().?;
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch("ab", .{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch("az", .{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("zc", .{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("c", .{})).pos);
}

test "find (1st pat el is string)" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = Expr.create(allocr, "asdf?b").asOpt().?;
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
  var expr = Expr.create(allocr, "x+asdf?b").asOpt().?;
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