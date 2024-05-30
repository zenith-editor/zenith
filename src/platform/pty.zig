const std = @import("std");
const builtin = @import("builtin");

pub const PtyResult = switch (builtin.os.tag) {
  .linux => struct {
    const Self = @This();
    
    master: std.fs.File,
    slave: std.fs.File,
    
    fn fromFd(master: std.posix.fd_t, slave: std.posix.fd_t) Self {
      return .{
        .master = .{ .handle = master, },
        .slave = .{ .handle = slave, },
      };
    }
    
    pub fn close(self: *Self) void {
      self.master.close();
      self.slave.close();
    }
  },
  else => struct {},
};

// see https://web.archive.org/web/20190925164611/http://rachid.koucha.free.fr/tech_corner/pty_pdip.html

pub fn open(termios: std.posix.termios, wsz: *std.posix.winsize) !PtyResult {
  switch (builtin.os.tag) {
    .linux => {
      const m = try std.posix.open(
        "/dev/ptmx",
        .{ .ACCMODE = .RDWR, .NOCTTY = true, },
        @as(std.posix.mode_t, 0)
      );
      errdefer std.posix.close(m);
      
      var n: i32 = 0;
      var res = std.os.linux.ioctl(m, std.os.linux.T.IOCSPTLCK, @intFromPtr(&n));
      switch (std.posix.errno(res)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
      }
      res = std.os.linux.ioctl(m, std.os.linux.T.IOCGPTN, @intFromPtr(&n));
      switch (std.posix.errno(res)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
      }
      
      var buf: [32]u8 = undefined;
      const pts_path = try std.fmt.bufPrintZ(&buf, "/dev/pts/{}", .{n});
      const s = try std.posix.openZ(
        pts_path,
        .{ .ACCMODE = .RDWR, .NOCTTY = true, },
        @as(std.posix.mode_t, 0)
      );
      errdefer std.posix.close(s);
      
      try std.posix.tcsetattr(s, std.posix.TCSA.FLUSH, termios);
      
      res = std.os.linux.ioctl(s, std.os.linux.T.IOCSWINSZ, @intFromPtr(wsz));
      if (std.posix.errno(res) != .SUCCESS) {
        return std.posix.unexpectedErrno(std.posix.errno(res));
      }
      
      return PtyResult.fromFd(m, s);
    },
    else => @compileError("TODO: implement openpty")
  }
}