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
const Error = @import("../ds/error.zig").Error;

const Reader = @This();

const ConfigSection = enum {
  global,
};

pub const ConfigErrorType = parser.ParseErrorType || OpenDirError || error {
  OutOfMemory,
  ExpectedI32Value,
  ExpectedBoolValue,
  ExpectedStringValue,
  InvalidSection,
  UnknownKey,
};

pub const ConfigError = struct {
  type: ConfigErrorType,
  pos: ?usize = null,
};

const ParseResult = Error(void, ConfigError);
pub const ConfigResult = Error(Reader, ConfigError);

const CONFIG_DIR = "zenith";
const CONFIG_FILENAME = "zenith.conf";

config_dir: ?std.fs.Dir = null,
config_file: ?[]u8 = null,

// config fields

tab_size: i32 = 2,
use_tabs: bool = false,
use_native_clipboard: bool = true,
show_line_numbers: bool = true,

// methods

const OpenDirError =
  std.fs.File.OpenError
  || std.fs.File.ReadError
  || std.fs.Dir.RealPathAllocError
  || error {
    EnvironmentVariableNotFound,
  };

fn openDir(comptime dirs: anytype) OpenDirError!std.fs.Dir {
  var opt_path: ?std.fs.Dir = null;
  inline for (dirs) |dir| {
    var path_str: []const u8 = undefined;
    if (std.mem.startsWith(u8, dir, "$")) {
      if (std.posix.getenv(dir[1..])) |env| {
        path_str = env;
      } else {
        return error.EnvironmentVariableNotFound;
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

fn getConfigDir() OpenDirError!std.fs.Dir {
  const os = builtin.target.os.tag;
  if (comptime (os == .linux or os.isBSD())) {
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

fn getConfigFile(
  allocr: std.mem.Allocator,
  config_dir: std.fs.Dir
) std.fs.Dir.RealPathAllocError![]u8 {
  return config_dir.realpathAlloc(allocr, CONFIG_FILENAME);
}

const OpenWithoutParsingResult = struct {
  reader: Reader,
  source: []u8,
};

fn openWithoutParsing(allocr: std.mem.Allocator) ConfigErrorType!OpenWithoutParsingResult {
  var config_dir: std.fs.Dir = try Reader.getConfigDir();
  errdefer config_dir.close();
  
  const config_file: []u8 = try Reader.getConfigFile(allocr, config_dir);
  errdefer allocr.free(config_file);
  
  const reader: Reader = .{
    .config_dir = config_dir,
    .config_file = config_file,
  };
  
  const file = try std.fs.openFileAbsolute(reader.config_file.?, .{.mode = .read_only});
  defer file.close();
  
  const source = try file.readToEndAlloc(allocr, 1 << 24);
  errdefer allocr.free(source);
  
  return .{ .reader = reader, .source = source, };
}

pub fn open(allocr: std.mem.Allocator) ConfigResult {
  var res = openWithoutParsing(allocr) catch |err| {
    return .{ .err = .{ .type = err, }, };
  };
  switch(res.reader.parse(allocr, res.source)) {
    .ok => {
      res.reader.config_dir.?.close();
      res.reader.config_dir = null;
      allocr.free(res.reader.config_file.?);
      res.reader.config_file = null;
      return .{ .ok = res.reader, };
    },
    .err => |err| {
      return .{ .err = err, };
    }
  }
}

fn parseInner(self: *Reader,
              expr: *parser.Expr,
              config_section: *ConfigSection) !void {
  switch (expr.*) {
    .kv => |*kv| {
      switch (config_section.*) {
        .global => {
          if (try kv.get(i32, "tab-size")) |int| {
            if (int > conf.MAX_TAB_SIZE) {
              self.tab_size = conf.MAX_TAB_SIZE;
            } else if (int < 0) {
              self.tab_size = 2;
            } else {
              self.tab_size = int;
            }
          } else if (try kv.get(bool, "use-tabs")) |b| {
            self.use_tabs = b;
          } else if (try kv.get(bool, "use-native-clipboard")) |b| {
            self.use_native_clipboard = b;
          } else if (try kv.get(bool, "show-line-numbers")) |b| {
            self.show_line_numbers = b;
          } else {
            return error.UnknownKey;
          }
        },
      }
    },
    .section => |section| {
      if (std.mem.eql(u8, section, "global")) {
        config_section.* = ConfigSection.global;
      } else {
        return error.InvalidSection;
      }
    },
  }
}

fn parse(self: *Reader, allocr: std.mem.Allocator, source: []const u8) ParseResult {
  var P = parser.Parser.init(source);
  var config_section = ConfigSection.global;
  while (true) {
    const expr_start = P.pos;
    var expr = switch (P.nextExpr(allocr)) {
      .ok => |val| val,
      .err => |err| {
        return .{ .err = .{ .type = err.type, .pos = err.pos, } };
      },
    } orelse break;
    errdefer expr.deinit(allocr);
    self.parseInner(&expr, &config_section) catch |err| {
      return .{ .err = .{ .type = err, .pos = expr_start, } };
    };
  }
  return .{ .ok = {}, };
}
