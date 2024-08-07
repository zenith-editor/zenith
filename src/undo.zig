//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");

const str = @import("./str.zig");
const text = @import("./text.zig");
const Editor = @import("./editor.zig").Editor;

const Action = union(enum) {
    const Append = struct {
        pos: u32,
        len: u32,
        /// Original appended string, only set when action is moved to redo
        orig_buffer: ?[]const u8,

        fn deinit(self: *Append, allocator: std.mem.Allocator) void {
            if (self.orig_buffer) |orig_buffer| {
                allocator.free(orig_buffer);
            }
        }
    };

    const Delete = struct {
        pos: u32,
        orig_buffer: str.StringUnmanaged,

        fn deinit(self: *Delete, allocator: std.mem.Allocator) void {
            self.orig_buffer.deinit(allocator);
        }
    };

    const Replace = struct {
        pos: u32,
        orig_buffer: []const u8,
        new_buffer: []const u8,

        fn deinit(self: *Replace, allocator: std.mem.Allocator) void {
            allocator.free(self.orig_buffer);
            allocator.free(self.new_buffer);
        }
    };

    append: Append,
    delete: Delete,
    replace: Replace,

    fn deinit(self: *Action, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .append => |*e| {
                e.deinit(allocator);
            },
            .delete => |*e| {
                e.deinit(allocator);
            },
            .replace => |*e| {
                e.deinit(allocator);
            },
        }
    }
};

const ActionStack = std.DoublyLinkedList(Action);

pub const UndoManager = struct {
    const GPAConfig: std.heap.GeneralPurposeAllocatorConfig = .{
        .enable_memory_limit = true,
    };

    // TODO: handle out of memory
    const DEFAULT_MEM_LIMIT: usize = 4 * 1024 * 1024;

    undo_stack: ActionStack = .{},
    redo_stack: ActionStack = .{},
    gpa: std.heap.GeneralPurposeAllocator(GPAConfig) = .{
        .requested_memory_limit = DEFAULT_MEM_LIMIT,
    },
    text_handler: *text.TextHandler,

    fn allocator(self: *UndoManager) std.mem.Allocator {
        return self.gpa.allocator();
    }

    pub fn setMemoryLimit(self: *UndoManager, bytes: usize) void {
        self.gpa.setRequestedMemoryLimit(bytes);
    }

    pub fn canAllocateMemory(self: *UndoManager, bytes: usize) bool {
        return (self.gpa.total_requested_bytes + bytes) < self.gpa.requested_memory_limit;
    }

    pub fn clear(self: *UndoManager) void {
        self.clearRedoStack();
        while (self.undo_stack.popFirst()) |action_ptr| {
            self.destroyActionNode(action_ptr);
        }
    }

    fn clearRedoStack(self: *UndoManager) void {
        while (self.redo_stack.pop()) |node| {
            node.data.deinit(self.allocator());
        }
    }

    fn appendAction(self: *UndoManager, action: *const Action) !void {
        std.debug.assert(self.redo_stack.first == null);
        while (!self.canAllocateMemory(@sizeOf(ActionStack.Node))) {
            if (self.undo_stack.popFirst()) |action_ptr| {
                self.destroyActionNode(action_ptr);
            } else {
                break;
            }
        }
        const action_node: *ActionStack.Node = self.allocator().create(ActionStack.Node) catch {
            return error.OutOfMemoryUndo;
        };
        action_node.* = ActionStack.Node{
            .data = action.*,
        };
        self.undo_stack.append(action_node);
    }

    fn destroyActionNode(self: *UndoManager, node: *ActionStack.Node) void {
        node.data.deinit(self.allocator());
        self.allocator().destroy(node);
    }

    // allocated objects within undo heap

    pub fn copySlice(self: *UndoManager, slice: []const u8) ![]const u8 {
        const result = try self.allocator().alloc(u8, slice.len);
        @memcpy(result, slice);
        return result;
    }

    // actions

    pub fn doAppend(self: *UndoManager, pos: u32, len: u32) !void {
        self.clearRedoStack();
        if (self.undo_stack.last) |node| {
            switch (node.data) {
                Action.append => |*append| {
                    if (append.orig_buffer == null and append.pos + append.len == pos) {
                        append.len += len;
                        return;
                    }
                },
                else => {},
            }
        }
        try self.appendAction(&.{
            .append = Action.Append{
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
                        try delete.orig_buffer.appendSlice(self.allocator(), del_contents);
                        errdefer self.clearUndoStack();
                        return;
                    } else if (pos + del_contents.len == delete.pos) {
                        delete.pos = pos;
                        try delete.orig_buffer.insertSlice(self.allocator(), 0, del_contents);
                        errdefer self.clearUndoStack();
                        return;
                    }
                },
                else => {},
            }
        }

        var orig_buffer: str.StringUnmanaged = .{};
        try orig_buffer.appendSlice(
            self.allocator(),
            del_contents,
        );
        errdefer orig_buffer.deinit(self.allocator());

        try self.appendAction(&.{
            .delete = Action.Delete{
                .pos = pos,
                .orig_buffer = orig_buffer,
            },
        });
    }

    pub fn doReplace(self: *UndoManager, pos: u32, orig_buffer: []const u8, new_buffer: []const u8) !void {
        self.clearRedoStack();

        const a_orig_buffer = try self.allocator().dupe(u8, orig_buffer);
        errdefer self.allocator().free(a_orig_buffer);

        const a_new_buffer = try self.allocator().dupe(u8, new_buffer);
        errdefer self.allocator().free(a_new_buffer);

        try self.appendAction(&.{
            .replace = Action.Replace{
                .pos = pos,
                .orig_buffer = a_orig_buffer,
                .new_buffer = a_new_buffer,
            },
        });
    }

    // undo

    pub fn undo(self: *UndoManager) !void {
        if (self.undo_stack.pop()) |act| {
            switch (act.data) {
                .append => |*append| {
                    if (append.orig_buffer == null) {
                        if (!self.canAllocateMemory(append.len)) {
                            return error.OutOfMemoryUndo;
                        }
                        append.orig_buffer = try self.text_handler.deleteRegionAtPos(
                            append.pos,
                            append.pos + append.len,
                            false, // record_undoable_action
                            true, // copy_orig_slice_to_undo_heap
                        );
                    } else {
                        _ = try self.text_handler.deleteRegionAtPos(
                            append.pos,
                            append.pos + append.len,
                            false, // record_undoable_action
                            false, // copy_orig_slice_to_undo_heap
                        );
                    }
                },
                .delete => |*delete| {
                    try self.text_handler.insertSliceAtPos(delete.pos, delete.orig_buffer.items);
                },
                .replace => |*replace| {
                    try self.text_handler.replaceRegion(
                        replace.pos,
                        @intCast(replace.pos + replace.new_buffer.len),
                        replace.orig_buffer,
                        false, // record_undoable_action
                    );
                },
            }
            self.redo_stack.append(act);
        }
    }

    pub fn redo(self: *UndoManager) !void {
        if (self.redo_stack.pop()) |act| {
            switch (act.data) {
                .append => |*append| {
                    try self.text_handler.insertSliceAtPos(append.pos, append.orig_buffer.?);
                },
                .delete => |*delete| {
                    _ = try self.text_handler.deleteRegionAtPos(
                        delete.pos,
                        @intCast(delete.pos + delete.orig_buffer.items.len),
                        false, // record_undoable_action
                        false, // copy_orig_slice_to_undo_heap
                    );
                },
                .replace => |*replace| {
                    try self.text_handler.replaceRegion(
                        replace.pos,
                        @intCast(replace.pos + replace.orig_buffer.len),
                        replace.new_buffer,
                        false, // record_undoable_action
                    );
                },
            }
            self.undo_stack.append(act);
        }
    }
};
