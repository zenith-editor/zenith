//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const Self = @This();

const std = @import("std");
const builtin = @import("builtin");

const parser = @import("./parser.zig");
const conf = @import("../config.zig");
const str = @import("../str.zig");
const editor = @import("../editor.zig");
const patterns = @import("../patterns.zig");
const utils = @import("../utils.zig");
const Rc = @import("../ds/rc.zig").Rc;

pub const ConfigError =
    parser.ParseError || parser.AccessError || OpenDirError || error{
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

pub const DirWithPath = struct {
    path: []u8,
    dir: std.fs.Dir,

    pub fn fromPath(path: []u8) !DirWithPath {
        return .{
            .path = path,
            .dir = try std.fs.openDirAbsolute(path, .{}),
        };
    }
};

pub const Diagnostic = struct {
    pos: ?usize = null,
    path: []const u8,
};

const CONFIG_DIR = "zenith";
const CONFIG_FILENAME = "zenith.conf";

pub const HighlightType = struct {
    name: []u8,
    pattern: ?[]u8,
    color: ?u32,
    bg: ?u32,
    deco: editor.ColorCode.Decoration,
    flags: patterns.Expr.Flags,
    promote_types: std.ArrayListUnmanaged(PromoteType),

    pub fn deinit(self: *Highlight, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.pattern) |pattern| {
            allocator.free(pattern);
        }
        self.promote_types.deinit(allocator);
    }
};

pub const PromoteType = struct {
    to_typeid: usize,
    /// Must be sorted
    matches: [][]u8,

    fn deinit(self: *PromoteType, allocator: std.mem.Allocator) void {
        for (self.matches) |match| {
            allocator.free(match);
        }
        allocator.free(self.matches);
    }
};

pub const Highlight = struct {
    tokens: std.ArrayListUnmanaged(HighlightType) = .{},
    name_to_token: std.StringHashMapUnmanaged(u32) = .{},
    tab_size: ?u32 = null,
    use_tabs: ?bool = null,

    fn deinit(self: *Highlight, allocator: std.mem.Allocator) void {
        for (self.tokens.items) |*token| {
            token.deinit(allocator);
        }
        self.tokens.deinit(allocator);
        self.name_to_token.deinit(allocator);
    }
};

pub const HighlightRc = Rc(Highlight);

const HighlightDecl = struct {
    path: ?[]u8 = null,
    extension: std.ArrayListUnmanaged([]u8) = .{},
    tab_size: ?u32 = null,
    use_tabs: ?bool = null,

    fn deinit(self: *HighlightDecl, allocator: std.mem.Allocator) void {
        if (self.path) |s| {
            allocator.free(s);
        }
        for (self.extension.items) |ext| {
            allocator.free(ext);
        }
        self.extension.deinit(allocator);
    }
};

const HighlightClass = struct {
    name: []u8,
    color: ?u32 = null,
    bg: ?u32 = null,
    deco: editor.ColorCode.Decoration = .{},

    fn deinit(self: *HighlightClass, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

config_dir: ?DirWithPath = null,
config_filepath: ?[]u8 = null,
allocator: std.mem.Allocator,

imported_paths: std.ArrayListUnmanaged([]u8) = .{},
diagnostics: std.ArrayListUnmanaged(Diagnostic) = .{},

// config fields

tab_size: u32 = 2,
detect_tab_size: bool = true,
use_tabs: bool = false,
use_native_clipboard: bool = true,
show_line_numbers: bool = true,
wrap_text: bool = true,
undo_memory_limit: usize = 4 * 1024 * 1024, // bytes
escape_time: i64 = 20, // ms
large_file_limit: u32 = 10 * 1024 * 1024, // bytes
update_mark_on_nav: bool = false,
use_file_opener: ?[][]u8 = null,
buffered_output: bool = false,
bg: editor.ColorCode.Bg = .transparent,
empty_bg: editor.ColorCode.Bg = .transparent,
color: u32 = 8,
special_char_color: u32 = 10,
line_number_color: u32 = 10,

// terminal feature flags
force_bracketed_paste: bool = true,
force_alt_screen_buf: bool = true,
force_alt_scroll_mode: bool = true,
force_mouse_tracking: bool = true,

highlights: std.ArrayListUnmanaged(?HighlightRc) = .{},
highlight_decls: std.ArrayListUnmanaged(HighlightDecl) = .{},
/// extension key strings owned highlight_decls
highlights_ext_to_idx: std.StringHashMapUnmanaged(usize) = .{},

hl_classes: std.ArrayListUnmanaged(HighlightClass) = .{},
hl_classes_by_name: std.StringHashMapUnmanaged(usize) = .{},

// regular config fields
const ConfigField = struct {
    field: []const u8,
    conf: []const u8,
};

const REGULAR_CONFIG_FIELDS = [_]ConfigField{
    .{ .field = "use_tabs", .conf = "use-tabs" },
    .{ .field = "detect_tab_size", .conf = "detect-tab-size" },
    .{ .field = "use_native_clipboard", .conf = "use-native-clipboard" },
    .{ .field = "show_line_numbers", .conf = "show-line-numbers" },
    .{ .field = "wrap_text", .conf = "wrap-text" },
    .{ .field = "escape_time", .conf = "escape-time" },
    .{ .field = "buffered_output", .conf = "buffered-output" },
    .{ .field = "update_mark_on_nav", .conf = "update-mark-on-navigate" },
    .{ .field = "force_bracketed_paste", .conf = "force-bracketed-paste" },
    .{ .field = "force_alt_screen_buf", .conf = "force-alt-screen-buf" },
    .{ .field = "force_alt_scroll_mode", .conf = "force-alt-scroll-mode" },
    .{ .field = "force_mouse_tracking", .conf = "force-mouse-tracking" },
};

// methods

fn reset(self: *Self) void {
    for (self.imported_paths.items) |path| {
        self.allocator.free(path);
    }
    self.imported_paths.clearAndFree(self.allocator);
    self.diagnostics.clearAndFree(self.allocator);
    for (self.highlights.items) |*highlight| {
        highlight.deinit(self.allocator);
    }
    self.highlights.clearAndFree(self.allocator);
    self.highlight_decls.clearAndFree(self.allocator);
    self.highlights_ext_to_idx.clearAndFree(self.allocator);
    for (self.hl_classes.items) |*hl_classes| {
        hl_classes.deinit(self.allocator);
    }
    self.hl_classes.clearAndFree(self.allocator);
    self.hl_classes_by_name.deinit(self.allocator);
    self.* = .{};
}

pub fn clearDiagnostics(self: *Self) void {
    self.diagnostics.clearAndFree(self.allocator);
}

const OpenDirError =
    std.fs.File.OpenError || std.fs.File.ReadError || std.fs.Dir.RealPathAllocError || error{
    OutOfMemory,
    EnvironmentVariableNotFound,
};

fn openDir(allocator: std.mem.Allocator, dirs: []const []const u8) OpenDirError!DirWithPath {
    var paths = std.ArrayList([]const u8).init(allocator);
    errdefer paths.deinit();
    for (dirs) |dir| {
        var path_comp: []const u8 = undefined;
        if (std.mem.startsWith(u8, dir, "$")) {
            if (std.posix.getenv(dir[1..])) |env| {
                path_comp = env;
            } else {
                return error.EnvironmentVariableNotFound;
            }
        } else {
            path_comp = dir;
        }
        try paths.append(path_comp);
    }
    const path = try std.fs.path.join(allocator, paths.items);
    errdefer allocator.free(path);
    const dir = try std.fs.openDirAbsolute(path, .{});
    return .{
        .path = path,
        .dir = dir,
    };
}

fn getConfigDir(allocator: std.mem.Allocator) OpenDirError!DirWithPath {
    const os = builtin.target.os.tag;
    if (comptime (os == .linux or os.isBSD())) {
        return openDir(allocator, &[_][]const u8{ "$XDG_CONFIG_HOME", CONFIG_DIR }) catch {
            return openDir(allocator, &[_][]const u8{ "$HOME", ".config", CONFIG_DIR });
        };
    } else {
        @compileError("TODO: config dir for target");
    }
}

fn getConfigFile(
    allocator: std.mem.Allocator,
    config_dir: DirWithPath,
    path: []const u8,
) std.fs.Dir.RealPathAllocError![]u8 {
    return config_dir.dir.realpathAlloc(allocator, path);
}

fn openWithoutParsing(self: *Self) ConfigError![]u8 {
    if (self.config_dir == null) {
        self.config_dir = try getConfigDir(self.allocator);
    }

    const config_filepath: []u8 = try getConfigFile(self.allocator, self.config_dir.?, CONFIG_FILENAME);
    self.config_filepath = config_filepath;

    const file = try std.fs.openFileAbsolute(self.config_filepath.?, .{ .mode = .read_only });
    defer file.close();

    const source = try file.readToEndAlloc(self.allocator, std.math.maxInt(u32));
    return source;
}

pub fn open(self: *Self) ConfigError!void {
    const source = try self.openWithoutParsing();
    try self.parse(source, self.config_dir.?.dir);
}

const ConfigParserState = struct {
    config_section: ConfigSection = .global,
    parent_dir: std.fs.Dir,
};

fn splitPrefix(key: []const u8, comptime prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, key, prefix)) {
        return key[prefix.len..];
    }
    return null;
}

fn parseTabSize(int: i64) u32 {
    if (int > conf.MAX_TAB_SIZE) {
        return conf.MAX_TAB_SIZE;
    } else if (int < 0) {
        return 2;
    } else {
        return @intCast(int);
    }
}

const ConfigSection = union(enum) {
    global,
    highlight: usize,
    hl_class: usize,
};

fn parseColor(val: *const parser.Value) !u32 {
    if (val.getOpt([]const u8)) |s| {
        return editor.ColorCode.idFromStr(s) orelse {
            return error.ExpectedColorCode;
        };
    } else if (val.getOpt(i64)) |int| {
        return @intCast(int);
    } else {
        return error.ExpectedColorCode;
    }
}

// Highlighting

const HighlightWriter = struct {
    reader: *Self,
    allocator: std.mem.Allocator,

    highlight_type: ?HighlightType = null,
    highlight: Highlight = .{},

    fn deinit(self: *HighlightWriter) void {
        if (self.highlight_type != null) {
            self.highlight_type.?.deinit(self.allocator);
        }
        self.highlight.deinit(self.allocator);
    }

    fn beginHighlightType(self: *HighlightWriter, name_in: []const u8) !void {
        if (self.highlight_type != null) {
            @panic("highlight_type is not null");
        }
        const name = try self.allocator.dupe(u8, name_in);
        self.highlight_type = .{
            .name = name,
            .pattern = null,
            .color = null,
            .bg = null,
            .deco = .{},
            .flags = .{},
            .promote_types = .{},
        };
    }

    fn setPattern(self: *HighlightWriter, pattern: []const u8) !void {
        if (self.highlight_type.?.pattern != null) {
            return error.DuplicateKey;
        }
        self.highlight_type.?.pattern = try self.allocator.dupe(u8, pattern);
    }

    fn setFlags(self: *HighlightWriter, flags: []const u8) !void {
        self.highlight_type.?.flags = patterns.Expr.Flags.fromShortCode(flags) catch {
            return error.ExpectedRegexFlag;
        };
    }

    fn flush(self: *HighlightWriter) !void {
        if (self.highlight_type == null) {
            return;
        }

        const highlight_type = self.highlight_type.?;
        self.highlight_type = null;

        const tt_idx = self.highlight.tokens.items.len;
        if (try self.highlight.name_to_token.fetchPut(self.allocator, highlight_type.name, @intCast(tt_idx)) != null) {
            return error.DuplicateKey;
        }

        try self.highlight.tokens.append(self.allocator, highlight_type);
    }
};

pub fn parseHighlight(
    self: *Self,
    highlight_id: usize,
) ConfigError!void {
    if (self.highlights.items[highlight_id] != null) {
        return;
    }

    const decl = &self.highlight_decls.items[highlight_id];
    const highlight_filepath: []u8 = getConfigFile(self.allocator, self.config_dir.?, decl.path orelse {
        return error.HighlightLoadError;
    }) catch |err| {
        try self.diagnostics.append(self.allocator, .{ .path = decl.path.? });
        return err;
    };
    defer self.allocator.free(highlight_filepath);

    const file = std.fs.openFileAbsolute(highlight_filepath, .{ .mode = .read_only }) catch |err| {
        try self.diagnostics.append(self.allocator, .{ .path = highlight_filepath });
        return err;
    };
    defer file.close();

    const source = file.readToEndAlloc(self.allocator, 1 << 24) catch |err| {
        try self.diagnostics.append(self.allocator, .{ .path = highlight_filepath });
        return err;
    };
    defer self.allocator.free(source);

    var P: parser.Parser = .{
        .source = source,
        .allocator = self.allocator,
    };

    var writer: HighlightWriter = .{
        .reader = self,
        .allocator = self.allocator,
        .highlight = .{
            .tab_size = decl.tab_size,
            .use_tabs = decl.use_tabs,
        },
    };

    var expr_start: usize = 0;

    while (true) {
        expr_start = P.pos;
        var expr = P.nextExpr() catch |err| {
            try self.diagnostics.append(self.allocator, .{
                .pos = P.pos,
                .path = decl.path.?,
            });
            return err;
        } orelse break;
        defer expr.deinit(self.allocator);

        parseHighlightInner(&writer, &expr) catch |err| {
            try self.diagnostics.append(self.allocator, .{
                .pos = expr_start,
                .path = decl.path.?,
            });
            return err;
        };
    }

    if (writer.highlight_type != null) {
        writer.flush() catch |err| {
            try self.diagnostics.append(self.allocator, .{
                .pos = expr_start,
                .path = decl.path.?,
            });
            return err;
        };
    }

    self.highlights.items[highlight_id] = HighlightRc.create(self.allocator, &writer.highlight) catch |err| {
        try self.diagnostics.append(self.allocator, .{
            .path = decl.path.?,
        });
        return err;
    };
    writer.highlight = .{};
}

fn parseHighlightInner(writer: *HighlightWriter, expr: *const parser.Expr) !void {
    switch (expr.*) {
        .kv => |*kv| {
            if (try kv.get([]const u8, "pattern")) |s| {
                try writer.setPattern(s);
            } else if (try kv.get([]const u8, "flags")) |s| {
                try writer.setFlags(s);
            } else if (try kv.get([]const u8, "inherit")) |s| {
                const hl_class_id = writer.reader.hl_classes_by_name.get(s) orelse {
                    return error.InvalidKey;
                };
                const hl_class: *const HighlightClass = &writer.reader.hl_classes.items[hl_class_id];
                writer.highlight_type.?.color = hl_class.color;
                writer.highlight_type.?.bg = hl_class.bg;
                writer.highlight_type.?.deco = hl_class.deco;
            } else if (std.mem.eql(u8, kv.key, "color")) {
                writer.highlight_type.?.color = try parseColor(&kv.val);
            } else if (std.mem.eql(u8, kv.key, "bg")) {
                writer.highlight_type.?.bg = try parseColor(&kv.val);
            } else if (try kv.get(bool, "bold")) |b| {
                writer.highlight_type.?.deco.is_bold = b;
            } else if (try kv.get(bool, "italic")) |b| {
                writer.highlight_type.?.deco.is_italic = b;
            } else if (try kv.get(bool, "underline")) |b| {
                writer.highlight_type.?.deco.is_underline = b;
            } else if (splitPrefix(kv.key, "promote:")) |promote_key| {
                if (promote_key.len == 0) {
                    return error.InvalidKey;
                }
                const to_typeid = writer.highlight.name_to_token.get(promote_key) orelse {
                    return error.InvalidKey;
                };
                var promote_strs = std.ArrayList([]u8).init(writer.allocator);
                errdefer {
                    for (promote_strs.items) |item| {
                        writer.allocator.free(item);
                    }
                    promote_strs.deinit();
                }
                const val_arr = kv.val.getOpt([]parser.Value) orelse {
                    return error.InvalidKey;
                };
                for (val_arr) |val| {
                    try promote_strs.append(try writer.allocator.dupe(u8, val.getOpt([]const u8) orelse {
                        return error.InvalidKey;
                    }));
                }
                std.mem.sort([]const u8, promote_strs.items, {}, utils.lessThanStr);
                try writer.highlight_type.?.promote_types.append(writer.allocator, .{
                    .to_typeid = to_typeid,
                    .matches = try promote_strs.toOwnedSlice(),
                });
            } else {
                return error.InvalidKey;
            }
        },
        .table_section => |table_section| {
            if (writer.highlight_type != null) {
                try writer.flush();
            }
            try writer.beginHighlightType(table_section);
        },
        else => {
            return error.HighlightParseError;
        },
    }
}

// Config

fn parse(self: *Self, source: []const u8, parent_dir: std.fs.Dir) ConfigError!void {
    var P: parser.Parser = .{
        .source = source,
        .allocator = self.allocator,
    };
    var state: ConfigParserState = .{
        .parent_dir = parent_dir,
    };

    while (true) {
        const expr_start = P.pos;
        var expr = P.nextExpr() catch |err| {
            try self.diagnostics.append(self.allocator, .{
                .pos = P.pos,
                .path = self.config_filepath.?,
            });
            return err;
        } orelse break;
        defer expr.deinit(self.allocator);
        self.parseConfig(&state, &expr) catch |err| {
            try self.diagnostics.append(self.allocator, .{
                .pos = expr_start,
                .path = self.config_filepath.?,
            });
            return err;
        };
    }

    self.highlights.appendNTimes(self.allocator, null, self.highlight_decls.items.len) catch |err| {
        try self.diagnostics.append(self.allocator, .{
            .path = self.config_filepath.?,
        });
        return err;
    };
}

fn parseConfig(self: *Self, state: *ConfigParserState, expr: *parser.Expr) ConfigError!void {
    switch (expr.*) {
        .kv => |*kv| {
            switch (state.config_section) {
                .global => {
                    if (try kv.get(i64, "tab-size")) |int| {
                        self.tab_size = parseTabSize(int);
                    } else if (try kv.get(i64, "undo-memory-limit")) |int| {
                        self.undo_memory_limit =
                            if (int > std.math.maxInt(usize) or int < 0) std.math.maxInt(usize) else @intCast(int);
                    } else if (try kv.get(i64, "large-file-limit")) |int| {
                        self.large_file_limit =
                            if (int > std.math.maxInt(u32) or int < 0) std.math.maxInt(u32) else @intCast(int);
                    } else if (try kv.get([]parser.Value, "use-file-opener")) |val_arr| {
                        if (self.use_file_opener != null) {
                            return error.DuplicateKey;
                        }
                        var use_file_opener = std.ArrayList([]u8).init(self.allocator);
                        errdefer {
                            for (use_file_opener.items) |item| {
                                self.allocator.free(item);
                            }
                            use_file_opener.deinit();
                        }
                        for (val_arr) |val| {
                            try use_file_opener.append(try self.allocator.dupe(u8, val.getOpt([]const u8) orelse {
                                return error.InvalidKey;
                            }));
                        }
                        self.use_file_opener = try use_file_opener.toOwnedSlice();
                    } else if (try kv.get([]const u8, "include")) |path| {
                        const abs_path: []u8 = try state.parent_dir.realpathAlloc(self.allocator, path);
                        defer self.allocator.free(abs_path);
                        const parent_dirpath: []const u8 = std.fs.path.dirname(abs_path).?;
                        const parent_dir: std.fs.Dir = try std.fs.openDirAbsolute(parent_dirpath, .{});
                        const file = try std.fs.openFileAbsolute(abs_path, .{ .mode = .read_only });
                        defer file.close();
                        const source = try file.readToEndAlloc(self.allocator, std.math.maxInt(u32));
                        defer self.allocator.free(source);
                        try parseIncludeConfig(self, source, parent_dir, abs_path);
                    } else if (std.mem.eql(u8, kv.key, "bg")) {
                        self.bg = .{ .coded = try parseColor(&kv.val) };
                    } else if (std.mem.eql(u8, kv.key, "empty-bg")) {
                        self.empty_bg = .{ .coded = try parseColor(&kv.val) };
                    } else if (std.mem.eql(u8, kv.key, "color")) {
                        self.color = try parseColor(&kv.val);
                    } else if (std.mem.eql(u8, kv.key, "special-char-color")) {
                        self.special_char_color = try parseColor(&kv.val);
                    } else if (std.mem.eql(u8, kv.key, "line-number-color")) {
                        self.line_number_color = try parseColor(&kv.val);
                    } else {
                        inline for (&REGULAR_CONFIG_FIELDS) |*config_field| {
                            if (try kv.get(@TypeOf(@field(self, config_field.field)), config_field.conf)) |b| {
                                @field(self, config_field.field) = b;
                                return;
                            }
                        }
                        return error.UnknownKey;
                    }
                },
                .highlight => |decl_idx| {
                    const decl: *HighlightDecl = &self.highlight_decls.items[decl_idx];
                    if (try kv.get([]const u8, "path")) |s| {
                        if (decl.path != null) {
                            return error.DuplicateKey;
                        }
                        decl.path = try self.allocator.dupe(u8, s);
                    } else if (std.mem.eql(u8, kv.key, "extension")) {
                        if (kv.val.getOpt([]const u8)) |s| {
                            const ext = try self.allocator.dupe(u8, s);
                            try decl.extension.append(self.allocator, ext);
                            const old = try self.highlights_ext_to_idx.fetchPut(self.allocator, ext, decl_idx);
                            if (old != null) {
                                return error.DuplicateKey;
                            }
                        } else if (kv.val.getOpt([]parser.Value)) |array| {
                            for (array) |val| {
                                const ext = try self.allocator.dupe(u8, try val.getErr([]const u8));
                                try decl.extension.append(self.allocator, ext);
                                const old = try self.highlights_ext_to_idx.fetchPut(self.allocator, ext, decl_idx);
                                if (old != null) {
                                    return error.DuplicateKey;
                                }
                            }
                        } else {
                            return error.UnknownKey;
                        }
                    } else if (try kv.get(i64, "tab-size")) |int| {
                        decl.tab_size = parseTabSize(int);
                    } else if (try kv.get(bool, "use-tabs")) |b| {
                        decl.use_tabs = b;
                    } else {
                        return error.UnknownKey;
                    }
                },
                .hl_class => |hl_class_idx| {
                    const hl_class: *HighlightClass = &self.hl_classes.items[hl_class_idx];
                    if (std.mem.eql(u8, kv.key, "color")) {
                        hl_class.color = try parseColor(&kv.val);
                    } else if (try kv.get(bool, "bold")) |b| {
                        hl_class.deco.is_bold = b;
                    } else if (try kv.get(bool, "italic")) |b| {
                        hl_class.deco.is_italic = b;
                    } else if (try kv.get(bool, "underline")) |b| {
                        hl_class.deco.is_underline = b;
                    } else if (std.mem.eql(u8, kv.key, "bg")) {
                        hl_class.bg = try parseColor(&kv.val);
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
            if (splitPrefix(table_section, "highlight.")) |highlight| {
                if (highlight.len == 0) {
                    return error.InvalidSection;
                }
                state.config_section = .{
                    .highlight = self.highlight_decls.items.len,
                };
                try self.highlight_decls.append(self.allocator, .{});
            } else if (splitPrefix(table_section, "hl_class.")) |hl_class_name| {
                if (hl_class_name.len == 0) {
                    return error.InvalidSection;
                }
                const hl_class_id = self.hl_classes.items.len;
                const hl_class: HighlightClass = .{
                    .name = try self.allocator.dupe(u8, hl_class_name),
                };
                state.config_section = .{
                    .hl_class = hl_class_id,
                };
                try self.hl_classes.append(self.allocator, hl_class);
                const old = try self.hl_classes_by_name.fetchPut(self.allocator, hl_class.name, hl_class_id);
                if (old != null) {
                    return error.DuplicateKey;
                }
            } else {
                return error.InvalidSection;
            }
        },
    }
}

fn parseIncludeConfig(self: *Self, source: []const u8, parent_dir: std.fs.Dir, abs_path_src: []const u8) ConfigError!void {
    var P: parser.Parser = .{
        .source = source,
        .allocator = self.allocator,
    };
    var state: ConfigParserState = .{
        .parent_dir = parent_dir,
    };
    const abs_path: []u8 = try self.allocator.dupe(u8, abs_path_src);
    try self.imported_paths.append(self.allocator, abs_path);

    while (true) {
        const expr_start = P.pos;
        var expr = P.nextExpr() catch |err| {
            try self.diagnostics.append(self.allocator, .{
                .pos = P.pos,
                .path = abs_path,
            });
            return err;
        } orelse break;
        defer expr.deinit(self.allocator);
        self.parseConfig(&state, &expr) catch |err| {
            try self.diagnostics.append(self.allocator, .{
                .pos = expr_start,
                .path = abs_path,
            });
            return err;
        };
    }
}
