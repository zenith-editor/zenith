//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//

const std = @import("std");
const Parser = @import("config").parser.Parser;

test "parse empty section" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var parser = Parser.init("[section]");
  {
    var expr = parser.nextExpr(allocr).ok.?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "section", expr.section);
  }
}

test "parse empty table section" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var parser = Parser.init("[[section]]");
  {
    var expr = parser.nextExpr(allocr).ok.?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "section", expr.table_section);
  }
}

test "kv with int val" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var parser = Parser.init(
    \\[section]
    \\key=1
  );
  {
    var expr = parser.nextExpr(allocr).ok.?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "section", expr.section);
  }
  {
    var expr = parser.nextExpr(allocr).ok.?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "key", expr.kv.key);
    try std.testing.expectEqual(1, expr.kv.val.i64);
  }
}

test "kv with string val" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var parser = Parser.init(
    \\key="val"
  );
  {
    var expr = parser.nextExpr(allocr).ok.?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "key", expr.kv.key);
    try std.testing.expectEqualSlices(u8, "val", expr.kv.val.string.items);
  }
}

test "kv with bool val" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var parser = Parser.init(
    \\truth=true
    \\faux=false
  );
  {
    var expr = parser.nextExpr(allocr).ok.?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "truth", expr.kv.key);
    try std.testing.expectEqual(true, expr.kv.val.bool);
  }
  {
    var expr = parser.nextExpr(allocr).ok.?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "faux", expr.kv.key);
    try std.testing.expectEqual(false, expr.kv.val.bool);
  }
}

test "kv with comments" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var parser = Parser.init(
    \\ # comment1
    \\    #comment 2
    \\truth=true
    \\
    \\  #comment 3
    \\faux=false #comment4
  );
  {
    var expr = parser.nextExpr(allocr).ok.?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "truth", expr.kv.key);
    try std.testing.expectEqual(true, expr.kv.val.bool);
  }
  {
    var expr = parser.nextExpr(allocr).ok.?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "faux", expr.kv.key);
    try std.testing.expectEqual(false, expr.kv.val.bool);
  }
}

test "kv with esc seq in string val" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var parser = Parser.init(
    \\key="\"val\""
  );
  {
    var expr = parser.nextExpr(allocr).ok.?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "key", expr.kv.key);
    try std.testing.expectEqualSlices(u8, "\"val\"", expr.kv.val.string.items);
  }
}

test "kv with single-line multiline string" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var parser = Parser.init(
    \\key=\\a
  );
  {
    var expr = parser.nextExpr(allocr).ok.?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "key", expr.kv.key);
    try std.testing.expectEqualSlices(u8, "a", expr.kv.val.string.items);
  }
}

test "kv with multiline string" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var parser = Parser.init(
    \\key=\\a
    \\\\b
  );
  {
    var expr = parser.nextExpr(allocr).ok.?;
    defer expr.deinit(allocr);
    try std.testing.expectEqualSlices(u8, "key", expr.kv.key);
    try std.testing.expectEqualSlices(u8, "a\nb", expr.kv.val.string.items);
  }
}
