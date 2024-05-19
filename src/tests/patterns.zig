//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//

const std = @import("std");
const Expr = @import("patterns").Expr;

test "simple one" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "asdf", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(4, (try expr.checkMatch(allocr, "asdf", &.{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "as", &.{})).pos);
}

test "any" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "..", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "a", &.{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "as", &.{})).pos);
}

test "simple more than one" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "a+", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "a", &.{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "aa", &.{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "aba", &.{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "aad", &.{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "daa", &.{})).pos);
}

test "group more than one" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(ab)+", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "ab", &.{})).pos);
  try std.testing.expectEqual(4, (try expr.checkMatch(allocr, "abab", &.{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "dab", &.{})).pos);
}

test "group nested more than one" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(ax+b)+", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "axb", &.{})).pos);
  try std.testing.expectEqual(6, (try expr.checkMatch(allocr, "axbaxb", &.{})).pos);
  try std.testing.expectEqual(7, (try expr.checkMatch(allocr, "axxbaxb", &.{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "ab", &.{})).pos);
}

test "simple zero or more" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "a*b", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "ab", &.{})).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "aab", &.{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "aba", &.{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "aad", &.{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "daa", &.{})).pos);
}

test "simple greedy zero or more" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "x.*b", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "xb", &.{})).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "xab", &.{})).pos);
  try std.testing.expectEqual(4, (try expr.checkMatch(allocr, "xaab", &.{})).pos);
  try std.testing.expectEqual(8, (try expr.checkMatch(allocr, "xaabxaab", &.{})).pos);
}

test "group zero or more" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(ab)*c", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "c", &.{})).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "abc", &.{})).pos);
  try std.testing.expectEqual(5, (try expr.checkMatch(allocr, "ababc", &.{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "xab", &.{})).pos);
}

test "group nested zero or more" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(a(xy)*b)*c", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "c", &.{})).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "abc", &.{})).pos);
  try std.testing.expectEqual(5, (try expr.checkMatch(allocr, "ababc", &.{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "xab", &.{})).pos);
  try std.testing.expectEqual(7, (try expr.checkMatch(allocr, "axybabc", &.{})).pos);
  try std.testing.expectEqual(9, (try expr.checkMatch(allocr, "axybaxybc", &.{})).pos);
}

test "simple optional" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "a?b", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "ab", &.{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "aba", &.{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "db", &.{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "b", &.{})).pos);
}

test "group optional" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(ab)?c", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "abc", &.{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "c", &.{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "b", &.{})).pos);
}

test "group nested optional" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(a(xy)?b)?c", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "abc", &.{})).pos);
  try std.testing.expectEqual(5, (try expr.checkMatch(allocr, "axybc", &.{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "axbc", &.{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "c", &.{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "b", &.{})).pos);
}

test "simple lazy zero or more" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "x.-b", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "xb", &.{})).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "xab", &.{})).pos);
  try std.testing.expectEqual(4, (try expr.checkMatch(allocr, "xaab", &.{})).pos);
  try std.testing.expectEqual(4, (try expr.checkMatch(allocr, "xaabxaab", &.{})).pos);
}

test "simple range" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "[a-z]+", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "ab0", &.{})).pos);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, "aba0", &.{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "db0", &.{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "x0", &.{})).pos);
}

test "simple range inverse" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "[^b]", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "0", &.{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "b", &.{})).pos);
}

test "group" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "([a-z]*)([A-Z]+)", &.{}).asErr();
  defer expr.deinit(allocr);
  var groups = [1]Expr.MatchGroup{.{}} ** 2;
  const opts: Expr.MatchOptions = .{ .group_out = &groups, };
  try std.testing.expectEqual(4, (try expr.checkMatch(allocr, "abAB0", &opts)).pos);
  try std.testing.expectEqual(0, groups[0].start);
  try std.testing.expectEqual(2, groups[0].end);
  try std.testing.expectEqual(2, groups[1].start);
  try std.testing.expectEqual(4, groups[1].end);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "AB0", &opts)).pos);
  try std.testing.expectEqual(0, groups[0].start);
  try std.testing.expectEqual(0, groups[0].end);
  try std.testing.expectEqual(0, groups[1].start);
  try std.testing.expectEqual(2, groups[1].end);
}

test "simple alternate" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "[a-z]+|[A-Z]+", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "ab", &.{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "AB", &.{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "aB", &.{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "00", &.{})).pos);
}

test "group alternate" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(a|z)(b|c)", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "ab", &.{})).pos);
  try std.testing.expectEqual(1, (try expr.checkMatch(allocr, "az", &.{})).pos);
  try std.testing.expectEqual(2, (try expr.checkMatch(allocr, "zc", &.{})).pos);
  try std.testing.expectEqual(0, (try expr.checkMatch(allocr, "c", &.{})).pos);
}

test "integrate: string" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(
    allocr,
    \\"([^"]|\\.)*"
    , &.{}
  ).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(3, (try expr.checkMatch(allocr, \\"a"
                                                      , &.{})).pos);
  try std.testing.expectEqual(4, (try expr.checkMatch(allocr, \\"\\"
                                                      , &.{})).pos);
  try std.testing.expectEqual(4, (try expr.checkMatch(allocr, \\"ab"
                                                      , &.{})).pos);
  try std.testing.expectEqual(6, (try expr.checkMatch(allocr, \\"\"\""
                                                      , &.{})).pos);
}

test "integrate: huge simple" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "a+", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1000, (try expr.checkMatch(allocr, 
    &([_]u8{'a'}**1000), &.{}
  )).pos);
}

test "integrate: huge group" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "(ab)+", &.{}).asErr();
  defer expr.deinit(allocr);
  try std.testing.expectEqual(1000, (try expr.checkMatch(allocr, 
    &([_]u8{'a','b'}**500), &.{}
  )).pos);
}

test "find (1st pat el is string)" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "asdf?b", &.{}).asErr();
  defer expr.deinit(allocr);
  {
    const res = (try expr.find(allocr, "000asdfbasdfb")).?;
    try std.testing.expectEqual(3, res.start);
    try std.testing.expectEqual(8, res.end);
  }
  {
    const res = (try expr.find(allocr, "000asdbasdfb")).?;
    try std.testing.expectEqual(3, res.start);
    try std.testing.expectEqual(7, res.end);
  }
}

test "find (1st pat el is char, more than one)" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "xab+", &.{}).asErr();
  defer expr.deinit(allocr);
  {
    const res = (try expr.find(allocr, "xabb")).?;
    try std.testing.expectEqual(0, res.start);
    try std.testing.expectEqual(4, res.end);
  }
}

test "find (1st pat el is char)" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "x+asdf?b", &.{}).asErr();
  defer expr.deinit(allocr);
  {
    const res = (try expr.find(allocr, "000xxxasdfbasdfb")).?;
    try std.testing.expectEqual(3, res.start);
    try std.testing.expectEqual(11, res.end);
  }
  {
    const res = (try expr.find(allocr, "000xxxasdbasdfb")).?;
    try std.testing.expectEqual(3, res.start);
    try std.testing.expectEqual(10, res.end);
  }
}

test "find reverse (1st pat el is string)" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "asdf?b", &.{}).asErr();
  defer expr.deinit(allocr);
  {
    const res = (try expr.findBackwards(allocr, "000asdfbasdfb")).?;
    try std.testing.expectEqual(8, res.start);
    try std.testing.expectEqual(13, res.end);
  }
}

test "find reverse (1st pat el is char)" {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocr = gpa.allocator();
  var expr = try Expr.create(allocr, "x+asdf?b", &.{}).asErr();
  defer expr.deinit(allocr);
  {
    const res = (try expr.findBackwards(allocr, "000xxxasdfbasdfbxxxasdfb")).?;
    try std.testing.expectEqual(18, res.start);
    try std.testing.expectEqual(24, res.end);
  }
}