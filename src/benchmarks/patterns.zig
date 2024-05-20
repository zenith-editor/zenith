const std = @import("std");
const Expr = @import("patterns").Expr;
const benchmark = @import("bench").benchmark;

pub fn main() !void {
  var arena_shared = std.heap.ArenaAllocator.init(std.heap.page_allocator);
  const allocr_shared = arena_shared.allocator();
  
  const Benchmark = struct {
    pattern: Expr,
    source: []const u8,
  };
  
  const benches = [_]Benchmark{
    .{
      .pattern = Expr.create(allocr_shared,
                             \\"([^"]|\\.)*"
                             , &.{}).asErr() catch @panic("create"),
      .source = [_]u8{'b'}**1000 ++ "\"aaa\\\"a\""[0..],
    },
  };
  
  const bench_names = [_][]const u8{
    "string",
  };
  
  try benchmark(struct {
    pub fn run(bench: Benchmark) ?Expr.FindResult {
      var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
      defer arena.deinit();
      const allocr = arena.allocator();
      return (
        bench.pattern.find(allocr, bench.source)
        catch @panic("checkMatch")
      );
    }
  }, .{
    .args = benches,
    .arg_names = bench_names,
  });
}