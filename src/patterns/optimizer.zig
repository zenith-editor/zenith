//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");
const Expr = @import("./expr.zig");
const Instr = @import("./instr.zig").Instr;

pub fn optimizePrefixString(self: *Expr, allocr: std.mem.Allocator) !void {
    if (self.instrs.items.len < 2) {
        return;
    }

    var last_char_found = false;
    var last_char_instr: usize = 0;

    if (!self.instrs.items[0].isChar() or !self.instrs.items[1].isChar()) {
        return;
    }

    for (self.instrs.items, 0..self.instrs.items.len) |instr, idx| {
        if (instr.isChar()) {
            if (!last_char_found) {
                last_char_instr = idx;
            }
        } else {
            last_char_found = true;
            switch (instr) {
                .split => |split| {
                    if (split.a <= last_char_instr) {
                        if (split.a <= 1) {
                            return;
                        }
                        last_char_instr = split.a - 1;
                    }
                    if (split.b <= last_char_instr) {
                        if (split.b <= 1) {
                            return;
                        }
                        last_char_instr = split.b - 1;
                    }
                },
                .jmp => |jmp| {
                    if (jmp <= last_char_instr) {
                        if (jmp == 1) {
                            return;
                        }
                        last_char_instr = jmp - 1;
                    }
                },
                else => {},
            }
        }
    }

    if (last_char_instr == 0) {
        // no need to fuse one char
        return;
    }

    var bytes: std.ArrayListUnmanaged(u8) = .{};
    errdefer bytes.deinit(allocr);

    for (0..(last_char_instr + 1)) |idx| {
        const instr = &self.instrs.items[idx];
        switch (instr.*) {
            .char => |char| {
                var char_bytes: [4]u8 = undefined;
                const n_bytes = std.unicode.utf8Encode(@intCast(char), &char_bytes) catch unreachable;
                try bytes.appendSlice(allocr, char_bytes[0..n_bytes]);
            },
            else => {
                break;
            },
        }
    }

    const removed = last_char_instr;
    self.instrs.items[0] = .{
        .string = try bytes.toOwnedSlice(allocr),
    };
    self.instrs.replaceRangeAssumeCapacity(1, removed, &[_]Instr{});
    for (self.instrs.items[1..]) |*item| {
        item.decrPc(removed, 1);
    }
}
