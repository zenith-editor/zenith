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
const patterns = @import("../patterns.zig");
const utils = @import("../utils.zig");

const Error = @import("../ds/error.zig").Error;
const Rc = @import("../ds/rc.zig").Rc;

const Reader = @This();

pub const ConfigErrorType =
  parser.ParseErrorType
  || parser.AccessError
  || OpenDirError
  || error {
    OutOfMemory,
    ExpectedRegexFlag,
    ExpectedColorCode,
    InvalidSection,
    InvalidKey,
    DuplicateKey,
    UnknownKey,
    HighlightLoadError,
    HighlightParseError,
  };

pub const ConfigError = struct {
  type: ConfigErrorType,
  pos: ?usize = null,
};

const ParseResult = Error(void, ConfigError);
pub const ConfigResult = Error(Reader, ConfigError);

const CONFIG_DIR = "zenith";
const CONFIG_FILENAME = "zenith.conf";

pub const HighlightType = struct {
  name: []u8,
  pattern: ?[]u8,
  color: ?u32,
  is_bold: bool,
  flags: patterns.Expr.Flags,
  promote_types: ?PromoteTypesList = null,
  
  fn deinit(self: *Highlight, allocr: std.mem.Allocator) void {
    allocr.free(self.name);
    if (self.pattern) |pattern| {
      allocr.free(pattern);
    }
    if (self.promote_types) |*promote_types| {
      promote_types.deinit(allocr);
    }
  }
};

pub const PromoteType = struct {
  to_typeid: usize,
  /// Must be sorted
  matches: [][]u8,
  
  fn deinit(self: *PromoteType, allocr: std.mem.Allocator) void {
    for (self.matches) |match| {
      allocr.free(match);
    }
    allocr.free(self.matches);
  }
};

pub const PromoteTypesList = Rc(std.ArrayListUnmanaged(PromoteType));

pub const Highlight = struct {
  tokens: std.ArrayListUnmanaged(HighlightType) = .{},
  extension: ?[]u8 = null,
  name_to_idx: std.StringHashMapUnmanaged(u32) = .{},
  
  fn deinit(self: *Highlight, allocr: std.mem.Allocator) void {
    for (self.tokens.items) |*token| {
      token.deinit(allocr);
    }
    self.tokens.deinit(allocr);
    if (self.extension) |extension| {
      allocr.free(extension);
    }
    self.name_to_idx.deinit(allocr);
  }
};

config_dir: ?std.fs.Dir = null,
config_filepath: ?[]u8 = null,

// config fields

tab_size: i32 = 2,
use_tabs: bool = false,
use_native_clipboard: bool = true,
show_line_numbers: bool = true,
wrap_text: bool = true,
highlights: std.ArrayListUnmanaged(Highlight) = .{},
highlights_ext_to_idx: std.StringHashMapUnmanaged(u32) = .{},

// methods

fn reset(self: *Reader, allocr: std.mem.Allocator) void {
  for (self.highlights.items) |*highlight| {
    highlight.deinit(allocr);
  }
  self.highlights.clearAndFree(allocr);
  self.highlights_ext_to_idx.clearAndFree(allocr);
  self.* = .{};
}

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
  config_dir: std.fs.Dir,
  path: []const u8,
) std.fs.Dir.RealPathAllocError![]u8 {
  return config_dir.realpathAlloc(allocr, path);
}

const OpenWithoutParsingResult = struct {
  reader: Reader,
  source: []u8,
};

fn openWithoutParsing(allocr: std.mem.Allocator) ConfigErrorType!OpenWithoutParsingResult {
  var config_dir: std.fs.Dir = try Reader.getConfigDir();
  errdefer config_dir.close();
  
  const config_filepath: []u8 =
    try Reader.getConfigFile(allocr, config_dir, CONFIG_FILENAME);
  errdefer allocr.free(config_filepath);
  
  const reader: Reader = .{
    .config_dir = config_dir,
    .config_filepath = config_filepath,
  };
  
  const file = try std.fs.openFileAbsolute(reader.config_filepath.?, .{.mode = .read_only});
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
      allocr.free(res.reader.config_filepath.?);
      res.reader.config_filepath = null;
      return .{ .ok = res.reader, };
    },
    .err => |err| {
      return .{ .err = err, };
    }
  }
}

const HighlightToParse = struct {
  path: ?[]u8 = null,
  extension: ?[]u8 = null,
  
  fn deinit(self: *HighlightToParse, allocr: std.mem.Allocator) void {
    if (self.path) |s| { allocr.free(s); }
    if (self.extension) |s| { allocr.free(s); }
  }
};

const ParserState = struct {
  config_section: ConfigSection = .global,
  highlights: std.ArrayListUnmanaged(HighlightToParse) = .{},
  allocr: std.mem.Allocator,
  
  fn deinit(self: *ParserState) void {
    for (self.highlights.items) |*highlight| {
      highlight.deinit(self.allocr);
    }
    self.highlights.deinit(self.allocr);
  }
};

const ConfigSection = union(enum) {
  global,
  highlight: usize,
};

fn parseInner(
  self: *Reader,
  state: *ParserState,
  expr: *parser.Expr
) !void {
  switch (expr.*) {
    .kv => |*kv| {
      switch (state.config_section) {
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
          } else if (try kv.get(bool, "wrap-text")) |b| {
            self.wrap_text = b;
          } else {
            return error.UnknownKey;
          }
        },
        .highlight => |highlight_idx| {
          const highlight = &state.highlights.items[highlight_idx];
          if (try kv.get([]const u8, "path")) |s| {
            if (highlight.path != null) {
              return error.DuplicateKey;
            }
            highlight.path = try state.allocr.dupe(u8, s);
          } else if (try kv.get([]const u8, "extension")) |s| {
            if (highlight.extension != null) {
              return error.DuplicateKey;
            }
            highlight.extension = try state.allocr.dupe(u8, s);
          } else {
            return error.UnknownKey;
          }
        },
      }
    },
    .section => |section| {
      if (std.mem.eql(u8, section, "global")) {
        state.config_section = .global;
      } else {
        return error.InvalidSection;
      }
    },
    .table_section => |table_section| {
      if (std.mem.startsWith(u8, table_section, "highlight.")) {
        const highlight = table_section[("highlight".len)..];
        if (highlight.len == 0) {
          return error.InvalidSection;
        }
        state.config_section = .{ .highlight = state.highlights.items.len, };
        try state.highlights.append(state.allocr, .{});
      } else {
        return error.InvalidSection;
      }
    },
  }
}

const HighlightWriter = struct {
  reader: *Reader,
  state: *ParserState,
  
  name: ?[]u8 = null,
  pattern: ?[]u8 = null,
  flags: patterns.Expr.Flags = .{},
  color: ?u32 = null,
  is_bold: bool = false,
  promote_types: std.ArrayListUnmanaged(PromoteType) = .{},
  
  highlight: Highlight = .{},
  
  fn deinit(self: *HighlightWriter) void {
    if (self.pattern) |pattern| {
      self.state.allocr.free(pattern);
    }
    for (self.promote_types.items) |*match| {
      match.deinit(self.allocr);
    }
    self.promote_types.deinit(self.state.allocr);
    self.highlight.deinit(self.state.allocr);
  }
  
  fn setPattern(self: *HighlightWriter, pattern: []const u8) !void {
    if (self.pattern != null) {
      return error.DuplicateKey;
    }
    self.pattern = try self.state.allocr.dupe(u8, pattern);
  }
  
  fn setFlags(self: *HighlightWriter, flags: []const u8) !void {
    self.flags = patterns.Expr.Flags.fromShortCode(flags) catch {
      return error.ExpectedRegexFlag;
    };
  }
  
  fn flush(self: *HighlightWriter) !void {
    const tt_idx = self.highlight.tokens.items.len;
    try self.highlight.tokens.append(self.state.allocr, .{
      .name = self.name.?,
      .pattern = self.pattern,
      .flags = self.flags,
      .color = self.color,
      .is_bold = self.is_bold,
      .promote_types = (
        if (self.promote_types.items.len > 0)
          try PromoteTypesList.create(self.state.allocr, &self.promote_types)
        else
          null
      ),
    });
    if (try self.highlight.name_to_idx.fetchPut(
      self.state.allocr, self.name.?, @intCast(tt_idx)
    ) != null) {
      return error.DuplicateKey;
    }
    self.name = null;
    self.pattern = null;
    self.flags = .{};
    self.color = null;
    self.is_bold = false;
    self.promote_types = .{};
  }
};

fn parseHighlight(self: *Reader, state: *ParserState, hl_parse: *HighlightToParse) !void {
  const highlight_filepath: []u8 =
    try Reader.getConfigFile(
      state.allocr,
      self.config_dir.?,
      hl_parse.path orelse { return error.HighlightLoadError; }
    );
  defer state.allocr.free(highlight_filepath);
  
  const file = try std.fs.openFileAbsolute(highlight_filepath, .{.mode = .read_only});
  defer file.close();
  
  const source = try file.readToEndAlloc(state.allocr, 1 << 24);
  defer state.allocr.free(source);
  
  var P = parser.Parser.init(source);
  
  var writer: HighlightWriter = .{
    .reader = self,
    .state = state,
  };
  
  while (true) {
    var expr = switch (P.nextExpr(state.allocr)) {
      .ok => |val| val,
      .err => {
        // TODO: propagate error code
        return error.HighlightParseError;
      },
    } orelse break;
    errdefer expr.deinit(state.allocr);
    
    switch (expr) {
      .kv => |*kv| {
        if (try kv.get([]const u8, "pattern")) |s| {
          try writer.setPattern(s);
        } else if (try kv.get([]const u8, "flags")) |s| {
          try writer.setFlags(s);
        } else if (std.mem.eql(u8, kv.key, "color")) {
          if (kv.val.get([]const u8) catch null) |s| {
            writer.color = editor.Editor.ColorCode.idFromStr(s) orelse {
              return error.ExpectedColorCode;
            };
          } else if (kv.val.get(i32) catch null) |int| {
            writer.color = @intCast(int);
          } else {
            return error.ExpectedColorCode;
          }
        } else if (try kv.get(bool, "bold")) |b| {
          writer.is_bold = b;
        } else if (std.mem.startsWith(u8, kv.key, "promote:")) {
          
          const promote_key = kv.key[("promote:".len)..];
          if (promote_key.len == 0) {
            return error.InvalidKey;
          }
          const to_typeid = writer.highlight.name_to_idx.get(promote_key) orelse {
            return error.InvalidKey;
          };
          var promote_strs = std.ArrayList([]u8).init(state.allocr);
          errdefer promote_strs.deinit();
          const val_arr = (try kv.val.get([]parser.Value)) orelse {
            return error.InvalidKey;
          };
          for (val_arr) |val| {
            try promote_strs.append(
              try state.allocr.dupe(
                u8,
                try val.get([]const u8) orelse { return error.InvalidKey; }
              )
            );
          }
          std.mem.sort([]const u8, promote_strs.items, {}, utils.lessThanStr);
          try writer.promote_types.append(state.allocr, .{
            .to_typeid = to_typeid,
            .matches = try promote_strs.toOwnedSlice(),
          });
        } else {
          return error.InvalidKey;
        }
      },
      .table_section => |table_section| {
        if (writer.name != null) {
           try writer.flush();
        }
        writer.name = try state.allocr.dupe(u8, table_section);
      },
      else => {
        return error.HighlightParseError;
      },
    }
  }
  
  if (writer.name != null) {
    try writer.flush();
  }
  
  const highlight_idx = self.highlights.items.len;
  if (hl_parse.extension != null) {
    writer.highlight.extension = hl_parse.extension.?;
    hl_parse.extension = null;
    const old = try self.highlights_ext_to_idx.fetchPut(
      state.allocr,
      writer.highlight.extension.?, @intCast(highlight_idx)
    );
    if (old != null) {
      return error.DuplicateKey;
    }
  }
  try self.highlights.append(state.allocr, writer.highlight);
  writer.highlight = .{};
}

fn parse(self: *Reader, allocr: std.mem.Allocator, source: []const u8) ParseResult {
  var P = parser.Parser.init(source);
  var state: ParserState = .{
    .allocr = allocr,
  };
  defer state.deinit();
  
  while (true) {
    const expr_start = P.pos;
    var expr = switch (P.nextExpr(allocr)) {
      .ok => |val| val,
      .err => |err| {
        return .{ .err = .{ .type = err.type, .pos = err.pos, } };
      },
    } orelse break;
    errdefer expr.deinit(allocr);
    self.parseInner(&state, &expr) catch |err| {
      return .{ .err = .{ .type = err, .pos = expr_start, } };
    };
  }
  
  for (state.highlights.items) |*highlight| {
    self.parseHighlight(&state, highlight) catch |err| {
      return .{ .err = .{ .type = err, .pos = 0, } };
    };
  }
  
  return .{ .ok = {}, };
}
