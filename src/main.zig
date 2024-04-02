const std = @import("std");
const builtin = @import("builtin");

// keyboard event

const Keysym = struct {
    raw: u8,
    key: u8,
    ctrl_key: bool = false,
    
    pub const ESC = std.ascii.control_code.esc;
    
    pub const RAW_SPECIAL: u8 = 0;
    pub const UP: u8 = 0;
    pub const DOWN: u8 = 1;
    pub const RIGHT: u8 = 2;
    pub const LEFT: u8 = 3;
    
    pub fn init(raw: u8) Keysym {
        if (raw < std.ascii.control_code.us) {
            return Keysym {
                .raw = raw,
                .key = raw | 0b1100000,
                .ctrl_key = true,
            };
        } else {
            return Keysym {
                .raw = raw,
                .key = raw,
            };
        }
    }
    
    pub fn initSpecial(key: u8) Keysym {
        return Keysym {
            .raw = 0,
            .key = key,
        };
    }
    
    pub fn isSpecial(self: Keysym) bool {
        return self.raw == 0 || self.ctrl_key;
    }
    
    pub fn isPrint(self: Keysym) bool {
        return !isSpecial && std.ascii.isPrint(self.raw);
    }
};

// text handling

const TextPos = struct {
    row: u32 = 0,
    col: u32 = 0,
};

const TextHandler = struct {
    /// List of null-terminated strings representing lines.
    /// the final null-byte represents padding for appending
    const LineList = std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8));
    
    file: ?std.fs.File,
    lines: LineList,
    cursor: TextPos,
    scroll: TextPos,
    
    pub fn init() TextHandler {
        return TextHandler {
            .file = null,
            .lines = LineList {},
            .cursor = TextPos {},
            .scroll = TextPos {},
        };
    }
    
    pub fn open(self: *TextHandler, E: *Editor, file: std.fs.File) !void {
        if (self.file != null) {
            self.file.?.close();
        }
        self.cursor = TextPos {};
        self.scroll = TextPos {};
        self.file = file;
        self.lines.clearAndFree(E.allocr());
        try self.readLines(E);
    }
    
    fn readLines(self: *TextHandler, E: *Editor) !void {
        var file = self.file.?;
        const allocr = E.allocr();
        var line = try std.ArrayListUnmanaged(u8).initCapacity(allocr, 1);
        var buf: [512]u8 = undefined;
        while (true) {
            const nread = try file.read(&buf);
            for (0..nread) |i| {
                if (buf[i] == '\n') {
                    try line.append(allocr, 0);
                    try self.lines.append(allocr, line);
                    line = try std.ArrayListUnmanaged(u8).initCapacity(allocr, 1); // moved to self.lines
                } else {
                    try line.append(allocr, buf[i]);
                }
            }
            if (nread == 0) {
                try line.append(allocr, 0);
                try self.lines.append(allocr, line);
                break;
            }
        }
        // line is moved, so no need to free
    }
    
    fn draw(self: *TextHandler, E: *Editor) !void {
        var row: u32 = 0;
        const cursor_row: u32 = self.cursor.row - self.scroll.row;
        for (self.lines.items[self.scroll.row..]) |line| {
            if (row != cursor_row) {
                try E.renderLine(line.items, row, 0);
            } else {
                try E.renderLine(line.items, row, self.scroll.col);
            }
            row += 1;
            if (row == E.height) {
                break;
            }
        }
        try self.updateCursorPos(E);
    }
    
    // cursor
    
    fn updateCursorPos(self: *TextHandler, E: *Editor) !void {
        try E.moveCursor(TextPos {
            .row = self.cursor.row - self.scroll.row,
            .col = self.cursor.col - self.scroll.col,
        });
    }
    
    fn syncColumnAfterCursor(self: *TextHandler, E: *Editor) void {
        const rowlen: u32 = @intCast(self.lines.items[self.cursor.row].items.len);
        if (self.cursor.col <= rowlen - 1) {
            return;
        }
        self.cursor.col = rowlen - 1;
        const oldScrollCol = self.scroll.col;
        if (self.cursor.col > E.width) {
            self.scroll.col = self.cursor.col - E.width;
        } else {
            self.scroll.col = 0;
        }
        if (oldScrollCol != self.scroll.col) {
            E.needs_redraw = true;
        }
    }
    
    pub fn goUp(self: *TextHandler, E: *Editor) !void {
        if (self.cursor.row == 0) {
            return;
        }
        self.cursor.row -= 1;
        self.syncColumnAfterCursor(E);
        if (self.cursor.row < self.scroll.row) {
            self.scroll.row -= 1;
            E.needs_redraw = true;
        }
        try self.updateCursorPos(E);
    }
    
    pub fn goDown(self: *TextHandler, E: *Editor) !void {
        if (self.cursor.row == self.lines.items.len - 1) {
            return;
        }
        self.cursor.row += 1;
        self.syncColumnAfterCursor(E);
        if ((self.cursor.row - self.scroll.row) >= E.height) {
            self.scroll.row += 1;
            E.needs_redraw = true;
        }
        try self.updateCursorPos(E);
    }
    
    pub fn goLeft(self: *TextHandler, E: *Editor) !void {
        if (self.cursor.col == 0) {
            return;
        }
        self.cursor.col -= 1;
        if (self.cursor.col < self.scroll.col) {
            self.scroll.col -= 1;
            E.needs_redraw = true;
        }
        try self.updateCursorPos(E);
    }
    
    pub fn goRight(self: *TextHandler, E: *Editor) !void {
        if (self.cursor.col == self.lines.items[self.cursor.row].items.len - 1) {
            return;
        }
        self.cursor.col += 1;
        if ((self.cursor.col - self.scroll.col) >= E.width) {
            self.scroll.col += 1;
            E.needs_redraw = true;
        }
        try self.updateCursorPos(E);
    }
    
    pub fn syncScrollToNewDim(self: *TextHandler, E: *Editor) void {
        if ((self.scroll.col + self.cursor.col) > E.width) {
            if (E.width > self.cursor.col) {
                self.scroll.col = E.width - self.cursor.col + 1;
            } else {
                self.scroll.col = self.cursor.col - E.width + 1;
            }
        } else {
            self.scroll.col = 0;
        }
        if ((self.scroll.row + self.cursor.row) > E.height) {
            if (E.height > self.cursor.row) {
                self.scroll.row = E.height - self.cursor.row + 1;
            } else {
                self.scroll.row = self.cursor.row - E.height + 1;
            }
        } else { 
            self.scroll.row = 0;
        }
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
    width: u32,
    height: u32,
    buffered_byte: u8,
    
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
            .width = 0,
            .height = 0,
            .buffered_byte = 0,
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
        if (self.buffered_byte != 0) {
            const b = self.buffered_byte;
            self.buffered_byte = 0;
            return Keysym.init(b);
        }
        const raw = self.inr.readByte() catch return null;
        if (raw == Keysym.ESC) {
            if (self.inr.readByte() catch null) |possibleEsc| {
                if (possibleEsc == '[') {
                    switch (self.inr.readByte() catch 0) {
                        'A' => { return Keysym.initSpecial(Keysym.UP); },
                        'B' => { return Keysym.initSpecial(Keysym.DOWN); },
                        'C' => { return Keysym.initSpecial(Keysym.RIGHT); },
                        'D' => { return Keysym.initSpecial(Keysym.LEFT); },
                        else => |byte1| {
                            // unknown escape sequence, empty the buffer
                            std.debug.print("{}", .{byte1});
//                             _ = byte1;
                            while (true) {
                                const byte2 = self.inr.readByte() catch break;
                                std.debug.print("{}", .{byte2});
//                                 _ = byte2;
                            }
                        }
                    }
                } else {
                    self.buffered_byte = possibleEsc;
                }
            }
        }
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
        var row = pos.row;
        if (row > self.height - 1) { row = self.height - 1; }
        var col = pos.col;
        if (col > self.width - 1) { col = self.width - 1; }
        return self.writeFmt("\x1b[{d};{d}H", .{row + 1, col + 1});
    }
    
    fn refreshScreen(self: *Editor) !void {
        try self.writeAll(Editor.CLEAR_SCREEN);
        try self.writeAll(Editor.RESET_POS);
    }
    
    // high level output
    
    pub fn renderLine(self: *Editor, line: []const u8, row: u32, colOffset: u32) !void {
        try self.moveCursor(TextPos {.row = row, .col = 0});
        var col: u32 = 0;
        for (line[colOffset..]) |byte| {
            if (col == self.width) {
                return;
            }
            if (std.ascii.isControl(byte)) {
                continue;
            }
            try self.outw.writeByte(byte);
            col += 1;
        }
    }
    
    // console misc
    
    fn updateWinSize(self: *Editor) !void {
        if (builtin.target.os.tag == .linux) {
            const oldw = self.width;
            const oldh = self.height;
            var wsz: std.os.linux.winsize = undefined;
            const rc = std.os.linux.ioctl(self.in.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&wsz));
            if (std.os.linux.E.init(rc) == .SUCCESS) {
                self.height = wsz.ws_row;
                self.width = wsz.ws_col;
            }
            if (oldw != 0 and oldh != 0) {
                self.text_handler.syncScrollToNewDim(self);
            }
            self.needs_redraw = true;
        }
    }
    
    // handle input
    
    fn handleInput(self: *Editor) !void {
        if (self.readKey()) |keysym| {
//             std.debug.print("{}\r\n", .{keysym});
            switch(self.state) {
                State.text => {
                    if (keysym.raw == 0 and keysym.key == Keysym.UP) {
                        try self.text_handler.goUp(self);
                    }
                    else if (keysym.raw == 0 and keysym.key == Keysym.DOWN) {
                        try self.text_handler.goDown(self);
                    }
                    else if (keysym.raw == 0 and keysym.key == Keysym.LEFT) {
                        try self.text_handler.goLeft(self);
                    }
                    else if (keysym.raw == 0 and keysym.key == Keysym.RIGHT) {
                        try self.text_handler.goRight(self);
                    }
                    else if (keysym.ctrl_key and keysym.key == 'q') {
                        self.state = State.quit;
                    }
                    else if (keysym.ctrl_key and keysym.key == 's') {
                        // TODO
                    }
                    else if (keysym.ctrl_key and keysym.key == 'o') {
                        // TODO
                    }
                    else if (keysym.isPrint()) {
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
        if (!self.needs_redraw)
            return;
        try self.refreshScreen();
        try self.text_handler.draw(self);
        self.needs_redraw = false;
    }
    
    // tick
    
    const REFRESH_RATE = 16700000;
    
    pub fn run(self: *Editor) !void {
        try self.updateWinSize();
        try self.enableRawMode();
        self.needs_redraw = true;
        self.state = State.INIT;
        while (self.state != State.quit) {
            if (resized) {
                try self.updateWinSize();
                resized = false;
            }
            try self.handleInput();
            try self.handleOutput();
            std.time.sleep(Editor.REFRESH_RATE);
        }
        try self.disableRawMode();
    }
    
};

// signal handlers
var resized = false;
fn handle_sigwinch(signal: c_int) callconv(.C) void {
    _ = signal;
    resized = true;
}

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
    if (builtin.target.os.tag == .linux) {
        const sigaction = std.os.linux.Sigaction {
            .handler = .{ .handler = handle_sigwinch, },
            .mask = std.os.linux.empty_sigset,
            .flags = 0,
        };
        _ = std.os.linux.sigaction(std.os.linux.SIG.WINCH, &sigaction, null);
        // TODO log if sigaction fails
    }
    var E = Editor.init();
    if (opened_file != null) {
        try E.text_handler.open(&E, opened_file.?);
    }
    try E.run();
}
