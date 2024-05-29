const std = @import("std");
pub const cwidth = @import("./unicode/cwidth.zig").cwidth;
const Editor = @import("./editor.zig").Editor;

pub fn isContByte(byte: u8) bool {
  return switch(byte) {
    0b1000_0000...0b1011_1111 => true,
    else => false,
  };
}

pub fn isMultibyte(byte: u8) bool {
  return switch (byte) {
    '\t' => true,
    else => (byte >= 0x80),
  };
}

pub fn isSpace(bytes: []const u8) bool {
  return bytes.len == 1 and (
    bytes[0] == ' ' or
    bytes[0] == '\t'
  );
}

pub fn sequenceLen(first_byte: u8) !u3 {
  return std.unicode.utf8ByteSequenceLength(first_byte);
}

pub fn countChars(buf: []const u8) !usize {
  return std.unicode.utf8CountCodepoints(buf);
}

pub fn countCharCols(char: u32) u3 {
  return switch (char) {
    '\t' => Editor.HTAB_COLS,
    else => cwidth(char),
  };
}

pub fn isKeywordChar(char: u32) bool {
  return switch (char) {
    48...57 => true,
    65...90 => true,
    97...122 => true,
    '$', '_' => true,
    else => false,
  };
}