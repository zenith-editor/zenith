const std = @import("std");

pub fn build(b: *std.Build) void {
  const options = b.addOptions();

  options.addOption(bool, "dbg_show_multibyte_line",
                    b.option(
                      bool,
                      "dbg_show_multibyte_line",
                      "Show whether line is multibyte in line number"
                    ) orelse false);

  options.addOption(bool, "dbg_show_gap_buf",
                    b.option(
                      bool,
                      "dbg_show_gap_buf",
                      "Show whether character is in gap buffer"
                    ) orelse false);

  options.addOption(bool, "dbg_print_read_byte",
                    b.option(
                      bool,
                      "dbg_print_read_byte",
                      "Print byte read from stdin"
                    ) orelse false);

  const target = b.standardTargetOptions(.{});
  const optimize = b.standardOptimizeOption(.{});

  const exe = b.addExecutable(.{
    .name = "zenith",
    .root_source_file = .{ .path = "src/main.zig" },
    .target = target,
    .optimize = optimize,
  });
  
  exe.root_module.addOptions("config", options);

  b.installArtifact(exe);
}
