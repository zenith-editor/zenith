const Expr = @This();

const std = @import("std");

pub const CreateErrorType = enum {
  EmptyRegex,
  OutOfMemory,
  InvalidUnicode,
  ExpectedSimpleExpr,
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

const Instr = union(enum) {
  const Range = struct {
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
  /// Sets backtrack target
  backtrack_target: usize,
  
  fn deinit(self: *Instr, allocr: std.mem.Allocator) void {
    _ = self;
    _ = allocr;
  }
  
  fn isSimpleMatcher(self: *const Instr) bool {
    return switch(self.*) {
      .char, .range => true,
      else => false,
    };
  }
  
  fn isChar(self: *const Instr) bool {
    return switch(self.*) {
      .char => true,
      else => false,
    };
  }
  
  fn getString(self: *const Instr) ?[]u8 {
    return switch(self.*) {
      .string => |string| string,
      else => null,
    };
  }
  
  fn decrPc(self: *Instr, shifted: usize) void {
    switch(self.*) {
      .jmp => |*pc| { pc.* -= shifted; },
      .backtrack_target => |*pc| { pc.* -= shifted; },
      else => {},
    }
  }
};

instrs: std.ArrayListUnmanaged(Instr),

fn deinit(self: *Expr, allocr: std.mem.Allocator) void {
  for (self.instrs.items) |*instr| {
    instr.deinit(allocr);
  }
  self.instrs.deinit(allocr);
}

fn createInner(allocr: std.mem.Allocator, in_pattern: []const u8) !CreateResult {
  var expr: Expr = .{
    .instrs = .{},
  };
  errdefer expr.deinit(allocr);
  
  var i: usize = 0;
  while (i < in_pattern.len) {
    const seqlen = try std.unicode.utf8ByteSequenceLength(in_pattern[i]);
    if ((in_pattern.len - i) < seqlen) {
      return .{ .err = .{ .type = .InvalidUnicode, .pos = i, }, };
    }
    const char: u32 = try std.unicode.utf8Decode(in_pattern[i..(i+seqlen)]);
    switch (char) {
      '+' => {
        if (!expr.instrs.items[expr.instrs.items.len - 1].isSimpleMatcher()) {
          return .{ .err = .{ .type = .ExpectedSimpleExpr, .pos = i, }, };
        }
        // L1: <char>
        // bt L3
        // jmp L1
        // L3: ...
        const jmp = expr.instrs.items.len - 1;
        const backtrack_target = expr.instrs.items.len + 2;
        try expr.instrs.append(allocr, .{ // +0
          .backtrack_target = backtrack_target,
        });
        try expr.instrs.append(allocr, .{ // +1
          .jmp = jmp,
        });
      },
      '*' => {
        if (!expr.instrs.items[expr.instrs.items.len - 1].isSimpleMatcher()) {
          return .{ .err = .{ .type = .ExpectedSimpleExpr, .pos = i, }, };
        }
        // transform:
        //  -1 <char>
        // ... to
        //  -1 bt L3
        //  +0 L1: <char>
        //  +1 jmp L1
        //  +2 L3: ...
        const backtrack_target = expr.instrs.items.len + 2;
        const jmp = expr.instrs.items.len;
        try expr.instrs.insert(allocr, expr.instrs.items.len - 1, .{ // -1
          .backtrack_target = backtrack_target,
        });
        try expr.instrs.append(allocr, .{ // +1
          .jmp = jmp,
        });
      },
      '?' => {
        if (!expr.instrs.items[expr.instrs.items.len - 1].isSimpleMatcher()) {
          return .{ .err = .{ .type = .ExpectedSimpleExpr, .pos = i, }, };
        }
        // transform:
        //  -1 <char>
        // ... to
        //  -1 bt L3
        //  +0 <char>
        //  +1 L3: ...
        const backtrack_target = expr.instrs.items.len + 1;
        try expr.instrs.insert(allocr, expr.instrs.items.len - 1, .{ // -1
          .backtrack_target = backtrack_target,
        });
      },
      else => {
        try expr.instrs.append(allocr, .{ .char = char });
      },
    }
    i += seqlen;
  }
  try expr.instrs.append(allocr, .{ .matched = {}, });
  try expr.optimizePrefixString(allocr);
  return .{ .ok = expr, };
}

pub fn create(allocr: std.mem.Allocator, in_pattern: []const u8) CreateResult {
  if (in_pattern.len == 0) {
    return .{
      .err = .{ .type = .EmptyRegex, .pos = 0, },
    };
  }
  if (createInner(allocr, in_pattern)) |result| {
    return result;
  } else |err| {
    switch (err) {
      error.OutOfMemory => {
        return .{
          .err = .{
            .type = .OutOfMemory,
            .pos = 0,
          },
        };
      },
      error.Utf8InvalidStartByte,
      error.Utf8ExpectedContinuation,
      error.Utf8OverlongEncoding,
      error.Utf8EncodesSurrogateHalf,
      error.Utf8CannotEncodeSurrogateHalf,
      error.CodepointTooLarge,
      error.Utf8CodepointTooLarge => {
        return .{
          .err = .{
            .type = .InvalidUnicode,
            .pos = 0,
          },
        };
      }
    }
  }
}

fn optimizePrefixString(self: *Expr, allocr: std.mem.Allocator) !void {
  if (self.instrs.items.len < 2) {
    return;
  }
  if (!self.instrs.items[0].isChar() or !self.instrs.items[1].isChar()) {
    return;
  }
  
  var removed: usize = 0;
  var bytes: std.ArrayListUnmanaged(u8) = .{};
  errdefer bytes.deinit(allocr);
  
  for (self.instrs.items) |item| {
    switch (item) {
      .char => |char| {
        var char_bytes: [4]u8 = undefined;
        const n_bytes = try std.unicode.utf8Encode(@intCast(char), &char_bytes);
        try bytes.appendSlice(allocr, char_bytes[0..n_bytes]);
        removed += 1;
      },
      else => { break; },
    }
  }
  removed -= 1; // except for first char
  
  self.instrs.items[0] = .{ .string = try bytes.toOwnedSlice(allocr), };
  self.instrs.replaceRangeAssumeCapacity(1, removed, &[_]Instr {});
  for (self.instrs.items[1..]) |*item| {
    item.decrPc(removed);
  }
}

pub const MatchResult = struct {
  pos: usize,
  fully_matched: bool,
};

const VM = struct {
  haystack: []const u8,
  instrs: []const Instr,
  pc: usize = 0,
  str_index: usize = 0,
  backtrack: ?usize = null,
  fully_matched: bool = false,
  
  fn stopOrBacktrack(self: *VM) bool {
    if (self.backtrack) |bt| {
      self.pc = bt;
      self.backtrack = null;
      return true;
    }
    return false;
  }
  
  fn nextInstr(self: *VM) !bool {
    switch (self.instrs[self.pc]) {
      .matched => {
        self.fully_matched = true;
        return false;
      },
      .char => |char1| {
        if (self.str_index >= self.haystack.len) {
          return self.stopOrBacktrack();
        }
        const seqlen = try std.unicode.utf8ByteSequenceLength(
          self.haystack[self.str_index]
        );
        if ((self.haystack.len - self.str_index) < seqlen) {
          return error.InvalidUtf8;
        }
        const char: u32 = try std.unicode.utf8Decode(
          self.haystack[self.str_index..(self.str_index+seqlen)]
        );
        if (char != char1) {
          return self.stopOrBacktrack();
        }
        self.pc += 1;
        self.str_index += seqlen;
        return true;
      },
      .range => {
        @panic("TODO\n");
      },
      .string => |string| {
        for (0..string.len) |i| {
          if (self.str_index == self.haystack.len) {
            return false;
          }
          if (self.haystack[self.str_index] == string[i]) {
            self.str_index += 1;
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
        self.backtrack = backtrack_target;
        self.pc += 1;
        return true;
      },
    }
  }
  
  fn exec(self: *VM) !MatchResult {
    while (try self.nextInstr()) {}
    return .{
      .pos = self.str_index,
      .fully_matched = self.fully_matched,
    };
  }
};

pub fn checkMatch(
  self: *const Expr,
  haystack: []const u8,
) !MatchResult {
  var vm: VM = .{
    .haystack = haystack,
    .instrs = self.instrs.items,
  };
  return vm.exec();
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
      const match = try self.checkMatch(haystack[skip..]);
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
    const match = try self.checkMatch(haystack[skip..]);
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
  try std.testing.expectEqual(4, (try expr.checkMatch("asdf")).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("as")).pos);
}

test "simple more than one" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = Expr.create(allocr, "a+").asOpt().?;
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1, (try expr.checkMatch("a")).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("aa")).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch("aba")).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("aad")).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("daa")).pos);
}

test "simple zero or more" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = Expr.create(allocr, "a*b").asOpt().?;
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch("ab")).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch("aab")).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("aba")).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("aad")).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("daa")).pos);
}

test "simple optional" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = Expr.create(allocr, "a?b").asOpt().?;
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch("ab")).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch("aba")).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch("db")).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch("b")).pos);
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