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
use_tabs: bool = false,
use_native_clipboard: bool = true,
show_line_numbers: bool = true,

// methods

fn openDir(comptime dirs: anytype) !std.fs.Dir {
  var opt_path: ?std.fs.Dir = null;
  inline for (dirs) |dir| {
    var path_str: []const u8 = undefined;
    if (std.mem.startsWith(u8, dir, "$")) {
      if (std.posix.getenv(dir[1..])) |env| {
        path_str = env;
      } else {
        return error.EnvVarNotSet;
      }
    } else {
      path_str = dir;
    }
    if (opt_path == null) {
      opt_path = try std.fs.openDirAbsolute(path_str, .{});
    } else {
      opt_path = try opt_path.?.openDir(path_str, .{});
    }
  }
  return opt_path.?;
}

fn getConfigDir() !std.fs.Dir {
  const os = builtin.target.os.tag;
  if (os == .linux or os.isBSD()) {
    var config_dir: std.fs.Dir = undefined;
    if (openDir(.{ "$XDG_CONFIG_HOME" })) |config_path_env| {
      config_dir = config_path_env;
    } else |_| {
      config_dir = try openDir(.{ "$HOME", ".config" });
    }
    return config_dir.openDir(CONFIG_DIR, .{});
  } else {
    @compileError("TODO: config dir for target");
  }
}

fn getConfigFile(allocr: std.mem.Allocator, config_dir: std.fs.Dir) ![]u8 {
  return config_dir.realpathAlloc(allocr, CONFIG_FILENAME);
}

pub fn open(allocr: std.mem.Allocator) !Reader {
  var config_dir: std.fs.Dir = try Reader.getConfigDir();
  errdefer config_dir.close();
  
  const config_file: []u8 = try Reader.getConfigFile(allocr, config_dir);
  errdefer allocr.free(config_file);
  
  var reader: Reader = .{
    .config_dir = config_dir,
    .file_path = config_file,
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
        } else if (std.mem.eql(u8, kv.key, "use-tabs")) {
          switch (kv.val) {
            .bool => |b| { self.use_tabs = b; },
            else => { return ConfigError.ExpectedBoolValue; },
          }
        } else if (std.mem.eql(u8, kv.key, "use-native-clipboard")) {
          switch (kv.val) {
            .bool => |b| { self.use_native_clipboard = b; },
            else => { return ConfigError.ExpectedBoolValue; },
          }
        } else if (std.mem.eql(u8, kv.key, "show-line-numbers")) {
          switch (kv.val) {
            .bool => |b| { self.show_line_numbers = b; },
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
