//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");

pub const StringUnmanaged = std.ArrayListUnmanaged(u8);
pub const String = std.ArrayList(u8);

pub const MaybeOwnedSlice = union(enum) {
    owned: []u8,
    static: []const u8,

    pub fn isOwned(self: *const MaybeOwnedSlice) bool {
        return switch (self.*) {
            .owned => true,
            .static => false,
        };
    }

    pub fn slice(self: *const MaybeOwnedSlice) []const u8 {
        switch (self.*) {
            .owned => |owned| {
                return owned;
            },
            .static => |static| {
                return static;
            },
        }
    }

    pub fn deinit(self: *MaybeOwnedSlice, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .owned => |owned| {
                allocator.free(owned);
            },
            else => {},
        }
    }
};
