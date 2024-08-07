//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");
const builtin = @import("builtin");

pub const Keysym = struct {
    pub const Mouse = struct {
        x: u32,
        y: u32,
        is_release: bool,
    };

    pub const Key = union(enum) {
        normal: u8,
        multibyte: [4]u8,
        // special keys
        up,
        down,
        left,
        right,
        home,
        end,
        del,
        pgup,
        pgdown,
        paste_begin,
        paste_end,
        scroll_up,
        scroll_down,
        mouse: Mouse,
    };

    raw: u8,
    key: Key,
    ctrl_key: bool = false,

    pub const ESC: u8 = std.ascii.control_code.esc;
    pub const BACKSPACE: u8 = std.ascii.control_code.del;
    pub const NEWLINE: u8 = std.ascii.control_code.cr;
    pub const TAB: u8 = std.ascii.control_code.ht;

    pub fn init(raw: u8) Keysym {
        if (raw < std.ascii.control_code.us and raw != ESC) {
            return Keysym{
                .raw = raw,
                .key = .{
                    .normal = (raw | 0b1100000),
                },
                .ctrl_key = true,
            };
        } else {
            return Keysym{
                .raw = raw,
                .key = .{
                    .normal = raw,
                },
            };
        }
    }

    pub fn initSpecial(comptime key: Key) Keysym {
        switch (key) {
            .normal, .multibyte => {
                @compileError("initSpecial requires special key");
            },
            else => {
                return Keysym{
                    .raw = 0,
                    .key = key,
                };
            },
        }
    }

    pub fn initMultibyte(multibyte: []const u8) Keysym {
        var multibyte_copy = [_]u8{0} ** 4;
        std.mem.copyForwards(u8, multibyte_copy[0..multibyte.len], multibyte);
        return Keysym{
            .raw = 0,
            .key = .{
                .multibyte = multibyte_copy,
            },
        };
    }

    pub fn initMouse(x: u32, y: u32, is_release: bool) Keysym {
        return Keysym{
            .raw = 0,
            .key = .{
                .mouse = .{
                    .x = x,
                    .y = y,
                    .is_release = is_release,
                },
            },
        };
    }

    pub fn isSpecial(self: *const Keysym) bool {
        if (self.ctrl_key)
            return true;
        return switch (self.key) {
            .normal, .multibyte => false,
            else => true,
        };
    }

    pub fn isMouse(self: *const Keysym) bool {
        return switch (self.key) {
            .mouse => true,
            else => false,
        };
    }

    pub fn getPrint(self: *const Keysym) ?u8 {
        switch (self.key) {
            .normal => |c| {
                if (self.ctrl_key or !std.ascii.isPrint(c)) {
                    return null;
                }
                return c;
            },
            else => {
                return null;
            },
        }
    }

    pub fn getMultibyte(self: *const Keysym) ?[]const u8 {
        return switch (self.key) {
            .multibyte => |*s| {
                if (s[1] == 0) {
                    return s[0..1];
                } else if (s[2] == 0) {
                    return s[0..2];
                } else if (s[3] == 0) {
                    return s[0..3];
                }
                return s;
            },
            else => null,
        };
    }

    pub fn isChar(self: *const Keysym, char: u8) bool {
        return switch (self.key) {
            .normal => |c| c == char,
            else => false,
        };
    }
};
