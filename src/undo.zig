//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");
const builtin = @import("builtin");

const str = @import("./str.zig");

const Editor = @import("./editor.zig").Editor;

pub const UndoManager = struct {
  const Action = union(enum) {
    const Append = struct {
      pos: u32,
      len: u32,
    };
    
    const Delete = struct {
      pos: u32,
      orig_buffer: str.String,
      
      fn deinit(self: *Delete, U: *UndoManager) void {
        self.orig_buffer.deinit(U.allocr());
      }
    };
    
    append: Append,
    delete: Delete,
    
    fn deinit(self: *Action, U: *UndoManager) void {
      switch(self.*) {
        .delete => |*delete| { delete.deinit(U); },
        else => {},
      }
    }
  };
  
  const ActionStack = std.DoublyLinkedList(Action);
  
  const AllocGPAConfig: std.heap.GeneralPurposeAllocatorConfig = .{
    .enable_memory_limit = true,
  };
  
  const DEFAULT_MEM_LIMIT: usize = 32768;
  
  stack: ActionStack = .{},
  alloc_gpa: std.heap.GeneralPurposeAllocator(AllocGPAConfig) = .{
    .requested_memory_limit = DEFAULT_MEM_LIMIT,
  },

  fn allocr(self: *UndoManager) std.mem.Allocator {
    return self.alloc_gpa.allocator();
  }
  
  fn appendAction(self: *UndoManager, action: Action) !void {
    var alloc_gpa = &self.alloc_gpa;
    const allocator = alloc_gpa.allocator();
    while (alloc_gpa.total_requested_bytes > alloc_gpa.requested_memory_limit) {
      const opt_action_ptr = self.stack.popFirst();
      if (opt_action_ptr) |action_ptr| {
        self.destroyActionNode(action_ptr);
      }
    }
    const action_node: *ActionStack.Node = try allocator.create(ActionStack.Node);
    action_node.* = ActionStack.Node { .data = action, };
    self.stack.append(action_node);
  } 
  
  fn destroyActionNode(self: *UndoManager, node: *ActionStack.Node) void {
    node.data.deinit(self);
    self.allocr().destroy(node);
  }
  
  // actions
  
  pub fn doAppend(self: *UndoManager, pos: u32, len: u32) !void {
    if (self.stack.last) |node| {
      switch (node.data) {
        Action.append => |*append| {
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
      },
    });
  }
  
  pub fn doDelete(self: *UndoManager, pos: u32, del_contents: []const u8) !void {
    if (self.stack.last) |node| {
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
    if (self.stack.pop()) |act| {
      defer self.destroyActionNode(act);
      switch (act.data) {
        .append => |*append| {
          try E.text_handler.deleteRegionAtPos(E, append.pos, append.pos + append.len, false);
        },
        .delete => |*delete| {
          try E.text_handler.insertSliceAtPos(E, delete.pos, delete.orig_buffer.items);
        },
      }
    }
  }
  
};
