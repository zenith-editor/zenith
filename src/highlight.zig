//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const Highlight = @This();

const std = @import("std");
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
    return (
      self.pos_start == other.pos_start and
      self.pos_end == other.pos_end and
      self.typeid == other.typeid
    );
  }
};

pub const TokenType = struct {
  color: editor.Editor.ColorCode,
  pattern: ?patterns.Expr,
  promote_types: ?config.Reader.PromoteTypesList = null,
  
  fn deinit(self: *TokenType, allocr: std.mem.Allocator) void {
    if (self.pattern) |*pattern| {
      pattern.deinit(allocr);
    }
    if (self.promote_types) |*promote_types| {
      promote_types.deinit(allocr);
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
highlight_from_start_of_line: bool = false,

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
  cfg: *const config.Reader, 
) !void {
  self.clear(allocr);
  
  self.highlight_from_start_of_line = false;

  const extension = std.fs.path.extension(text_handler.file_path.items);
  if (extension.len < 1) {
    return;
  }
  
  const highlight_idx = cfg.highlights_ext_to_idx.get(extension) orelse {
    return;
  };
  const highlight = &cfg.highlights.items[highlight_idx];
  for (highlight.tokens.items) |*tt| {
    // TODO: error
      
    try self.token_types.append(allocr, .{
      .color = editor.Editor.ColorCode.init(
        tt.color, null, tt.is_bold
      ),
      .pattern = blk: {
        if (tt.pattern == null) {
          break :blk null;
        }
        
        const expr = try patterns.Expr.create(
          allocr,
          tt.pattern.?,
          &tt.flags,
        ).asErr();
        
        for (expr.instrs.items) |instr| {
          switch (instr) {
            .anchor_start => {
              self.highlight_from_start_of_line = true;
            },
            else => {},
          }
        }
        
        break :blk expr;
      },
      .promote_types = (
        if (tt.promote_types) |*promote_types|
          promote_types.clone()
        else null
      ),
    });
  }
}


fn promoteTokenType(
  text_handler: *const text.TextHandler,
  allocr: std.mem.Allocator,
  token_start: u32,
  token_end: u32,
  tt: *const TokenType,
  typeid: usize
) !usize {
  if (tt.promote_types) |promote_types_rc| {
    const promote_types = promote_types_rc.get();
    for (promote_types.items) |*promote_type| {
      var stackallocr = std.heap.stackFallback(128, allocr);
      var token_str = std.ArrayList(u8).init(stackallocr.get());
      defer token_str.deinit();
      var iter = text_handler.iterate(token_start);
      while (iter.nextCodepointSliceUntil(token_end)) |token_bytes| {
        try token_str.appendSlice(token_bytes);
      }
      if (std.sort.binarySearch(
        []const u8, token_str.items, promote_type.matches, u8, std.mem.order
      ) != null) {
        return promote_type.to_typeid;
      }
    }
  }
  return typeid;
}

pub fn runFromStart(
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
          .typeid = try promoteTokenType(
            text_handler, allocr, pos, @intCast(result.pos), tt, typeid
          ),
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
/// is changed before the call
pub fn run(
  self: *Highlight,
  text_handler: *const text.TextHandler,
  allocr: std.mem.Allocator,
  changed_region_start_in: u32,
  shift: u32,
  is_insert: bool,
  line_start: u32,
) !void {
  var src_view = text_handler.srcView();
  
  var changed_region_start = changed_region_start_in;
  if (self.highlight_from_start_of_line) {
    changed_region_start = text_handler.lineinfo.getOffset(line_start);
  }
  
  var changed_region_end: u32 = undefined;
  if (is_insert) {
    changed_region_end = changed_region_start_in + shift;
  } else {
    changed_region_end = changed_region_start_in;
  }
  
  const opt_tok_idx_at_pos = self.findLastNearestToken(changed_region_start, 0);
  
  if (opt_tok_idx_at_pos == null) {
    return self.runFromStart(text_handler, allocr);
  }
  
  const tok_idx_at_pos = opt_tok_idx_at_pos.?;

  if (is_insert) {
    for(self.tokens.items[(tok_idx_at_pos+1)..]) |*token| {
      token.pos_start += shift;
      token.pos_end += shift;
    }
  } else {
    const delete_end = changed_region_start_in + shift;
    const tok_idx_at_delete_end = self.findLastNearestToken(delete_end, tok_idx_at_pos).?;
    if (tok_idx_at_delete_end > (tok_idx_at_pos  + 1)) {
      try self.tokens.replaceRange(
        allocr,
        tok_idx_at_pos + 1,
        tok_idx_at_delete_end - (tok_idx_at_pos  + 1),
        &[_]Token{}
      );
    }
    for(self.tokens.items[(tok_idx_at_pos+1)..]) |*token| {
      if (token.pos_start >= delete_end) {
        token.pos_start -= shift;
        token.pos_end -= shift;
      }
    }
  }
  
  var pos: u32 = self.tokens.items[tok_idx_at_pos].pos_start;
  var existing_idx: usize = tok_idx_at_pos;
  var anchor_start_offset: u32 = (
    if (self.highlight_from_start_of_line)
      text_handler.lineinfo.getOffset(
        text_handler.lineinfo.findMaxLineBeforeOffset(pos, 0)
      )
    else 0
  );
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
          .typeid = try promoteTokenType(
            text_handler, allocr, pos, @intCast(result.pos), tt, typeid
          ),
        };
        
        existing_idx_catchup: while (existing_idx < self.tokens.items.len) {
          if (self.tokens.items[existing_idx].pos_start >= token.pos_start) {
            if (
              token.pos_start >= changed_region_end and
              token.eql(&self.tokens.items[existing_idx])
            ) {
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
    if (self.highlight_from_start_of_line and bytes[0] == '\n') {
      anchor_start_offset = pos;
    }
  }
  
  // replace region
  if (shared_suffix) {
    try self.tokens.replaceRange(
      allocr,
      tok_idx_at_pos,
      existing_idx - tok_idx_at_pos,
      new_token_region.items
    );
  } else {
    try self.tokens.replaceRange(
      allocr,
      tok_idx_at_pos,
      self.tokens.items.len - tok_idx_at_pos,
      new_token_region.items
    );
  }
}

/// Finds the last token with pos_start <= pos
pub fn findLastNearestToken(self: *const Highlight, pos: u32, from_idx: usize) ?usize {
  return utils.findLastNearestElement(
    Token, "pos_start", self.tokens.items, pos, from_idx
  );
}

pub fn iterate(self: *const Highlight, pos: u32, last_iter_idx: *usize) Iterator {
  var idx: usize = undefined;
  if (self.tokens.items.len > 0) {
    if (
      last_iter_idx.* < self.tokens.items.len and
      self.tokens.items[last_iter_idx.*].pos_start <= pos
    ) {
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