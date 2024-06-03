//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");
const build_config = @import("build_config");

const str = @import("./str.zig");
const sig = @import("./platform/sig.zig");
const editor = @import("./editor.zig");

const ArgAction = enum {
    none,
    exit,
    err,
};

const ProgramArgs = struct {
    args: std.process.ArgIterator,
    program_name: []const u8,
    writer: std.fs.File.Writer,

    opt_opened_file: ?[]const u8 = null,
    opt_config_dir: ?[]const u8 = null,

    fn showHelp(self: *ProgramArgs) !ArgAction {
        try self.writer.print(
            \\Usage: {s} [options] [file]
            \\
            \\Options:
            \\  -h/--help: Show this help message
            \\  --version: Show version
            \\  -c/--config [config_dir]: Set configuration directory
            \\
        , .{self.program_name});
        return .exit;
    }

    fn showVersion(self: *ProgramArgs) !ArgAction {
        try self.writer.print(
            \\{s}
            \\
        , .{build_config.version});
        return .exit;
    }

    fn setConfigDir(self: *ProgramArgs) !ArgAction {
        if (self.args.next()) |arg| {
            self.opt_config_dir = arg;
            return .none;
        } else {
            try self.writer.writeAll("Error: config directory not specified");
            _ = try self.showHelp();
            return .err;
        }
    }
};

const Arg = struct {
    /// Short option, starts with `-`
    o: ?[]const u8 = null,
    /// Long option, starts with `--`
    l: []const u8,
    func: *const fn (self: *ProgramArgs) anyerror!ArgAction,

    fn match(self: *const Arg, arg: []const u8) bool {
        if (self.o) |o| {
            if (std.mem.eql(u8, arg, o)) {
                return true;
            }
        }
        if (std.mem.eql(u8, arg, self.l)) {
            return true;
        }
        return false;
    }
};

const ARGS = [_]Arg{
    .{ .o = "-h", .l = "--help", .func = ProgramArgs.showHelp },
    .{ .l = "--version", .func = ProgramArgs.showVersion },
    .{ .o = "-c", .l = "--config", .func = ProgramArgs.setConfigDir },
};

pub fn main() !void {
    // arguments
    var prog_args: ProgramArgs = blk: {
        var args = std.process.args();
        var prog_args_ret: ProgramArgs = .{
            .args = undefined,
            .program_name = args.next() orelse @panic("args.next returned null"),
            .writer = std.io.getStdOut().writer(),
        };
        prog_args_ret.args = args;
        break :blk prog_args_ret;
    };
    {
        var parsing_args = true;
        parse_arguments: while (prog_args.args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--")) {
                parsing_args = false;
                continue :parse_arguments;
            }
            if (parsing_args and std.mem.startsWith(u8, arg, "-")) {
                inline for (ARGS) |pargs| {
                    if (pargs.match(arg)) {
                        switch (try pargs.func(&prog_args)) {
                            .none => {},
                            .exit => {
                                return;
                            },
                            .err => {
                                std.process.exit(1);
                                return;
                            },
                        }
                        continue :parse_arguments;
                    }
                }
                parsing_args = false;
            }

            if (prog_args.opt_opened_file == null) {
                prog_args.opt_opened_file = arg;
            }
            parsing_args = false;
        }
    }

    sig.registerSignals();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocr = gpa.allocator();

    var E = try editor.Editor.create(allocr);

    if (prog_args.opt_config_dir) |config_dir| {
        const cwd = std.fs.cwd();
        E.conf.config_dir = cwd.openDir(config_dir, .{}) catch |err| blk: {
            try E.outw.print("Error: failed to open config directory ({})", .{err});
            try E.errorPromptBeforeLoaded();
            break :blk null;
        };
    }
    try E.loadConfig();

    errdefer E.restoreTerminal() catch {};

    if (prog_args.opt_opened_file) |opened_file| {
        var opened_file_str: str.StringUnmanaged = .{};
        try opened_file_str.appendSlice(E.allocr, opened_file);
        try E.openAtStart(opened_file_str);
    }

    try E.run();
}
