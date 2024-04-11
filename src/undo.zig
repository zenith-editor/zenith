//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");
const builtin = @import("builtin");

const str = @import("./str.zig");

const Editor = @import("./editor.zig").Editor;

const Action = union(enum) {
  const Append = struct {
    pos: u32,
    len: u32,
    /// Original appended string, only set when action is moved to redo
    orig_buffer: ?[]const u8,
    
    fn deinit(self: *Append, allocr: std.mem.Allocator) void {
      if (self.orig_buffer) |orig_buffer| {
        allocr.free(orig_buffer);
      }
    }
  };
  
  const Delete = struct {
    pos: u32,
    orig_buffer: str.String,
    
    fn deinit(self: *Delete, allocr: std.mem.Allocator) void {
      self.orig_buffer.deinit(allocr);
    }
  };
  
  append: Append,
  delete: Delete,
  
  fn deinit(self: *Action, allocr: std.mem.Allocator) void {
    switch(self.*) {
      .append => |*e| { e.deinit(allocr); },
      .delete => |*e| { e.deinit(allocr); },
    }
  }
};

const ActionStack = std.DoublyLinkedList(Action);

pub const UndoManager = struct {
  const AllocGPAConfig: std.heap.GeneralPurposeAllocatorConfig = .{
    .enable_memory_limit = true,
  };
  
  const DEFAULT_MEM_LIMIT: usize = 32768;
  
  undo_stack: ActionStack = .{},
  redo_stack: ActionStack = .{},
  alloc_gpa: std.heap.GeneralPurposeAllocator(AllocGPAConfig) = .{
    .requested_memory_limit = DEFAULT_MEM_LIMIT,
  },

  fn allocr(self: *UndoManager) std.mem.Allocator {
    return self.alloc_gpa.allocator();
  }
  
  fn clearRedoStack(self: *UndoManager) void {
    while (self.redo_stack.pop()) |node| {
      node.data.deinit(self.allocr());
    }
  }
  
  fn appendAction(self: *UndoManager, action: Action) !void {
    std.debug.assert(self.redo_stack.first == null);
    var alloc_gpa = &self.alloc_gpa;
    const allocator = alloc_gpa.allocator();
    while (alloc_gpa.total_requested_bytes > alloc_gpa.requested_memory_limit) {
      const opt_action_ptr = self.undo_stack.popFirst();
      if (opt_action_ptr) |action_ptr| {
        self.destroyActionNode(action_ptr);
      }
    }
    const action_node: *ActionStack.Node = try allocator.create(ActionStack.Node);
    action_node.* = ActionStack.Node { .data = action, };
    self.undo_stack.append(action_node);
  } 
  
  fn destroyActionNode(self: *UndoManager, node: *ActionStack.Node) void {
    node.data.deinit(self.allocr());
    self.allocr().destroy(node);
  }
  
  // allocated objects within undo heap
  
  pub fn copySlice(self: *UndoManager, slice: []const u8) ![]const u8 {
    const result = try self.allocr().alloc(u8, slice.len);
    @memcpy(result, slice);
    return result;
  }
  
  // actions
  
  pub fn doAppend(self: *UndoManager, pos: u32, len: u32) !void {
    self.clearRedoStack();
    if (self.undo_stack.last) |node| {
      switch (node.data) {
        Action.append => |*append| {
          std.debug.assert(append.orig_buffer == null);
          if (append.pos + append.len == pos) {
            append.len += len;
            return;
          }
        },
        else => {},
      }
    }
    try self.appendAction(.{
      .append = Action.Append {
        .pos = pos,
        .len = len,
        .orig_buffer = null,
      },
    });
  }
  
  pub fn doDelete(self: *UndoManager, pos: u32, del_contents: []const u8) !void {
    self.clearRedoStack();
    if (self.undo_stack.last) |node| {
      switch (node.data) {
        .delete => |*delete| {
          if (delete.pos + delete.orig_buffer.items.len == pos) {
            try delete.orig_buffer.appendSlice(self.allocr(), del_contents);
            return;
          } else if (pos + del_contents.len == delete.pos) {
            delete.pos = pos;
            try delete.orig_buffer.insertSlice(self.allocr(), 0, del_contents);
            return;
          }
        },
        else => {},
      }
    }
    var orig_buffer: str.String = .{};
    try orig_buffer.appendSlice(
      self.allocr(),
      del_contents,
    );
    try self.appendAction(.{
      .delete = Action.Delete {
        .pos = pos,
        .orig_buffer = orig_buffer,
      },
    });
  }
  
  // undo
  
  pub fn undo(self: *UndoManager, E: *Editor) !void {
    if (self.undo_stack.pop()) |act| {
      switch (act.data) {
        .append => |*append| {
          if (append.orig_buffer == null) {
            append.orig_buffer = try E.text_handler.deleteRegionAtPos(
              E,
              append.pos,
              append.pos + append.len,
              false, // record_undoable_action
              true, // copy_orig_slice_to_undo_heap
            );
          } else {
            _ = try E.text_handler.deleteRegionAtPos(
              E,
              append.pos,
              append.pos + append.len,
              false, // record_undoable_action
              false, // copy_orig_slice_to_undo_heap
            );
          }
        },
        .delete => |*delete| {
          try E.text_handler.insertSliceAtPos(
            E,
            delete.pos,
            delete.orig_buffer.items
          );
        },
      }
      self.redo_stack.append(act);
    }
  }
  
  pub fn redo(self: *UndoManager, E: *Editor) !void {
    if (self.redo_stack.pop()) |act| {
      switch (act.data) {
        .append => |*append| {
          try E.text_handler.insertSliceAtPos(
            E, append.pos, append.orig_buffer.?
          );
        },
        .delete => |*delete| {
          _ = try E.text_handler.deleteRegionAtPos(
            E,
            delete.pos,
            @intCast(delete.pos + delete.orig_buffer.items.len),
            false, // record_undoable_action
            false, // copy_orig_slice_to_undo_heap
          );
        },
      }
      self.undo_stack.append(act);
    }
  }
  
};
