const Self = @This();

const std = @import("std");
const optimizer = @import("./optimizer.zig");
const Expr = @import("./expr.zig");
const Instr = @import("./instr.zig").Instr;

const GroupData = struct {
  id: usize,
  instr_start: usize, // including group_start op
};

str_idx: usize = 0,

fn findLastSimpleExprOrGroup(expr: *Expr) ?usize {
  if (expr.instrs.items.len == 0) {
    return null;
  }
  if (expr.instrs.items[expr.instrs.items.len - 1].isSimpleMatcher()) {
    return expr.instrs.items.len - 1;
  }
  return switch (expr.instrs.items[expr.instrs.items.len - 1]) {
    .group_end => |group_id| group_id,
    else => null,
  };
}

pub fn parse(
  self: *Self,
  allocr: std.mem.Allocator,
  in_pattern: []const u8,
) !Expr {
  var expr: Expr = .{
    .instrs = .{},
    .num_groups = 0,
  };
  errdefer expr.deinit(allocr);
  
  var groups: std.ArrayListUnmanaged(GroupData) = .{};
  defer groups.deinit(allocr);
  
  const AltJmpTarget = struct {
    jmp_instr: usize,
    for_group: ?usize, // id or null if in parent group
  };
  var alternate_jmp_targets: std.ArrayListUnmanaged(AltJmpTarget) = .{};
  defer alternate_jmp_targets.deinit(allocr);
  
  outer: while (self.str_idx < in_pattern.len) {
    const seqlen = try std.unicode.utf8ByteSequenceLength(
      in_pattern[self.str_idx]
    );
    if ((in_pattern.len - self.str_idx) < seqlen) {
      return error.Utf8ExpectedContinuation;
    }
    const char: u32 = try std.unicode.utf8Decode(
      in_pattern[self.str_idx..(self.str_idx+seqlen)]
    );
    switch (char) {
      '+' => {
        // (len-1) L1: <char>
        // (len+0) bt L3
        // (len+1) jmp L1
        // (len+2) L3: ...
        if (findLastSimpleExprOrGroup(&expr)) |L1| {
          const L3 = expr.instrs.items.len + 2;
          try expr.instrs.append(allocr, .{ // +0
            .backtrack_target = L3,
          });
          try expr.instrs.append(allocr, .{ // +1
            .jmp = L1,
          });
        } else {
          return error.ExpectedSimpleExpr;
        }
      },
      '*' => {
        // (len-1) L0: bt L3
        // (len+0) L1: <char>
        // (len+1) consume_backtrack
        // (len+2) jmp L0
        // (len+3) L3: ...
        if (findLastSimpleExprOrGroup(&expr)) |L0| {
          const L3 = expr.instrs.items.len + 3;
          try expr.instrs.insert(allocr, L0, .{
            .backtrack_target = L3,
          });
          try expr.instrs.append(allocr, .{
            .consume_backtrack = {},
          });
          try expr.instrs.append(allocr, .{
            .jmp = L0,
          });
        } else {
          return error.ExpectedSimpleExpr;
        }
      },
      '?' => {
        // (len-1) L0: bt L3
        // (len+0) L1: <char>
        // (len+1) consume_backtrack
        // (len+2) L3: ...
        if (findLastSimpleExprOrGroup(&expr)) |L0| {
          const L3 = expr.instrs.items.len + 2;
          try expr.instrs.insert(allocr, L0, .{
            .backtrack_target = L3,
          });
          try expr.instrs.append(allocr, .{
            .consume_backtrack = {},
          });
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
        var ranges: std.ArrayListUnmanaged(Instr.Range) = .{};
        
        inner: while (self.str_idx < in_pattern.len) {
          const seqlen1 = try std.unicode.utf8ByteSequenceLength(
            in_pattern[self.str_idx]
          );
          if ((in_pattern.len - self.str_idx) < seqlen1) {
            return error.Utf8ExpectedContinuation;
          }
          const char1: u32 = try std.unicode.utf8Decode(
            in_pattern[self.str_idx..(self.str_idx+seqlen1)]
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
        
        try expr.instrs.append(allocr, .{
          .range = try ranges.toOwnedSlice(allocr),
        });
        continue :outer;
      },
      '(' => {
        const group_id = expr.num_groups;
        try groups.append(allocr, .{
          .id = group_id,
          .instr_start = expr.instrs.items.len,
        });
        expr.num_groups += 1;
        try expr.instrs.append(allocr, .{
          .group_start = group_id,
        });
      },
      ')' => {
        if (groups.popOrNull()) |group| {
          try expr.instrs.append(allocr, .{
            .group_end = group.id,
          });
          while (alternate_jmp_targets.items.len > 0) {
            const jmp_target = alternate_jmp_targets.items[alternate_jmp_targets.items.len - 1];
            if (jmp_target.for_group == group.id) {
              _ = alternate_jmp_targets.pop();
              expr.instrs.items[jmp_target.jmp_instr] = .{
                .jmp = expr.instrs.items.len,
              };
            } else {
              break;
            }
          }
        } else {
          return error.UnbalancedGroupBrackets;
        }
      },
      '|' => {
        // bt L3
        // L1: ... (+0)
        // consume_backtrack
        // jmp L4
        // L3: ...
        // L4: ...
        var backtrack_target_fill: usize = undefined;
        var for_group: ?usize = null;
        if (groups.items.len == 0) {
          // backtrack for the first half of the alternate pair
          // to jump to the start of the second half
          backtrack_target_fill = 0;
          try expr.instrs.insert(allocr, backtrack_target_fill, .{
            .backtrack_target = 0,
          });
          for (expr.instrs.items[(backtrack_target_fill+1)..]) |*instr| {
            instr.incrPc(1);
          }
        } else {
          const group = groups.items[groups.items.len - 1];
          backtrack_target_fill = group.instr_start;
          try expr.instrs.insert(allocr, backtrack_target_fill, .{
            .backtrack_target = 0,
          });
          for_group = group.id;
          for (expr.instrs.items[(backtrack_target_fill+1)..]) |*instr| {
            instr.incrPc(1);
          }
        }
        
        try expr.instrs.append(allocr, .{
          .consume_backtrack = {},
        });
        
        const first_half_alt_end = expr.instrs.items.len;
        try expr.instrs.append(allocr, .{
          .jmp = 0, // to be filled
        });
        try alternate_jmp_targets.append(allocr, .{
          .jmp_instr = first_half_alt_end,
          .for_group = for_group,
        });
        
        const second_half_alt_start = expr.instrs.items.len;
        expr.instrs.items[backtrack_target_fill] = .{
          .backtrack_target = second_half_alt_start,
        };
      },
      else => {
        try expr.instrs.append(allocr, .{ .char = char, });
      },
    }
    self.str_idx += seqlen;
  }
  if (groups.items.len > 1) {
    return error.UnbalancedGroupBrackets;
  }
  for (alternate_jmp_targets.items) |jmp_target| {
    std.debug.assert(jmp_target.for_group == null);
    expr.instrs.items[jmp_target.jmp_instr] = .{ .matched = {}, };
  }
  try expr.instrs.append(allocr, .{ .matched = {}, });
  try optimizer.optimizePrefixString(&expr, allocr);
  return expr;
}

