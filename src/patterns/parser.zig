//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const Self = @This();

const std = @import("std");
const optimizer = @import("./optimizer.zig");
const Expr = @import("./expr.zig");
const Instr = @import("./instr.zig").Instr;

in_pattern: []const u8,
str_idx: usize = 0,
flags: Expr.Flags,

fn findLastSimpleExpr(expr: *Expr) ?usize {
  if (expr.instrs.items.len == 0) {
    return null;
  }
  if (expr.instrs.items[expr.instrs.items.len - 1].isSimpleMatcher()) {
    return expr.instrs.items.len - 1;
  }
  return null;
}

const QualifierCodegenInfo = struct {
  expr_shift: usize,
};

fn genQualifier(
  allocr: std.mem.Allocator,
  char: u32,
  expr: *Expr,
  L0: usize,
) !QualifierCodegenInfo {
  switch (char) {
    '+' => {
      // (L0)    L0: <char>
      // (len+0) split L2, L0
      // (len+1) L2: ...
      const L2 = expr.instrs.items.len + 1;
      try expr.instrs.append(allocr, .{
        // order of a and b matters here,
        // having L0 execute first means that '+' performs a greedy match
        .split = .{ .a = L2, .b = L0, },
      });
      return .{ .expr_shift = 0, };
    },
    '*' => {
      // (L0)    L0: split L1, L2
      // (L0+1)  L1: <char>
      // len+0 accounts for new L0
      // (len+1) jmp L0
      // (len+2) L2: ...
      const L1 = L0 + 1;
      const L2 = expr.instrs.items.len + 2;
      for (expr.instrs.items) |*instr| {
        instr.incrPc(1, L0);
      }
      try expr.instrs.insert(allocr, L0, .{
        // again, greedy match
        .split = .{ .a = L2, .b = L1, },
      });
      try expr.instrs.append(allocr, .{
        .jmp = L0,
      });
      return .{ .expr_shift = 1, };
    },
    '-' => {
      // (L0)    L0: split L1, L2
      // (L0+1)  L1: <char>
      // len+0 accounts for new L0
      // (len+1) jmp L0
      // (len+2) L2: ...
      const L1 = L0 + 1;
      const L2 = expr.instrs.items.len + 2;
      for (expr.instrs.items) |*instr| {
        instr.incrPc(1, L0);
      }
      try expr.instrs.insert(allocr, L0, .{
        .split = .{ .a = L1, .b = L2, },
      });
      try expr.instrs.append(allocr, .{
        .jmp = L0,
      });
      return .{ .expr_shift = 1, };
    },
    '?' => {
      // (L0)    L0: split L1, L2
      // (L0+1)  L1: <char>
      // len+0 accounts for new L0
      // (len+1) L2: ...
      const L1 = L0 + 1;
      const L2 = expr.instrs.items.len + 1;
      for (expr.instrs.items) |*instr| {
        instr.incrPc(1, L0);
      }
      try expr.instrs.insert(allocr, L0, .{
        .split = .{ .a = L1, .b = L2, },
      });
      return .{ .expr_shift = 1, };
    },
    else => @panic("Unknown qualifier"),
  }
}

const GroupOrRoot = struct {
  instr_start: usize,
  group_id: ?usize,
};

fn parseGroup(
  self: *Self,
  allocr: std.mem.Allocator,
  expr: *Expr,
  parse_stack: *std.ArrayListUnmanaged(GroupOrRoot),
) !void {
  var jmp_to_end_targets: std.ArrayListUnmanaged(usize) = .{};
  defer jmp_to_end_targets.deinit(allocr);
  
  const group_or_root: GroupOrRoot = parse_stack.items[parse_stack.items.len - 1];
  
  var escaped = false;
  
  outer: while (self.str_idx < self.in_pattern.len) {
    const seqlen = try std.unicode.utf8ByteSequenceLength(
      self.in_pattern[self.str_idx]
    );
    if ((self.in_pattern.len - self.str_idx) < seqlen) {
      return error.Utf8ExpectedContinuation;
    }
    const char: u32 = try std.unicode.utf8Decode(
      self.in_pattern[self.str_idx..(self.str_idx+seqlen)]
    );
    
    if (escaped) {
      try expr.instrs.append(allocr, .{ .char = char, });
      escaped = false;
      self.str_idx += seqlen;
      continue :outer;
    }
    
    switch (char) {
      '+', '-', '*', '?' => |qualifier| {
        if (findLastSimpleExpr(expr)) |L0| {
          _ = try genQualifier(allocr, qualifier, expr, L0);
        } else {
          return error.ExpectedSimpleExpr;
        }
      },
      '[' => {
        self.str_idx += seqlen;
        
        const ParseState = enum {
          Normal,
          Escaped,
          SpecifyTo,
        };
        
        var from: ?u32 = null;
        var state: ParseState = .Normal;
        var range_inverse = false;
        var ranges: std.ArrayListUnmanaged(Instr.Range) = .{};
        
        if (
          self.str_idx < self.in_pattern.len
          and self.in_pattern[self.str_idx] == '^'
        ) {
          range_inverse = true;
          self.str_idx += 1;
        }
        
        inner: while (self.str_idx < self.in_pattern.len) {
          const seqlen1 = try std.unicode.utf8ByteSequenceLength(
            self.in_pattern[self.str_idx]
          );
          if ((self.in_pattern.len - self.str_idx) < seqlen1) {
            return error.Utf8ExpectedContinuation;
          }
          const char1: u32 = try std.unicode.utf8Decode(
            self.in_pattern[self.str_idx..(self.str_idx+seqlen1)]
          );
          
          if (state != .Escaped) {
            switch (char1) {
              '-' => {
                if (from == null or state == .SpecifyTo) {
                  return error.ExpectedEscapeBeforeDashInRange;
                }
                self.str_idx += seqlen1;
                state = .SpecifyTo;
                continue :inner;
              },
              ']' => {
                self.str_idx += seqlen1;
                break :inner;
              },
              '\\' => {
                self.str_idx += seqlen1;
                state = .Escaped;
                continue :inner;
              },
              else => {},
            }
          }
          
          if (state == .SpecifyTo) {
            self.str_idx += seqlen1;
            try ranges.append(allocr, .{
              .from = from.?,
              .to = char1,
            });
            from = null;
            state = .Normal;
            continue :inner;
          }
          
          self.str_idx += seqlen1;
          if (from == null) {
            from = char1;
          } else {
            try ranges.append(allocr, .{
              .from = from.?,
              .to = from.?,
            });
          }
          continue :inner;
        }
        
        if (from != null) {
          try ranges.append(allocr, .{
            .from = from.?,
            .to = from.?,
          });
        }
        
        if (range_inverse) {
          if (ranges.items.len == 1 and ranges.items[0].from == ranges.items[0].to) {
            try expr.instrs.append(allocr, .{
              .char_inverse = ranges.items[0].from,
            });
            ranges.deinit(allocr);
            ranges = undefined;
          } else {
            try expr.instrs.append(allocr, .{
              .range_inverse = try ranges.toOwnedSlice(allocr),
            });
          }
        } else {
          try expr.instrs.append(allocr, .{
            .range = try ranges.toOwnedSlice(allocr),
          });
        }
        continue :outer;
      },
      '(' => {
        self.str_idx += 1;
        
        const group_id = expr.num_groups;
        expr.num_groups += 1;
        
        try expr.instrs.append(allocr, .{
          .group_start = group_id,
        });
        
        try parse_stack.append(allocr, .{
          .instr_start = expr.instrs.items.len,
          .group_id = group_id,
        });
        
        return;
      },
      ')' => {
        self.str_idx += 1;
        if (group_or_root.group_id == null) {
          return error.UnbalancedGroupBrackets;
        }
        
        _ = parse_stack.pop();
        
        const group_end_instr = expr.instrs.items.len;
        try expr.instrs.append(allocr, .{
          .group_end = group_or_root.group_id.?,
        });
        
        if (self.str_idx < self.in_pattern.len) {
          switch (self.in_pattern[self.str_idx]) {
            '+', '-', '*', '?' => |qualifier| {
              self.str_idx += 1;
              
              const L0 = group_or_root.instr_start;
              const cg = try genQualifier(allocr, qualifier, expr, L0);
              
              for (jmp_to_end_targets.items) |jmp_instr| {
                switch (expr.instrs.items[jmp_instr + cg.expr_shift]) {
                  .abort => {},
                  else => @panic("not abort"),
                }
                expr.instrs.items[jmp_instr + cg.expr_shift] = .{
                  .jmp = group_end_instr + cg.expr_shift,
                };
              }
              
              return;
            },
            else => {},
          }
        }
        
        for (jmp_to_end_targets.items) |jmp_instr| {
          switch (expr.instrs.items[jmp_instr]) {
            .abort => {},
            else => @panic("not abort"),
          }
          expr.instrs.items[jmp_instr] = .{
            .jmp = group_end_instr,
          };
        }
        
        return;
      },
      '|' => {
        // (L0)    split L1, L2
        // (L0+1)  L1: ...
        // len+0 accounts for new L0
        // (len+1) jmp L3
        // (len+2) L2: ...
        const L0 = group_or_root.instr_start;
        const L1 = L0 + 1;
        const L2 = expr.instrs.items.len + 2;
        for (expr.instrs.items) |*instr| {
          instr.incrPc(1, L0);
        }
        try expr.instrs.insert(allocr, L0, .{
          .split = .{ .a = L1, .b = L2, },
        });
        if (group_or_root.group_id != null) {
          const jmp_instr = expr.instrs.items.len;
          try expr.instrs.append(allocr, .{
            .abort = {},
          });
          try jmp_to_end_targets.append(allocr, jmp_instr);
        } else {
          try expr.instrs.append(allocr, .{
            .matched = {},
          });
        }
      },
      '\\' => {
        escaped = true;
      },
      '.' => {
        if (self.flags.multiline) {
          try expr.instrs.append(allocr, .{ .any = {}, });
        } else {
          try expr.instrs.append(
            allocr,
            .{ .char_inverse = std.ascii.control_code.lf, });
        }
      },
      else => {
        try expr.instrs.append(allocr, .{ .char = char, });
      },
    }
    self.str_idx += seqlen;
  }
}

pub fn parse(
  self: *Self,
  allocr: std.mem.Allocator,
) !Expr {
  var expr: Expr = .{
    .instrs = .{},
    .num_groups = 0,
  };
  
  var parse_stack: std.ArrayListUnmanaged(GroupOrRoot) = .{};
  defer parse_stack.deinit(allocr);
  try parse_stack.append(allocr, .{
    .instr_start = 0,
    .group_id = null,
  });
  while (self.str_idx < self.in_pattern.len) {
    try self.parseGroup(allocr, &expr, &parse_stack);
  }
  if (parse_stack.items.len != 1) {
    return error.UnbalancedGroupBrackets;
  }
  
  try expr.instrs.append(allocr, .{
    .matched = {},
  });
  try optimizer.optimizePrefixString(&expr, allocr);
  return expr;
}