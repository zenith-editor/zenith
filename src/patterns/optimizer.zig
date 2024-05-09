const std = @import("std");
const Expr = @import("./expr.zig");
const Instr = @import("./instr.zig").Instr;

pub fn optimizePrefixString(self: *Expr, allocr: std.mem.Allocator) !void {
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
        const n_bytes = std.unicode.utf8Encode(
          @intCast(char), &char_bytes
        ) catch unreachable;
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
