const std = @import("std");
const print = @import("std").debug.print;

const Editor = struct {
    in: std.fs.File,
    inr: std.fs.File.Reader,
    orig_termios: ?std.posix.termios,
    
    pub fn init() Editor {
        const stdin = std.io.getStdIn();
        return Editor {
            .in = stdin,
            .inr = stdin.reader(),
            .orig_termios = null,
        };
    }
    
    // raw mode
    
    pub fn enableRawMode(self: *Editor) !void {
        var termios = try std.posix.tcgetattr(self.in.handle);
        self.orig_termios = termios;
        
        termios.iflag.BRKINT = false;
        termios.iflag.ICRNL = false;
        termios.iflag.INPCK = false;
        termios.iflag.ISTRIP = false;
        termios.iflag.IXON = false;
        
        termios.oflag.OPOST = false;
        
        termios.cflag.CSIZE = std.posix.CSIZE.CS8;
        
        termios.lflag.ECHO = false;
        termios.lflag.ICANON = false;
        termios.lflag.IEXTEN = false;
        termios.lflag.ISIG = false;
        
        termios.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        termios.cc[@intFromEnum(std.posix.V.TIME)] = 1;
        
        try std.posix.tcsetattr(self.in.handle, std.posix.TCSA.FLUSH, termios);
    }
    
    pub fn disableRawMode(self: *Editor) !void {
        if (self.orig_termios) |termios| {
            try std.posix.tcsetattr(self.in.handle, std.posix.TCSA.FLUSH, termios);
        }
    }
    
};

pub fn main() !void {
    var E = Editor.init();
    try E.enableRawMode();
    const stdin = std.io.getStdIn().reader();
    while (true) {
        const byte = stdin.readByte() catch 0;
        if (byte == 'q')
            break;
        print("{}", .{byte});
    }
    try E.disableRawMode();
}
