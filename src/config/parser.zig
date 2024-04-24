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

pub const ParseError = error {
  ExpectedNewline,
  EmptySection,
  ExpectedDigit,
  ExpectedValue,
  ExpectedEqual,
  InvalidEscapeSeq,
  UnexpectedEof,
};

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
  
  fn skipSpaceAndNewline(self: *Parser) !void {
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
        return;
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
        return;
      }
      return ParseError.ExpectedNewline;
    }
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
  
  pub fn nextExpr(self: *Parser, allocr: std.mem.Allocator) !?Expr {
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
          return ParseError.EmptySection;
        }
        try self.skipSpaceAndNewline();
        return .{ .section = self.buffer[start_pos..(start_pos+size)], };
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
          return ParseError.ExpectedEqual;
        }
        self.pos += 1;
        
        self.skipSpace();
        
        const val = try self.nextValue(allocr);
        try self.skipSpaceAndNewline();
        
        const key = self.buffer[start_pos..(start_pos+size)];
        
        return .{
          .kv = .{
            .key = key,
            .val = val,
          },
        };
      }
    }
    return null;
  }
  
  fn nextValue(self: *Parser, allocr: std.mem.Allocator) !Value {
    if (self.getch()) |char| {
      if (self.matchStr("true")) {
        return .{ .boole = true, };
      }
      else if (self.matchStr("false")) {
        return .{ .boole = false, };
      }
      switch(char) {
        '0' ... '9' => {
          self.pos += 1;
          return self.parseInteger(char - '0', false);
        },
        '-' => {
          self.pos += 1;
          return self.parseInteger(null, true);
        },
        '"' => {
          self.pos += 1;
          return self.parseStr(allocr);
        },
        else => {
          return ParseError.ExpectedValue;
        },
      }
    } else {
      return ParseError.ExpectedValue;
    }
  }
  
  fn parseInteger(self: *Parser, init_digit: ?i32, is_neg: bool) !Value {
    var num: i32 = 0;
    if (init_digit == 0) {
      return .{ .int = 0, };
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
            return .{ .int = 0, };
          },
          else => {
            return ParseError.ExpectedDigit;
          },
        }
      } else {
        return ParseError.ExpectedDigit;
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
          return .{ .int = num, };
        },
      }
    }
    return .{ .int = num, };
  }

  fn parseStr(self: *Parser, allocr: std.mem.Allocator) !Value {
    var string: str.String = .{};
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
              else => { return ParseError.InvalidEscapeSeq; },
            }
          } else {
            return ParseError.UnexpectedEof;
          }
        },
        else => {
          self.pos += 1;
          try string.append(allocr, char);
        },
      }
    }
    return .{ .string = string, };
  }

};

test "parse empty section" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var parser = Parser.init("[section]");
  {
    var expr = (try parser.nextExpr(allocr)).?;
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
    var expr = (try parser.nextExpr(allocr)).?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "section", expr.section);
  }
  {
    var expr = (try parser.nextExpr(allocr)).?;
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
    var expr = (try parser.nextExpr(allocr)).?;
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
    var expr = (try parser.nextExpr(allocr)).?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "truth", expr.kv.key);
    try std.testing.expectEqual(true, expr.kv.val.boole);
  }
  {
    var expr = (try parser.nextExpr(allocr)).?;
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
    var expr = (try parser.nextExpr(allocr)).?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "truth", expr.kv.key);
    try std.testing.expectEqual(true, expr.kv.val.boole);
  }
  {
    var expr = (try parser.nextExpr(allocr)).?;
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
    var expr = (try parser.nextExpr(allocr)).?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "key", expr.kv.key);
    try std.testing.expectEqualSlices(u8, "\"val\"", expr.kv.val.string.items);
  }
}
