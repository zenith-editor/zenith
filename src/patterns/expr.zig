//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//

// This file implements a virtual machine used to execute regular expressions
// as described in the following article:
//
//   https://swtch.com/~rsc/regexp/regexp2.html
//
// The virtual machine is a simple backtracking-based implementation, with a
// few optimizations to help reduce memory usage:
//
//   * Threads are stored in a run-length encoded stack, to handle the simple
//     repetitions.
//   * The thread stack can either be stored on the hardware stack, or the heap
//     depending on the number of threads being ran.

const Expr = @This();

const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config");

const Instr = @import("./instr.zig").Instr;
const Parser = @import("./parser.zig");

pub const CreateErrorType = error{
    EmptyRegex,
    OutOfMemory,
    InvalidUtf8,
    ExpectedSimpleExpr,
    ExpectedEscapeBeforeDashInRange,
    UnbalancedGroupBrackets,
    ExpectedEscapeChar,
};

pub const CreateError = struct {
    type: CreateErrorType,
    pos: usize,
};

pub const CreateResult = union(enum) {
    ok: Expr,
    err: CreateError,

    pub fn asErr(self: CreateResult) !Expr {
        switch (self) {
            .ok => |expr| {
                return expr;
            },
            .err => |err| {
                return err.type;
            },
        }
    }
};

instrs: std.ArrayListUnmanaged(Instr),
flags: Flags,
num_groups: usize,

pub fn debugPrint(self: *const Expr) void {
    for (0..self.instrs.items.len) |i| {
        std.debug.print("{} {}\n", .{ i, self.instrs.items[i] });
    }
}

pub fn deinit(self: *Expr, allocr: std.mem.Allocator) void {
    for (self.instrs.items) |*instr| {
        instr.deinit(allocr);
    }
    self.instrs.deinit(allocr);
}

pub const Flags = struct {
    is_multiline: bool = false,

    pub fn fromShortCode(str: []const u8) error{InvalidString}!Flags {
        var flags: Flags = .{};
        for (str) |byte| {
            switch (byte) {
                'm' => {
                    flags.is_multiline = true;
                },
                else => {
                    return error.InvalidString;
                },
            }
        }
        return flags;
    }
};

pub fn create(
    allocr: std.mem.Allocator,
    in_pattern: []const u8,
    flags: *const Flags,
) CreateResult {
    if (in_pattern.len == 0) {
        return .{
            .err = .{
                .type = error.EmptyRegex,
                .pos = 0,
            },
        };
    }
    var parser: Parser = .{
        .in_pattern = in_pattern,
        .flags = flags.*,
    };
    if (parser.parse(allocr)) |expr| {
        return .{
            .ok = expr,
        };
    } else |err| {
        switch (err) {
            error.OutOfMemory => {
                return .{
                    .err = .{
                        .type = error.OutOfMemory,
                        .pos = 0,
                    },
                };
            },
            error.Utf8InvalidStartByte, error.Utf8ExpectedContinuation, error.Utf8OverlongEncoding, error.Utf8EncodesSurrogateHalf, error.Utf8CodepointTooLarge => {
                return .{
                    .err = .{
                        .type = error.InvalidUtf8,
                        .pos = parser.str_idx,
                    },
                };
            },
            error.ExpectedSimpleExpr, error.ExpectedEscapeBeforeDashInRange, error.UnbalancedGroupBrackets, error.ExpectedEscapeChar => |suberr| {
                return .{
                    .err = .{
                        .type = @errorCast(suberr),
                        .pos = parser.str_idx,
                    },
                };
            },
        }
    }
}

pub const SrcView = struct {
    const VTable = struct {
        codepointSliceAt: *const fn (ctx: *const anyopaque, pos: usize) error{InvalidUtf8}!?[]const u8,
    };
    ptr: *const anyopaque,
    inline_vtable: VTable,

    pub fn codepointSliceAt(self: *const SrcView, pos: usize) error{InvalidUtf8}!?[]const u8 {
        return self.inline_vtable.codepointSliceAt(self.ptr, pos);
    }
};

const Thread = struct {
    str_idx: usize,
    pc: usize,
    str_idx_delta: u32 = 0,
    str_idx_repeats: u32 = 0,
};

const ThreadStack = std.ArrayList(Thread);

const VM = struct {
    view: SrcView,
    instrs: []const Instr,
    flags: Flags,
    options: *const MatchOptions,
    arena: std.heap.ArenaAllocator,
    fully_matched: bool = false,

    fn deinit(self: *VM) void {
        self.arena.deinit();
    }

    fn allocr(self: *VM) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn nextInstr(self: *VM, thread: *const Thread, thread_stack: *ThreadStack) error{ InvalidUtf8, OutOfMemory }!void {
        if (comptime build_config.dbg_patterns_vm) {
            std.debug.print("{s}\n", .{self.haystack[thread.str_idx..]});
            std.debug.print(">>> {} {}\n", .{ thread.pc, self.instrs[thread.pc] });
            std.debug.print("{any}\n", .{thread_stack.items});
        }
        switch (self.instrs[thread.pc]) {
            .abort => {
                @panic("abort opcode reached");
            },
            .matched => {
                self.fully_matched = true;
                return;
            },
            .any, .char, .char_inverse, .range_opt, .range, .range_inverse => {
                const bytes = try self.view.codepointSliceAt(thread.str_idx) orelse {
                    return;
                };
                // utf8Decode is not automatically inlined in x86-64
                const char: u32 = @call(.always_inline, std.unicode.utf8Decode, .{bytes}) catch {
                    return error.InvalidUtf8;
                };
                if (!self.flags.is_multiline and char == '\n') {
                    return;
                }
                switch (self.instrs[thread.pc]) {
                    .any => {},
                    .char => |char1| {
                        if (char != char1) {
                            return;
                        }
                    },
                    .char_inverse => |char1| {
                        if (char == char1) {
                            return;
                        }
                    },
                    .range_opt => |range_opt| {
                        const matches = range_opt.from <= char and range_opt.to >= char;
                        if (matches == range_opt.inverse) {
                            return;
                        }
                    },
                    .range => |ranges| {
                        var matches = false;
                        for (ranges) |range| {
                            if (range.from <= char and range.to >= char) {
                                matches = true;
                                break;
                            }
                        }
                        if (!matches) {
                            return;
                        }
                    },
                    .range_inverse => |ranges| {
                        for (ranges) |range| {
                            if (range.from <= char and range.to >= char) {
                                return;
                            }
                        }
                    },
                    else => unreachable,
                }
                try VM.addThread(thread_stack, thread.str_idx + bytes.len, thread.pc + 1);
                return;
            },
            .string => {
                // string is only here for optimizing find calls
                @panic("should be handled in exec");
            },
            .jmp => |target| {
                try VM.addThread(thread_stack, thread.str_idx, target);
                return;
            },
            .split => |split| {
                try VM.addThread(thread_stack, thread.str_idx, split.a);
                try VM.addThread(thread_stack, thread.str_idx, split.b);
                return;
            },
            .group_start => |group_id| {
                if (self.options.group_out) |group_out| {
                    group_out[group_id].start = thread.str_idx;
                }
                try VM.addThread(thread_stack, thread.str_idx, thread.pc + 1);
                return;
            },
            .group_end => |group_id| {
                if (self.options.group_out) |group_out| {
                    group_out[group_id].end = thread.str_idx;
                }
                try VM.addThread(thread_stack, thread.str_idx, thread.pc + 1);
                return;
            },
            .anchor_start => {
                if (thread.str_idx == self.options.anchor_start_offset) {
                    try VM.addThread(thread_stack, thread.str_idx, thread.pc + 1);
                    return;
                }
            },
            .anchor_end => {
                const bytes = try self.view.codepointSliceAt(thread.str_idx);
                if (bytes == null) {
                    try VM.addThread(thread_stack, thread.str_idx, thread.pc + 1);
                    return;
                }
                if (self.flags.is_multiline and bytes.?[0] == '\n') {
                    try VM.addThread(thread_stack, thread.str_idx, thread.pc + 1);
                    return;
                }
            },
        }
    }

    fn topThread(thread_stack: *ThreadStack) ?*Thread {
        if (thread_stack.items.len > 0) {
            return &thread_stack.items[thread_stack.items.len - 1];
        }
        return null;
    }

    fn addThread(thread_stack: *ThreadStack, str_idx: usize, pc: usize) !void {
        if (VM.topThread(thread_stack)) |top| {
            // run length encode the thread stack so that less memory is used
            // when greedy matching repetitive groups of characters
            if (top.pc == pc) {
                if (top.str_idx_delta == 0) {
                    top.str_idx_delta = @intCast(str_idx - top.str_idx);
                    top.str_idx_repeats = 1;
                    return;
                } else if (str_idx > top.str_idx and
                    (top.str_idx + top.str_idx_delta * top.str_idx_repeats) == str_idx)
                {
                    top.str_idx_repeats += 1;
                    return;
                }
            }
        }
        try thread_stack.append(.{
            .str_idx = str_idx,
            .pc = pc,
        });
    }

    fn popThread(thread_stack: *ThreadStack) !Thread {
        if (VM.topThread(thread_stack).?.str_idx_delta == 0) {
            return thread_stack.pop();
        }
        const top: *Thread = VM.topThread(thread_stack).?;
        var ret_thread: Thread = top.*;
        ret_thread.str_idx = top.str_idx + top.str_idx_delta * top.str_idx_repeats;
        if (top.str_idx_repeats > 0) {
            top.str_idx_repeats -= 1;
        } else {
            _ = thread_stack.pop();
        }
        return ret_thread;
    }

    fn exec(self: *VM, init_offset: usize) !MatchResult {
        var thread_stack_allocr = std.heap.stackFallback(512, self.arena.allocator());
        var thread_stack = ThreadStack.init(thread_stack_allocr.get());

        if (self.instrs[0].getString()) |string| {
            var iter = std.unicode.Utf8View.initUnchecked(string).iterator();
            var str_idx: usize = init_offset;
            while (iter.nextCodepointSlice()) |bytes| {
                if (try self.view.codepointSliceAt(str_idx)) |source_bytes| {
                    if (std.mem.eql(u8, bytes, source_bytes)) {
                        str_idx += bytes.len;
                        continue;
                    }
                }
                return .{ .pos = str_idx, .fully_matched = false };
            }
            try thread_stack.append(.{
                .str_idx = str_idx,
                .pc = 1,
            });
        } else {
            try thread_stack.append(.{
                .str_idx = init_offset,
                .pc = 0,
            });
        }

        while (true) {
            const thread: Thread = try VM.popThread(&thread_stack);
            try self.nextInstr(&thread, &thread_stack);
            if (thread_stack.items.len == 0 or self.fully_matched) {
                return .{
                    .pos = thread.str_idx,
                    .fully_matched = self.fully_matched,
                };
            }
            if (comptime build_config.dbg_patterns_vm) {
                _ = std.io.getStdIn().reader().readByte() catch {};
            }
        }
    }

    fn execAndReset(self: *VM, init_offset: usize) !MatchResult {
        defer {
            _ = self.arena.reset(.retain_capacity);
            self.fully_matched = false;
        }
        return self.exec(init_offset);
    }
};

pub const MatchResult = struct {
    pos: usize,
    fully_matched: bool,
};

pub const MatchGroup = struct {
    start: usize = 0,
    end: usize = 0,
};

pub const MatchOptions = struct {
    group_out: ?[]MatchGroup = null,
    match_from: usize = 0,
    anchor_start_offset: usize = 0,
};

pub const MatchError = error{
    OutOfMemory,
    InvalidGroupSize,
    InvalidUtf8,
};

pub fn checkMatchGeneric(
    self: *const Expr,
    view: *const SrcView,
    options: *const MatchOptions,
) MatchError!MatchResult {
    if (options.group_out) |group_out| {
        if (group_out.len != self.num_groups) {
            return error.InvalidGroupSize;
        }
    }
    var vm: VM = .{
        .view = view.*,
        .instrs = self.instrs.items,
        .flags = self.flags,
        .options = options,
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };
    defer vm.deinit();
    return vm.exec(options.match_from);
}

pub const StringView = struct {
    source: []const u8,

    fn codepointSliceAt(ctx: *const anyopaque, pos: usize) error{InvalidUtf8}!?[]const u8 {
        const self: *const StringView = @ptrCast(@alignCast(ctx));
        if (pos >= self.source.len) {
            return null;
        }
        const seqlen = std.unicode.utf8ByteSequenceLength(self.source[pos]) catch {
            return error.InvalidUtf8;
        };
        if ((pos + seqlen) > self.source.len) {
            return error.InvalidUtf8;
        }
        return self.source[pos .. pos + seqlen];
    }

    pub fn srcView(self: *StringView) SrcView {
        return .{
            .ptr = @ptrCast(self),
            .inline_vtable = .{
                .codepointSliceAt = StringView.codepointSliceAt,
            },
        };
    }
};

pub fn checkMatch(
    self: *const Expr,
    haystack: []const u8,
    options: *const MatchOptions,
) MatchError!MatchResult {
    var view: StringView = .{
        .source = haystack,
    };
    return self.checkMatchGeneric(&.{
        .ptr = @ptrCast(&view),
        .inline_vtable = .{
            .codepointSliceAt = StringView.codepointSliceAt,
        },
    }, options);
}

pub const FindResult = struct {
    start: usize,
    end: usize,
};

pub fn find(self: *const Expr, haystack: []const u8) !?FindResult {
    var view: StringView = .{
        .source = haystack,
    };
    var vm: VM = .{
        .view = view.srcView(),
        .instrs = self.instrs.items,
        .flags = self.flags,
        .options = &.{},
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };
    defer vm.deinit();

    if (self.instrs.items[0].getString()) |string| {
        var skip: usize = 0;
        while (std.mem.indexOf(u8, haystack[skip..], string)) |rel_skip| {
            skip += rel_skip;
            const match = try vm.execAndReset(skip);
            if (match.fully_matched) {
                return .{
                    .start = skip,
                    .end = match.pos,
                };
            }
            skip += string.len;
        }
        return null;
    }

    for (0..haystack.len - 1) |skip| {
        const match = try vm.execAndReset(skip);
        if (match.fully_matched) {
            return .{
                .start = skip,
                .end = match.pos,
            };
        }
    }
    return null;
}

pub fn findBackwards(self: *const Expr, haystack: []const u8) !?FindResult {
    var view: StringView = .{
        .source = haystack,
    };
    var vm: VM = .{
        .view = view.srcView(),
        .instrs = self.instrs.items,
        .flags = self.flags,
        .options = &.{},
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };
    defer vm.deinit();

    if (self.instrs.items[0].getString()) |string| {
        var limit: usize = haystack.len;
        while (std.mem.lastIndexOf(u8, haystack[0..limit], string)) |rel_limit| {
            limit = rel_limit;
            const match = try vm.execAndReset(limit);
            if (match.fully_matched) {
                return .{
                    .start = rel_limit,
                    .end = match.pos,
                };
            }
            limit -= 1;
        }
        return null;
    }

    var skip: usize = haystack.len;
    while (skip > 0) {
        skip -= 1;
        const match = try vm.execAndReset(skip);
        if (match.fully_matched) {
            return .{
                .start = skip,
                .end = match.pos,
            };
        }
    }
    return null;
}
