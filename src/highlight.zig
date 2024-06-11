//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const Highlight = @This();

const std = @import("std");
const build_config = @import("build_config");
const testing = std.testing;

const utils = @import("./utils.zig");
const text = @import("./text.zig");
const patterns = @import("./patterns.zig");
const config = @import("./config.zig");
const editor = @import("./editor.zig");

pub const Token = struct {
    pos_start: u32,
    pos_end: u32,
    typeid: usize,

    fn eql(self: *const Token, other: *const Token) bool {
        return (self.pos_start == other.pos_start and
            self.pos_end == other.pos_end and
            self.typeid == other.typeid);
    }
};

pub const TokenType = struct {
    color: editor.Editor.ColorCode,
    pattern: ?patterns.Expr,
    promote_types: []const config.Reader.PromoteType,

    fn deinit(self: *TokenType, allocr: std.mem.Allocator) void {
        if (self.pattern) |*pattern| {
            pattern.deinit(allocr);
        }
    }
};

pub const Iterator = struct {
    highlight: *const Highlight,
    pos: u32 = 0,
    idx: usize = 0,

    pub fn nextCodepoint(self: *Iterator, seqlen: u32) ?Token {
        if (self.idx == self.highlight.tokens.items.len) {
            // after last token
            return null;
        }
        const cur_pos = self.pos;
        const cur_token = self.highlight.tokens.items[self.idx];
        self.pos += seqlen;
        if (cur_token.pos_start <= cur_pos and cur_pos < cur_token.pos_end) {
            // codepoint within current token
            return cur_token;
        } else if (cur_pos >= cur_token.pos_end) {
            self.idx += 1;
            if (self.idx == self.highlight.tokens.items.len) {
                // after last token
                return null;
            }
            const next_token = self.highlight.tokens.items[self.idx];
            if (next_token.pos_start <= cur_pos and cur_pos < next_token.pos_end) {
                // codepoint within next token
                return next_token;
            }
        }
        return null;
    }
};

tokens: std.ArrayListUnmanaged(Token) = .{},
token_types: std.ArrayListUnmanaged(TokenType) = .{},
highlight: ?config.Reader.HighlightRc = null,

pub fn clear(self: *Highlight, allocr: std.mem.Allocator) void {
    self.tokens.shrinkAndFree(allocr, 0);
    for (self.token_types.items) |*tt| {
        tt.deinit(allocr);
    }
    self.token_types.shrinkAndFree(allocr, 0);
}

pub fn loadTokenTypesForFile(
    self: *Highlight,
    text_handler: *const text.TextHandler,
    allocr: std.mem.Allocator,
    cfg: *config.Reader,
) !void {
    self.clear(allocr);

    const extension = std.fs.path.extension(text_handler.file_path.items);
    if (extension.len < 1) {
        return;
    }

    const highlight_idx = cfg.highlights_ext_to_idx.get(extension) orelse {
        return;
    };

    // TODO: log parseHighlight error
    try cfg.parseHighlight(allocr, highlight_idx);

    self.highlight = cfg.highlights.items[highlight_idx].?.clone();
    const highlight: *const config.Reader.Highlight = self.highlight.?.get();
    for (highlight.tokens.items) |*tt| {
        // TODO: error

        try self.token_types.append(allocr, .{
            .color = editor.Editor.ColorCode.init(tt.color, null, tt.deco),
            .pattern = blk: {
                if (tt.pattern == null) {
                    break :blk null;
                }

                const expr = try patterns.Expr.create(
                    allocr,
                    tt.pattern.?,
                    &tt.flags,
                ).asErr();

                break :blk expr;
            },
            .promote_types = tt.promote_types.items,
        });
    }
}

fn promoteTokenType(text_handler: *const text.TextHandler, allocr: std.mem.Allocator, token_start: u32, token_end: u32, tt: *const TokenType, typeid: usize) !usize {
    for (tt.promote_types) |*promote_type| {
        var stackallocr = std.heap.stackFallback(128, allocr);
        var token_str = std.ArrayList(u8).init(stackallocr.get());
        defer token_str.deinit();
        var iter = text_handler.iterate(token_start);
        while (iter.nextCodepointSliceUntil(token_end)) |token_bytes| {
            try token_str.appendSlice(token_bytes);
        }
        if (std.sort.binarySearch([]const u8, token_str.items, promote_type.matches, u8, std.mem.order) != null) {
            return promote_type.to_typeid;
        }
    }
    return typeid;
}

pub fn runText(
    self: *Highlight,
    text_handler: *const text.TextHandler,
    allocr: std.mem.Allocator,
) !void {
    self.tokens.shrinkAndFree(allocr, 0);

    if (self.token_types.items.len == 0) {
        return;
    }

    var src_view = text_handler.srcView();
    var anchor_start_offset: u32 = 0;
    var pos: u32 = 0;
    outer: while (try src_view.codepointSliceAt(pos)) |bytes| {
        for (self.token_types.items, 0..self.token_types.items.len) |*tt, typeid| {
            if (tt.pattern == null) {
                continue;
            }

            const result = try tt.pattern.?.checkMatchGeneric(&src_view, &.{
                .match_from = @intCast(pos),
                .anchor_start_offset = @intCast(anchor_start_offset),
            });
            if (result.fully_matched) {
                const token: Token = .{
                    .pos_start = pos,
                    .pos_end = @intCast(result.pos),
                    .typeid = try promoteTokenType(text_handler, allocr, pos, @intCast(result.pos), tt, typeid),
                };
                try self.tokens.append(allocr, token);
                pos = @intCast(result.pos);
                continue :outer;
            }
        }
        // no token matched
        pos += @intCast(bytes.len);
        if (bytes[0] == '\n') {
            anchor_start_offset = pos;
        }
    }
}

/// Retokenize text buffer, assumes that only one continuous region
/// is changed before the call.
pub fn runFrom(
    self: *Highlight,
    text_handler: *const text.TextHandler,
    allocr: std.mem.Allocator,
    changed_region_start_in: u32,
    changed_region_end: u32,
    shift: u32,
    is_insert: bool,
    line_start: u32,
) !void {
    var src_view = text_handler.srcView();

    const opt_tok_idx_at_pos = self.findLastNearestToken(text_handler.lineinfo.getOffset(line_start), 0);

    if (opt_tok_idx_at_pos == null) {
        return self.runText(text_handler, allocr);
    }

    const tok_idx_at_pos = opt_tok_idx_at_pos.?;

    if (is_insert) {
        for (self.tokens.items[(tok_idx_at_pos + 1)..]) |*token| {
            if (token.pos_start >= changed_region_start_in) {
                token.pos_start += shift;
                token.pos_end += shift;
            }
        }
    } else {
        const delete_end = changed_region_start_in + shift;
        const tok_idx_at_delete_end = self.findLastNearestToken(delete_end, tok_idx_at_pos).?;
        if (tok_idx_at_delete_end > (tok_idx_at_pos + 1)) {
            try self.tokens.replaceRange(allocr, tok_idx_at_pos + 1, tok_idx_at_delete_end - (tok_idx_at_pos + 1), &[_]Token{});
        }
        for (self.tokens.items[(tok_idx_at_pos + 1)..]) |*token| {
            if (token.pos_start >= delete_end) {
                token.pos_start -= shift;
                token.pos_end -= shift;
            }
        }
    }

    var pos: u32 = self.tokens.items[tok_idx_at_pos].pos_start;
    var existing_idx: usize = tok_idx_at_pos;
    var anchor_start_offset: u32 = blk: {
        var anchor_start_line = line_start;
        while (anchor_start_line > 0 and text_handler.lineinfo.getOffset(anchor_start_line) > pos) {
            anchor_start_line -= 1;
        }
        break :blk text_handler.lineinfo.getOffset(anchor_start_line);
    };
    var new_token_region = std.ArrayList(Token).init(allocr);
    defer new_token_region.deinit();
    var shared_suffix = false;

    outer: while (try src_view.codepointSliceAt(pos)) |bytes| {
        for (self.token_types.items, 0..self.token_types.items.len) |*tt, typeid| {
            if (tt.pattern == null) {
                continue;
            }

            const result = try tt.pattern.?.checkMatchGeneric(&src_view, &.{
                .match_from = @intCast(pos),
                .anchor_start_offset = @intCast(anchor_start_offset),
            });
            if (result.fully_matched) {
                const token: Token = .{
                    .pos_start = pos,
                    .pos_end = @intCast(result.pos),
                    .typeid = try promoteTokenType(text_handler, allocr, pos, @intCast(result.pos), tt, typeid),
                };

                existing_idx_catchup: while (existing_idx < self.tokens.items.len) {
                    if (self.tokens.items[existing_idx].pos_start >= token.pos_start) {
                        if (token.pos_start >= changed_region_end and
                            token.eql(&self.tokens.items[existing_idx]))
                        {
                            // assume that if we get the same token at the same position,
                            // and that the token is after the changed region,
                            // then all of the following tokens should be the same
                            shared_suffix = true;
                            break :outer;
                        }
                        break :existing_idx_catchup;
                    }
                    existing_idx += 1;
                }

                try new_token_region.append(token);
                pos = @intCast(result.pos);

                continue :outer;
            }
        }
        // no token matched
        pos += @intCast(bytes.len);
        if (bytes[0] == '\n') {
            anchor_start_offset = pos;
        }
    }

    // replace region
    if (comptime build_config.dbg_highlighting) {
        std.debug.print("old highlight: {any}\n", .{self.tokens.items});
        std.debug.print("new highlight: {any}\n", .{new_token_region.items});
    }
    if (shared_suffix) {
        const existing_start = tok_idx_at_pos;

        if (comptime build_config.dbg_highlighting) {
            std.debug.print("shared from {}..{}\n", .{ existing_start, existing_idx });
        }
        try self.tokens.replaceRange(allocr, existing_start, existing_idx - existing_start, new_token_region.items);
    } else {
        if (comptime build_config.dbg_highlighting) {
            std.debug.print("new at {}\n", .{tok_idx_at_pos});
        }
        self.tokens.shrinkRetainingCapacity(existing_idx);
        try self.tokens.replaceRange(allocr, tok_idx_at_pos, self.tokens.items.len - tok_idx_at_pos, new_token_region.items);
    }
    if (comptime build_config.dbg_highlighting) {
        std.debug.print("=> highlight: {any}\n", .{self.tokens.items});
    }
}

/// Finds the last token with pos_start <= pos
pub fn findLastNearestToken(self: *const Highlight, pos: u32, from_idx: usize) ?usize {
    return utils.findLastNearestElement(Token, "pos_start", self.tokens.items, pos, from_idx);
}

pub fn iterate(self: *const Highlight, pos: u32, last_iter_idx: *usize) Iterator {
    var idx: usize = undefined;
    if (self.tokens.items.len > 0) {
        if (last_iter_idx.* < self.tokens.items.len and
            self.tokens.items[last_iter_idx.*].pos_start <= pos)
        {
            idx = self.findLastNearestToken(pos, last_iter_idx.*) orelse 0;
        } else {
            idx = self.findLastNearestToken(pos, 0) orelse 0;
        }
    } else {
        idx = 0;
    }
    last_iter_idx.* = idx;
    return .{
        .highlight = self,
        .pos = pos,
        .idx = idx,
    };
}
