//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const Cmd = @This();

const std = @import("std");
const builtin = @import("builtin");

const str = @import("../str.zig");
const text = @import("../text.zig");
const editor = @import("../editor.zig");
const sig = @import("../platform/sig.zig");
const pty = @import("../platform/pty.zig");

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
        self.text_handler.open(self, opened_file, true) catch |err| {
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
        self.text_handler.open(self, opened_file, false) catch |err| {
            try self.getCmdData().replacePromptOverlayFmt(self, PROMPT_ERR_SAVE_FILE, .{err});
            return;
        };
        self.text_handler.save(self) catch |err| {
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
    .onInputted = Cmd.onInputted,
};

pub const FnsTryToSave: editor.CommandData.FnTable = .{
    .onInputted = Cmd.onInputtedTryToSave,
};

fn runFileOpener(self: *editor.Editor, file_opener: []const []const u8, action: enum { open, save }) !void {
    try self.restoreTerminal();
    try self.enableRawModeForSpawnedApplications();
    defer {
        self.setupTerminal() catch {};
    }

    // force raw mode for termios
    var wsz: std.posix.winsize = undefined;
    {
        const rc = std.os.linux.ioctl(self.in.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&wsz));
        if (std.posix.errno(rc) != .SUCCESS) {
            return std.posix.unexpectedErrno(std.posix.errno(rc));
        }
    }
    const termios = try std.posix.tcgetattr(self.in.handle);
    var pty_res = try pty.open(termios, &wsz);
    defer pty_res.close();
    const pty_writer = pty_res.master.writer();

    // setup process

    const old_stdin = try std.posix.dup(std.posix.STDIN_FILENO);
    const old_stderr = try std.posix.dup(std.posix.STDERR_FILENO);
    try std.posix.dup2(pty_res.slave.handle, std.posix.STDIN_FILENO);
    try std.posix.dup2(pty_res.slave.handle, std.posix.STDERR_FILENO);

    var child = std.process.Child.init(file_opener, self.allocr);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    sig.sigchld_triggered = false;
    try child.spawn();
    try std.posix.dup2(old_stdin, std.posix.STDIN_FILENO);
    try std.posix.dup2(old_stderr, std.posix.STDERR_FILENO);

    // poll

    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = self.in.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
        .{
            .fd = child.stdout.?.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
        .{
            .fd = pty_res.master.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    var stdout_pipe = std.fifo.LinearFifo(u8, .Dynamic).init(self.allocr);
    defer stdout_pipe.deinit();
    var is_termios_setup = false;

    while (!sig.sigchld_triggered) {
        const poll_res = std.posix.poll(&poll_fds, editor.Editor.REFRESH_RATE_MS) catch {
            break;
        };

        if (sig.resized) {
            const rc = std.os.linux.ioctl(self.in.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&wsz));
            if (std.posix.errno(rc) == .SUCCESS) {
                const res = std.os.linux.ioctl(pty_res.slave.handle, std.os.linux.T.IOCSWINSZ, @intFromPtr(&wsz));
                if (std.posix.errno(res) != .SUCCESS) {
                    return std.posix.unexpectedErrno(std.posix.errno(res));
                }
            }
            try std.posix.kill(child.id, std.posix.SIG.WINCH);
            sig.resized = false;
        }

        if (poll_res == 0) {
            continue;
        }

        const bump_amt = 512;

        // stdin
        {
            const poll_fd = &poll_fds[0];
            if (poll_fd.revents & std.posix.POLL.IN != 0) {
                var buf: [bump_amt]u8 = undefined;
                const amt = try std.posix.read(poll_fd.fd, &buf);
                if (amt == 0) {
                    break;
                }
                try pty_writer.writeAll(buf[0..amt]);
            }
        }

        // stdout
        {
            const poll_fd = &poll_fds[1];
            if (poll_fd.revents & std.posix.POLL.IN != 0) {
                const buf = try stdout_pipe.writableWithSize(bump_amt);
                const amt = try std.posix.read(poll_fd.fd, buf);
                if (amt == 0) {
                    break;
                }
                stdout_pipe.update(amt);
            }
        }

        // stderr
        {
            const poll_fd = &poll_fds[2];
            if (poll_fd.revents & std.posix.POLL.IN != 0) {
                var buf: [bump_amt]u8 = undefined;
                const amt = try std.posix.read(poll_fd.fd, &buf);
                if (amt == 0) {
                    break;
                }
                try self.writeAll(buf[0..amt]);
                if (!is_termios_setup) {
                    // termios
                    const c_termios = try std.posix.tcgetattr(pty_res.master.handle);
                    try std.posix.tcsetattr(self.in.handle, std.posix.TCSA.FLUSH, c_termios);
                    is_termios_setup = true;
                }
            }
        }
    }

    _ = child.wait() catch null;

    // parse the path
    var stdout: []u8 = try stdout_pipe.toOwnedSlice();
    defer self.allocr.free(stdout);

    var path = stdout;
    if (std.mem.indexOfScalar(u8, stdout, '\n')) |end| {
        path = stdout[0..end];
    }

    if (path.len == 0) {
        return error.FileNotFound;
    }

    const opened_file = try onInputtedGeneric(path);

    switch (action) {
        .open => {
            try self.text_handler.open(self, opened_file, true);
        },
        .save => {
            try self.text_handler.open(self, opened_file, false);
            try self.text_handler.save(self);
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
            self.text_handler.open(self, opened_file, true) catch |err| {
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
