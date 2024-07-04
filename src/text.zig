//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");

const str = @import("./str.zig");
const undo = @import("./undo.zig");
const config = @import("./config.zig");
const lineinfo = @import("./lineinfo.zig");
const clipboard = @import("./clipboard.zig");
const encoding = @import("./encoding.zig");

const editor = @import("./editor.zig");
const Expr = @import("./patterns.zig").Expr;
const Highlight = @import("./highlight.zig");

pub const TextPos = struct {
    /// Row
    row: u32 = 0,
    /// Column as measured by byte offsets into the row
    col: u32 = 0,
    /// Column as measured in characters
    gfx_col: u32 = 0,
};

pub const RecordAction = enum {
    record_action,
    record_by_undo_mgr,
};

pub const TextIterator = struct {
    text_handler: *const TextHandler,
    pos: u32 = 0,

    pub fn nextCodepointSlice(self: *TextIterator) ?[]const u8 {
        if (self.text_handler.bytesStartingAt(self.pos)) |bytes| {
            const seqlen = encoding.sequenceLen(bytes[0]) catch unreachable;
            self.pos += seqlen;
            return bytes[0..seqlen];
        }
        return null;
    }

    pub fn nextCodepointSliceUntil(self: *TextIterator, offset_end: u32) ?[]const u8 {
        if (self.pos >= offset_end) {
            return null;
        }
        return self.nextCodepointSlice();
    }

    pub const SliceWithCurPos = struct {
        bytes: []const u8,
        pos: usize,
    };

    pub fn nextCodepointSliceUntilWithCurPos(self: *TextIterator, offset_end: u32) ?SliceWithCurPos {
        if (self.pos >= offset_end) {
            return null;
        }
        const cur_pos = self.pos;
        if (self.nextCodepointSlice()) |bytes| {
            return .{
                .bytes = bytes,
                .pos = cur_pos,
            };
        }
        return null;
    }

    pub fn prevCodepointSlice(self: *TextIterator) ?[]const u8 {
        if (self.pos == 0) {
            return null;
        }
        self.pos -= 1;
        var seqlen: usize = 1;
        while (true) {
            const bytes = self.text_handler.bytesStartingAt(self.pos).?;
            if (encoding.isContByte(bytes[0])) {
                self.pos -= 1;
                seqlen += 1;
                continue;
            }
            return bytes[0..seqlen];
        }
    }
};

pub const Dimensions = struct {
    width: u32 = 0,
    height: u32 = 0,
    left_padding: u32 = 0,
};

pub const TextHandler = struct {
    const Self = TextHandler;

    pub const Markers = struct {
        /// Logical position of starting marker
        start: u32,
        /// Logical position of starting marker when user first starts marking
        orig_start: u32,
        /// Logical position of ending marker
        end: u32,
        /// Cursor at starting marker
        start_cur: TextPos,
    };

    pub const BufferAllocator = std.heap.page_allocator;

    file: ?std.fs.File = null,

    /// Allocated by self.allocator
    file_path: str.StringUnmanaged = .{},

    /// Buffer of characters. Logical text buffer is then:
    ///   text = buffer[0..(head_end)] ++ gap ++ buffer[tail_start..]
    buffer: str.String,

    /// Real position where the head of the text ends (excluding the last
    /// character)
    head_end: u32 = 0,

    /// Real position where the tail of the text starts
    tail_start: u32 = 0,

    /// Gap buffer, allocated by PageAllocator
    gap: str.StringUnmanaged,

    /// Line information
    lineinfo: lineinfo.LineInfoList,

    /// Maximum number of digits needed to print line position (starting from 1)
    line_digits: u32 = 1,

    highlight: Highlight,
    cursor: TextPos = .{},
    scroll: TextPos = .{},
    markers: ?Markers = null,

    tab_size: u32 = 2,
    use_tabs: bool = false,

    /// Allocated by PageAllocator
    clipboard: str.String,

    undo_mgr: undo.UndoManager,
    buffer_changed: bool = false,

    dims: Dimensions = .{},

    ui_signaller: editor.UISignaller,
    conf: *const config.Reader,
    allocator: std.mem.Allocator,

    // events

    pub fn onResize(self: *Self, ws: *const editor.Dimensions) !void {
        self.dims.left_padding = if (self.conf.show_line_numbers)
            (self.line_digits + 1)
        else
            0;
        self.dims.width = ws.width - self.dims.left_padding;
        self.dims.height = ws.height - editor.Editor.STATUS_BAR_HEIGHT;
        const pos = self.calcOffsetFromCursor();
        if (self.isTextWrapped()) {
            try self.wrapText();
        }
        try self.gotoPos(pos);
    }

    // io

    pub const OpenFileArgs = struct {
        file: ?std.fs.File,
        file_path: []const u8,
    };

    pub const OpenFileResult = union(enum) {
        ok: void,
        warn_highlight: config.Reader.ConfigError,
    };

    pub fn open(self: *Self, args: OpenFileArgs, flush_buffer: bool) !OpenFileResult {
        if (args.file == null) {
            if (self.file != null) {
                self.file.?.close();
            }
            self.file_path.clearAndFree(self.allocator);
            try self.file_path.appendSlice(self.allocator, args.file_path);
            self.highlight.loadTokenTypesForFile(self) catch |err| {
                return .{ .warn_highlight = err };
            };
            return .ok;
        }

        const file = args.file.?;
        const stat = try file.stat();
        const size = stat.size;
        if (size > std.math.maxInt(u32)) {
            return error.FileTooBig;
        }

        if (self.file != null) {
            self.file.?.close();
        }
        self.file = file;

        self.file_path.clearAndFree(self.allocator);
        try self.file_path.appendSlice(self.allocator, args.file_path);

        if (flush_buffer) {
            self.clearBuffersForFile();

            const new_buffer = blk: {
                var ret_buffer = str.String.init(BufferAllocator);
                errdefer ret_buffer.deinit();
                const new_buffer_slice = try ret_buffer.addManyAsSlice(size);
                _ = try self.file.?.readAll(new_buffer_slice);
                if (!std.unicode.utf8ValidateSlice(ret_buffer.items)) {
                    return error.InvalidUtf8;
                }
                break :blk ret_buffer;
            };

            // Try to load highlighting first so that indentation is detected
            self.highlight.loadTokenTypesForFile(self) catch |err| {
                return .{ .warn_highlight = err };
            };
            self.readLines(new_buffer) catch |err| {
                self.clearBuffersForFile();
                return err;
            };
            try self.highlightText();
        }

        return .ok;
    }

    fn clearBuffersForFile(self: *Self) void {
        self.highlight.clear();
        self.cursor = .{};
        self.scroll = .{};
        self.markers = null;
        self.buffer.clearAndFree();
        self.lineinfo.reset();
        self.head_end = 0;
        self.tail_start = 0;
        self.gap.shrinkRetainingCapacity(0);
        self.undo_mgr.clear();
        self.buffer_changed = false;
    }

    pub fn save(self: *Self) !void {
        if (self.file == null) {
            self.file = std.fs.cwd().createFile(self.file_path.items, .{
                .read = true,
                .truncate = true,
            }) catch |err| {
                return err;
            };
        }
        const file: std.fs.File = self.file.?;
        try file.seekTo(0);
        try file.setEndPos(0);
        const writer: std.fs.File.Writer = file.writer();
        try writer.writeAll(self.buffer.items[0..self.head_end]);
        try writer.writeAll(self.gap.items);
        try writer.writeAll(self.buffer.items[self.tail_start..]);
        self.buffer_changed = false;
        // buffer save status is handled by status bar
        self.ui_signaller.setNeedsUpdateCursor();
    }

    const ReadLineError = error{
        OutOfMemory,
    };

    /// Read lines from new_buffer. Takes ownership of the new_buffer
    fn readLines(self: *Self, new_buffer: str.String) ReadLineError!void {
        self.buffer = new_buffer;

        var is_mb = false;
        for (self.buffer.items, 0..self.buffer.items.len) |byte, offset| {
            if (encoding.isMultibyte(byte)) {
                is_mb = true;
            }
            if (byte == '\n') {
                const prev_row: u32 = self.lineinfo.getLen() - 1;
                // next line must be appended first so that the prev_row
                // has corrects bounds needed for wrapLineWithCols
                try self.lineinfo.append(@intCast(offset + 1));

                self.lineinfo.setMultibyte(prev_row, is_mb);
                is_mb = false;
            }
        }

        const last_row: u32 = self.lineinfo.getLen() - 1;
        self.lineinfo.setMultibyte(last_row, is_mb);

        self.calcLineDigits();

        if (self.isTextWrapped()) {
            // wrap text must be done after calcLineDigits
            try self.wrapText();
        }

        self.tab_size = self.conf.tab_size;
        self.use_tabs = self.conf.use_tabs;

        var tab_size_detected = false;
        if (self.highlight.getTabSize()) |tab_size| {
            self.tab_size = tab_size;
            tab_size_detected = true;
        }
        if (self.highlight.getUseTabs()) |use_tabs| {
            self.use_tabs = use_tabs;
            tab_size_detected = true;
        }
        if (!tab_size_detected and self.conf.detect_tab_size) {
            self.detectTabSize();
        }
    }

    fn detectTabSize(self: *Self) void {
        const MAX_LINES = 1024;
        var lines_to_consider: std.BoundedArray(u8, 4) = .{};
        var indent_byte: ?u8 = null;

        next_line: for (0..@min(self.lineinfo.getLen(), MAX_LINES)) |row| {
            const offset_start: u32 = self.lineinfo.getOffset(@intCast(row));
            const offset_end: u32 = self.getRowOffsetEnd(@intCast(row));
            const line = self.buffer.items[offset_start..offset_end];
            if (line.len == 0) {
                continue;
            }

            const first_char_len = encoding.sequenceLen(line[0]) catch unreachable;
            const first_bytes = line[0..first_char_len];
            if (!encoding.isSpace(first_bytes)) {
                continue;
            }

            if (indent_byte == null) {
                if (std.mem.eql(u8, first_bytes, "\t")) {
                    indent_byte = '\t';
                } else {
                    indent_byte = ' ';
                }
            }

            var tab_size: u8 = 0;
            for (line) |byte| {
                if (byte == indent_byte.?) {
                    tab_size += 1;
                } else {
                    break;
                }
            }
            for (lines_to_consider.slice()) |prev_tab_size| {
                if (tab_size == prev_tab_size) {
                    continue :next_line;
                }
                if (tab_size > prev_tab_size) {
                    break;
                }
            }
            lines_to_consider.append(tab_size) catch unreachable;
            if (lines_to_consider.len == lines_to_consider.buffer.len) {
                break;
            }
        }

        if (lines_to_consider.len < 1) {
            return;
        }

        self.use_tabs = indent_byte.? == '\t';
        const slice = lines_to_consider.slice();
        self.tab_size = @intCast(slice[0]);
        for (slice[1..]) |indent| {
            self.tab_size = @intCast(std.math.gcd(self.conf.tab_size, indent));
        }
    }

    // general manip

    pub fn iterate(self: *const Self, pos: u32) TextIterator {
        return TextIterator{
            .text_handler = self,
            .pos = pos,
        };
    }

    pub fn getLogicalLen(self: *const Self) u32 {
        return @intCast(self.head_end + self.gap.items.len + (self.buffer.items.len - self.tail_start));
    }

    fn calcLineDigits(self: *Self) void {
        if (self.conf.show_line_numbers) {
            self.line_digits = std.math.log10(self.lineinfo.getMaxLineNo()) + 1;
        }
        return;
    }

    pub fn getRowOffsetEnd(self: *const Self, row: u32) u32 {
        // The newline character of the current line is not counted
        if ((row + 1) < self.lineinfo.getLen()) {
            const offset = self.lineinfo.getOffset(row + 1);
            if (self.lineinfo.isContLine(row + 1)) {
                // cont lines do not have newlines
                return offset;
            }
            return offset - 1;
        } else {
            return self.getLogicalLen();
        }
    }

    pub fn getRowLen(self: *const Self, row: u32) u32 {
        const offset_start: u32 = self.lineinfo.getOffset(row);
        const offset_end: u32 = self.getRowOffsetEnd(row);
        return offset_end - offset_start;
    }

    pub fn calcOffsetFromCursor(self: *const Self) u32 {
        return self.lineinfo.getOffset(self.cursor.row) + self.cursor.col;
    }

    fn bytesStartingAt(self: *const Self, offset: u32) ?[]const u8 {
        const logical_tail_start = self.head_end + self.gap.items.len;
        if (offset < self.head_end) {
            return self.buffer.items[offset..];
        } else if (offset >= self.head_end and offset < logical_tail_start) {
            const gap_relidx = offset - self.head_end;
            return self.gap.items[gap_relidx..];
        } else {
            const real_tailidx = self.tail_start + (offset - logical_tail_start);
            if (real_tailidx >= self.buffer.items.len) {
                return null;
            }
            return self.buffer.items[real_tailidx..];
        }
    }

    fn recheckIsMultibyte(self: *Self, from_line: u32) !void {
        const offset_start: u32 = self.lineinfo.getOffset(from_line);
        const opt_next_real_line = self.lineinfo.findNextNonContLine(from_line);
        const offset_end: u32 = self.getRowOffsetEnd(if (opt_next_real_line) |next_real_line| next_real_line - 1 else from_line);
        var is_mb = false;
        var iter = self.iterate(offset_start);
        while (iter.nextCodepointSliceUntil(offset_end)) |bytes| {
            if (encoding.isMultibyte(bytes[0])) {
                is_mb = true;
                break;
            }
        }
        self.lineinfo.setMultibyte(from_line, is_mb);

        if (opt_next_real_line) |next_real_line| {
            for ((from_line + 1)..next_real_line) |line| {
                self.lineinfo.setMultibyte(@intCast(line), is_mb);
            }
        }
    }

    fn recheckIsMultibyteAfterDelete(self: *Self, line: u32, deleted_char_is_mb: bool) !void {
        if (!self.lineinfo.isMultibyte(line) and !deleted_char_is_mb) {
            // fast path to avoid looping through the string
            return;
        }
        return self.recheckIsMultibyte(line);
    }

    pub fn srcView(self: *const Self) Expr.SrcView {
        const Funcs = struct {
            fn codepointSliceAt(ctx: *const anyopaque, pos: usize) error{InvalidUtf8}!?[]const u8 {
                const self_: *const Self = @ptrCast(@alignCast(ctx));
                if (self_.bytesStartingAt(@intCast(pos))) |bytes| {
                    const seqlen = encoding.sequenceLen(bytes[0]) catch unreachable;
                    return bytes[0..seqlen];
                }
                return null;
            }
        };
        return .{
            .ptr = self,
            .inline_vtable = .{
                .codepointSliceAt = Funcs.codepointSliceAt,
            },
        };
    }

    // gap

    pub fn flushGapBuffer(self: *Self) !void {
        if (self.tail_start > self.head_end) {
            // buffer contains deleted characters
            const deleted_chars = self.tail_start - self.head_end;
            const logical_tail_start = self.head_end + self.gap.items.len;
            const logical_len = self.getLogicalLen();
            if (deleted_chars > self.gap.items.len) {
                const gapdest: []u8 = self.buffer.items[self.head_end..logical_tail_start];
                @memcpy(gapdest, self.gap.items);
                const taildest: []u8 = self.buffer.items[logical_tail_start..logical_len];
                std.mem.copyForwards(u8, taildest, self.buffer.items[self.tail_start..]);
            } else {
                const reserved_chars = self.gap.items.len - deleted_chars;
                _ = try self.buffer.addManyAt(self.head_end, reserved_chars);
                const dest: []u8 = self.buffer.items[self.head_end..logical_tail_start];
                @memcpy(dest, self.gap.items);
            }
            self.buffer.shrinkRetainingCapacity(logical_len);
        } else {
            try self.buffer.insertSlice(self.head_end, self.gap.items);
        }
        self.head_end = 0;
        self.tail_start = 0;
        self.gap.shrinkRetainingCapacity(0);
    }

    pub fn isGapBufferEmpty(self: *const Self) bool {
        return self.head_end == 0 and self.tail_start == 0 and self.gap.items.len == 0;
    }

    // cursor

    fn syncColumnAfterCursor(self: *Self) void {
        const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
        const offset_end: u32 = self.getRowOffsetEnd(self.cursor.row);
        const rowlen: u32 = offset_end - offset_start;
        const old_gfx_col = self.cursor.gfx_col;
        const old_scroll_gfx_col = self.scroll.gfx_col;
        if (rowlen == 0) {
            self.cursor.col = 0;
            self.cursor.gfx_col = 0;
            self.scroll.col = 0;
            self.scroll.gfx_col = 0;
        } else {
            if (!self.lineinfo.isMultibyte(self.cursor.row)) {
                if (old_gfx_col >= rowlen) {
                    self.cursor.col = rowlen;
                    self.cursor.gfx_col = rowlen;
                } else {
                    self.cursor.col = old_gfx_col;
                    self.cursor.gfx_col = old_gfx_col;
                }
                if (self.cursor.col > self.dims.width) {
                    self.scroll.col = self.cursor.col - self.dims.width;
                } else {
                    self.scroll.col = 0;
                }
                self.scroll.gfx_col = self.scroll.col;
            } else {
                self.cursor.col = 0;
                self.cursor.gfx_col = 0;
                var iter = self.iterate(offset_start);
                while (iter.nextCodepointSliceUntil(offset_end)) |bytes| {
                    if (self.cursor.gfx_col == old_gfx_col) {
                        break;
                    }
                    self.cursor.col += @intCast(bytes.len);
                    self.cursor.gfx_col += encoding.countCharCols(std.unicode.utf8Decode(bytes) catch unreachable);
                }
                self.scroll.col = 0;
                self.scroll.gfx_col = 0;
                self.syncColumnScroll();
            }
        }
        if (old_scroll_gfx_col != self.scroll.gfx_col) {
            self.ui_signaller.setNeedsRedraw();
        }
    }

    pub fn goUp(self: *Self) void {
        if (self.cursor.row == 0) {
            return;
        }
        self.cursor.row -= 1;
        self.syncColumnAfterCursor();
        if (self.cursor.row < self.scroll.row) {
            self.scroll.row -= 1;
            self.ui_signaller.setNeedsRedraw();
        }
        self.ui_signaller.setNeedsUpdateCursor();
    }

    pub fn goDown(self: *Self) void {
        if (self.cursor.row == self.lineinfo.getLen() - 1) {
            return;
        }
        self.cursor.row += 1;
        self.syncColumnAfterCursor();
        if ((self.scroll.row + self.dims.height) <= self.cursor.row) {
            self.scroll.row += 1;
            self.ui_signaller.setNeedsRedraw();
        }
        self.ui_signaller.setNeedsUpdateCursor();
    }

    pub fn goPgUp(self: *Self, is_scroll: bool) void {
        var scroll_delta = self.dims.height + 1;
        if (is_scroll) {
            scroll_delta >>= 2;
        }
        if (self.cursor.row < scroll_delta) {
            self.cursor.row = 0;
        } else {
            self.cursor.row -= scroll_delta;
        }
        self.syncColumnAfterCursor();
        self.syncRowScroll();
        self.ui_signaller.setNeedsRedraw();
        self.ui_signaller.setNeedsUpdateCursor();
    }

    pub fn goPgDown(self: *Self, is_scroll: bool) void {
        var scroll_delta = self.dims.height + 1;
        if (is_scroll) {
            scroll_delta >>= 2;
        }
        self.cursor.row += scroll_delta;
        if (self.cursor.row >= self.lineinfo.getLen()) {
            self.cursor.row = self.lineinfo.getLen() - 1;
        }
        self.syncColumnAfterCursor();
        self.syncRowScroll();
        self.ui_signaller.setNeedsRedraw();
        self.ui_signaller.setNeedsUpdateCursor();
    }

    fn goLeftTextPos(self: *const Self, pos_in: TextPos, row_start: u32, opt_char_under_cursor: ?*u32) TextPos {
        var iter = self.iterate(row_start + pos_in.col);
        const bytes = iter.prevCodepointSlice().?;

        const char = std.unicode.utf8Decode(bytes) catch unreachable;
        if (opt_char_under_cursor) |char_under_cursor| {
            char_under_cursor.* = char;
        }

        var pos = pos_in;
        pos.col -= @intCast(bytes.len);
        pos.gfx_col -= encoding.countCharCols(char);
        return pos;
    }

    pub fn goLeft(self: *Self) void {
        if (self.cursor.col == 0) {
            return;
        }
        const row_start: u32 = self.lineinfo.getOffset(self.cursor.row);
        self.cursor = self.goLeftTextPos(self.cursor, row_start, null);
        if (self.cursor.gfx_col < self.scroll.gfx_col) {
            self.scroll = self.goLeftTextPos(self.scroll, row_start, null);
            self.ui_signaller.setNeedsRedraw();
        }
        self.ui_signaller.setNeedsUpdateCursor();
    }

    pub fn goLeftWord(self: *Self) void {
        if (self.cursor.col == 0) {
            return;
        }
        self.goLeft();
        const row_start: u32 = self.lineinfo.getOffset(self.cursor.row);
        var go_left_end: ?bool = null;
        while (self.cursor.col > 0) {
            var char: u32 = 0;
            const new_cursor = self.goLeftTextPos(self.cursor, row_start, &char);
            if (go_left_end == null) {
                go_left_end = encoding.isKeywordChar(char);
            } else if (encoding.isKeywordChar(char) != go_left_end.?) {
                break;
            }
            self.cursor = new_cursor;
            if (self.cursor.gfx_col < self.scroll.gfx_col) {
                self.scroll = self.goLeftTextPos(self.scroll, row_start, null);
                self.ui_signaller.setNeedsRedraw();
            }
        }
        self.ui_signaller.setNeedsUpdateCursor();
    }

    fn goRightTextPos(self: *const Self, pos_in: TextPos, row_start: u32, opt_char_under_cursor: ?*u32) TextPos {
        var pos = pos_in;
        const bytes = self.bytesStartingAt(row_start + pos.col).?;
        const seqlen = encoding.sequenceLen(bytes[0]) catch unreachable;
        const char = std.unicode.utf8Decode(bytes[0..seqlen]) catch unreachable;
        if (opt_char_under_cursor) |char_under_cursor| {
            char_under_cursor.* = char;
        }
        pos.col += seqlen;
        pos.gfx_col += encoding.countCharCols(char);
        return pos;
    }

    pub fn goRight(self: *Self) void {
        if (self.cursor.col >= self.getRowLen(self.cursor.row)) {
            return;
        }
        const row_start: u32 = self.lineinfo.getOffset(self.cursor.row);
        self.cursor = self.goRightTextPos(self.cursor, row_start, null);
        if ((self.scroll.gfx_col + self.dims.width) <= self.cursor.gfx_col) {
            self.scroll = self.goRightTextPos(self.scroll, row_start, null);
            self.ui_signaller.setNeedsRedraw();
        }
        self.ui_signaller.setNeedsUpdateCursor();
    }

    pub fn goRightWord(self: *Self) void {
        const rowlen = self.getRowLen(self.cursor.row);
        if (self.cursor.col >= rowlen) {
            return;
        }
        self.goRight();
        const row_start: u32 = self.lineinfo.getOffset(self.cursor.row);
        var go_right_end: ?bool = null;
        while (self.cursor.col < rowlen) {
            var char: u32 = 0;
            const new_cursor = self.goRightTextPos(self.cursor, row_start, &char);
            if (go_right_end == null) {
                go_right_end = encoding.isKeywordChar(char);
            } else if (encoding.isKeywordChar(char) != go_right_end.?) {
                break;
            }
            self.cursor = new_cursor;
            if ((self.scroll.gfx_col + self.dims.width) <= self.cursor.gfx_col) {
                self.scroll = self.goRightTextPos(self.scroll, row_start, null);
                self.ui_signaller.setNeedsRedraw();
            }
        }
        self.ui_signaller.setNeedsUpdateCursor();
    }

    pub fn goHeadOrContentStart(self: *Self) void {
        const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
        const offset_end: u32 = self.getRowOffsetEnd(self.cursor.row);

        const init_col = self.cursor.col;
        self.cursor.col = 0;
        self.cursor.gfx_col = 0;

        var iter = self.iterate(offset_start);
        while (iter.nextCodepointSliceUntil(offset_end)) |bytes| {
            if (encoding.isSpace(bytes)) {
                self.cursor.col += 1;
                self.cursor.gfx_col += encoding.countCharCols(std.unicode.utf8Decode(bytes) catch unreachable);
            } else {
                break;
            }
        }

        if (init_col == self.cursor.col) {
            self.cursor.col = 0;
            self.cursor.gfx_col = 0;
            self.scroll.col = 0;
            self.scroll.gfx_col = 0;
        } else {
            self.syncColumnScroll();
        }
        self.ui_signaller.setNeedsRedraw();
        self.ui_signaller.setNeedsUpdateCursor();
    }

    pub fn goTail(self: *Self) void {
        const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
        const offset_end: u32 = self.getRowOffsetEnd(self.cursor.row);

        if (!self.lineinfo.isMultibyte(self.cursor.row)) {
            const rowlen = offset_end - offset_start;
            self.cursor.col = rowlen;
            self.cursor.gfx_col = rowlen;
        } else {
            self.cursor.col = 0;
            self.cursor.gfx_col = 0;

            var iter = self.iterate(offset_start);
            while (iter.nextCodepointSliceUntil(offset_end)) |bytes| {
                self.cursor.col += @intCast(bytes.len);
                self.cursor.gfx_col += encoding.countCharCols(std.unicode.utf8Decode(bytes) catch unreachable);
            }
        }

        self.syncColumnScroll();
        self.ui_signaller.setNeedsRedraw();
    }

    pub fn goDownHead(self: *Self) void {
        self.cursor.row += 1;
        self.cursor.col = 0;
        self.cursor.gfx_col = 0;
        if ((self.scroll.row + self.dims.height) <= self.cursor.row) {
            self.scroll.row += 1;
        }
        self.scroll.col = 0;
        self.scroll.gfx_col = 0;
        self.ui_signaller.setNeedsRedraw();
    }

    pub fn gotoFirstLine(self: *Self) void {
        self.cursor.row = 0;
        self.syncRowScroll();
        self.cursor.col = 0;
        self.cursor.gfx_col = 0;
        self.scroll.col = 0;
        self.scroll.gfx_col = 0;
        self.ui_signaller.setNeedsRedraw();
    }

    pub fn gotoLastLine(self: *Self) void {
        self.cursor.row = self.lineinfo.getLen();
        while (self.cursor.row > 0) {
            self.cursor.row -= 1;
            if (!self.lineinfo.isContLine(self.cursor.row)) {
                break;
            }
        }
        self.syncRowScroll();
        self.cursor.col = 0;
        self.cursor.gfx_col = 0;
        self.scroll.col = 0;
        self.scroll.gfx_col = 0;
        self.ui_signaller.setNeedsRedraw();
    }

    pub fn gotoLineNo(self: *Self, line: u32) error{Overflow}!void {
        self.cursor.row = self.lineinfo.findLineWithLineNo(line) orelse {
            return error.Overflow;
        };
        self.syncRowScroll();
        self.cursor.col = 0;
        self.cursor.gfx_col = 0;
        self.scroll.col = 0;
        self.scroll.gfx_col = 0;
        self.ui_signaller.setNeedsRedraw();
    }

    pub fn gotoPos(self: *Self, pos: u32) error{Overflow}!void {
        if (pos > self.getLogicalLen()) {
            return error.Overflow;
        }
        self.cursor.row = self.lineinfo.findMaxLineBeforeOffset(pos, 0);
        self.cursor.col = pos - self.lineinfo.getOffset(self.cursor.row);
        if (!self.lineinfo.isMultibyte(self.cursor.row)) {
            self.cursor.gfx_col = self.cursor.col;
        } else {
            const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
            self.cursor.gfx_col = 0;
            var iter = self.iterate(offset_start);
            while (iter.nextCodepointSliceUntil(pos)) |char| {
                self.cursor.gfx_col += encoding.countCharCols(std.unicode.utf8Decode(char) catch unreachable);
            }
        }
        self.scroll.col = 0;
        self.scroll.gfx_col = 0;
        self.syncColumnScroll();
        self.syncRowScroll();
        self.ui_signaller.setNeedsRedraw();
    }

    pub fn gotoCursor(self: *Self, cursor_x: u32, cursor_y: u32) void {
        if (cursor_y >= self.dims.height) {
            return;
        }
        if (cursor_x < self.dims.left_padding) {
            return;
        }

        var target_row: u32 = cursor_y + self.scroll.row;
        const target_gfx_col = (cursor_x - self.dims.left_padding) + self.scroll.gfx_col;

        if (target_row >= self.lineinfo.getLen()) {
            target_row = self.lineinfo.getLen() - 1;
        }

        self.cursor.row = target_row;
        const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
        const offset_end: u32 = self.getRowOffsetEnd(self.cursor.row);
        const rowlen: u32 = offset_end - offset_start;
        if (!self.lineinfo.isMultibyte(self.cursor.row)) {
            self.cursor.col = @min(target_gfx_col, rowlen);
            self.cursor.gfx_col = self.cursor.col;
        } else {
            self.cursor.col = 0;
            var iter = self.iterate(offset_start);
            while (iter.nextCodepointSliceUntil(offset_end)) |char| {
                const ccol = encoding.countCharCols(std.unicode.utf8Decode(char) catch unreachable);
                if ((self.cursor.gfx_col + ccol) > target_gfx_col) {
                    break;
                }
                self.cursor.col += @intCast(char.len);
                self.cursor.gfx_col += ccol;
            }
        }

        // shouldn't need to resync scroll
        self.ui_signaller.setNeedsRedraw();
    }

    pub fn syncColumnScroll(self: *Self) void {
        const text_width = self.dims.width;

        var target_gfx_col: u32 = self.scroll.gfx_col;

        if (self.lineinfo.isContLine(self.cursor.row)) {
            std.debug.assert(self.cursor.gfx_col <= text_width);
            target_gfx_col = 0;
        } else if (target_gfx_col > self.cursor.gfx_col) {
            if (text_width < self.cursor.gfx_col) {
                target_gfx_col = self.cursor.gfx_col - text_width + 1;
            } else if (self.cursor.gfx_col == 0) {
                target_gfx_col = 0;
            } else {
                target_gfx_col = self.cursor.gfx_col - 1;
            }
        } else if ((target_gfx_col + self.cursor.gfx_col) > text_width) {
            // cursor is farther than horizontal edge
            if (text_width > self.cursor.gfx_col) {
                target_gfx_col = text_width - self.cursor.gfx_col + 1;
            } else {
                target_gfx_col = self.cursor.gfx_col - text_width + 1;
            }
        }

        if (!self.lineinfo.isMultibyte(self.cursor.row)) {
            self.scroll.col = target_gfx_col;
            self.scroll.gfx_col = target_gfx_col;
        } else {
            if (target_gfx_col == 0) {
                self.scroll.col = 0;
                self.scroll.gfx_col = 0;
            } else {
                const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
                const offset_end: u32 = self.getRowOffsetEnd(self.cursor.row);
                var count_cols_from: u32 = offset_start;
                if (target_gfx_col > self.scroll.gfx_col) {
                    count_cols_from += self.scroll.col;
                } else {
                    count_cols_from += 0;
                    self.scroll.col = 0;
                    self.scroll.gfx_col = 0;
                }
                var iter = self.iterate(count_cols_from);
                while (iter.nextCodepointSliceUntil(offset_end)) |bytes| {
                    const ccol = encoding.countCharCols(std.unicode.utf8Decode(bytes) catch unreachable);
                    self.scroll.col += @intCast(bytes.len);
                    self.scroll.gfx_col += ccol;
                    if (self.scroll.gfx_col >= target_gfx_col) {
                        break;
                    }
                }
            }
        }
    }

    pub fn syncRowScroll(self: *Self) void {
        if (self.scroll.row > self.cursor.row) {
            if (self.dims.height < self.cursor.row) {
                self.scroll.row = self.cursor.row - self.dims.height + 1;
            } else if (self.cursor.row == 0) {
                self.scroll.row = 0;
            } else {
                self.scroll.row = self.cursor.row - 1;
            }
        } else if ((self.cursor.row - self.scroll.row) >= self.dims.height) {
            if (self.dims.height > self.cursor.row) {
                self.scroll.row = self.dims.height - self.cursor.row + 1;
            } else {
                self.scroll.row = self.cursor.row - self.dims.height + 1;
            }
        }
    }

    // append

    pub fn insertChar(self: *Self, char: []const u8, advance_right_after_ins: bool) !void {
        self.buffer_changed = true;
        self.ui_signaller.setNeedsRedraw();

        // Perform insertion

        const line_is_multibyte = self.lineinfo.isMultibyte(self.cursor.row);
        const insidx: u32 = self.calcOffsetFromCursor();

        self.undo_mgr.doAppend(insidx, @intCast(char.len)) catch |err| {
            if (err == error.OutOfMemoryUndo) {
                try self.handleUndoOOM();
            } else {
                return err;
            }
        };

        if (insidx > self.head_end and insidx <= self.head_end + self.gap.items.len) {
            // insertion within gap
            if ((self.gap.items.len + char.len) >= self.gap.capacity) {
                // overflow if inserted
                try self.flushGapBuffer();
                self.head_end = insidx;
                self.tail_start = insidx;
                self.gap.appendSliceAssumeCapacity(char);
            } else {
                const gap_relidx = insidx - self.head_end;
                if (gap_relidx == self.gap.items.len) {
                    self.gap.appendSliceAssumeCapacity(char);
                } else {
                    self.gap.replaceRangeAssumeCapacity(gap_relidx, 0, char);
                }
            }
        } else {
            // insertion outside of gap
            try self.flushGapBuffer();
            self.head_end = insidx;
            self.tail_start = insidx;
            self.gap.appendSliceAssumeCapacity(char);
        }

        // Highlighting

        try self.highlightFrom(insidx, // changed_region_start_in
            @intCast(insidx + char.len), // changed_region_end
            @intCast(char.len), // shift
            true, // is_insert
            self.cursor.row // line_start
        );

        // Move cursor

        if (char[0] == '\n') {
            self.lineinfo.increaseOffsets(self.cursor.row + 1, 1);
            const line_inserted =
                try self.lineinfo.insert(self.cursor.row + 1, insidx + 1, false);
            if (line_is_multibyte) {
                try self.recheckIsMultibyte(self.cursor.row);
                try self.recheckIsMultibyte(self.cursor.row + 1);
            }
            if (line_inserted and self.isTextWrapped()) {
                try self.wrapLine(self.cursor.row + 1);
            }
            self.goDownHead();
            self.calcLineDigits();
        } else {
            if (char.len > 1) {
                self.lineinfo.setMultibyte(self.cursor.row, true);
            }
            self.lineinfo.increaseOffsets(self.cursor.row + 1, @intCast(char.len));
            if (self.isTextWrapped()) {
                try self.wrapLine(self.cursor.row);
                if (self.cursor.col == self.getRowLen(self.cursor.row) and
                    (self.cursor.row + 1) < self.lineinfo.getLen() and
                    self.lineinfo.isContLine(self.cursor.row + 1))
                {
                    self.goDownHead();
                }
                if (advance_right_after_ins) {
                    self.goRight();
                }
            } else {
                if (advance_right_after_ins) {
                    self.goRight();
                }
            }
        }
    }

    pub fn insertCharPair(self: *Self, char1: []const u8, char2: []const u8) !void {
        try self.insertChar(char1, true);
        try self.insertChar(char2, false);
    }

    pub fn insertCharUnlessOverwrite(self: *Self, char: []const u8) !void {
        const insidx: u32 = self.calcOffsetFromCursor();
        const bytes_starting = self.bytesStartingAt(insidx) orelse {
            return self.insertChar(char, true);
        };
        if (std.mem.startsWith(u8, bytes_starting, char)) {
            self.goRight();
            return;
        }
        try self.insertChar(char, true);
    }

    pub fn insertTab(self: *Self) !void {
        var indent: std.BoundedArray(u8, config.MAX_TAB_SIZE) = .{};
        if (self.conf.use_tabs) {
            indent.append('\t') catch unreachable;
        } else {
            for (0..@intCast(self.tab_size)) |_| {
                indent.append(' ') catch break;
            }
        }
        const insidx: u32 = self.calcOffsetFromCursor();
        self.undo_mgr.doAppend(insidx, @intCast(indent.len)) catch |err| {
            if (err == error.OutOfMemoryUndo) {
                try self.handleUndoOOM();
            } else {
                return err;
            }
        };
        return self.insertSliceAtPosWithHints(insidx, indent.slice(), true, false);
    }

    pub fn insertNewline(self: *Self) !void {
        var indent: std.BoundedArray(u8, 32) = .{};

        var iter = self.iterate(self.lineinfo.getOffset(self.cursor.row));
        while (iter.nextCodepointSliceUntil(self.calcOffsetFromCursor())) |bytes| {
            if (encoding.isSpace(bytes)) {
                indent.appendSlice(bytes) catch break;
            } else {
                break;
            }
        }

        try self.insertChar("\n", true);

        if (indent.len > 0) {
            const insidx: u32 = self.calcOffsetFromCursor();
            self.undo_mgr.doAppend(insidx, @intCast(indent.len)) catch |err| {
                if (err == error.OutOfMemoryUndo) {
                    try self.handleUndoOOM();
                } else {
                    return err;
                }
            };
            try self.insertSliceAtPosWithHints(insidx, indent.constSlice(), false, false);
        }
    }

    fn shiftAndInsertNewLines(
        self: *Self,
        slice: []const u8,
        insidx: u32,
        first_row_after_insidx: u32,
        is_slice_always_inline: bool,
    ) !u32 {
        if (first_row_after_insidx < self.lineinfo.getLen()) {
            self.lineinfo.increaseOffsets(first_row_after_insidx, @intCast(slice.len));
        }

        var newlines_allocator = std.heap.stackFallback(16, self.allocator);
        var newlines = std.ArrayList(u32).init(newlines_allocator.get());
        defer newlines.deinit();

        if (!is_slice_always_inline) {
            var absidx: u32 = insidx;
            for (slice) |byte| {
                if (byte == '\n') {
                    try newlines.append(absidx + 1);
                }
                absidx += 1;
            }
        }

        if (insidx > self.head_end and insidx <= self.head_end + self.gap.items.len) {
            // insertion within gap
            if ((self.gap.items.len + slice.len) < self.gap.capacity) {
                const gap_relidx = insidx - self.head_end;
                self.gap.replaceRangeAssumeCapacity(gap_relidx, 0, slice);
            } else {
                // overflow if inserted
                try self.flushGapBuffer();
                try self.buffer.insertSlice(insidx, slice);
            }
        } else {
            try self.flushGapBuffer();
            try self.buffer.insertSlice(insidx, slice);
        }

        if (newlines.items.len > 0) {
            try self.lineinfo.insertSlice(first_row_after_insidx, newlines.items);
            self.calcLineDigits();
        }

        for ((first_row_after_insidx - 1)..(first_row_after_insidx + newlines.items.len)) |i| {
            try self.recheckIsMultibyte(@intCast(i));
        }
        if (self.isTextWrapped()) {
            const insidx_end: u32 = @intCast(insidx + slice.len);
            const ins_row: u32 = @intCast(first_row_after_insidx - 1);
            const next_row: u32 = (try self.wrapTextFrom(@intCast(first_row_after_insidx - 1), @intCast(first_row_after_insidx + newlines.items.len)));
            var row: u32 = next_row;
            while (row > ins_row) {
                row -= 1;
                if (self.lineinfo.getOffset(@intCast(row)) <= insidx_end) {
                    return @intCast(row);
                }
            }
            return self.lineinfo.findMaxLineBeforeOffset(insidx_end, ins_row);
        } else {
            return @intCast(first_row_after_insidx - 1 + newlines.items.len);
        }
    }

    pub fn insertSlice(self: *Self, slice: []const u8) !void {
        const insidx: u32 = self.calcOffsetFromCursor();
        self.undo_mgr.doAppend(insidx, @intCast(slice.len)) catch |err| {
            if (err == error.OutOfMemoryUndo) {
                try self.handleUndoOOM();
            } else {
                return err;
            }
        };
        return self.insertSliceAtPosWithHints(
            insidx,
            slice,
            true, // use_cursor_line_hint
            false, // is_slice_always_inline
        );
    }

    fn insertSliceAtPosWithHints(
        self: *Self,
        insidx: u32,
        slice: []const u8,
        use_cursor_line_hint: bool,
        is_slice_always_inline: bool,
    ) !void {
        self.buffer_changed = true;
        self.ui_signaller.setNeedsRedraw();

        // Perform insertion

        const first_row_after_insidx: u32 = if (use_cursor_line_hint)
            self.cursor.row + 1
        else
            self.lineinfo.findMinLineAfterOffset(insidx, 0);

        const row_at_end_of_slice: u32 =
            try self.shiftAndInsertNewLines(slice, insidx, first_row_after_insidx, is_slice_always_inline);

        // Highlighting

        try self.highlightFrom(insidx, // changed_region_start_in
            @intCast(insidx + slice.len), // changed_region_end
            @intCast(slice.len), // shift
            true, // is_insert
            (first_row_after_insidx - 1) // line_start
        );

        // Move the cursor to end of entered slice

        self.cursor.row = row_at_end_of_slice;

        const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
        const insidx_end: u32 = @intCast(insidx + slice.len);
        self.cursor.col = insidx_end - offset_start;

        if (!self.lineinfo.isMultibyte(self.cursor.row)) {
            self.cursor.gfx_col = self.cursor.col;
        } else {
            self.cursor.gfx_col = 0;
            var iter = self.iterate(offset_start);
            while (iter.nextCodepointSliceUntil(insidx_end)) |bytes| {
                const char = std.unicode.utf8Decode(bytes) catch unreachable;
                self.cursor.gfx_col += encoding.countCharCols(char);
            }
        }

        self.scroll.col = 0;
        self.scroll.gfx_col = 0;
        self.syncColumnScroll();
        self.syncRowScroll();
    }

    /// Inserts slice at specified position. Used by UndoManager.
    pub fn insertSliceAtPos(self: *Self, insidx: u32, slice: []const u8) !void {
        return self.insertSliceAtPosWithHints(insidx, slice, false, false);
    }

    // deletion

    /// delete_next_char is true when pressing Delete, false when backspacing
    pub fn deleteChar(self: *Self, delete_next_char: bool) !void {
        var delidx: u32 = self.calcOffsetFromCursor();

        if (delete_next_char and delidx == self.getLogicalLen()) {
            return;
        } else if (!delete_next_char and delidx == 0) {
            return;
        }

        self.buffer_changed = true;
        var deleted_char = [_]u8{0} ** 4;
        var seqlen: u32 = undefined;

        // Delete the character and record the deleted char

        if (delete_next_char) {
            const bytes_starting = self.bytesStartingAt(delidx).?;
            seqlen = @intCast(encoding.sequenceLen(bytes_starting[0]) catch unreachable);
            @memcpy(deleted_char[0..seqlen], bytes_starting[0..seqlen]);
        } else {
            var iter = self.iterate(delidx);
            const bytes = iter.prevCodepointSlice().?;
            seqlen = @intCast(bytes.len);
            delidx -= @intCast(bytes.len);
            @memcpy(deleted_char[0..seqlen], bytes);
        }

        // Move the cursor to the previous char, if we are backspacing

        const cur_at_deleted_char = self.cursor;
        const delete_first_col_in_cont = blk: {
            if (self.lineinfo.isContLine(cur_at_deleted_char.row) and cur_at_deleted_char.gfx_col == 1) {
                const rowlen = self.getRowLen(cur_at_deleted_char.row);
                if (self.lineinfo.isMultibyte(cur_at_deleted_char.row)) {
                    const bytes = self.bytesStartingAt(self.lineinfo.getOffset(cur_at_deleted_char.row)).?;
                    const seqlen1 = encoding.sequenceLen(bytes[0]) catch unreachable;
                    break :blk (rowlen == seqlen1);
                } else {
                    break :blk (rowlen == 1);
                }
            }
            break :blk false;
        };
        if (!delete_next_char) {
            if (self.cursor.gfx_col == 0 or delete_first_col_in_cont) {
                self.goUp();
                self.goTail();
                if (delete_first_col_in_cont) {
                    self.goLeft();
                }
            } else {
                self.goLeft();
            }
        }

        // Perform deletion

        const logical_tail_start = self.head_end + self.gap.items.len;

        if (delidx < self.head_end) {
            if (delidx == (self.head_end - seqlen)) {
                // deletion exactly before gap
                self.head_end -= seqlen;
            } else {
                // deletion before gap
                const dest: []u8 = self.buffer.items[delidx..(self.head_end - seqlen)];
                const src: []const u8 = self.buffer.items[(delidx + seqlen)..self.head_end];
                std.mem.copyForwards(u8, dest, src);
                self.head_end -= seqlen;
            }
        } else if (delidx >= logical_tail_start) {
            const real_tailidx = self.tail_start + (delidx - logical_tail_start);
            if (delidx == logical_tail_start) {
                // deletion one char after gap
                self.tail_start += seqlen;
            } else {
                // deletion after gap
                self.buffer.replaceRangeAssumeCapacity(real_tailidx, seqlen, &[_]u8{});
            }
        } else {
            // deletion within gap
            const gap_relidx = delidx - self.head_end;
            self.gap.replaceRangeAssumeCapacity(gap_relidx, seqlen, &[_]u8{});
        }

        self.undo_mgr.doDelete(delidx, deleted_char[0..seqlen]) catch |err| {
            if (err == error.OutOfMemoryUndo) {
                try self.handleUndoOOM();
            } else {
                return err;
            }
        };

        // Highlighting

        try self.highlightFrom(delidx, // changed_region_start_in
            delidx, // changed_region_end
            @intCast(seqlen), // shift
            false, // is_insert
            blk: { // line_start
            if (!delete_next_char and self.cursor.gfx_col == 0 and self.cursor.row > 0) {
                break :blk cur_at_deleted_char.row - 1;
            } else {
                break :blk cur_at_deleted_char.row;
            }
        });

        // Update line offset info

        const deleted_char_is_mb = seqlen > 1;

        // checkIsMultibyte is done after decreaseOffsets
        // because if not then the bounds of the line would not be updated

        if (delete_next_char) {
            if (cur_at_deleted_char.row == self.lineinfo.getLen() - 1) {
                // do nothing if deleting character of last line
            } else if (cur_at_deleted_char.col == self.getRowLen(cur_at_deleted_char.row)) {
                // deleting next line
                self.lineinfo.decreaseOffsets(cur_at_deleted_char.row + 1, 1);
                self.lineinfo.remove(cur_at_deleted_char.row + 1);
                try self.recheckIsMultibyteAfterDelete(cur_at_deleted_char.row, deleted_char_is_mb);
                if (self.isTextWrapped()) {
                    try self.wrapLine(cur_at_deleted_char.row);
                }
                self.calcLineDigits();
            } else {
                self.lineinfo.decreaseOffsets(cur_at_deleted_char.row + 1, seqlen);
                try self.recheckIsMultibyteAfterDelete(cur_at_deleted_char.row, deleted_char_is_mb);
                if (self.isTextWrapped()) {
                    try self.wrapLine(cur_at_deleted_char.row);
                }
            }
        } else {
            if (self.lineinfo.isContLine(cur_at_deleted_char.row)) {
                if (delete_first_col_in_cont) {
                    self.lineinfo.decreaseOffsets(cur_at_deleted_char.row + 1, seqlen);
                    self.lineinfo.remove(cur_at_deleted_char.row);
                    try self.recheckIsMultibyteAfterDelete(cur_at_deleted_char.row - 1, deleted_char_is_mb);
                } else {
                    self.lineinfo.decreaseOffsets(cur_at_deleted_char.row + 1, seqlen);
                    try self.recheckIsMultibyteAfterDelete(cur_at_deleted_char.row, deleted_char_is_mb);
                    if (self.isTextWrapped()) {
                        try self.wrapLine(cur_at_deleted_char.row);
                    }
                }
            } else if (cur_at_deleted_char.col == 0) {
                std.debug.assert(deleted_char[0] == '\n');
                self.lineinfo.decreaseOffsets(cur_at_deleted_char.row + 1, 1);
                self.lineinfo.remove(cur_at_deleted_char.row);
                // newlines may fuse an ascii line and a unicode line together,
                // so the generic function should be used
                try self.recheckIsMultibyte(cur_at_deleted_char.row - 1);
                self.calcLineDigits();
            } else {
                self.lineinfo.decreaseOffsets(cur_at_deleted_char.row + 1, seqlen);
                try self.recheckIsMultibyteAfterDelete(cur_at_deleted_char.row, deleted_char_is_mb);
                if (self.isTextWrapped()) {
                    try self.wrapLine(cur_at_deleted_char.row);
                }
            }
        }

        self.ui_signaller.setNeedsRedraw();
    }

    /// Delete region at specified position. Used by UndoManager.
    pub fn deleteRegionAtPos(
        self: *Self,
        delete_start: u32,
        delete_end: u32,
        record_undoable_action: bool,
        copy_orig_slice_to_undo_heap: bool,
    ) !?[]const u8 {
        self.buffer_changed = true;
        self.ui_signaller.setNeedsRedraw();

        const logical_tail_start = self.head_end + self.gap.items.len;

        var retval: ?[]const u8 = null;

        if (delete_start >= self.head_end and delete_end < logical_tail_start) {
            // deletion within gap buffer
            const gap_delete_start = delete_start - self.head_end;
            const gap_delete_end = delete_end - self.head_end;

            if (record_undoable_action) {
                self.undo_mgr.doDelete(delete_start, self.gap.items[gap_delete_start..gap_delete_end]) catch |err| {
                    if (err == error.OutOfMemoryUndo) {
                        try self.handleUndoOOM();
                        return null;
                    } else {
                        return err;
                    }
                };
            }

            retval = if (copy_orig_slice_to_undo_heap)
                try self.undo_mgr.copySlice(self.gap.items[gap_delete_start..gap_delete_end])
            else
                null;

            const n_deleted = gap_delete_end - gap_delete_start;

            // Remove chars from gap
            self.gap.replaceRangeAssumeCapacity(gap_delete_start, n_deleted, &[_]u8{});
        } else {
            // deletion outside, or between gap buffer

            // assume that the gap buffer is flushed to make it easier
            // for us to delete the region
            try self.flushGapBuffer();

            if (record_undoable_action) {
                self.undo_mgr.doDelete(delete_start, self.buffer.items[delete_start..delete_end]) catch |err| {
                    if (err == error.OutOfMemoryUndo) {
                        try self.handleUndoOOM();
                        return null;
                    } else {
                        return err;
                    }
                };
            }

            retval = if (copy_orig_slice_to_undo_heap)
                try self.undo_mgr.copySlice(self.buffer.items[delete_start..delete_end])
            else
                null;

            const n_deleted = delete_end - delete_start;

            if (delete_end >= self.buffer.items.len) {
                const new_len = self.buffer.items.len - n_deleted;
                self.buffer.shrinkRetainingCapacity(new_len);
            } else {
                // Remove chars from buffer
                const new_len = self.buffer.items.len - n_deleted;
                std.mem.copyForwards(u8, self.buffer.items[delete_start..new_len], self.buffer.items[delete_end..]);
                self.buffer.shrinkRetainingCapacity(new_len);
            }
        }

        // Update line info

        const removed_line_start = self.lineinfo.removeLinesInRange(delete_start, delete_end);

        // Highlighting

        try self.highlightFrom(delete_start, // changed_region_start_in
            delete_start, // changed_region_end
            delete_end - delete_start, // shift
            false, // is_insert
            removed_line_start // line_start
        );

        // Text wrapping and update cursor

        try self.recheckIsMultibyte(removed_line_start);
        if ((removed_line_start + 1) < self.lineinfo.getLen()) {
            try self.recheckIsMultibyte(removed_line_start + 1);
        }

        if (self.isTextWrapped()) {
            _ = try self.wrapTextFrom(removed_line_start, removed_line_start + 1);
        }

        if (self.lineinfo.isContLine(removed_line_start) and
            self.getRowLen(removed_line_start) == 0)
        {
            self.lineinfo.remove(removed_line_start);
            self.cursor.row = removed_line_start - 1;
            self.goTail();
        } else {
            self.cursor.row = removed_line_start;
            const row_start = self.lineinfo.getOffset(self.cursor.row);
            self.cursor.col = delete_start - row_start;

            if (!self.lineinfo.isMultibyte(self.cursor.row)) {
                self.cursor.gfx_col = self.cursor.col;
            } else {
                self.cursor.gfx_col = 0;
                var iter = self.iterate(row_start);
                while (iter.nextCodepointSliceUntil(delete_start)) |char| {
                    self.cursor.gfx_col += encoding.countCharCols(try std.unicode.utf8Decode(char));
                }
            }
        }

        self.calcLineDigits();
        self.syncColumnScroll();
        self.syncRowScroll();
        return retval;
    }

    pub fn deleteMarked(self: *Self) !void {
        if (self.markers == null) {
            return;
        }

        const markers = self.markers.?;

        if (markers.start == markers.end) {
            return;
        }

        _ = try self.deleteRegionAtPos(markers.start, markers.end, true, false);

        self.cursor = markers.start_cur;
        if (self.cursor.row >= self.lineinfo.getLen()) {
            self.cursor.row = self.lineinfo.getLen() - 1;
            self.goTail();
            self.syncRowScroll();
        } else {
            self.syncColumnScroll();
            self.syncRowScroll();
        }

        self.markers = null;
    }

    pub fn deleteLine(self: *Self) !void {
        const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
        var offset_end: u32 = self.getRowOffsetEnd(self.cursor.row);
        if (self.cursor.row < self.lineinfo.getLen() - 1) {
            offset_end += 1; // include newline
        }
        if (offset_start == offset_end) {
            return;
        }
        _ = try self.deleteRegionAtPos(offset_start, offset_end, true, false);
    }

    pub fn deleteWord(self: *Self) !void {
        if (self.cursor.col == 0) {
            return;
        }
        const delete_end = self.calcOffsetFromCursor();
        self.goLeftWord();
        const delete_start = self.calcOffsetFromCursor();
        _ = try self.deleteRegionAtPos(delete_start, delete_end, true, false);
    }

    // Replacement

    pub fn replaceRegion(
        self: *Self,
        replace_start: u32,
        replace_end: u32,
        new_buffer: []const u8,
        record_undoable_action: bool,
    ) !void {
        self.ui_signaller.setNeedsRedraw();

        if (replace_start == replace_end) {
            if (record_undoable_action) {
                self.undo_mgr.doAppend(replace_start, @intCast(new_buffer.len)) catch |err| {
                    if (err == error.OutOfMemoryUndo) {
                        try self.handleUndoOOM();
                    } else {
                        return err;
                    }
                };
            }
            return self.insertSliceAtPos(
                replace_start,
                new_buffer,
            );
        }

        try self.flushGapBuffer();

        // TODO: replace within gap buffer

        if (record_undoable_action) {
            self.undo_mgr.doReplace(
                replace_start,
                self.buffer.items[replace_start..replace_end],
                new_buffer,
            ) catch |err| {
                if (err == error.OutOfMemoryUndo) {
                    try self.handleUndoOOM();
                } else {
                    return err;
                }
            };
        }

        const old_buffer_len = replace_end - replace_start;

        try self.buffer.replaceRange(
            replace_start,
            old_buffer_len,
            new_buffer,
        );

        var newlines = std.ArrayList(u32).init(self.allocator);
        defer newlines.deinit();

        for (new_buffer, 0..new_buffer.len) |item, idx| {
            if (item == '\n') {
                try newlines.append(@intCast(replace_start + idx + 1));
            }
        }

        // line info

        const replace_line_start = self.lineinfo.removeLinesInRange(replace_start, replace_end);

        // Highlighting
        if (new_buffer.len < old_buffer_len) {
            // decrease
            try self.highlightFrom(replace_start, // changed_region_start_in
                @intCast(replace_start + new_buffer.len), // changed_region_end
                @intCast(old_buffer_len - new_buffer.len), // shift
                false, replace_line_start);
        } else {
            // increase
            try self.highlightFrom(replace_start, // changed_region_start_in
                @intCast(replace_start + new_buffer.len), // changed_region_end
                @intCast(new_buffer.len - old_buffer_len), // shift
                true, replace_line_start);
        }

        // text wrapping and update line info

        const row_at_end_of_slice: u32 = @intCast(replace_line_start + 1 + newlines.items.len);

        try self.lineinfo.insertSlice(replace_line_start + 1, newlines.items);
        self.lineinfo.increaseOffsets(row_at_end_of_slice, @intCast(new_buffer.len));
        self.calcLineDigits();

        for (replace_line_start..row_at_end_of_slice) |i| {
            try self.recheckIsMultibyte(@intCast(i));
        }

        if (self.isTextWrapped()) {
            _ = try self.wrapTextFrom(replace_line_start, row_at_end_of_slice);
        }

        // cursor

        self.cursor.row = row_at_end_of_slice - 1;

        const new_replace_end: u32 = @intCast(replace_start + new_buffer.len);
        self.cursor.col = 0;
        self.cursor.gfx_col = 0;
        var iter = self.iterate(self.lineinfo.getOffset(self.cursor.row));
        while (iter.nextCodepointSliceUntil(new_replace_end)) |char| {
            self.cursor.col += @intCast(char.len);
            self.cursor.gfx_col += encoding.countCharCols(try std.unicode.utf8Decode(char));
        }

        self.syncColumnScroll();
        self.syncRowScroll();
    }

    pub fn replaceMarked(self: *Self, new_buffer: []const u8) !void {
        var markers = &self.markers.?;
        const new_end: u32 = @intCast(markers.start + new_buffer.len);
        try self.replaceRegion(markers.start, markers.end, new_buffer, true);
        markers.end = new_end;
    }

    pub const ReplaceNeedle = union(enum) {
        string: []const u8,
        regex: Expr,

        pub fn deinit(self: *ReplaceNeedle, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .string => |needle| {
                    allocator.free(needle);
                },
                .regex => |*regex| {
                    regex.deinit(allocator);
                },
            }
        }

        fn checkMatch(self: *const ReplaceNeedle, haystack: []const u8) ?usize {
            switch (self.*) {
                .string => |needle| {
                    if (std.mem.startsWith(u8, haystack, needle)) {
                        return needle.len;
                    } else {
                        return null;
                    }
                },
                .regex => |*regex| {
                    const match = regex.checkMatch(haystack, &.{}) catch {
                        return null;
                    };
                    if (match.fully_matched) {
                        return match.pos;
                    } else {
                        return null;
                    }
                },
            }
        }
    };

    pub fn replaceAllMarked(self: *Self, needle: ReplaceNeedle, replacement: []const u8) !usize {
        var markers = &self.markers.?;
        var replaced = str.String.init(self.allocator);
        defer replaced.deinit();

        // TODO: replace all within gap buffer
        try self.flushGapBuffer();

        const src_text = self.buffer.items[markers.start..markers.end];

        var slide: usize = 0;
        var replacements: usize = 0;
        while (slide < src_text.len) {
            if (needle.checkMatch(src_text[slide..])) |len| {
                try replaced.appendSlice(replacement);
                slide += len;
                replacements += 1;
            } else {
                try replaced.append(src_text[slide]);
                slide += 1;
            }
        }

        const new_end: u32 = @intCast(markers.start + replaced.items.len);
        try self.replaceRegion(markers.start, markers.end, replaced.items, true);
        markers.end = new_end;

        return replacements;
    }

    // Indentation

    pub fn indentMarked(self: *Self) !void {
        if (self.markers == null) {
            return;
        }

        var markers = &self.markers.?;
        if (markers.start_cur.col != 0) {
            markers.start_cur.col = 0;
            markers.start_cur.gfx_col = 0;
            markers.start = self.lineinfo.getOffset(markers.start_cur.row);
        }

        if (markers.start == markers.end) {
            markers.end = self.getRowOffsetEnd(markers.start_cur.row);
        }

        var indented = str.String.init(self.allocator);
        defer indented.deinit();
        for (0..@intCast(self.tab_size)) |_| {
            try indented.append(' ');
        }

        var iter = self.iterate(self.lineinfo.getOffset(markers.start_cur.row));
        while (iter.nextCodepointSliceUntil(markers.end)) |char| {
            try indented.appendSlice(char);
            if (char[0] == '\n') {
                for (0..@intCast(self.tab_size)) |_| {
                    try indented.append(' ');
                }
            }
        }

        try self.replaceMarked(indented.items);
    }

    fn startsWithIndent(self: *const Self, slice: []const u8) bool {
        if (slice.len < self.tab_size) {
            return false;
        }
        for (0..@intCast(self.tab_size)) |i| {
            if (slice[i] != ' ') {
                return false;
            }
        }
        return true;
    }

    pub fn dedentMarked(self: *Self) !void {
        if (self.markers == null) {
            return;
        }

        var markers = &self.markers.?;

        if (markers.start_cur.col != 0) {
            markers.start_cur.col = 0;
            markers.start_cur.gfx_col = 0;
            markers.start = self.lineinfo.getOffset(markers.start_cur.row);
        }

        if (markers.start == markers.end) {
            markers.end = self.getRowOffsetEnd(markers.start_cur.row);
        }

        var dedented = str.String.init(self.allocator);
        defer dedented.deinit();

        var iter = self.iterate(self.lineinfo.getOffset(markers.start_cur.row));
        while (iter.nextCodepointSliceUntil(markers.end)) |char| {
            try dedented.appendSlice(char);
        }

        var dest: usize = 0;
        var src: usize = 0;
        var newlen: usize = dedented.items.len;

        if (self.startsWithIndent(dedented.items)) {
            src += @intCast(self.tab_size);
            newlen -= @intCast(self.tab_size);
        }

        while (src < dedented.items.len) {
            if (dedented.items[src] == '\n' and self.startsWithIndent(dedented.items[(src + 1)..])) {
                dedented.items[dest] = '\n';
                dest += 1;
                src += @intCast(self.tab_size + 1);
                newlen -= @intCast(self.tab_size);
            } else {
                dedented.items[dest] = dedented.items[src];
                dest += 1;
                src += 1;
            }
        }
        dedented.shrinkRetainingCapacity(newlen);

        try self.replaceMarked(dedented.items);
    }

    // markers

    pub fn markStart(self: *Self) void {
        const markidx: u32 = self.calcOffsetFromCursor();
        self.markers = .{
            .start = markidx,
            .end = markidx,
            .start_cur = self.cursor,
            .orig_start = markidx,
        };
        self.ui_signaller.setNeedsRedraw();
        self.ui_signaller.setNeedsUpdateCursor();
    }

    pub fn markEnd(self: *Self) void {
        const markidx: u32 = self.calcOffsetFromCursor();
        if (self.markers) |*markers| {
            const orig_start: u32 = markers.orig_start;
            if (markidx > markers.orig_start) {
                if (markers.start < orig_start) {
                    // flip the selection direction
                    const orig_row = self.lineinfo.findMaxLineBeforeOffset(orig_start, 0);
                    const orig_cur: TextPos = .{
                        .row = orig_row,
                        .col = orig_start - self.lineinfo.getOffset(orig_row),
                    };
                    markers.* = .{
                        .start = orig_start,
                        .orig_start = orig_start,
                        .end = markidx,
                        .start_cur = orig_cur,
                    };
                } else {
                    markers.end = markidx;
                }
            } else {
                markers.* = .{
                    .start = markidx,
                    .orig_start = orig_start,
                    .end = orig_start,
                    .start_cur = self.cursor,
                };
            }
        } else {
            @panic("markEnd called without markers");
        }
        self.ui_signaller.setNeedsRedraw();
    }

    pub fn markAll(self: *Self) void {
        self.markers = .{
            .start = 0,
            .orig_start = 0,
            .end = self.getLogicalLen(),
            .start_cur = .{
                .row = 0,
                .col = 0,
                .gfx_col = 0,
            },
        };
        self.ui_signaller.setNeedsRedraw();
    }

    pub fn markLine(self: *Self) void {
        const mark_start = self.lineinfo.getOffset(self.cursor.row);
        self.markers = .{
            .start = mark_start,
            .orig_start = mark_start,
            .end = self.getRowOffsetEnd(self.cursor.row),
            .start_cur = .{
                .row = self.cursor.row,
                .col = 0,
                .gfx_col = 0,
            },
        };
        self.ui_signaller.setNeedsRedraw();
    }

    // clipboard

    pub fn copy(self: *Self) !void {
        if (self.markers == null) {
            return;
        }
        const markers = self.markers.?;

        try self.flushGapBuffer();

        const n_copied = markers.end - markers.start;
        if (n_copied > 0) {
            if (self.conf.use_native_clipboard) {
                if (clipboard.write(self.allocator, self.buffer.items[markers.start..markers.end])) |_| {
                    return;
                } else |_| {}
            }
            self.clipboard.shrinkRetainingCapacity(0);
            try self.clipboard.appendSlice(self.buffer.items[markers.start..markers.end]);
        }
    }

    pub fn paste(self: *Self) !void {
        if (self.conf.use_native_clipboard) {
            if (try clipboard.read(self.allocator)) |native_clip| {
                defer self.allocator.free(native_clip);
                try self.insertSlice(native_clip);
                return;
            }
        }
        if (self.clipboard.items.len > 0) {
            try self.insertSlice(self.clipboard.items);
        }
    }

    pub fn duplicateLine(self: *Self) !void {
        var line = str.String.init(self.allocator);
        defer line.deinit();
        try line.append('\n');
        const offset_start: u32 = self.lineinfo.getOffset(self.cursor.row);
        const offset_end: u32 = self.getRowOffsetEnd(self.cursor.row);
        var iter = self.iterate(offset_start);
        while (iter.nextCodepointSliceUntil(offset_end)) |bytes| {
            try line.appendSlice(bytes);
        }
        self.goTail();
        try self.insertSlice(line.items);
    }

    // line wrapping

    pub fn isTextWrapped(self: *const Self) bool {
        if (!self.conf.wrap_text) {
            return false;
        }
        if (self.getLogicalLen() >= self.conf.large_file_limit) {
            return false;
        }
        return true;
    }

    pub fn wrapText(self: *Self) !void {
        var line: u32 = 0;
        while (line < self.lineinfo.getLen()) {
            const result = try self.lineinfo.updateLineWrap(self, line);
            line = result.next_line;
        }
    }

    /// Returns the final line after the wrapped text
    pub fn wrapTextFrom(
        self: *Self,
        from_line: u32,
        to_line: u32,
    ) !u32 {
        var line = from_line;
        var to = to_line;
        while (line < to) {
            const result = try self.lineinfo.updateLineWrap(self, line);
            to = @intCast(to + result.len_change);
            line = @intCast(result.next_line);
        }
        return line;
    }

    fn wrapLine(self: *Self, line: u32) !void {
        _ = try self.lineinfo.updateLineWrap(self, line);
    }

    // Highlighting

    pub fn highlightText(self: *Self) !void {
        if (self.getLogicalLen() >= self.conf.large_file_limit) {
            return;
        }
        return self.highlight.runText(self);
    }

    pub fn highlightFrom(
        self: *Self,
        changed_region_start: u32,
        changed_region_end: u32,
        shift: u32,
        is_insert: bool,
        line_start: u32,
    ) !void {
        if (self.getLogicalLen() >= self.conf.large_file_limit) {
            return;
        }
        return self.highlight.runFrom(self, changed_region_start, changed_region_end, shift, is_insert, line_start);
    }

    // Undo

    pub fn handleUndoOOM(self: *Self) !void {
        self.ui_signaller.setHideableMsgConst("Unable to allocate undo action");
    }
};
