//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//

const std = @import("std");

const str = @import("../str.zig");

pub const Value = union(enum) {
  uninitialized: void,
  int: i32,
  string: str.String,
  boole: bool,  
  
  fn deinit(self: *Value, allocr: std.mem.Allocator) void {
    switch(self.*) {
      .uninitialized => { unreachable; },
      .string => |*string| {
        string.deinit(allocr);
      },
      else => {},
    }
    self.* = .uninitialized;
  }
};

pub const KV = struct {
  key: []const u8,
  val: Value,
  
  fn deinit(self: *KV, allocr: std.mem.Allocator) void {
    self.val.deinit(allocr);
  }
  
  pub fn takeValue(self: *KV) Value {
    switch (self.val) {
      .uninitialized => { unreachable; },
      else => {
        const old = self.val.*;
        self.val.* = Value.uninitialized;
        return old;
      }
    }
  }
};

pub const Expr = union(enum) {
  kv: KV,
  section: []const u8,
  
  pub fn deinit(self: *Expr, allocr: std.mem.Allocator) void {
    switch(self.*) {
      .kv => |*kv| {
        kv.deinit(allocr);
      },
      .section => {},
    }
  }
};

pub const ParseErrorType = enum {
  ExpectedNewline,
  EmptySection,
  ExpectedDigit,
  ExpectedValue,
  ExpectedEqual,
  InvalidEscapeSeq,
  UnexpectedEof,
  OutOfMemory,
};

pub const ParseError = struct {
  type: ParseErrorType,
  pos: usize,
};

fn ParseResult(comptime T: type) type {
  return union(enum) {
    const Self = @This();
  
    ok: T,
    err: ParseError,
    
    pub fn unwrap(self: *Self) T {
      switch (self.*) {
        .ok => |v| {
          return v;
        },
        else => unreachable,
      }
    }
    
    pub fn isErr(self: *const Self) bool {
      return switch(self.*) {
        .err => true,
        else => false,
      };
    }
  };
}

const ValueResult = ParseResult(Value);
const ExprOrNullResult = ParseResult(?Expr);

pub const Parser = struct {
  buffer: []const u8,
  pos: usize = 0,

  fn isId(char: u8) bool {
     return switch(char) {
       '0' ... '9' => true,
       'a' ... 'z' => true,
       'A' ... 'Z' => true,
       '-' => true,
       else => false,
     };
  }
  
  fn isSpace(char: u8) bool {
    return char == ' ' or char == '\t';
  }
  
  pub fn init(buffer: []const u8) Parser {
    return Parser { .buffer = buffer, };
  }
  
  fn getch(self: *Parser) ?u8 {
    if (self.pos == self.buffer.len) {
      return null;
    }
    return self.buffer[self.pos];
  }
  
  fn skipSpace(self: *Parser) void {
    while (self.getch()) |char| {
      if (Parser.isSpace(char)) {
        self.pos += 1;
      } else {
        break;
      }
    }
  }
  
  fn skipSpaceAndNewline(self: *Parser) ?ParseError {
    self.skipSpace();
    if (self.getch()) |char| {
      if (char == '#') {
        self.pos += 1;
        while (self.getch()) |c2| {
          if (c2 == '\n') {
            self.pos += 1;
            break;
          } else {
            self.pos += 1;
          }
        }
        return null;
      }
      if (char == '\n') {
        self.pos += 1;
        while (self.getch()) |c2| {
          if (c2 == '\n') {
            self.pos += 1;
          } else {
            break;
          }
        }
        return null;
      }
      return .{
        .type = ParseErrorType.ExpectedNewline,
        .pos = self.pos,
      };
    }
    return null;
  }
  
  fn matchStr(self: *Parser, match: []const u8) bool {
    if (std.mem.startsWith(u8, self.buffer[self.pos..], match)) {
      self.pos += match.len;
      return true;
    } else {
      return false;
    }
  }
  
  fn skipSpaceBeforeExpr(self: *Parser) void {
    self.skipSpace();
    while (self.getch()) |char| {
      if (char == '#') {
        self.pos += 1;
        while (self.getch()) |c2| {
          if (c2 == '\n') {
            self.pos += 1;
            break;
          } else {
            self.pos += 1;
          }
        }
      } else if (Parser.isSpace(char)) {
        self.skipSpace();
      } else {
        break;
      }
    }
  }
  
  pub fn nextExpr(self: *Parser, allocr: std.mem.Allocator) ExprOrNullResult {
    // expr = ws* (comment newline)* keyval ws* comment? newline+
    self.skipSpaceBeforeExpr();
    if (self.getch()) |char| {
      if (char == '['){
        self.pos += 1;
        const start_pos = self.pos;
        var size: usize = 0;
        while (self.getch()) |close| {
          if (close == ']') {
            self.pos += 1;
            break;
          } else {
            size += 1;
            self.pos += 1;
          }
        }
        if (size == 0) {
          return .{ 
            .err = .{
              .type = ParseErrorType.EmptySection,
              .pos = self.pos,
            },
          };
        }
        if (self.skipSpaceAndNewline()) |err| {
          return .{ .err = err, };
        }
        return .{
          .ok = .{
            .section = self.buffer[start_pos..(start_pos+size)],
          },
        };
      }
      else if (Parser.isId(char)) {
        const start_pos = self.pos;
        self.pos += 1;
        var size: usize = 1;
        while (self.getch()) |next| {
          if (Parser.isId(next)) {
            size += 1;
            self.pos += 1;
          } else {
            break;
          }
        }
        
        self.skipSpace();
        
        if (self.getch() != '=') {
          return .{ 
            .err = .{
              .type = ParseErrorType.ExpectedEqual,
              .pos = self.pos,
            },
          };
        }
        self.pos += 1;
        
        self.skipSpace();
        
        var val = self.nextValue(allocr);
        if (val.isErr()) {
          return .{ .err = val.err, };
        }
        if (self.skipSpaceAndNewline()) |err| {
          return .{ .err = err, };
        }
        
        const key = self.buffer[start_pos..(start_pos+size)];
        
        return .{
          .ok = .{
            .kv = .{
              .key = key,
              .val = val.unwrap(),
            },
          },
        };
      }
    }
    return .{ .ok = null, };
  }
  
  fn nextValue(self: *Parser, allocr: std.mem.Allocator) ValueResult {
    if (self.getch()) |char| {
      if (self.matchStr("true")) {
        return .{
          .ok = .{ .boole = true, },
        };
      }
      else if (self.matchStr("false")) {
        return .{
          .ok = .{ .boole = false, },
        };
      }
      const start_pos = self.pos;
      switch(char) {
        '0' ... '9' => {
          self.pos += 1;
          return self.parseInteger(char - '0', false, start_pos);
        },
        '-' => {
          self.pos += 1;
          return self.parseInteger(null, true, start_pos);
        },
        '"' => {
          self.pos += 1;
          return self.parseStr(allocr, start_pos);
        },
        else => {
          return .{
            .err = .{
              .type = ParseErrorType.ExpectedValue,
              .pos = start_pos,
            },
          };
        },
      }
    } else {
      return .{
        .err = .{
          .type = ParseErrorType.ExpectedValue,
          .pos = self.pos,
        },
      };
    }
  }
  
  fn parseInteger(self: *Parser, init_digit: ?i32, is_neg: bool, start_pos: usize) ValueResult {
    var num: i32 = 0;
    if (init_digit == 0) {
      return .{ .ok = .{ .int = 0, }, };
    }
    else if (init_digit == null) {
      if (self.getch()) |char| {
        switch(char) {
          '1' ... '9' => {
            num = char - '0';
            self.pos += 1;
          },
          '0' => {
            self.pos += 1;
            return .{ .ok = .{ .int = 0, }, };
          },
          else => {
            return .{
              .err = .{
                .type = ParseErrorType.ExpectedDigit,
                .pos = start_pos,
              },
            };
          },
        }
      } else {
        return .{
          .err = .{
            .type = ParseErrorType.ExpectedDigit,
            .pos = start_pos,
          },
        };
      }
    }
    else {
      num = init_digit.?;
      if (is_neg) {
        num = -num;
      }
    }
    while (self.getch()) |char| {
      switch (char) {
        '0' ... '9' => |digitch| {
          const digit = digitch - '0';
          num *= 10;
          num += digit;
          self.pos += 1;
        },
        else => {
          return .{ .ok = .{ .int = num, }, };
        },
      }
    }
    return .{ .ok = .{ .int = num, }, };
  }

  fn parseStrInner(self: *Parser, allocr: std.mem.Allocator, start_pos: usize) !ValueResult {
    var string: str.String = .{};
    errdefer string.deinit(allocr);
    while (self.getch()) |char| {
      switch (char) {
        '"' => {
          self.pos += 1;
          break;
        },
        '\\' => {
          self.pos += 1;
          if (self.getch()) |esc| {
            switch (esc) {
              '\\' => {
                self.pos += 1;
                try string.append(allocr, '\\');
              },
              '"' => {
                self.pos += 1;
                try string.append(allocr, '"');
              },
              else => {
                return .{
                  .err =  .{
                    .type = ParseErrorType.InvalidEscapeSeq,
                    .pos = start_pos,
                  },
                };
              },
            }
          } else {
            return .{
              .err =  .{
                .type = ParseErrorType.UnexpectedEof,
                .pos = start_pos,
              },
            };
          }
        },
        else => {
          self.pos += 1;
          try string.append(allocr, char);
        },
      }
    }
    return .{ .ok = .{ .string = string, }, };
  }
  
  fn parseStr(self: *Parser, allocr: std.mem.Allocator, start_pos: usize) ValueResult {
    if (self.parseStrInner(allocr, start_pos)) |result| {
      return result;
    } else |err| {
      switch(err) {
        error.OutOfMemory => {
          return .{
            .err =  .{
              .type = ParseErrorType.OutOfMemory,
              .pos = start_pos,
            },
          };
        },
      }
    }
  }
};

test "parse empty section" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var parser = Parser.init("[section]");
  {
    var expr = parser.nextExpr(allocr).unwrap().?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "section", expr.section);
  }
}

test "parse section with int val" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var parser = Parser.init(
    \\[section]
    \\key=1
  );
  {
    var expr = parser.nextExpr(allocr).unwrap().?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "section", expr.section);
  }
  {
    var expr = parser.nextExpr(allocr).unwrap().?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "key", expr.kv.key);
    try std.testing.expectEqual(1, expr.kv.val.int);
  }
}

test "parse section with string val" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var parser = Parser.init(
    \\key="val"
  );
  {
    var expr = parser.nextExpr(allocr).unwrap().?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "key", expr.kv.key);
    try std.testing.expectEqualSlices(u8, "val", expr.kv.val.string.items);
  }
}

test "parse section with bool val" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var parser = Parser.init(
    \\truth=true
    \\faux=false
  );
  {
    var expr = parser.nextExpr(allocr).unwrap().?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "truth", expr.kv.key);
    try std.testing.expectEqual(true, expr.kv.val.boole);
  }
  {
    var expr = parser.nextExpr(allocr).unwrap().?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "faux", expr.kv.key);
    try std.testing.expectEqual(false, expr.kv.val.boole);
  }
}

test "parse section with comments" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var parser = Parser.init(
    \\ # comment1
    \\    #comment 2
    \\truth=true
    \\
    \\  #comment 3
    \\faux=false #comment4
  );
  {
    var expr = parser.nextExpr(allocr).unwrap().?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "truth", expr.kv.key);
    try std.testing.expectEqual(true, expr.kv.val.boole);
  }
  {
    var expr = parser.nextExpr(allocr).unwrap().?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "faux", expr.kv.key);
    try std.testing.expectEqual(false, expr.kv.val.boole);
  }
}

test "parse section with esc seq in string val" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var parser = Parser.init(
    \\key="\"val\""
  );
  {
    var expr = parser.nextExpr(allocr).unwrap().?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "key", expr.kv.key);
    try std.testing.expectEqualSlices(u8, "\"val\"", expr.kv.val.string.items);
  }
}
