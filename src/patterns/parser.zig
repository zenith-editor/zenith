//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const Self = @This();

const std = @import("std");
const optimizer = @import("./optimizer.zig");
const Expr = @import("./expr.zig");
const Instr = @import("./instr.zig").Instr;

in_pattern: []const u8,
str_idx: usize = 0,
flags: Expr.Flags,

const QualifierCodegenInfo = struct {
    expr_shift: usize,
};

fn genQualifier(
    allocator: std.mem.Allocator,
    char: u32,
    expr: *Expr,
    L0: usize,
) !QualifierCodegenInfo {
    switch (char) {
        '+' => {
            // (L0)    L0: <char>
            // (len+0) split L2, L0
            // (len+1) L2: ...
            const L2 = expr.instrs.items.len + 1;
            try expr.instrs.append(allocator, .{
                // order of a and b matters here,
                // having L0 execute first means that '+' performs a greedy match
                .split = .{
                    .a = L2,
                    .b = L0,
                },
            });
            return .{
                .expr_shift = 0,
            };
        },
        '*' => {
            // (L0)    L0: split L2, L1
            // (L0+1)  L1: <char>
            // len+0 accounts for new L0
            // (len+1) jmp L0
            // (len+2) L2: ...
            const L1 = L0 + 1;
            const L2 = expr.instrs.items.len + 2;
            for (expr.instrs.items) |*instr| {
                instr.incrPc(1, L0);
            }
            try expr.instrs.insert(allocator, L0, .{
                // again, greedy match
                .split = .{
                    .a = L2,
                    .b = L1,
                },
            });
            try expr.instrs.append(allocator, .{
                .jmp = L0,
            });
            return .{
                .expr_shift = 1,
            };
        },
        '-' => {
            // (L0)    L0: split L1, L2
            // (L0+1)  L1: <char>
            // len+0 accounts for new L0
            // (len+1) jmp L0
            // (len+2) L2: ...
            const L1 = L0 + 1;
            const L2 = expr.instrs.items.len + 2;
            for (expr.instrs.items) |*instr| {
                instr.incrPc(1, L0);
            }
            try expr.instrs.insert(allocator, L0, .{
                .split = .{
                    .a = L1,
                    .b = L2,
                },
            });
            try expr.instrs.append(allocator, .{
                .jmp = L0,
            });
            return .{
                .expr_shift = 1,
            };
        },
        '?' => {
            // (L0)    L0: split L2, L1
            // (L0+1)  L1: <char>
            // len+0 accounts for new L0
            // (len+1) L2: ...
            const L1 = L0 + 1;
            const L2 = expr.instrs.items.len + 1;
            for (expr.instrs.items) |*instr| {
                instr.incrPc(1, L0);
            }
            try expr.instrs.insert(allocator, L0, .{
                .split = .{
                    .a = L2,
                    .b = L1,
                },
            });
            return .{
                .expr_shift = 1,
            };
        },
        else => @panic("Unknown qualifier"),
    }
}

const GroupOrRoot = struct {
    instr_start: usize,
    group_id: ?usize,
};

const ParseEscapeResult = struct {
    char: u32,
    seqlen: u3,
};

fn parseEscapeChar(self: *Self) !ParseEscapeResult {
    if (self.str_idx >= self.in_pattern.len) {
        return error.ExpectedEscapeChar;
    }

    const seqlen = try std.unicode.utf8ByteSequenceLength(self.in_pattern[self.str_idx]);
    if ((self.in_pattern.len - self.str_idx) < seqlen) {
        return error.Utf8ExpectedContinuation;
    }
    const char: u32 = try std.unicode.utf8Decode(self.in_pattern[self.str_idx..(self.str_idx + seqlen)]);

    var esc_char: u32 = undefined;
    switch (char) {
        '\\' => {
            esc_char = '\\';
        },
        'b' => {
            esc_char = 0x08;
        }, // backspace
        'f' => {
            esc_char = 0x0C;
        }, // form feed
        'n' => {
            esc_char = 0x0A;
        },
        'r' => {
            esc_char = 0x0D;
        },
        't' => {
            esc_char = 0x09;
        }, // horiz. tab
        else => {
            esc_char = char;
        },
    }
    return .{
        .char = esc_char,
        .seqlen = seqlen,
    };
}

fn parseGroup(
    self: *Self,
    allocator: std.mem.Allocator,
    expr: *Expr,
    parse_stack: *std.ArrayListUnmanaged(GroupOrRoot),
) !void {
    var jmp_to_end_targets: std.ArrayListUnmanaged(usize) = .{};
    defer jmp_to_end_targets.deinit(allocator);

    const group_or_root: GroupOrRoot = parse_stack.items[parse_stack.items.len - 1];

    var is_last_simple_matcher: bool = false;

    outer: while (self.str_idx < self.in_pattern.len) {
        const seqlen = try std.unicode.utf8ByteSequenceLength(self.in_pattern[self.str_idx]);
        if ((self.in_pattern.len - self.str_idx) < seqlen) {
            return error.Utf8ExpectedContinuation;
        }
        const char: u32 = try std.unicode.utf8Decode(self.in_pattern[self.str_idx..(self.str_idx + seqlen)]);

        switch (char) {
            '+', '-', '*', '?' => |qualifier| {
                if (is_last_simple_matcher) {
                    const L0 = expr.instrs.items.len - 1;
                    _ = try genQualifier(allocator, qualifier, expr, L0);
                    is_last_simple_matcher = false;
                } else {
                    return error.ExpectedSimpleExpr;
                }
            },
            '[' => {
                self.str_idx += seqlen;

                const ParseState = enum {
                    normal,
                    specify_to,
                };

                var from: ?u32 = null;
                var state: ParseState = .normal;
                var range_inverse = false;
                var ranges: std.ArrayListUnmanaged(Instr.Range) = .{};

                if (self.str_idx < self.in_pattern.len and self.in_pattern[self.str_idx] == '^') {
                    range_inverse = true;
                    self.str_idx += 1;
                }

                inner: while (self.str_idx < self.in_pattern.len) {
                    var range_seqlen = try std.unicode.utf8ByteSequenceLength(self.in_pattern[self.str_idx]);
                    if ((self.in_pattern.len - self.str_idx) < range_seqlen) {
                        return error.Utf8ExpectedContinuation;
                    }
                    var range_char: u32 = try std.unicode.utf8Decode(self.in_pattern[self.str_idx..(self.str_idx + range_seqlen)]);

                    switch (range_char) {
                        '-' => {
                            if (from == null or state == .specify_to) {
                                return error.ExpectedEscapeBeforeDashInRange;
                            }
                            self.str_idx += range_seqlen;
                            state = .specify_to;
                            continue :inner;
                        },
                        ']' => {
                            self.str_idx += range_seqlen;
                            break :inner;
                        },
                        '\\' => {
                            self.str_idx += range_seqlen;
                            const res = try self.parseEscapeChar();
                            range_char = res.char;
                            range_seqlen = res.seqlen;
                        },
                        else => {},
                    }

                    if (state == .specify_to) {
                        self.str_idx += range_seqlen;
                        try ranges.append(allocator, .{
                            .from = from.?,
                            .to = range_char,
                        });
                        from = null;
                        state = .normal;
                        continue :inner;
                    }

                    self.str_idx += range_seqlen;
                    if (from == null) {
                        from = range_char;
                    } else {
                        try ranges.append(allocator, .{
                            .from = from.?,
                            .to = from.?,
                        });
                        from = range_char;
                    }
                }

                if (from != null) {
                    try ranges.append(allocator, .{
                        .from = from.?,
                        .to = from.?,
                    });
                }

                is_last_simple_matcher = true;

                if (range_inverse) {
                    if (ranges.items.len == 1 and ranges.items[0].from == ranges.items[0].to) {
                        try expr.instrs.append(allocator, .{
                            .char_inverse = ranges.items[0].from,
                        });
                        ranges.deinit(allocator);
                        ranges = undefined;
                    } else if (ranges.items.len == 1) {
                        try expr.instrs.append(allocator, .{
                            .range_opt = .{
                                .from = ranges.items[0].from,
                                .to = ranges.items[0].to,
                                .inverse = true,
                            },
                        });
                        ranges.deinit(allocator);
                        ranges = undefined;
                    } else {
                        try expr.instrs.append(allocator, .{
                            .range_inverse = try ranges.toOwnedSlice(allocator),
                        });
                    }
                } else {
                    if (ranges.items.len == 1 and ranges.items[0].from == ranges.items[0].to) {
                        try expr.instrs.append(allocator, .{
                            .char = ranges.items[0].from,
                        });
                        ranges.deinit(allocator);
                        ranges = undefined;
                    } else if (ranges.items.len == 1) {
                        try expr.instrs.append(allocator, .{
                            .range_opt = .{
                                .from = ranges.items[0].from,
                                .to = ranges.items[0].to,
                                .inverse = false,
                            },
                        });
                        ranges.deinit(allocator);
                        ranges = undefined;
                    } else {
                        try expr.instrs.append(allocator, .{
                            .range = try ranges.toOwnedSlice(allocator),
                        });
                    }
                }
                continue :outer;
            },
            '(' => {
                is_last_simple_matcher = false;

                self.str_idx += 1;

                const group_id = expr.num_groups;
                expr.num_groups += 1;

                try expr.instrs.append(allocator, .{
                    .group_start = group_id,
                });

                try parse_stack.append(allocator, .{
                    .instr_start = expr.instrs.items.len,
                    .group_id = group_id,
                });

                return;
            },
            ')' => {
                is_last_simple_matcher = false;

                self.str_idx += 1;
                if (group_or_root.group_id == null) {
                    return error.UnbalancedGroupBrackets;
                }

                _ = parse_stack.pop();

                const group_end_instr = expr.instrs.items.len;
                try expr.instrs.append(allocator, .{
                    .group_end = group_or_root.group_id.?,
                });

                if (self.str_idx < self.in_pattern.len) {
                    switch (self.in_pattern[self.str_idx]) {
                        '+', '-', '*', '?' => |qualifier| {
                            self.str_idx += 1;

                            const L0 = group_or_root.instr_start;
                            const cg = try genQualifier(allocator, qualifier, expr, L0);

                            for (jmp_to_end_targets.items) |jmp_instr| {
                                switch (expr.instrs.items[jmp_instr + cg.expr_shift]) {
                                    .abort => {},
                                    else => @panic("not abort"),
                                }
                                expr.instrs.items[jmp_instr + cg.expr_shift] = .{
                                    .jmp = group_end_instr + cg.expr_shift,
                                };
                            }

                            return;
                        },
                        else => {},
                    }
                }

                for (jmp_to_end_targets.items) |jmp_instr| {
                    switch (expr.instrs.items[jmp_instr]) {
                        .abort => {},
                        else => @panic("not abort"),
                    }
                    expr.instrs.items[jmp_instr] = .{
                        .jmp = group_end_instr,
                    };
                }

                return;
            },
            '|' => {
                is_last_simple_matcher = false;
                // (L0)    split L1, L2
                // (L0+1)  L1: ...
                // len+0 accounts for new L0
                // (len+1) jmp L3
                // (len+2) L2: ...
                const L0 = group_or_root.instr_start;
                const L1 = L0 + 1;
                const L2 = expr.instrs.items.len + 2;
                for (expr.instrs.items) |*instr| {
                    instr.incrPc(1, L0);
                }
                try expr.instrs.insert(allocator, L0, .{
                    .split = .{
                        .a = L1,
                        .b = L2,
                    },
                });
                if (group_or_root.group_id != null) {
                    const jmp_instr = expr.instrs.items.len;
                    try expr.instrs.append(allocator, .{
                        .abort = {},
                    });
                    try jmp_to_end_targets.append(allocator, jmp_instr);
                } else {
                    try expr.instrs.append(allocator, .{
                        .matched = {},
                    });
                }
            },
            '\\' => {
                self.str_idx += seqlen;
                const res = try self.parseEscapeChar();
                try expr.instrs.append(allocator, .{
                    .char = res.char,
                });
                self.str_idx += res.seqlen;
                continue :outer;
            },
            '.' => {
                is_last_simple_matcher = true;
                try expr.instrs.append(allocator, .{
                    .any = {},
                });
            },
            '^' => {
                is_last_simple_matcher = false;
                try expr.instrs.append(allocator, .{
                    .anchor_start = {},
                });
            },
            '$' => {
                is_last_simple_matcher = false;
                try expr.instrs.append(allocator, .{
                    .anchor_end = {},
                });
            },
            else => {
                is_last_simple_matcher = true;
                try expr.instrs.append(allocator, .{
                    .char = char,
                });
            },
        }
        self.str_idx += seqlen;
    }
}

pub fn parse(
    self: *Self,
    allocator: std.mem.Allocator,
) !Expr {
    var expr: Expr = .{
        .instrs = .{},
        .num_groups = 0,
        .flags = self.flags,
    };

    var parse_stack: std.ArrayListUnmanaged(GroupOrRoot) = .{};
    defer parse_stack.deinit(allocator);
    try parse_stack.append(allocator, .{
        .instr_start = 0,
        .group_id = null,
    });
    while (self.str_idx < self.in_pattern.len) {
        try self.parseGroup(allocator, &expr, &parse_stack);
    }
    if (parse_stack.items.len != 1) {
        return error.UnbalancedGroupBrackets;
    }

    try expr.instrs.append(allocator, .{
        .matched = {},
    });
    try optimizer.optimizePrefixString(&expr, allocator);
    return expr;
}
