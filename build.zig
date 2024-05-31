const std = @import("std");

pub fn build(b: *std.Build) !void {
  const options = b.addOptions();
  
  // debug options

  inline for ([_]struct {
    name: []const u8,
    desc: []const u8,
  }{
    .{ .name = "dbg_show_multibyte_line",
       .desc = "Show whether line is multibyte in line number", },
    .{ .name = "dbg_show_gap_buf",
       .desc = "Show whether character is in the gap buffer", },
    .{ .name = "dbg_print_read_byte",
       .desc = "Print byte read from stdin", },
    .{ .name = "dbg_show_cont_line_no",
       .desc = "Show line numbers even for cont-lines", },
    .{ .name = "dbg_patterns_vm",
       .desc = "Enable debugging for regex VM", },
    .{ .name = "dbg_highlighting",
       .desc = "Enable debugging for syntax highlighting", },
  }) |dbg_opt| {
    const build_opt = b.option(bool, dbg_opt.name, dbg_opt.desc) orelse false;
    options.addOption(bool, dbg_opt.name, build_opt);
  }

  const version_opt = b.option(
    []const u8, "version", "overrides the version reported",
  ) orelse v: {
    var code: u8 = undefined;
    const git_describe = b.runAllowFail(&[_][]const u8{
      "git", "describe", "--tags",
    }, &code, .Ignore) catch {
      break :v "<unk>";
    };
    break :v std.mem.trim(u8, git_describe, " \n\r");
  };
  options.addOption([]const u8, "version", version_opt);
  
  // exe
  
  const target = b.standardTargetOptions(.{});
  const optimize = b.standardOptimizeOption(.{});
  
  const exe = b.addExecutable(.{
    .name = "zenith",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
  });
  
  exe.root_module.addOptions("build_config", options);

  b.installArtifact(exe);
  
  // modules (for testing)
  
  const patterns_module = b.addModule("patterns", .{
    .root_source_file = b.path("src/patterns.zig"),
    .target = target,
    .optimize = optimize,
  });
  patterns_module.addOptions("build_config", options);
  
  const config_module = b.addModule("config", .{
    .root_source_file = b.path("src/config.zig"),
    .target = target,
    .optimize = optimize,
  });
  config_module.addOptions("build_config", options);
  
  // tests
  
  const test_step = b.step("test", "Run tests");
  
  inline for ([_]struct {
    const Module = struct {
      name: []const u8,
      module: *std.Build.Module,
    };
    
    name: []const u8,
    path: []const u8,
    module: ?Module = null,
  }{
    .{ .name = "patterns",
       .path = "src/tests/patterns.zig",
       .module = .{ .name = "patterns", .module = patterns_module }, },
    .{ .name = "config",
       .path = "src/tests/config.zig",
       .module = .{ .name = "config", .module = config_module }, },
  }) |test_target| {
    const build_tests = b.addTest(.{
      .name = try std.fmt.allocPrint(b.allocator, "test_{s}", .{test_target.name}),
      .root_source_file = b.path(test_target.path),
      .target = target,
      .optimize = optimize,
    });
    if (test_target.module) |module| {
      build_tests.root_module.addImport(module.name, module.module);
    }
    
    const run_tests = b.addRunArtifact(build_tests);
    const install_tests = b.addInstallArtifact(build_tests, .{});
    
    const run_tests_step = b.step(
      try std.fmt.allocPrint(b.allocator, "test-{s}", .{test_target.name}),
      try std.fmt.allocPrint(b.allocator, "Run {s} tests", .{test_target.name}),
    );
    run_tests_step.dependOn(&run_tests.step);
    run_tests_step.dependOn(&install_tests.step);
    
    test_step.dependOn(run_tests_step);
  }
  
  // benchmark
  
  const bench_dep = b.addModule("bench", .{
    .root_source_file = .{ .path = "ext/zig-bench/bench.zig" },
    .target = target,
    .optimize = optimize,
  });
  
  const bench_step = b.step("benchmark", "Run benchmarks");
  
  inline for ([_]struct {
    const Module = struct {
      name: []const u8,
      module: *std.Build.Module,
    };
    
    name: []const u8,
    path: []const u8,
    module: ?Module = null,
  }{
    .{ .name = "patterns",
       .path = "src/benchmarks/patterns.zig",
       .module = .{ .name = "patterns", .module = patterns_module }, },
  }) |bench_target| {
    const build_benchs = b.addExecutable(.{
      .name = try std.fmt.allocPrint(b.allocator, "bench_{s}", .{bench_target.name}),
      .root_source_file = b.path(bench_target.path),
      .target = target,
      .optimize = optimize,
    });
    build_benchs.root_module.addImport("bench", bench_dep);
    if (bench_target.module) |module| {
      build_benchs.root_module.addImport(module.name, module.module);
    }
    
    const run_benchs = b.addRunArtifact(build_benchs);
    const install_benchs = b.addInstallArtifact(build_benchs, .{});
    
    const run_benchs_step = b.step(
      try std.fmt.allocPrint(b.allocator, "bench-{s}", .{bench_target.name}),
      try std.fmt.allocPrint(b.allocator, "Run {s} benchmarks", .{bench_target.name}),
    );
    run_benchs_step.dependOn(&run_benchs.step);
    run_benchs_step.dependOn(&install_benchs.step);
    
    bench_step.dependOn(run_benchs_step);
  }
}
