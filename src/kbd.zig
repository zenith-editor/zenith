//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//
const std = @import("std");
const builtin = @import("builtin");

pub const Keysym = struct {
  pub const Key = union(enum) {
    normal: u8,
    // special keys
    up,
    down,
    left,
    right,
    home,
    end,
    del,
  };
  
  raw: u8,
  key: Key,
  ctrl_key: bool = false,
  
  pub const ESC: u8 = std.ascii.control_code.esc;
  pub const BACKSPACE: u8 = std.ascii.control_code.del;
  pub const NEWLINE: u8 = std.ascii.control_code.cr;
  
  pub fn init(raw: u8) Keysym {
    if (raw < std.ascii.control_code.us) {
      return Keysym {
        .raw = raw,
        .key = .{ .normal = (raw | 0b1100000), },
        .ctrl_key = true,
      };
    } else {
      return Keysym {
        .raw = raw,
        .key = .{ .normal = raw, },
      };
    }
  }
  
  pub fn initSpecial(comptime key: Key) Keysym {
    switch(key) {
      .normal => { @compileError("initSpecial requires special key"); },
      else => {
        return Keysym {
          .raw = 0,
          .key = key,
        };
      },
      
    }
  }
  
  pub fn isSpecial(self: Keysym) bool {
    if (self.ctrl_key)
      return true;
    return switch(self.key) {
      .normal => false,
      else => true,
    };
  }
  
  pub fn getPrint(self: Keysym) ?u8 {
    if (!self.isSpecial() and std.ascii.isPrint(self.raw)) {
      return switch(self.key) {
        .normal => |c| c,
        else => null,
      };
    } else {
      return null;
    }
  }
  
  pub fn isChar(self: Keysym, char: u8) bool {
    return switch(self.key) {
      .normal => |c| c == char,
      else => false,
    };
  }
};