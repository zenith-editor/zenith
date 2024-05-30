//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//

const std = @import("std");

const str = @import("../str.zig");
const Error = @import("../ds/error.zig").Error;

pub const Value = union(enum) {
  uninitialized: void,
  i64: i64,
  string: str.StringUnmanaged,
  bool: bool,  
  array: []Value,
  
  fn deinit(self: *Value, allocr: std.mem.Allocator) void {
    switch(self.*) {
      .string => |*string| {
        string.deinit(allocr);
      },
      .array => |array| {
        for (array) |*v| {
          v.deinit(allocr);
        }
        allocr.free(array);
      },
      else => {},
    }
    self.* = .uninitialized;
  }
  
  pub fn getErr(self: *const Value, comptime T: type) AccessError!T {
    switch(T) {
      inline i64 => {
        switch(self.*) {
          .i64 => |v| { return v; },
          else => {return error.ExpectedI64Value;},
        }
      },
      inline bool => {
        switch(self.*) {
          .bool => |v| { return v; },
          else => {return error.ExpectedBoolValue;},
        }
      },
      inline []const u8 => {
        switch(self.*) {
          .string => |*v| { return v.items; },
          else => { return error.ExpectedStringValue; },
        }
      },
      inline []Value => {
        switch(self.*) {
          .array => |v| { return v; },
          else => { return error.ExpectedArrayValue; },
        }
      },
      else => {
        @compileError("invalid type");
      },
    }
  }
  
  pub fn getOpt(self: *const Value, comptime T: type) ?T {
    return self.getErr(T) catch null;
  }
};

pub const AccessError = error {
  ExpectedI64Value,
  ExpectedBoolValue,
  ExpectedStringValue,
  ExpectedArrayValue,
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
  
  pub fn get(self: *const KV, comptime T: type, key: []const u8) AccessError!?T {
    if (!std.mem.eql(u8, self.key, key)) {
      return null;
    }
    return try self.val.getErr(T);
  }
  
};

pub const Expr = union(enum) {
  kv: KV,
  section: []const u8,
  table_section: []const u8,
  
  pub fn deinit(self: *Expr, allocr: std.mem.Allocator) void {
    switch(self.*) {
      .kv => |*kv| {
        kv.deinit(allocr);
      },
      .section => {},
      .table_section => {},
    }
  }
};

pub const ParseErrorType = error {
  ExpectedNewline,
  EmptySection,
  ExpectedDigit,
  ExpectedValue,
  ExpectedEqual,
  ExpectedDoubleBracket,
  InvalidEscapeSeq,
  UnexpectedChar,
  UnexpectedEof,
  OutOfMemory,
};

pub const ParseError = struct {
  type: ParseErrorType,
  pos: usize,
};

const ValueResult = Error(Value, ParseError);
const ExprOrNullResult = Error(?Expr, ParseError);

pub const Parser = struct {
  buffer: []const u8,
  pos: usize = 0,

  fn isId(char: u8) bool {
     return switch(char) {
       '0' ... '9' => true,
       'a' ... 'z' => true,
       'A' ... 'Z' => true,
       '-', ':' => true,
       else => false,
     };
  }
  
  fn isSpace(char: u8) bool {
    return char == ' ' or char == '\t';
  }
  
  pub fn init(buffer: []const u8) Parser {
    return Parser { .buffer = buffer, };
  }
  
  fn peek(self: *Parser) ?u8 {
    if (self.pos == self.buffer.len) {
      return null;
    }
    return self.buffer[self.pos];
  }
  
  fn skipSpace(self: *Parser) void {
    while (self.peek()) |char| {
      if (Parser.isSpace(char)) {
        self.pos += 1;
      } else {
        break;
      }
    }
  }
  
  fn skipSpaceAndNewline(self: *Parser) ?ParseError {
    self.skipSpace();
    if (self.peek()) |char| {
      if (char == '#') {
        self.pos += 1;
        while (self.peek()) |c2| {
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
        while (self.peek()) |c2| {
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
    while (self.peek()) |char| {
      if (char == '#') {
        self.pos += 1;
        while (self.peek()) |c2| {
          if (c2 == '\n') {
            self.pos += 1;
            break;
          } else {
            self.pos += 1;
          }
        }
      } else if (Parser.isSpace(char)) {
        self.skipSpace();
      } else if (char == '\n') {
        self.pos += 1;
      } else {
        break;
      }
    }
  }
  
  pub fn nextExpr(self: *Parser, allocr: std.mem.Allocator) ExprOrNullResult {
    // expr = ws* (comment newline)* keyval ws* comment? newline+
    self.skipSpaceBeforeExpr();
    if (self.peek()) |char| {
      if (char == '[') {
        self.pos += 1;
        var is_table = false;
        if (self.peek()) |next| {
          if (next == '[') {
            is_table = true;
            self.pos += 1;
          }
        }
        const start_pos = self.pos;
        var size: usize = 0;
        while (self.peek()) |close| {
          if (close == ']') {
            self.pos += 1;
            if (is_table) {
              if (self.peek() != ']') {
                return .{ 
                  .err = .{
                    .type = ParseErrorType.ExpectedDoubleBracket,
                    .pos = self.pos,
                  },
                };
              }
              self.pos += 1;
            }
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
        if (is_table) {
          return .{
            .ok = .{
              .table_section = self.buffer[start_pos..(start_pos+size)],
            },
          };
        } else {
          return .{
            .ok = .{
              .section = self.buffer[start_pos..(start_pos+size)],
            },
          };
        }
      }
      else if (Parser.isId(char)) {
        const start_pos = self.pos;
        self.pos += 1;
        var size: usize = 1;
        while (self.peek()) |next| {
          if (Parser.isId(next)) {
            size += 1;
            self.pos += 1;
          } else {
            break;
          }
        }
        
        self.skipSpace();
        
        if (self.peek() != '=') {
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
              .val = val.ok,
            },
          },
        };
      }
      else {
        return .{ 
          .err = .{
            .type = ParseErrorType.UnexpectedChar,
            .pos = self.pos,
          },
        };
      }
    }
    return .{ .ok = null, };
  }
  
  fn nextValue(self: *Parser, allocr: std.mem.Allocator) ValueResult {
    if (self.peek()) |char| {
      if (self.matchStr("true")) {
        return .{
          .ok = .{ .bool = true, },
        };
      }
      else if (self.matchStr("false")) {
        return .{
          .ok = .{ .bool = false, },
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
        '\\' => {
          self.pos += 1;
          if (self.peek() == '\\') {
            self.pos += 1;
            return self.parseMultilineStr(allocr, start_pos);
          }
        },
        '[' => {
          self.pos += 1;
          return self.parseArray(allocr, start_pos);
        },
        else => {},
      }
      return .{
        .err = .{
          .type = ParseErrorType.ExpectedValue,
          .pos = start_pos,
        },
      };
    } else {
      return .{
        .err = .{
          .type = ParseErrorType.ExpectedValue,
          .pos = self.pos,
        },
      };
    }
  }
  
  fn parseInteger(self: *Parser, init_digit: ?i64, is_neg: bool, start_pos: usize) ValueResult {
    var num: i64 = 0;
    if (init_digit == 0) {
      return .{ .ok = .{ .i64 = 0, }, };
    }
    else if (init_digit == null) {
      if (self.peek()) |char| {
        switch(char) {
          '1' ... '9' => {
            num = char - '0';
            self.pos += 1;
          },
          '0' => {
            self.pos += 1;
            return .{ .ok = .{ .i64 = 0, }, };
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
    while (self.peek()) |char| {
      switch (char) {
        '0' ... '9' => |digitch| {
          const digit = digitch - '0';
          num *= 10;
          num += digit;
          self.pos += 1;
        },
        else => {
          return .{ .ok = .{ .i64 = num, }, };
        },
      }
    }
    return .{ .ok = .{ .i64 = num, }, };
  }

  fn parseStrInner(self: *Parser, allocr: std.mem.Allocator, start_pos: usize) !ValueResult {
    var string: str.StringUnmanaged = .{};
    errdefer string.deinit(allocr);
    while (self.peek()) |char| {
      switch (char) {
        '"' => {
          self.pos += 1;
          break;
        },
        '\\' => {
          self.pos += 1;
          if (self.peek()) |esc| {
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

  fn parseMultilineStrInner(self: *Parser, allocr: std.mem.Allocator) !ValueResult {
    var string: str.StringUnmanaged = .{};
    errdefer string.deinit(allocr);
    while (self.peek()) |char| {
      switch (char) {
        '\n' => {
          const orig_pos = self.pos;
          self.pos += 1;
          self.skipSpace();
          if (self.peek() == '\\') {
            self.pos += 1;
            if (self.peek() == '\\') {
              self.pos += 1;
              try string.append(allocr, '\n');
              continue;
            }
          }
          self.pos = orig_pos;
          break;
        },
        else => {
          self.pos += 1;
          try string.append(allocr, char);
        },
      }
    }
    return .{ .ok = .{ .string = string, }, };
  }
  
  fn parseMultilineStr(self: *Parser, allocr: std.mem.Allocator, start_pos: usize) ValueResult {
    if (self.parseMultilineStrInner(allocr)) |result| {
      return result;
    } else |err| {
      switch(err) {
        error.OutOfMemory => {
          return .{
            .err =  .{
              .type = @errorCast(err),
              .pos = start_pos,
            },
          };
        },
      }
    }
  }
  
  fn parseArrayInner(self: *Parser, allocr: std.mem.Allocator) !ValueResult {
    var array = std.ArrayList(Value).init(allocr);
    errdefer array.deinit();
    self.skipSpaceBeforeExpr();
    while (self.peek()) |char| {
      if (char == ']') {
        break;
      }
      const value = self.nextValue(allocr);
      if (value.isErr()) {
        return value;
      }
      try array.append(value.ok);
      self.skipSpaceBeforeExpr();
      if (self.peek()) |char1| {
        switch (char1) {
          ']' => {
            self.pos += 1;
            break;
          },
          ',' => {
            self.pos += 1;
            self.skipSpaceBeforeExpr();
          },
          else => {
            return error.ExpectedArrayValue;
          }
        }
      } else {
        return error.ExpectedArrayValue;
      }
    }
    return .{ .ok = .{ .array = try array.toOwnedSlice() } };
  }
  
  fn parseArray(self: *Parser, allocr: std.mem.Allocator, start_pos: usize) ValueResult {
    if (self.parseArrayInner(allocr)) |result| {
      return result;
    } else |err| {
      switch(err) {
        error.OutOfMemory, error.ExpectedArrayValue => {
          return .{
            .err =  .{
              .type = @errorCast(err),
              .pos = start_pos,
            },
          };
        },
      }
    }
  }
};
