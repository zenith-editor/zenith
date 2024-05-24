//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//

pub fn Error(comptime T: type, comptime E: type) type {
  return union(enum) {
    const Self = @This();
    
    ok: T,
    err: E,
    
    pub fn isErr(self: *const Self) bool {
      return switch(self.*) {
        .err => true,
        else => false,
      };
    }
  };
}