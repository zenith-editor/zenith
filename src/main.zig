const std = @import("std");
const print = @import("std").debug.print;

// keyboard event

const Keysym = struct {
    raw: u8,
    key: u8,
    ctrl_key: bool,
    
    pub const ESC = std.ascii.control_code.esc;
    
    pub fn init(raw: u8) Keysym {
        if (raw <= std.ascii.control_code.us) {
            return Keysym {
                .raw = raw,
                .key = raw | 0b1100000,
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

// text handling

const TextPos = struct {
    row: i32,
    col: i32,
};

const TextHandler = struct {
    const LineList = std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8));
    
    file: ?std.fs.File,
    lines: LineList,
    
    pub fn init() TextHandler {
        return TextHandler {
            .file = null,
            .lines = LineList {},
        };
    }
    
    pub fn open(self: *TextHandler, E: *Editor, file: std.fs.File) !void {
        if (self.file != null) {
            self.file.?.close();
        }
        self.file = file;
        self.lines.clearAndFree(E.allocr());
        try self.readLines(E);
    }
    
    fn readLines(self: *TextHandler, E: *Editor) !void {
        var file = self.file.?;
        var line = std.ArrayListUnmanaged(u8) {};
        var buf: [512]u8 = undefined;
        while (true) {
            const nread = try file.read(&buf);
            for (0..nread) |i| {
                if (buf[i] == '\n') {
                    try self.lines.append(E.allocr(), line);
                    line = std.ArrayListUnmanaged(u8) {}; // moved to self.lines
                } else {
                    try line.append(E.allocr(), buf[i]);
                }
            }
            if (nread == 0) {
                try self.lines.append(E.allocr(), line);
                break;
            }
        }
        // line is moved, so no need to free
    }
};

// editor

const Editor = struct {
    pub const State = enum {
        text,
        command,
        quit,
        
        pub const INIT = State.text;
    };
    
    in: std.fs.File,
    inr: std.fs.File.Reader,
    out: std.fs.File,
    outw: std.fs.File.Writer,
    orig_termios: ?std.posix.termios,
    needs_redraw: bool,
    state: State,
    text_handler: TextHandler,
    alloc_gpa: std.heap.GeneralPurposeAllocator(.{}),
    
    pub fn init() Editor {
        const stdin = std.io.getStdIn();
        const stdout = std.io.getStdOut();
        return Editor {
            .in = stdin,
            .inr = stdin.reader(),
            .out = stdout,
            .outw = stdout.writer(),
            .orig_termios = null,
            .needs_redraw = true,
            .state = State.INIT,
            .text_handler = TextHandler.init(),
            .alloc_gpa = std.heap.GeneralPurposeAllocator(.{}){},
        };
    }
    
    pub fn allocr(self: *Editor) std.mem.Allocator {
        return self.alloc_gpa.allocator();
    }
    
    // raw mode
    
    fn enableRawMode(self: *Editor) !void {
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
    
    fn disableRawMode(self: *Editor) !void {
        if (self.orig_termios) |termios| {
            try std.posix.tcsetattr(self.in.handle, std.posix.TCSA.FLUSH, termios);
        }
    }
    
    // console input
    
    fn readKey(self: *Editor) ?Keysym {
        const raw = self.inr.readByte() catch return null;
        return Keysym.init(raw);
    }
    
    // console output
    
    const CLEAR_SCREEN = "\x1b[2J";
    const RESET_POS = "\x1b[H";
    
    fn writeAll(self: *Editor, bytes: []const u8) !void {
        return self.outw.writeAll(bytes);
    }
    
    fn writeFmt(self: *Editor, comptime fmt: []const u8, args: anytype,) !void {
        return std.fmt.format(self.outw, fmt, args);
    }
    
    fn moveCursor(self: *Editor, pos: TextPos) !void {
        return self.writeFmt("\x1b[{d};{d}H", pos.row, pos.col);
    }
    
    fn refreshScreen(self: *Editor) !void {
        try self.writeAll(Editor.CLEAR_SCREEN);
        try self.writeAll(Editor.RESET_POS);
    }
    
    // handle input
    
    fn handleInput(self: *Editor) !void {
        if (self.readKey()) |keysym| {
            std.debug.print("{}\r\n", .{keysym});
            switch(self.state) {
                State.text => {
                    if (keysym.ctrl_key and keysym.key == 'q') {
                        self.state = State.quit;
                    }
                    else if (keysym.ctrl_key and keysym.key == 's') {
                        // TODO
                    }
                    else if (keysym.ctrl_key and keysym.key == 'o') {
                        // TODO
                    }
                },
                State.command => {
                    if (keysym.raw == Keysym.ESC) {
                        self.state = State.text;
                    }
                },
                State.quit => {},
            }
        }
    }
    
    // handle output
    
    fn handleOutput(self: *Editor) !void {
        _=self;
    }
    
    // tick
    
    const REFRESH_RATE = 16700000;
    
    pub fn run(self: *Editor) !void {
        try self.enableRawMode();
        self.needs_redraw = true;
        self.state = State.INIT;
        while (self.state != State.quit) {
            try self.handleInput();
            try self.handleOutput();
            std.time.sleep(Editor.REFRESH_RATE);
        }
        try self.disableRawMode();
    }
    
};

pub fn main() !void {
    var opened_file: ?std.fs.File = null;
    {
        // arguments
        var args = std.process.args();
        _ = args.skip();
        const cwd = std.fs.cwd();
        while (args.next()) |arg| {
            if (opened_file != null) {
                // TODO
                return;
            }
            // std.debug.print("{}", .{arg});
            opened_file = try cwd.openFile(
                arg,
                std.fs.File.OpenFlags {
                    .mode = .read_write,
                    .lock = .shared,
                }
            );
        }
    }
    var E = Editor.init();
    if (opened_file != null) {
        try E.text_handler.open(&E, opened_file.?);
    }
    try E.run();
}
