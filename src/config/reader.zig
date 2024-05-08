//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//

const std = @import("std");
const builtin = @import("builtin");

const parser = @import("./parser.zig");
const conf = @import("../config.zig");
const str = @import("../str.zig");
const editor = @import("../editor.zig");

const Reader = @This();

const ConfigSection = enum {
  global,
};

pub const ConfigError = error {
  ExpectedIntValue,
  ExpectedBoolValue,
  ExpectedStringValue,
  InvalidSection,
  UnknownKey,
};

const CONFIG_DIR = "zenith";
const CONFIG_FILENAME = "zenith.conf";

config_dir: ?std.fs.Dir = null,
file_path: ?[]u8 = null,

// config fields

tab_size: i32 = 2,
use_native_clipboard: bool = true,
show_line_numbers: bool = true,

// methods

fn getConfigDir() !?std.fs.Dir {
  switch (builtin.target.os.tag) {
    .linux => {
      var opt_config_path: ?std.fs.Dir = null;
      if (std.posix.getenv("XDG_CONFIG_HOME")) |config_path_env| {
        opt_config_path = std.fs.openDirAbsolute(config_path_env, .{}) catch blk: {
          break :blk null;
        };
      }
      if (opt_config_path == null) {
        if (std.posix.getenv("HOME")) |home_env| {
          const home: std.fs.Dir = try std.fs.openDirAbsolute(home_env, .{});
          opt_config_path = try home.openDir(".config", .{});
        }
      }
      const config_path = opt_config_path.?;
      return try config_path.openDir(CONFIG_DIR, .{});
    },
    else => {
      @compileError("TODO: config dir for target");
    }
  }
}

fn getConfigFile(allocr: std.mem.Allocator, opt_config_dir: ?std.fs.Dir) !?[]u8 {
  if (opt_config_dir) |config_dir| {
    return try config_dir.realpathAlloc(allocr, CONFIG_FILENAME);
  } else {
    return null;
  }
}

pub fn open(allocr: std.mem.Allocator) !Reader {
  var opt_config_dir: ?std.fs.Dir = try Reader.getConfigDir();
  errdefer if (opt_config_dir != null) {
    opt_config_dir.?.close();
  };
  
  const opt_config_file: ?[]u8 = try Reader.getConfigFile(allocr, opt_config_dir);
  errdefer if (opt_config_file != null) {
    allocr.free(opt_config_file.?);
  };
  
  var reader: Reader = .{
    .config_dir = opt_config_dir,
    .file_path = opt_config_file,
  };
  
  const file = try std.fs.openFileAbsolute(reader.file_path.?, .{.mode = .read_only});
  errdefer file.close();
  
  const source = try file.readToEndAlloc(allocr, 1 << 24);
  errdefer allocr.free(source);
  
  try reader.parse(allocr, source);
  
  return reader;
}

fn parse(self: *Reader, allocr: std.mem.Allocator, source: []const u8) !void {
  var P = parser.Parser.init(source);
  var config_section = ConfigSection.global;
  while (true) {
    var expr = switch (P.nextExpr(allocr)) {
      .ok => |val| val,
      .err => |err| {
        _ = err;
        // TODO
        return;
      },
    } orelse return;
    errdefer expr.deinit(allocr);
    switch (expr) {
      .kv => |*kv| {
        if (std.mem.eql(u8, kv.key, "tab-size")) {
          switch (kv.val) {
            .int => |int| {
              if (int > conf.MAX_TAB_SIZE) {
                self.tab_size = conf.MAX_TAB_SIZE;
              } else if (int < 0) {
                self.tab_size = 2;
              } else {
                self.tab_size = int;
              }
            },
            else => { return ConfigError.ExpectedIntValue; },
          }
        } else if (std.mem.eql(u8, kv.key, "use-native-clipboard")) {
          switch (kv.val) {
            .boole => |boole| { self.use_native_clipboard = boole; },
            else => { return ConfigError.ExpectedBoolValue; },
          }
        } else if (std.mem.eql(u8, kv.key, "show-line-numbers")) {
          switch (kv.val) {
            .boole => |boole| { self.show_line_numbers = boole; },
            else => { return ConfigError.ExpectedBoolValue; },
          }
        } else {
          return ConfigError.UnknownKey;
        }
      },
      .section => |section| {
        if (std.mem.eql(u8, section, "global")) {
          config_section = ConfigSection.global;
        } else {
          return ConfigError.InvalidSection;
        }
      },
    }
  }
}
