const std = @import("std");

fn noAlloc(ctx: *anyopaque, len: usize, log2_align: u8, ra: usize) ?[*]u8 {
  _ = ctx;
  _ = len;
  _ = log2_align;
  _ = ra;
  return null;
}

pub const null_allocator = std.mem.Allocator {
  .ptr = undefined,
  .vtable = &.{
    .alloc = noAlloc,
    .resize = std.mem.Allocator.noResize,
    .free = std.mem.Allocator.noFree,
  },
};