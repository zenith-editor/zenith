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

pub const ConfigError = struct {
    pub const Type =
        parser.ParseErrorType || parser.AccessError || OpenDirError || error{
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

    pub const Location = union(enum) {
        not_loaded,
        main,
        highlight: []u8,
    };

    type: Type,
    pos: ?usize = null,
    location: Location = .not_loaded,

    pub fn deinit(self: *ConfigError, allocr: std.mem.Allocator) void {
        switch (self.location) {
            .highlight => |v| {
                allocr.free(v);
            },
            else => {},
        }
    }

    pub fn toString(self: *const ConfigError, allocr: std.mem.Allocator, args: struct {
        main_path: []const u8 = "",
    }) ![]u8 {
        switch (self.location) {
            .not_loaded => {
                return std.fmt.allocPrint(allocr, "Unable to read config file: {}", .{self.type});
            },
            .main => {
                return std.fmt.allocPrint(allocr, "Unable to read config file <{s}:+{}>: {}", .{ args.main_path, self.pos orelse 0, self.type });
            },
            .highlight => |path| {
                return std.fmt.allocPrint(allocr, "Unable to read config file <{s}:+{}>: {}", .{ path, self.pos.?, self.type });
            },
        }
    }
};

pub const ConfigResult = Error(void, ConfigError);

const CONFIG_DIR = "zenith";
const CONFIG_FILENAME = "zenith.conf";

pub const HighlightType = struct {
    name: []u8,
    pattern: ?[]u8,
    color: ?u32,
    deco: editor.Editor.ColorCode.Decoration,
    flags: patterns.Expr.Flags,
    promote_types: std.ArrayListUnmanaged(PromoteType),

    pub fn deinit(self: *Highlight, allocr: std.mem.Allocator) void {
        allocr.free(self.name);
        if (self.pattern) |pattern| {
            allocr.free(pattern);
        }
        self.promote_types.deinit(allocr);
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

pub const Highlight = struct {
    tokens: std.ArrayListUnmanaged(HighlightType) = .{},
    name_to_token: std.StringHashMapUnmanaged(u32) = .{},
    tab_size: ?u32 = null,
    use_tabs: ?bool = null,

    fn deinit(self: *Highlight, allocr: std.mem.Allocator) void {
        for (self.tokens.items) |*token| {
            token.deinit(allocr);
        }
        self.tokens.deinit(allocr);
        self.name_to_token.deinit(allocr);
    }
};

pub const HighlightRc = Rc(Highlight);

const HighlightDecl = struct {
    path: ?[]u8 = null,
    extension: std.ArrayListUnmanaged([]u8) = .{},
    tab_size: ?u32 = null,
    use_tabs: ?bool = null,

    fn deinit(self: *HighlightDecl, allocr: std.mem.Allocator) void {
        if (self.path) |s| {
            allocr.free(s);
        }
        for (self.extension.items) |ext| {
            allocr.free(ext);
        }
        self.extension.deinit(allocr);
    }
};

const HighlightClass = struct {
    name: []u8,
    color: ?u32 = null,
    deco: editor.Editor.ColorCode.Decoration = .{},

    fn deinit(self: *HighlightClass, allocr: std.mem.Allocator) void {
        allocr.free(self.name);
    }
};

config_dir: ?std.fs.Dir = null,
config_filepath: ?[]u8 = null,

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

//terminal feature flags
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
    .{ .field = "update_mark_on_nav", .conf = "update-mark-on-navigate" },
    .{ .field = "force_bracketed_paste", .conf = "force-bracketed-paste" },
    .{ .field = "force_alt_screen_buf", .conf = "force-alt-screen-buf" },
    .{ .field = "force_alt_scroll_mode", .conf = "force-alt-scroll-mode" },
    .{ .field = "force_mouse_tracking", .conf = "force-mouse-tracking" },
};

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
    std.fs.File.OpenError || std.fs.File.ReadError || std.fs.Dir.RealPathAllocError || error{
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
        if (openDir(.{"$XDG_CONFIG_HOME"})) |config_path_env| {
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
    source: []u8,
};

fn openWithoutParsing(self: *Reader, allocr: std.mem.Allocator) ConfigError.Type!OpenWithoutParsingResult {
    if (self.config_dir == null) {
        self.config_dir = try Reader.getConfigDir();
    }

    const config_filepath: []u8 = try Reader.getConfigFile(allocr, self.config_dir.?, CONFIG_FILENAME);
    self.config_filepath = config_filepath;

    const file = try std.fs.openFileAbsolute(self.config_filepath.?, .{ .mode = .read_only });
    defer file.close();

    const source = try file.readToEndAlloc(allocr, 1 << 24);
    return .{
        .source = source,
    };
}

pub fn open(self: *Reader, allocr: std.mem.Allocator) ConfigResult {
    const res = self.openWithoutParsing(allocr) catch |err| {
        return .{
            .err = .{
                .type = err,
            },
        };
    };
    switch (self.parse(allocr, res.source)) {
        .ok => {
            return .{
                .ok = {},
            };
        },
        .err => |err| {
            return .{
                .err = err,
            };
        },
    }
}

const ParserState = struct {
    config_section: ConfigSection = .global,
    highlight_decls: std.ArrayListUnmanaged(HighlightDecl) = .{},
    /// Must be E.allocr
    allocr: std.mem.Allocator,

    fn deinit(self: *ParserState) void {
        for (self.highlight_decls.items) |*highlight| {
            highlight.deinit(self.allocr);
        }
        self.highlight_decls.deinit(self.allocr);
    }
};

const ConfigSection = union(enum) {
    global,
    highlight: usize,
    hl_class: usize,
};

fn splitPrefix(key: []const u8, comptime prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, key, prefix)) {
        return key[prefix.len..];
    }
    return null;
}

fn parseInner(self: *Reader, state: *ParserState, expr: *parser.Expr) !void {
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
                        var use_file_opener = std.ArrayList([]u8).init(state.allocr);
                        errdefer {
                            for (use_file_opener.items) |item| {
                                state.allocr.free(item);
                            }
                            use_file_opener.deinit();
                        }
                        for (val_arr) |val| {
                            try use_file_opener.append(try state.allocr.dupe(u8, val.getOpt([]const u8) orelse {
                                return error.InvalidKey;
                            }));
                        }
                        self.use_file_opener = try use_file_opener.toOwnedSlice();
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
                    const decl: *HighlightDecl = &state.highlight_decls.items[decl_idx];
                    if (try kv.get([]const u8, "path")) |s| {
                        if (decl.path != null) {
                            return error.DuplicateKey;
                        }
                        decl.path = try state.allocr.dupe(u8, s);
                    } else if (std.mem.eql(u8, kv.key, "extension")) {
                        if (kv.val.getOpt([]const u8)) |s| {
                            const ext = try state.allocr.dupe(u8, s);
                            try decl.extension.append(state.allocr, ext);
                            const old = try self.highlights_ext_to_idx.fetchPut(state.allocr, ext, decl_idx);
                            if (old != null) {
                                return error.DuplicateKey;
                            }
                        } else if (kv.val.getOpt([]parser.Value)) |array| {
                            for (array) |val| {
                                const ext = try state.allocr.dupe(u8, try val.getErr([]const u8));
                                try decl.extension.append(state.allocr, ext);
                                const old = try self.highlights_ext_to_idx.fetchPut(state.allocr, ext, decl_idx);
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
                    } else if (try kv.get([]const u8, "inherit")) |s| {
                        _ = s;
                        @panic("TODO");
                    } else {
                        return error.UnknownKey;
                    }
                },
                .hl_class => |hl_class_idx| {
                    const hl_class: *HighlightClass = &self.hl_classes.items[hl_class_idx];
                    if (std.mem.eql(u8, kv.key, "color")) {
                        if (kv.val.getOpt([]const u8)) |s| {
                            hl_class.color = editor.Editor.ColorCode.idFromStr(s);
                        } else if (kv.val.getOpt(i64)) |int| {
                            hl_class.color = @intCast(int);
                        } else {
                            return error.ExpectedColorCode;
                        }
                    } else if (try kv.get(bool, "bold")) |b| {
                        hl_class.deco.is_bold = b;
                    } else if (try kv.get(bool, "italic")) |b| {
                        hl_class.deco.is_italic = b;
                    } else if (try kv.get(bool, "underline")) |b| {
                        hl_class.deco.is_underline = b;
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
                    .highlight = state.highlight_decls.items.len,
                };
                try state.highlight_decls.append(state.allocr, .{});
            } else if (splitPrefix(table_section, "hl_class.")) |hl_class_name| {
                if (hl_class_name.len == 0) {
                    return error.InvalidSection;
                }
                const hl_class_id = self.hl_classes.items.len;
                const hl_class: HighlightClass = .{
                    .name = try state.allocr.dupe(u8, hl_class_name),
                };
                state.config_section = .{
                    .hl_class = hl_class_id,
                };
                try self.hl_classes.append(state.allocr, hl_class);
                const old = try self.hl_classes_by_name.fetchPut(state.allocr, hl_class.name, hl_class_id);
                if (old != null) {
                    return error.DuplicateKey;
                }
            } else {
                return error.InvalidSection;
            }
        },
    }
}

const HighlightWriter = struct {
    reader: *Reader,
    allocr: std.mem.Allocator,

    highlight_type: ?HighlightType = null,
    highlight: Highlight = .{},

    fn deinit(self: *HighlightWriter) void {
        if (self.highlight_type != null) {
            self.highlight_type.?.deinit(self.allocr);
        }
        self.highlight.deinit(self.allocr);
    }

    fn beginHighlightType(self: *HighlightWriter, name_in: []const u8) !void {
        if (self.highlight_type != null) {
            @panic("highlight_type is not null");
        }
        const name = try self.allocr.dupe(u8, name_in);
        self.highlight_type = .{
            .name = name,
            .pattern = null,
            .color = null,
            .deco = .{},
            .flags = .{},
            .promote_types = .{},
        };
    }

    fn setPattern(self: *HighlightWriter, pattern: []const u8) !void {
        if (self.highlight_type.?.pattern != null) {
            return error.DuplicateKey;
        }
        self.highlight_type.?.pattern = try self.allocr.dupe(u8, pattern);
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
        if (try self.highlight.name_to_token.fetchPut(self.allocr, highlight_type.name, @intCast(tt_idx)) != null) {
            return error.DuplicateKey;
        }

        try self.highlight.tokens.append(self.allocr, highlight_type);
    }
};

fn parseTabSize(int: i64) u32 {
    if (int > conf.MAX_TAB_SIZE) {
        return conf.MAX_TAB_SIZE;
    } else if (int < 0) {
        return 2;
    } else {
        return @intCast(int);
    }
}

pub fn parseHighlight(
    self: *Reader,
    allocr: std.mem.Allocator,
    highlight_id: usize,
) ConfigResult {
    if (self.highlights.items[highlight_id] != null) {
        return .{ .ok = {} };
    }

    const decl = &self.highlight_decls.items[highlight_id];
    const highlight_filepath: []u8 = Reader.getConfigFile(allocr, self.config_dir.?, decl.path orelse {
        return .{
            .err = .{
                .type = error.HighlightLoadError,
                .pos = 0,
                .location = .not_loaded,
            },
        };
    }) catch |err| {
        return .{
            .err = .{
                .type = err,
                .pos = 0,
                .location = .{
                    .highlight = decl.path.?,
                },
            },
        };
    };
    defer allocr.free(highlight_filepath);

    const file = std.fs.openFileAbsolute(highlight_filepath, .{ .mode = .read_only }) catch |err| {
        return .{
            .err = .{
                .type = err,
                .pos = 0,
                .location = .not_loaded,
            },
        };
    };
    defer file.close();

    const source = file.readToEndAlloc(allocr, 1 << 24) catch |err| {
        return .{
            .err = .{
                .type = err,
                .pos = 0,
                .location = .not_loaded,
            },
        };
    };
    defer allocr.free(source);

    var P = parser.Parser.init(source);

    var writer: HighlightWriter = .{
        .reader = self,
        .allocr = allocr,
        .highlight = .{
            .tab_size = decl.tab_size,
            .use_tabs = decl.use_tabs,
        },
    };

    var expr_start: usize = 0;

    while (true) {
        expr_start = P.pos;
        var expr = switch (P.nextExpr(allocr)) {
            .ok => |val| val,
            .err => |err| {
                return .{ .err = .{
                    .type = err.type,
                    .pos = err.pos,
                    .location = .{ .highlight = decl.path.? },
                } };
            },
        } orelse break;
        defer expr.deinit(allocr);

        parseHighlightInner(&writer, &expr) catch |err| {
            return .{ .err = .{
                .type = err,
                .pos = expr_start,
                .location = .{ .highlight = decl.path.? },
            } };
        };
    }

    if (writer.highlight_type != null) {
        writer.flush() catch |err| {
            return .{ .err = .{
                .type = err,
                .pos = expr_start,
                .location = .{ .highlight = decl.path.? },
            } };
        };
    }

    self.highlights.items[highlight_id] = HighlightRc.create(allocr, &writer.highlight) catch |err| {
        return .{ .err = .{
            .type = err,
            .pos = 0,
            .location = .{ .highlight = decl.path.? },
        } };
    };
    writer.highlight = .{};

    return .{
        .ok = {},
    };
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
                writer.highlight_type.?.deco = hl_class.deco;
            } else if (std.mem.eql(u8, kv.key, "color")) {
                if (kv.val.getOpt([]const u8)) |s| {
                    writer.highlight_type.?.color = editor.Editor.ColorCode.idFromStr(s) orelse {
                        return error.ExpectedColorCode;
                    };
                } else if (kv.val.getOpt(i64)) |int| {
                    writer.highlight_type.?.color = @intCast(int);
                } else {
                    return error.ExpectedColorCode;
                }
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
                var promote_strs = std.ArrayList([]u8).init(writer.allocr);
                errdefer {
                    for (promote_strs.items) |item| {
                        writer.allocr.free(item);
                    }
                    promote_strs.deinit();
                }
                const val_arr = kv.val.getOpt([]parser.Value) orelse {
                    return error.InvalidKey;
                };
                for (val_arr) |val| {
                    try promote_strs.append(try writer.allocr.dupe(u8, val.getOpt([]const u8) orelse {
                        return error.InvalidKey;
                    }));
                }
                std.mem.sort([]const u8, promote_strs.items, {}, utils.lessThanStr);
                try writer.highlight_type.?.promote_types.append(writer.allocr, .{
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

fn parse(self: *Reader, allocr: std.mem.Allocator, source: []const u8) ConfigResult {
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
                return .{ .err = .{
                    .type = err.type,
                    .pos = err.pos,
                    .location = .main,
                } };
            },
        } orelse break;
        defer expr.deinit(allocr);
        self.parseInner(&state, &expr) catch |err| {
            return .{ .err = .{
                .type = err,
                .pos = expr_start,
                .location = .main,
            } };
        };
    }

    self.highlight_decls = state.highlight_decls;
    state.highlight_decls = .{};
    self.highlights.appendNTimes(allocr, null, self.highlight_decls.items.len) catch |err| {
        return .{ .err = .{
            .type = err,
        } };
    };

    return .{
        .ok = {},
    };
}
