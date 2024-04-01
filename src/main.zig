const std = @import("std");
const print = @import("std").debug.print;

const Keysym = struct {
    raw: u8,
    key: u8,
    ctrl_key: bool,
    
    pub const ESC = std.ascii.control_code.esc;
    
    pub fn init(raw: u8) Keysym {
        if (raw <= std.ascii.control_code.us) {
            return Keysym {
                .raw = raw,
                .key = raw & std.ascii.control_code.us,
                .ctrl_key = true,
            };
        } else {
            return Keysym {
                .raw = raw,
                .key = raw,
                .ctrl_key = false,
            };
        }
    }
};

const Editor = struct {
    in: std.fs.File,
    inr: std.fs.File.Reader,
    out: std.fs.File,
    outw: std.fs.File.Writer,
    orig_termios: ?std.posix.termios,
    
    pub fn init() Editor {
        const stdin = std.io.getStdIn();
        const stdout = std.io.getStdOut();
        return Editor {
            .in = stdin,
            .inr = stdin.reader(),
            .out = stdout,
            .outw = stdout.writer(),
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
    
    // input
    
    pub fn readKey(self: *Editor) ?Keysym {
        const raw = self.inr.readByte() catch return null;
        return Keysym.init(raw);
    }
    
    // screen
    
    pub const CLEAR_SCREEN = "\x1b[2J";
    pub const RESET_POS = "\x1b[H";
    
    pub fn writeAll(self: *Editor, bytes: []const u8) !void {
        return self.outw.writeAll(bytes);
    }
    
    pub fn refreshScreen(self: *Editor) !void {
        try self.writeAll(Editor.CLEAR_SCREEN);
        try self.writeAll(Editor.RESET_POS);
    }
    
    // tick
    
    pub fn loop(self: *Editor) !void {
        try self.refreshScreen();
        while (true) {
            if (self.readKey()) |key| {
                if (key.raw == Keysym.ESC)
                    break;
                print("{}\r\n", .{key});
            }
        }
    }
    
};

pub fn main() !void {
    var E = Editor.init();
    try E.enableRawMode();
    try E.loop();
    try E.disableRawMode();
}
