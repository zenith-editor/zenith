//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config");

const config = @import("./config.zig");
const kbd = @import("./kbd.zig");
const str = @import("./str.zig");
const text = @import("./text.zig");
const sig = @import("./platform/sig.zig");
const shortcuts = @import("./shortcuts.zig");
const encoding = @import("./encoding.zig");
const highlight = @import("./highlight.zig");
const lineinfo = @import("./lineinfo.zig");

const Expr = @import("./patterns.zig").Expr;

pub const State = enum {
    text,
    command,
    mark,

    const INIT = State.text;
};

const StateHandler = struct {
    handleInput: *const fn (self: *Editor, keysym: *const kbd.Keysym, is_clipboard: bool) anyerror!void,
    handleOutput: *const fn (self: *Editor) anyerror!void,
    onSet: ?*const fn (self: *Editor) void,
    onUnset: ?*const fn (self: *Editor, next_state: State) void,

    fn _createStateHandler(comptime T: type) StateHandler {
        return StateHandler{
            .handleInput = T.handleInput,
            .handleOutput = T.handleOutput,
            .onSet = (if (@hasDecl(T, "onSet")) @field(T, "onSet") else null),
            .onUnset = (if (@hasDecl(T, "onUnset")) @field(T, "onUnset") else null),
        };
    }

    const TextImpl = @import("./states/text.zig");
    const Text: StateHandler = _createStateHandler(TextImpl);

    const CommandImpl = @import("./states/command.zig");
    const Command: StateHandler = _createStateHandler(CommandImpl);

    const MarkImpl = @import("./states/mark.zig");
    const Mark: StateHandler = _createStateHandler(MarkImpl);

    const List = [_]*const StateHandler{
        &Text,
        &Command,
        &Mark,
    };
};

pub const CommandData = struct {
    pub const FnTable = struct {
        onInputted: *const fn (self: *Editor) anyerror!void,
        /// Handle key, returns false if no key is handled
        onKey: ?*const fn (self: *Editor, keysym: *const kbd.Keysym) anyerror!bool = null,
        onUnset: ?*const fn (self: *Editor, next_state: State) void = null,
    };

    pub const Args = union(enum) {
        pub const ReplaceAll = struct {
            needle: text.TextHandler.ReplaceNeedle,
        };

        pub const Find = struct {
            regex: ?Expr = null,
        };

        pub const Prompt = struct {
            handleYes: *const fn (self: *Editor) anyerror!void,
            handleNo: *const fn (self: *Editor) anyerror!void,
        };

        replace_all: ReplaceAll,
        find: Find,
        prompt: Prompt,

        fn deinit(self: *Args, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .replace_all => |*e| {
                    e.needle.deinit(allocator);
                },
                .find => |*e| {
                    if (e.regex) |*regex| {
                        regex.deinit(allocator);
                    }
                },
                else => {},
            }
        }
    };

    /// Prompt
    prompt: ?[]const u8 = null,

    /// (Error) message to display on top of prompt
    promptoverlay: ?str.MaybeOwnedSlice = null,

    /// Input for command
    cmdinp: str.StringUnmanaged = .{},

    /// Position of cursor in cmdinp
    cmdinp_pos: text.TextPos = .{},

    /// Functions for the current executed command
    fns: FnTable,

    /// Optional arguments
    args: ?Args = null,

    fn deinit(self: *CommandData, E: *Editor) void {
        if (self.promptoverlay) |*promptoverlay| {
            promptoverlay.deinit(E.allocator);
        }
        if (self.args) |*args| {
            args.deinit(E.allocator);
        }
        self.cmdinp.deinit(E.allocator);
    }

    pub fn replace(self: *CommandData, E: *Editor, new_cmd_data: *const CommandData) void {
        self.deinit(E);
        self.* = new_cmd_data.*;
    }

    pub fn replaceArgs(self: *CommandData, E: *Editor, new_args: *const Args) void {
        if (self.args != null) {
            self.args.?.deinit(E.allocator);
        }
        self.args = new_args.*;
    }

    pub fn replacePromptOverlay(self: *CommandData, E: *Editor, static: []const u8) void {
        if (self.promptoverlay != null) {
            self.promptoverlay.?.deinit(E.allocator);
        }
        self.promptoverlay = .{
            .static = static,
        };
    }

    pub fn replacePromptOverlayFmt(self: *CommandData, E: *Editor, comptime fmt: []const u8, args: anytype) !void {
        if (self.promptoverlay != null) {
            self.promptoverlay.?.deinit(E.allocator);
        }
        self.promptoverlay = .{
            .owned = try std.fmt.allocPrint(E.allocator, fmt, args),
        };
    }
};

pub const Commands = struct {
    pub const Open = @import("./cmd/open.zig");
    pub const GotoLine = @import("./cmd/gotoline.zig");
    pub const Find = @import("./cmd/find.zig");
    pub const Replace = @import("./cmd/replace.zig");
    pub const Prompt = @import("./cmd/prompt.zig");
};

pub const HideableMessage = struct {
    header: ?[]const u8 = null,
    text: str.MaybeOwnedSlice,
    rows: u32,
    offset: u32 = 0,
    offset_rows: u32 = 0,

    fn fromAllocated(header: ?[]const u8, owned_text: []u8) HideableMessage {
        return .{
            .header = header,
            .text = .{
                .owned = owned_text,
            },
            .rows = blk: {
                var n: u32 = 1;
                for (owned_text) |byte| {
                    if (byte == '\n') {
                        n += 1;
                    }
                }
                break :blk n;
            },
        };
    }

    fn deinit(self: *HideableMessage, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
    }

    fn calcRenderableRows(self: *const HideableMessage) u32 {
        return @min(self.rows - self.offset_rows, 5);
    }

    fn scrollNext(self: *HideableMessage) bool {
        const renderable_rows = self.calcRenderableRows();
        const slice = self.text.slice();
        var row: u32 = 0;
        while (self.offset < slice.len) {
            const byte = slice[self.offset];
            self.offset += 1;
            if (byte == '\n') {
                self.offset_rows += 1;
                row += 1;
                if (row == renderable_rows) {
                    break;
                }
            }
        }
        if (self.offset == slice.len and slice[slice.len - 1] != '\n') {
            self.offset_rows += 1;
        }
        return self.offset == slice.len;
    }
};

pub const Esc = struct {
    pub const CLEAR_SCREEN = "\x1b[2J";
    pub const CLEAR_LINE = "\x1b[2K";
    pub const CLEAR_REST_OF_LINE = "\x1b[K";
    pub const RESET_POS = "\x1b[H";

    pub const CURSOR_HIDE = "\x1b[?25l";
    pub const CURSOR_SHOW = "\x1b[?25h";

    pub const COLOR_INVERT = "\x1b[7m";
    pub const COLOR_DEFAULT = "\x1b[0m";

    pub const FG_BOLD = "\x1b[1m";
    pub const FG_ITALIC = "\x1b[3m";
    pub const FG_UNDERLINE = "\x1b[4m";
    pub const BG_COLOR = "\x1b[48;5;{d}m";
    pub const FG_COLOR = "\x1b[38;5;{d}m";
};

pub const ColorCode = struct {
    pub const Bg = union(enum) {
        transparent,
        coded: u32,

        pub fn eql(self: *const Bg, other: *const Bg) bool {
            switch (self.*) {
                .transparent => {
                    switch (other.*) {
                        .transparent => return true,
                        else => return false,
                    }
                },
                .coded => |coded| {
                    switch (other.*) {
                        .coded => |c1| return coded == c1,
                        else => return false,
                    }
                },
            }
        }

        pub fn isTransparent(self: *const Bg) bool {
            return switch (self.*) {
                .transparent => true,
                else => false,
            };
        }
    };

    pub const Decoration = struct {
        is_bold: bool = false,
        is_italic: bool = false,
        is_underline: bool = false,
        is_invert: bool = false,

        pub fn eql(self: *const Decoration, other: *const Decoration) bool {
            return (self.is_bold == other.is_bold and
                self.is_italic == other.is_italic and
                self.is_underline == other.is_underline and
                self.is_invert == other.is_invert);
        }
    };

    fg: ?u32 = null,
    bg: Bg = .transparent,
    deco: Decoration = .{},

    pub const MAX_COLORS = 15;

    pub const COLOR_STR = [_][]const u8{
        "black",
        "dark-red",
        "dark-green",
        "dark-yellow",
        "dark-blue",
        "dark-purple",
        "dark-cyan",
        "gray",
        "dark-gray",
        "red",
        "green",
        "yellow",
        "blue",
        "purple",
        "cyan",
        "white",
    };

    pub fn init(fg: ?u32, bg: ?u32, deco: Decoration) ColorCode {
        return .{
            .fg = (if (fg != null and fg.? <= MAX_COLORS) fg.? else null),
            .bg = blk: {
                if (bg) |coded| {
                    break :blk .{ .coded = coded };
                } else {
                    break :blk .transparent;
                }
            },
            .deco = deco,
        };
    }

    pub fn eql(self: *const ColorCode, other: *const ColorCode) bool {
        return (self.fg == other.fg and
            self.bg.eql(&other.bg) and
            self.deco.eql(&other.deco));
    }

    pub fn idFromStr(s: []const u8) ?u32 {
        for (COLOR_STR, 0..COLOR_STR.len) |color_cmp, i| {
            if (std.mem.eql(u8, color_cmp, s)) {
                return @intCast(i);
            }
        }
        return null;
    }
};

const RowPrinter = struct {
    const Self = @This();
    editor: *Editor,
    col: u32 = 0,
    text_width: u32,
    bg: ColorCode.Bg = .transparent,
    color_code: ColorCode = .{ .bg = .transparent },
    had_decoration: bool = false,

    fn init(editor: *Editor) Self {
        return .{
            .editor = editor,
            .text_width = editor.text_handler.dims.width,
        };
    }

    fn setColor(self: *Self, cc: *const ColorCode) !void {
        if (self.color_code.eql(cc)) {
            return;
        }
        self.color_code = cc.*;
        try self.writeColorCode(cc);
    }

    fn writeColorCodeBg(self: *Self, cc: *const ColorCode) !void {
        const bg: *const ColorCode.Bg = if (cc.bg.isTransparent()) &self.editor.conf.bg else &cc.bg;
        if (self.bg.eql(bg)) {
            return;
        }
        try self.editor.setBgColor(bg);
        self.bg = bg.*;
    }

    fn writeColorCode(self: *Self, cc: *const ColorCode) !void {
        if (self.had_decoration) {
            // TODO: properly reset decorations instead of clearing all cell attributes
            try self.editor.writeAll(Esc.COLOR_DEFAULT);
            self.bg = .transparent;
        }
        try self.writeColorCodeBg(cc);
        if (cc.fg) |fg| {
            try self.editor.writeFmt(Esc.FG_COLOR, .{fg});
        } else {
            try self.editor.writeFmt(Esc.FG_COLOR, .{self.editor.conf.color});
        }
        if (cc.deco.is_bold) {
            try self.editor.writeAll(Esc.FG_BOLD);
            self.had_decoration = true;
        }
        if (cc.deco.is_italic) {
            try self.editor.writeAll(Esc.FG_ITALIC);
            self.had_decoration = true;
        }
        if (cc.deco.is_underline) {
            try self.editor.writeAll(Esc.FG_UNDERLINE);
            self.had_decoration = true;
        }
        if (cc.deco.is_invert) {
            try self.editor.writeAll(Esc.COLOR_INVERT);
            self.had_decoration = true;
        }
    }

    fn writeAll(self: *Self, bytes: []const u8) !bool {
        var cwidth: u32 = 0;
        if (bytes.len == 1 and bytes[0] == '\t') {
            cwidth = Editor.HTAB_COLS;
        } else {
            cwidth = encoding.cwidth(std.unicode.utf8Decode(bytes) catch unreachable);
            if (cwidth == 0) {
                return true;
            }
        }
        if ((self.col + cwidth) > self.text_width) {
            return false;
        }
        if (bytes.len == 1 and bytes[0] == '\t') {
            const old_cc = self.color_code;

            var new_cc = self.color_code;
            new_cc.fg = self.editor.conf.special_char_color;
            try self.setColor(&new_cc);

            try self.editor.writeAll(Editor.HTAB_CHAR);

            try self.setColor(&old_cc);
        } else {
            try self.editor.writeAll(bytes);
        }
        self.col += cwidth;
        return true;
    }

    fn reset(self: *RowPrinter) !void {
        self.col = 0;
        try self.setColor(&.{ .bg = .transparent });
    }
};

pub const Dimensions = struct {
    width: u32 = 0,
    height: u32 = 0,
};

pub const UISignaller = struct {
    unprotected_editor: *Editor,

    pub inline fn setNeedsRedraw(self: *UISignaller) void {
        self.unprotected_editor.needs_redraw = true;
    }

    pub inline fn setNeedsUpdateCursor(self: *UISignaller) void {
        self.unprotected_editor.needs_update_cursor = true;
    }

    pub inline fn setHideableMsgConst(self: *UISignaller, static: []const u8) void {
        self.unprotected_editor.setHideableMsgConst(static);
    }
};

pub const Editor = struct {
    const Self = @This();
    pub const STATUS_BAR_HEIGHT = 2;
    const INPUT_BUFFER_SIZE = 64;
    const OutBuffer = std.fifo.LinearFifo(u8, .Dynamic);

    in: std.fs.File,
    inr: std.fs.File.Reader,
    /// Number of bytes read for this character
    in_read: usize = 0,

    out: std.fs.File,
    out_raw: std.fs.File.Writer,
    out_buffer: OutBuffer,

    orig_termios: ?std.posix.termios = null,

    needs_redraw: bool = true,
    needs_update_cursor: bool = true,

    state_handler: *const StateHandler,

    allocator: std.mem.Allocator,
    ws: Dimensions = .{},

    text_handler: text.TextHandler,
    highlight_last_iter_idx: usize = 0,
    conf: config.Reader,
    unprotected_hideable_msg: ?HideableMessage = null,
    unprotected_state: State = State.INIT,
    unprotected_cmd_data: ?CommandData = null,

    // terminal extensions

    has_bracketed_paste: bool = false,
    has_alt_screen_buf: bool = false,
    has_alt_scroll_mode: bool = false,
    has_mouse_tracking: bool = false,

    pub fn loadConfig(self: *Self) !void {
        self.conf.open() catch |err| {
            defer self.conf.clearDiagnostics();
            if (err == error.FileNotFound) {
                // ignored
            } else {
                try std.fmt.format(self.out_raw, "Unable to read config file: {}\n", .{err});
                try self.showConfigDiagnostics(self.out_raw);
                try self.errorPromptBeforeLoaded();
            }
        };

        self.text_handler.undo_mgr.setMemoryLimit(self.conf.undo_memory_limit);
    }

    pub fn showConfigDiagnostics(self: *const Self, writer: anytype) !void {
        for (self.conf.diagnostics.items) |*diagnostic| {
            if (diagnostic.pos) |pos| {
                try std.fmt.format(writer, "from {s}:+{}\n", .{ diagnostic.path, pos });
            } else {
                try std.fmt.format(writer, "from {s}\n", .{diagnostic.path});
            }
        }
    }

    pub fn showConfigErrors(self: *Self, err: config.Reader.ConfigError) !void {
        var fifo = std.fifo.LinearFifo(u8, .Dynamic).init(self.allocator);
        errdefer fifo.deinit();
        const writer = fifo.writer();
        try std.fmt.format(writer, "Unable to read config file: {}\n", .{err});
        try self.showConfigDiagnostics(writer);
        self.copyHideableMsg(&HideableMessage.fromAllocated("config error", try fifo.toOwnedSlice()));
    }

    pub fn errorPromptBeforeLoaded(self: *const Self) !void {
        try self.out_raw.print("Press Enter to continue...\n", .{});
        _ = self.inr.readByte() catch {};
        try self.out_raw.writeByte('\r');
    }

    pub fn getState(self: *const Self) State {
        return self.unprotected_state;
    }

    pub fn setState(self: *Self, state: State) void {
        std.debug.assert(state != self.unprotected_state);
        const old_state_handler = StateHandler.List[@intFromEnum(self.unprotected_state)];
        if (old_state_handler.onUnset) |onUnset| {
            onUnset(self, state);
        }
        self.unprotected_state = state;
        const state_handler = StateHandler.List[@intFromEnum(state)];
        self.state_handler = state_handler;
        if (state_handler.onSet) |onSet| {
            onSet(self);
        }
        self.needs_redraw = true;
        self.needs_update_cursor = true;
    }

    // command data

    pub fn getCmdData(self: *Self) *CommandData {
        return &self.unprotected_cmd_data.?;
    }

    pub fn setCmdData(self: *Self, cmd_data: *const CommandData) void {
        std.debug.assert(self.unprotected_cmd_data == null);
        self.unprotected_cmd_data = cmd_data.*;
    }

    pub fn unsetCmdData(self: *Self) void {
        self.unprotected_cmd_data.?.deinit(self);
        self.unprotected_cmd_data = null;
    }

    // hideable message

    pub fn setHideableMsgConst(self: *Self, static: []const u8) void {
        self.copyHideableMsg(&.{
            .text = .{
                .static = static,
            },
            .rows = 1,
        });
    }

    pub fn copyHideableMsg(self: *Self, other: *const HideableMessage) void {
        switch (other.text) {
            .owned => {
                if (self.unprotected_hideable_msg) |*msg| {
                    // TODO: scrollable message for owned slices
                    msg.deinit(self.allocator);
                }
                self.unprotected_hideable_msg = other.*;
            },
            .static => {
                if (self.unprotected_hideable_msg) |*msg| {
                    if (!msg.text.isOwned() and msg.text.static.ptr == other.text.static.ptr) {
                        if (msg.scrollNext()) {
                            msg.deinit(self.allocator);
                            self.unprotected_hideable_msg = null;
                        }
                        return;
                    } else {
                        msg.deinit(self.allocator);
                    }
                }
                self.unprotected_hideable_msg = other.*;
            },
        }
    }

    pub fn unsetHideableMsg(self: *Self) void {
        if (self.unprotected_hideable_msg != null) {
            self.unprotected_hideable_msg.?.deinit(self.allocator);
            self.unprotected_hideable_msg = null;
        }
    }

    // raw mode

    fn enableRawMode(self: *Self) !void {
        var termios: std.posix.termios = undefined;
        if (self.orig_termios) |orig_termios| {
            termios = orig_termios;
        } else {
            termios = try std.posix.tcgetattr(self.in.handle);
            self.orig_termios = termios;
        }

        termios.iflag.BRKINT = false;
        termios.iflag.ICRNL = false;
        termios.iflag.INPCK = false;
        termios.iflag.ISTRIP = false;
        termios.iflag.IXON = false;
        termios.iflag.IUTF8 = false;

        termios.oflag.OPOST = false;

        termios.cflag.CSIZE = std.posix.CSIZE.CS8;

        termios.lflag.ECHO = false;
        termios.lflag.ICANON = false;
        termios.lflag.IEXTEN = false;
        termios.lflag.ISIG = false;

        termios.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        termios.cc[@intFromEnum(std.posix.V.TIME)] = 1;

        try std.posix.tcsetattr(self.in.handle, std.posix.TCSA.FLUSH, termios);
    }

    pub fn disableRawMode(self: *Self) !void {
        if (self.orig_termios) |termios| {
            try std.posix.tcsetattr(self.in.handle, std.posix.TCSA.FLUSH, termios);
        }
        // self.orig_termios = null;
    }

    // console input

    fn readRaw(self: *Self) !u8 {
        return self.inr.readByte();
    }

    fn readByte(self: *Self) !u8 {
        const byte: u8 = try self.readRaw();
        self.in_read += 1;
        if (comptime build_config.dbg_print_read_byte) {
            if (std.ascii.isPrint(byte)) {
                std.debug.print("read: {} ({c})\n", .{ byte, byte });
            } else {
                std.debug.print("read: {}\n", .{byte});
            }
        }
        return byte;
    }

    fn readEsc(self: *Self) !u8 {
        const start = std.time.milliTimestamp();
        var now: i64 = start;
        while ((now - start) < self.conf.escape_time) {
            if (self.readRaw()) |byte| {
                if (comptime build_config.dbg_print_read_byte) {
                    if (std.ascii.isPrint(byte)) {
                        std.debug.print("readEsc: {} ({c})\n", .{ byte, byte });
                    } else {
                        std.debug.print("readEsc: {}\n", .{byte});
                    }
                }
                return byte;
            } else |_| {}
            std.time.sleep(std.time.ns_per_ms);
            now = std.time.milliTimestamp();
        }
        return error.EndOfStream;
    }

    fn flushConsoleInput(self: *Self) void {
        while (true) {
            _ = self.readRaw() catch break;
        }
    }

    const EscapeMatcher = struct {
        buffered: std.BoundedArray(u8, 4) = .{},
        editor: *Self,

        inline fn readByte(self: *EscapeMatcher) u8 {
            if (self.buffered.popOrNull()) |byte| {
                return byte;
            }
            return self.editor.readEsc() catch 0;
        }

        inline fn match(self: *EscapeMatcher, bytes: []const u8) bool {
            for (bytes, 0..bytes.len) |byte, i| {
                const cmp = self.readByte();
                if (cmp != byte) {
                    self.buffered.append(cmp) catch {
                        @panic("EscapeMatcher buffer too small");
                    };
                    var it = std.mem.reverseIterator(bytes[0..i]);
                    while (it.next()) |byte_read| {
                        self.buffered.append(byte_read) catch {
                            @panic("EscapeMatcher buffer too small");
                        };
                    }
                    return false;
                }
            }
            return true;
        }
    };

    fn readKey(self: *Self) ?kbd.Keysym {
        self.in_read = 0;
        const raw = self.readByte() catch return null;
        if (raw == kbd.Keysym.ESC) {
            if (self.readEsc()) |possible_esc| {
                if (possible_esc == '[') {
                    var matcher: EscapeMatcher = .{
                        .editor = self,
                    };
                    // 4 bytes
                    if (matcher.match("200~")) {
                        return kbd.Keysym.initSpecial(.paste_begin);
                    } else if (matcher.match("201~")) {
                        return kbd.Keysym.initSpecial(.paste_end);
                    } else if (matcher.match("1;5D")) {
                        return .{
                            .raw = 0,
                            .key = .left,
                            .ctrl_key = true,
                        };
                    } else if (matcher.match("1;5C")) {
                        return .{
                            .raw = 0,
                            .key = .right,
                            .ctrl_key = true,
                        };
                    } else if (matcher.match("<0;")) {
                        var input: std.BoundedArray(u8, 16) = .{};
                        var is_release = false;
                        while (self.readEsc() catch null) |cont| {
                            if (cont == 'M' or cont == 'm') {
                                is_release = cont == 'm';
                                break;
                            } else {
                                input.append(cont) catch {
                                    // escape sequence too large
                                    self.flushConsoleInput();
                                    return null;
                                };
                            }
                        }
                        var iter = std.mem.splitScalar(u8, input.slice(), ';');
                        var x: ?u32 = null;
                        var y: ?u32 = null;

                        while (iter.next()) |value| {
                            const pos = std.fmt.parseInt(u32, value, 10) catch return null;
                            if (x == null) {
                                x = pos;
                            } else if (y == null) {
                                y = pos;
                            } else {
                                break;
                            }
                        }

                        return kbd.Keysym.initMouse(x orelse return null, y orelse return null, is_release);
                    } else if (matcher.match("<64;")) {
                        while (self.readEsc() catch null) |cont| {
                            if (cont == 'M' or cont == 'm') {
                                break;
                            }
                        }
                        return kbd.Keysym.initSpecial(.scroll_up);
                    } else if (matcher.match("<65;")) {
                        while (self.readByte() catch null) |cont| {
                            if (cont == 'M' or cont == 'm') {
                                break;
                            }
                        }
                        return kbd.Keysym.initSpecial(.scroll_down);
                    }
                    // 2 bytes
                    else if (matcher.match("3~")) {
                        return kbd.Keysym.initSpecial(.del);
                    } else if (matcher.match("5~")) {
                        return kbd.Keysym.initSpecial(.pgup);
                    } else if (matcher.match("6~")) {
                        return kbd.Keysym.initSpecial(.pgdown);
                    }
                    // 1 byte
                    else if (matcher.match("A")) {
                        return kbd.Keysym.initSpecial(.up);
                    } else if (matcher.match("B")) {
                        return kbd.Keysym.initSpecial(.down);
                    } else if (matcher.match("C")) {
                        return kbd.Keysym.initSpecial(.right);
                    } else if (matcher.match("D")) {
                        return kbd.Keysym.initSpecial(.left);
                    } else if (matcher.match("F")) {
                        return kbd.Keysym.initSpecial(.end);
                    } else if (matcher.match("H")) {
                        return kbd.Keysym.initSpecial(.home);
                    } else {
                        self.flushConsoleInput();
                        return null;
                    }
                } else {
                    self.flushConsoleInput();
                    return null;
                }
            } else |_| {}
        }
        if (encoding.sequenceLen(raw)) |seqlen| {
            if (seqlen > 1) {
                var seq = std.BoundedArray(u8, 4).init(0) catch unreachable;
                seq.append(raw) catch unreachable;
                for (1..seqlen) |_| {
                    const cont = self.readByte() catch {
                        return null;
                    };
                    seq.append(cont) catch {
                        return null;
                    };
                }
                return kbd.Keysym.initMultibyte(seq.constSlice());
            }
        } else |_| {}
        return kbd.Keysym.init(raw);
    }

    // console output

    pub const HTAB_CHAR = "\xc2\xbb ";
    pub const HTAB_COLS = 2;
    pub const LINEWRAP_SYM = "\xe2\x8f\x8e";

    pub fn flushOutput(self: *Self) !void {
        if (self.conf.buffered_output) {
            const slice = self.out_buffer.readableSlice(0);
            if (slice.len == 0) {
                return;
            }
            // std.debug.print("{any}\n", .{slice});
            try self.out_raw.writeAll(slice);
            self.out_buffer.discard(slice.len);
        }
    }

    pub fn writeAll(self: *Self, bytes: []const u8) !void {
        if (self.conf.buffered_output) {
            return self.out_buffer.write(bytes);
        } else {
            return self.out_raw.writeAll(bytes);
        }
    }

    pub fn writeByte(self: *Self, byte: u8) !void {
        if (self.conf.buffered_output) {
            return self.out_buffer.writeItem(byte);
        } else {
            return self.out_raw.writeByte(byte);
        }
    }

    pub fn writeFmt(
        self: *Self,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        if (self.conf.buffered_output) {
            return std.fmt.format(self.out_buffer.writer(), fmt, args);
        } else {
            return std.fmt.format(self.out_raw, fmt, args);
        }
    }

    pub fn moveCursor(self: *Self, p_row: u32, p_col: u32) !void {
        var row = p_row;
        if (row > self.ws.height - 1) {
            row = self.ws.height - 1;
        }
        var col = p_col;
        if (col > self.ws.width - 1) {
            col = self.ws.width - 1;
        }
        return self.writeFmt("\x1b[{d};{d}H", .{ row + 1, col + 1 });
    }

    pub fn updateCursorPos(self: *Self) !void {
        const text_handler: *text.TextHandler = &self.text_handler;
        var col = text_handler.cursor.gfx_col - text_handler.scroll.gfx_col;
        if (self.conf.show_line_numbers) {
            col += text_handler.line_digits + 1;
        }
        try self.moveCursor(text_handler.cursor.row - text_handler.scroll.row, col);
    }

    pub fn refreshScreen(self: *Self) !void {
        try self.setBgColor(&self.conf.bg);
        try self.writeAll(Esc.CLEAR_SCREEN);
        try self.writeAll(Esc.RESET_POS);
    }

    pub fn setBgColor(self: *Self, bg: *const ColorCode.Bg) !void {
        switch (bg.*) {
            .transparent => {
                try self.writeAll(Esc.COLOR_DEFAULT);
            },
            .coded => |coded| {
                try self.writeFmt(Esc.BG_COLOR, .{coded});
            },
        }
    }

    // console dims

    pub fn updateWinSize(self: *Self) !void {
        if (builtin.target.os.tag == .linux) {
            const oldw = self.ws.width;
            const oldh = self.ws.height;
            var wsz: std.os.linux.winsize = undefined;
            const rc = std.os.linux.ioctl(self.in.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&wsz));
            if (std.posix.errno(rc) == .SUCCESS) {
                self.ws.height = wsz.ws_row;
                self.ws.width = wsz.ws_col;
            }
            if (oldw != 0 and oldh != 0) {
                self.text_handler.syncColumnScroll();
                self.text_handler.syncRowScroll();
            }
            self.needs_redraw = true;
        }
        try self.text_handler.onResize(&self.ws);
    }

    // handle input

    /// minimum number of consecutive bytes read to be considered
    /// from clipboard. this is a heuristic to detect input from clipboard
    /// if for some reason the vterm doesn't support it
    const TYPED_CLIPBOARD_BYTE_THRESHOLD = 3;

    const HandleInputResult = struct {
        is_special: bool = false,
        nread: usize = 0,
    };

    fn handleInput(self: *Self, is_clipboard: bool) !HandleInputResult {
        var nread: usize = 0;
        if (self.readKey()) |keysym| {
            nread += self.in_read;
            // TODO: specify ctrl-h somewhere else as opposed to hardcoding it
            if (!(keysym.ctrl_key and keysym.isChar('h')) and
                self.unprotected_hideable_msg != null)
            {
                self.unsetHideableMsg();
                self.needs_redraw = true;
            }
            switch (keysym.key) {
                .paste_begin => {
                    // see https://invisible-island.net/xterm/xterm-paste64.html
                    while (self.readKey()) |keysym1| {
                        nread += self.in_read;
                        switch (keysym1.key) {
                            .paste_end => {
                                break;
                            },
                            else => {
                                try self.state_handler.handleInput(self, &keysym1, true);
                            },
                        }
                    }
                    return .{ .is_special = true, .nread = nread };
                },
                else => {},
            }
            try self.state_handler.handleInput(self, &keysym, is_clipboard);
            return .{
                .is_special = keysym.isSpecial(),
                .nread = nread,
            };
        }
        return .{};
    }

    fn handleInputPolling(self: *Self) !void {
        switch (builtin.target.os.tag) {
            .linux => {
                var pollfd = [1]std.posix.pollfd{.{
                    .fd = self.in.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};

                const pollres = std.posix.poll(&pollfd, 0) catch {
                    _ = try self.handleInput(false);
                    return;
                };

                if (pollres == 0) {
                    _ = try self.handleInput(false);
                    return;
                }

                while (true) {
                    var int_bytes_avail: i32 = 0;
                    if (std.os.linux.ioctl(self.in.handle, std.os.linux.T.FIONREAD, @intFromPtr(&int_bytes_avail)) < 0) {
                        // ignore error reading available bytes and return
                        _ = try self.handleInput(false);
                        return;
                    }

                    // no more bytes left
                    if (int_bytes_avail == 0) {
                        return;
                    }

                    const bytes_avail: usize = @intCast(int_bytes_avail);
                    var bytes_read: usize = 0;

                    // although you could read *bytes_avail* bytes of input from stdin
                    // into a buffer, doing so would remove timing information needed
                    // to parse escape sequences

                    if (self.has_bracketed_paste) {
                        // bracketed pasting is handled in handleInput
                        while (bytes_read < bytes_avail) {
                            const res = try self.handleInput(false);
                            if (res.nread == 0) {
                                break;
                            }
                            bytes_read += res.nread;
                        }
                    } else {
                        const is_clipboard = bytes_avail > TYPED_CLIPBOARD_BYTE_THRESHOLD;
                        while (bytes_read < bytes_avail) {
                            const res = try self.handleInput(is_clipboard);
                            if (res.nread == 0) {
                                break;
                            }
                            bytes_read += res.nread;
                        }
                    }

                    // remaining keys
                    while (bytes_read < bytes_avail) {
                        const res = try self.handleInput(false);
                        if (res.nread == 0) {
                            break;
                        }
                        bytes_read += res.nread;
                    }
                }
            },
            else => {
                try self.handleInput(false);
            },
        }
    }

    // handle output

    pub fn renderText(self: *Self) !void {
        const text_handler: *const text.TextHandler = &self.text_handler;
        if (self.text_handler.dims.height == 0) {
            return;
        }

        var row: u32 = 0;
        try self.moveCursor(0, 0);
        try self.writeAll(Esc.CLEAR_LINE);
        try self.writeAll(Esc.CURSOR_HIDE);

        const cursor_row: u32 = text_handler.cursor.row - text_handler.scroll.row;
        var lineno: [16]u8 = undefined;

        var printer = RowPrinter.init(self);

        for (text_handler.scroll.row..text_handler.lineinfo.getLen()) |i| {
            const offset_start: u32 = text_handler.lineinfo.getOffset(@intCast(i));
            const offset_end: u32 = text_handler.getRowOffsetEnd(@intCast(i));

            const offset_col: u32 = if (row == cursor_row) text_handler.scroll.col else 0;
            var iter = text_handler.iterate(offset_start + offset_col);
            var highlight_iter = text_handler.highlight.iterate(iter.pos, &self.highlight_last_iter_idx);

            try printer.reset();

            // Line number

            const line_no: u32 = text_handler.lineinfo.getLineNo(@intCast(i));

            if (self.conf.show_line_numbers) {
                if ((comptime build_config.dbg_show_multibyte_line) and
                    self.text_handler.lineinfo.checkIsMultibyte(@intCast(i)))
                {
                    try printer.setColor(&.{ .deco = .{ .is_invert = true } });
                } else {
                    try printer.setColor(&.{ .fg = self.conf.line_number_color });
                }
                const lineno_slice = if (text_handler.lineinfo.isContLine(@intCast(i)) and
                    comptime !build_config.dbg_show_cont_line_no)
                    ">"
                else
                    try std.fmt.bufPrint(&lineno, "{d}", .{line_no});
                for (0..(self.text_handler.line_digits - lineno_slice.len)) |_| {
                    try self.writeByte(' ');
                }
                try self.writeAll(lineno_slice);
                try self.writeByte(' ');
                try printer.setColor(&.{ .bg = .transparent });
            }

            // Text

            if (text_handler.markers) |*markers| {
                if (iter.pos >= markers.start and iter.pos < markers.end) {
                    try printer.setColor(&.{ .deco = .{ .is_invert = true } });
                }

                while (iter.nextCodepointSliceUntilWithCurPos(offset_end)) |bytes_with_pos| {
                    const curr_highlight = highlight_iter.nextCodepoint(@intCast(bytes_with_pos.bytes.len));
                    if (bytes_with_pos.pos >= markers.end or
                        bytes_with_pos.pos < markers.start)
                    {
                        if (curr_highlight != null) {
                            try printer.setColor(self.getHighlightColor(&curr_highlight.?));
                        } else {
                            try printer.setColor(&.{ .bg = .transparent });
                        }
                    } else if (bytes_with_pos.pos >= markers.start) {
                        try printer.setColor(&.{ .deco = .{ .is_invert = true } });
                    }
                    if (!try printer.writeAll(bytes_with_pos.bytes)) {
                        break;
                    }
                }
            } else if (comptime build_config.dbg_show_gap_buf) {
                const logical_gap_buf_start: u32 = self.text_handler.head_end;
                const logical_gap_buf_end: u32 =
                    @intCast(logical_gap_buf_start + self.text_handler.gap.items.len);

                if (iter.pos >= logical_gap_buf_start and iter.pos < logical_gap_buf_end) {
                    try printer.setColor(&.{ .deco = .{ .is_invert = true } });
                }

                while (iter.nextCodepointSliceUntilWithCurPos(offset_end)) |bytes_with_pos| {
                    const curr_highlight = highlight_iter.next(bytes_with_pos.bytes.len);
                    if (bytes_with_pos.pos >= logical_gap_buf_end or
                        bytes_with_pos.pos < logical_gap_buf_start)
                    {
                        if (curr_highlight != null) {
                            try printer.setColor(self.getHighlightColor(&curr_highlight.?));
                        } else {
                            try printer.setColor(&.{ .bg = .transparent });
                        }
                    } else if (bytes_with_pos.pos >= logical_gap_buf_start) {
                        try printer.setColor(&.{ .deco = .{ .is_invert = true } });
                    }
                    if (!try printer.writeAll(bytes_with_pos.bytes)) {
                        break;
                    }
                }
            } else {
                while (iter.nextCodepointSliceUntil(offset_end)) |bytes| {
                    const curr_highlight = highlight_iter.nextCodepoint(@intCast(bytes.len));
                    if (curr_highlight != null) {
                        try printer.setColor(self.getHighlightColor(&curr_highlight.?));
                    } else {
                        try printer.setColor(&.{ .bg = .transparent });
                    }
                    if (!try printer.writeAll(bytes)) {
                        break;
                    }
                }
            }

            if ((i + 1) < text_handler.lineinfo.getLen() and text_handler.lineinfo.isContLine(@intCast(i + 1))) {
                try printer.setColor(&.{ .fg = self.conf.special_char_color });
                _ = try printer.writeAll(LINEWRAP_SYM);
            }

            try printer.setColor(&.{ .bg = .transparent });
            if (printer.col < printer.text_width) {
                try self.writeAll(Esc.CLEAR_REST_OF_LINE);
            }
            try self.writeAll("\n\r");

            row += 1;
            if (row == text_handler.dims.height) {
                break;
            }
        }

        try printer.setColor(&.{ .bg = self.conf.empty_bg });

        while (row < text_handler.dims.height) {
            try self.writeAll(Esc.CLEAR_REST_OF_LINE);
            try self.writeAll("\n\r");
            row += 1;
        }

        try self.showHideableMessage();

        try self.writeAll(Esc.CURSOR_SHOW);
        self.needs_update_cursor = true;
    }

    fn getHighlightColor(self: *const Self, token: *const highlight.Token) *const ColorCode {
        const token_type = &self.text_handler.highlight.token_types.items[token.typeid];
        return &token_type.color;
    }

    fn showHideableMessage(self: *Self) !void {
        const msg: *const HideableMessage = blk: {
            if (self.unprotected_hideable_msg != null) {
                break :blk &self.unprotected_hideable_msg.?;
            } else {
                return;
            }
        };

        const renderable_rows_inner: u32 = msg.calcRenderableRows();
        const renderable_rows_outer: u32 = renderable_rows_inner + 1;
        var row: u32 = 0;
        var draw_row: u32 = 0;
        if (self.text_handler.dims.height >= renderable_rows_outer) {
            row = self.text_handler.dims.height - renderable_rows_outer;
        }
        try self.moveCursor(row, 0);

        var printer = RowPrinter.init(self);
        try printer.writeColorCodeBg(&printer.color_code);
        try self.writeAll(Esc.CLEAR_LINE);

        // header
        if (msg.header) |header| {
            const header_max_width: u32 = self.ws.width;
            const header_col: u32 = blk: {
                if (header_max_width > header.len) {
                    break :blk @intCast((header_max_width - header.len) / 2);
                } else {
                    break :blk 0;
                }
            };
            try self.moveCursor(row, header_col);
            try printer.setColor(&.{ .deco = .{ .is_invert = true } });
            try self.writeAll(header);
            try printer.setColor(&.{ .bg = .transparent });
        }

        // body
        row += 1;
        try self.moveCursor(row, 0);
        try printer.setColor(&.{ .bg = .transparent });
        try self.writeAll(Esc.CLEAR_LINE);
        for (msg.text.slice()[msg.offset..]) |byte| {
            if (byte == '\n') {
                row += 1;
                draw_row += 1;
                try self.moveCursor(row, 0);
                try self.writeAll(Esc.CLEAR_LINE);
                if (draw_row == renderable_rows_inner) {
                    break;
                }
            } else {
                try self.writeByte(byte);
            }
        }
    }

    fn handleOutput(self: *Self) !void {
        try self.state_handler.handleOutput(self);
        try self.flushOutput();
    }

    // terminal extensions

    const TermExt = struct {
        ansi: []const []const u8,
        flag: []const u8,
        conf: []const u8,
    };

    const TERM_EXT = [_]TermExt{
        .{ .ansi = &.{"2004"}, .flag = "has_bracketed_paste", .conf = "force_bracketed_paste" },
        .{ .ansi = &.{"1049"}, .flag = "has_alt_screen_buf", .conf = "force_alt_screen_buf" },
        .{ .ansi = &.{"1007"}, .flag = "has_alt_scroll_mode", .conf = "force_alt_scroll_mode" },
        // enables mouse tracking, sgr mouse mode
        .{ .ansi = &.{ "1000", "1006" }, .flag = "has_mouse_tracking", .conf = "force_mouse_tracking" },
    };

    fn enableTermExts(self: *Self) !void {
        inline for (&TERM_EXT) |*term_ext| {
            if (@field(self.conf, term_ext.conf)) {
                inline for (term_ext.ansi) |ansi| {
                    try self.writeAll("\x1b[?" ++ ansi ++ "h");
                }
                @field(self, term_ext.flag) = true;
            } else {
                @field(self, term_ext.flag) = false;
            }
        }
    }
    fn disableTermExts(self: *Self) !void {
        inline for (&TERM_EXT) |*term_ext| {
            if (@field(self, term_ext.flag)) {
                inline for (term_ext.ansi) |ansi| {
                    try self.writeAll("\x1b[?" ++ ansi ++ "l");
                }
            }
        }
    }

    // terminal setup & restore

    pub fn resetTerminal(self: *Self) !void {
        try self.writeAll("\x1b" ++ "c");
    }

    pub fn setupTerminal(self: *Self) !void {
        try self.resetTerminal();
        try self.enableRawMode();
        try self.enableTermExts();
        try self.flushOutput();
        self.needs_redraw = true;
        self.needs_update_cursor = true;
    }

    pub fn restoreTerminal(self: *Self) !void {
        try self.disableTermExts();
        try self.writeAll(Esc.COLOR_DEFAULT);
        try self.writeAll(Esc.CLEAR_SCREEN);
        try self.writeAll(Esc.RESET_POS);
        try self.disableRawMode();
        try self.flushOutput();
    }

    // tick

    pub const REFRESH_RATE_MS = 16;

    pub fn run(self: *Self) !void {
        try self.setupTerminal();
        try self.refreshScreen();
        try self.text_handler.onResize(&self.ws);
        var ts = std.time.milliTimestamp();
        while (true) {
            if (sig.resized) {
                sig.resized = false;
                try self.updateWinSize();
            }
            self.handleInputPolling() catch |err| {
                if (err == error.Quit) {
                    break;
                } else {
                    return err;
                }
            };
            try self.handleOutput();

            const new_ts = std.time.milliTimestamp();
            const elapsed = (new_ts - ts);
            if (elapsed < REFRESH_RATE_MS) {
                const refresh_ts = (REFRESH_RATE_MS - (new_ts - ts)) * std.time.ns_per_ms;
                std.time.sleep(@intCast(refresh_ts));
            }
            ts = new_ts;
        }
        self.restoreTerminal() catch {};
    }

    /// opened_file_str must be allocated by E.allocator
    pub fn openAtStart(self: *Self, opened_file_str: str.StringUnmanaged) !void {
        _ = try Commands.Open.setupOpen(self, opened_file_str);
    }
};

pub const EditorBuilder = struct {
    const Inner = struct {
        editor: Editor,
    };
    is_initialized: bool,
    allocator: std.mem.Allocator,
    inner: Inner,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .is_initialized = false,
            .allocator = allocator,
            .inner = undefined,
        };
    }

    pub fn create(self: *EditorBuilder) !*Editor {
        if (self.is_initialized) {
            return error.AlreadyInitialized;
        }
        const stdin: std.fs.File = std.io.getStdIn();
        const stdout: std.fs.File = std.io.getStdOut();
        self.inner.editor = .{
            .in = stdin,
            .inr = stdin.reader(),
            .out = stdout,
            .out_raw = stdout.writer(),
            .out_buffer = Editor.OutBuffer.init(self.allocator),
            .state_handler = &StateHandler.Text,
            .conf = .{
                .allocator = self.allocator,
            },
            .allocator = self.allocator,
            .text_handler = undefined,
        };
        var lineinfo_inst: lineinfo.LineInfoList = .{};
        try lineinfo_inst.append(0);
        self.inner.editor.text_handler = .{
            .lineinfo = lineinfo_inst,
            .buffer = str.String.init(text.TextHandler.BufferAllocator),
            .gap = .{
                // get the range 0..0 to set the length to zero
                .items = (try text.TextHandler.BufferAllocator.alloc(u8, std.mem.page_size))[0..0],
                .capacity = std.mem.page_size,
            },
            .clipboard = str.String.init(text.TextHandler.BufferAllocator),
            .ui_signaller = .{
                .unprotected_editor = &self.inner.editor,
            },
            .highlight = .{
                .conf = &self.inner.editor.conf,
                .allocator = self.allocator,
            },
            .conf = &self.inner.editor.conf,
            .allocator = self.allocator,
            .undo_mgr = undefined,
        };
        self.inner.editor.text_handler.undo_mgr = .{
            .text_handler = &self.inner.editor.text_handler,
        };
        return &self.inner.editor;
    }
};
