//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");
const builtin = @import("builtin");

const str = @import("../str.zig");
const text = @import("../text.zig");
const editor = @import("../editor.zig");
const sig = @import("../platform/sig.zig");
const tty = @import("../platform/tty.zig");

fn onInputtedGeneric(file_path: []const u8) !text.TextHandler.OpenFileArgs {
    const cwd = std.fs.cwd();
    cwd.access(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            return .{
                .file = null,
                .file_path = file_path,
            };
        },
        else => {
            return err;
        },
    };
    const opened_file = blk: {
        const flags: std.fs.File.OpenFlags = .{
            .mode = .read_write,
            .lock = .shared,
        };
        break :blk try cwd.openFile(file_path, flags);
    };
    return .{
        .file = opened_file,
        .file_path = file_path,
    };
}

pub fn onInputted(self: *editor.Editor) !void {
    self.needs_update_cursor = true;
    if (onInputtedGeneric(self.getCmdData().cmdinp.items)) |opened_file| {
        tryOpen(self, opened_file, true) catch |err| {
            try self.getCmdData().replacePromptOverlayFmt(self, PROMPT_ERR_OPEN_FILE, .{err});
            return;
        };
        self.setState(.text);
        self.needs_redraw = true;
    } else |err| {
        try self.getCmdData().replacePromptOverlayFmt(self, PROMPT_ERR_OPEN_FILE, .{err});
        return;
    }
}

pub fn onInputtedTryToSave(self: *editor.Editor) !void {
    self.needs_update_cursor = true;
    if (onInputtedGeneric(self.getCmdData().cmdinp.items)) |opened_file| {
        tryOpen(self, opened_file, false) catch |err| {
            try self.getCmdData().replacePromptOverlayFmt(self, PROMPT_ERR_SAVE_FILE, .{err});
            return;
        };
        self.text_handler.save() catch |err| {
            try self.getCmdData().replacePromptOverlayFmt(self, PROMPT_ERR_SAVE_FILE, .{err});
            return;
        };
        self.setState(.text);
        self.needs_redraw = true;
    } else |err| {
        try self.getCmdData().replacePromptOverlayFmt(self, PROMPT_ERR_SAVE_FILE, .{err});
        return;
    }
}

pub const PROMPT_OPEN = "Open file:";
pub const PROMPT_SAVE = "Save file:";
pub const PROMPT_SAVE_NEW = "Save file to new location:";
pub const PROMPT_ERR_NEW_FILE = "Unable to create new file! (ERR: {})";
pub const PROMPT_ERR_OPEN_FILE = "Unable to open file! (ERR: {})";
pub const PROMPT_ERR_SAVE_FILE =
    "Unable to save file, try saving to another location! (ERR: {})";
pub const PROMPT_ERR_SPAWN_FM = "Unable to run file manager! (ERR: {})";

pub const Fns: editor.CommandData.FnTable = .{
    .onInputted = onInputted,
};

pub const FnsTryToSave: editor.CommandData.FnTable = .{
    .onInputted = onInputtedTryToSave,
};

fn runFileOpener(self: *editor.Editor, argv: []const []const u8, action: enum { open, save }) !void {
    defer {
        self.setupTerminal() catch {};
    }

    var path_buf = std.ArrayList(u8).init(self.allocator);
    defer path_buf.deinit();

    try tty.run(.{
        .argv = argv,
        .captured_stdout = &path_buf,
        .piped_stdin = self.in,
        .piped_stdout = self.out,
        .poll_timeout = editor.Editor.REFRESH_RATE_MS,
    });

    var path = path_buf.items;
    if (std.mem.indexOfScalar(u8, path, '\n')) |end| {
        path = path[0..end];
    }

    if (path.len == 0) {
        return;
    }

    const opened_file = try onInputtedGeneric(path);

    switch (action) {
        .open => {
            try tryOpen(self, opened_file, true);
        },
        .save => {
            try tryOpen(self, opened_file, false);
            try self.text_handler.save();
        },
    }
}

fn tryOpen(self: *editor.Editor, args: text.TextHandler.OpenFileArgs, flush_buffer: bool) !void {
    const result = try self.text_handler.open(args, flush_buffer);
    switch (result) {
        .ok => {},
        .warn_highlight => |warn_highlight| {
            try self.showConfigErrors(warn_highlight);
        },
    }
}

pub fn setupOpen(self: *editor.Editor, opt_opened_file_str: ?str.StringUnmanaged) !bool {
    if (opt_opened_file_str) |opened_file_str| {
        const new_cmd_data: editor.CommandData = .{
            .prompt = PROMPT_OPEN,
            .fns = Fns,
            .cmdinp = opened_file_str,
        };
        if (onInputtedGeneric(opened_file_str.items)) |opened_file| {
            tryOpen(self, opened_file, true) catch |err| {
                self.setState(.command);
                self.setCmdData(&new_cmd_data);
                try self.getCmdData().replacePromptOverlayFmt(self, PROMPT_ERR_OPEN_FILE, .{err});
                return true;
            };
            if (self.getState() != .text) {
                self.setState(.text);
            }
            self.needs_redraw = true;
            return false;
        } else |err| {
            self.setState(.command);
            self.setCmdData(&new_cmd_data);
            try self.getCmdData().replacePromptOverlayFmt(self, PROMPT_ERR_OPEN_FILE, .{err});
            return true;
        }
    } else {
        const new_cmd_data: editor.CommandData = .{
            .prompt = PROMPT_OPEN,
            .fns = Fns,
        };
        if (self.conf.use_file_opener) |use_file_opener| {
            runFileOpener(self, use_file_opener, .open) catch |err| {
                self.setState(.command);
                self.setCmdData(&new_cmd_data);
                try self.getCmdData().replacePromptOverlayFmt(self, PROMPT_ERR_SPAWN_FM, .{err});
                return true;
            };
            if (self.getState() != .text) {
                self.setState(.text);
            }
            self.needs_redraw = true;
            return false;
        }
        self.setState(.command);
        self.setCmdData(&new_cmd_data);
    }
    return true;
}

pub fn setupTryToSave(self: *editor.Editor, is_new_loc: bool) !bool {
    const prompt = if (is_new_loc) PROMPT_SAVE_NEW else PROMPT_SAVE;

    const new_cmd_data: editor.CommandData = .{
        .prompt = prompt,
        .fns = FnsTryToSave,
    };
    if (self.conf.use_file_opener) |use_file_opener| {
        runFileOpener(self, use_file_opener, .save) catch |err| {
            self.setState(.command);
            self.setCmdData(&new_cmd_data);
            try self.getCmdData().replacePromptOverlayFmt(self, PROMPT_ERR_SPAWN_FM, .{err});
            return true;
        };
        if (self.getState() != .text) {
            self.setState(.text);
        }
        self.needs_redraw = true;
        return false;
    }
    self.setState(.command);
    self.setCmdData(&new_cmd_data);
    return true;
}
