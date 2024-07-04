//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//

const std = @import("std");

const str = @import("../str.zig");
const editor = @import("../editor.zig");

pub const Value = union(enum) {
    uninitialized: void,
    i64: i64,
    string: str.StringUnmanaged,
    bool: bool,
    array: []Value,

    fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |*string| {
                string.deinit(allocator);
            },
            .array => |array| {
                for (array) |*v| {
                    v.deinit(allocator);
                }
                allocator.free(array);
            },
            else => {},
        }
        self.* = .uninitialized;
    }

    pub fn getErr(self: *const Value, comptime T: type) AccessError!T {
        switch (T) {
            inline i64 => {
                switch (self.*) {
                    .i64 => |v| {
                        return v;
                    },
                    else => {
                        return error.ExpectedI64Value;
                    },
                }
            },
            inline bool => {
                switch (self.*) {
                    .bool => |v| {
                        return v;
                    },
                    else => {
                        return error.ExpectedBoolValue;
                    },
                }
            },
            inline []const u8 => {
                switch (self.*) {
                    .string => |*v| {
                        return v.items;
                    },
                    else => {
                        return error.ExpectedStringValue;
                    },
                }
            },
            inline []Value => {
                switch (self.*) {
                    .array => |v| {
                        return v;
                    },
                    else => {
                        return error.ExpectedArrayValue;
                    },
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

pub const AccessError = error{
    ExpectedI64Value,
    ExpectedBoolValue,
    ExpectedStringValue,
    ExpectedArrayValue,
};

pub const KV = struct {
    key: []const u8,
    val: Value,

    fn deinit(self: *KV, allocator: std.mem.Allocator) void {
        self.val.deinit(allocator);
    }

    pub fn takeValue(self: *KV) Value {
        switch (self.val) {
            .uninitialized => {
                unreachable;
            },
            else => {
                const old = self.val.*;
                self.val.* = Value.uninitialized;
                return old;
            },
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

    pub fn deinit(self: *Expr, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .kv => |*kv| {
                kv.deinit(allocator);
            },
            .section => {},
            .table_section => {},
        }
    }
};

pub const ParseError = error{
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

pub const Parser = struct {
    source: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,

    fn isId(char: u8) bool {
        return switch (char) {
            '0'...'9' => true,
            'a'...'z' => true,
            'A'...'Z' => true,
            '-', ':' => true,
            else => false,
        };
    }

    fn isSpace(char: u8) bool {
        return char == ' ' or char == '\t';
    }

    fn peek(self: *Parser) ?u8 {
        if (self.pos == self.source.len) {
            return null;
        }
        return self.source[self.pos];
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

    fn skipSpaceAndNewline(self: *Parser) ParseError!void {
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
                return;
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
                return;
            }
            return error.ExpectedNewline;
        }
    }

    fn matchStr(self: *Parser, match: []const u8) bool {
        if (std.mem.startsWith(u8, self.source[self.pos..], match)) {
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

    pub fn nextExpr(self: *Parser) ParseError!?Expr {
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
                                return error.ExpectedDoubleBracket;
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
                    return error.EmptySection;
                }
                try self.skipSpaceAndNewline();
                if (is_table) {
                    return .{ .table_section = self.source[start_pos..(start_pos + size)] };
                } else {
                    return .{
                        .section = self.source[start_pos..(start_pos + size)],
                    };
                }
            } else if (Parser.isId(char)) {
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
                    return error.ExpectedEqual;
                }
                self.pos += 1;
                self.skipSpace();

                const val = try self.nextValue();
                try self.skipSpaceAndNewline();
                const key = self.source[start_pos..(start_pos + size)];
                return .{ .kv = .{
                    .key = key,
                    .val = val,
                } };
            } else {
                return error.UnexpectedChar;
            }
        }
        return null;
    }

    fn nextValue(self: *Parser) ParseError!Value {
        if (self.peek()) |char| {
            if (self.matchStr("true")) {
                return .{ .bool = true };
            } else if (self.matchStr("false")) {
                return .{ .bool = false };
            }
            switch (char) {
                '0'...'9' => {
                    self.pos += 1;
                    return try self.parseInteger(char - '0', false);
                },
                '-' => {
                    self.pos += 1;
                    return try self.parseInteger(null, true);
                },
                '"' => {
                    self.pos += 1;
                    return try self.parseStr();
                },
                '\\' => {
                    self.pos += 1;
                    if (self.peek() == '\\') {
                        self.pos += 1;
                        return try self.parseMultilineStr();
                    }
                },
                '[' => {
                    self.pos += 1;
                    return try self.parseArray();
                },
                else => {},
            }
        }
        return error.ExpectedValue;
    }

    fn parseInteger(self: *Parser, init_digit: ?i64, is_neg: bool) ParseError!Value {
        var num: i64 = 0;
        if (init_digit == 0) {
            return .{
                .i64 = 0,
            };
        } else if (init_digit == null) {
            if (self.peek()) |char| {
                switch (char) {
                    '1'...'9' => {
                        num = char - '0';
                        self.pos += 1;
                    },
                    '0' => {
                        self.pos += 1;
                        return .{
                            .i64 = 0,
                        };
                    },
                    else => {
                        return error.ExpectedDigit;
                    },
                }
            } else {
                return error.ExpectedDigit;
            }
        } else {
            num = init_digit.?;
            if (is_neg) {
                num = -num;
            }
        }
        while (self.peek()) |char| {
            switch (char) {
                '0'...'9' => |digitch| {
                    const digit = digitch - '0';
                    num *= 10;
                    num += digit;
                    self.pos += 1;
                },
                else => {
                    return .{
                        .i64 = num,
                    };
                },
            }
        }
        return .{
            .i64 = num,
        };
    }

    fn parseStr(self: *Parser) ParseError!Value {
        var string: str.StringUnmanaged = .{};
        errdefer string.deinit(self.allocator);
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
                                try string.append(self.allocator, '\\');
                            },
                            '"' => {
                                self.pos += 1;
                                try string.append(self.allocator, '"');
                            },
                            else => {
                                return error.InvalidEscapeSeq;
                            },
                        }
                    } else {
                        return error.UnexpectedEof;
                    }
                },
                else => {
                    self.pos += 1;
                    try string.append(self.allocator, char);
                },
            }
        }
        return .{ .string = string };
    }

    fn parseMultilineStr(self: *Parser) ParseError!Value {
        var string: str.StringUnmanaged = .{};
        errdefer string.deinit(self.allocator);
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
                            try string.append(self.allocator, '\n');
                            continue;
                        }
                    }
                    self.pos = orig_pos;
                    break;
                },
                else => {
                    self.pos += 1;
                    try string.append(self.allocator, char);
                },
            }
        }
        return .{ .string = string };
    }

    fn parseArray(self: *Parser) ParseError!Value {
        var array = std.ArrayList(Value).init(self.allocator);
        errdefer array.deinit();
        self.skipSpaceBeforeExpr();
        while (self.peek()) |char| {
            if (char == ']') {
                break;
            }
            const value = try self.nextValue();
            try array.append(value);
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
                        return error.ExpectedValue;
                    },
                }
            } else {
                return error.ExpectedValue;
            }
        }
        return .{ .array = try array.toOwnedSlice() };
    }
};
