//
// Copyright (c) 2024 T. M. <pm2mtr@gmail.com>.
//
// This work is licensed under the BSD 3-Clause License.
//

const std = @import("std");
const Expr = @import("patterns").Expr;

test "simple one" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "asdf", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(4, (try expr.checkMatch("asdf", &.{})).pos);
    try std.testing.expectEqual(2, (try expr.checkMatch("as", &.{})).pos);
}

test "escape" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "\\\\", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(1, (try expr.checkMatch("\\", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("a", &.{})).pos);
}

test "any" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "..", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(1, (try expr.checkMatch("a", &.{})).pos);
    try std.testing.expectEqual(2, (try expr.checkMatch("as", &.{})).pos);
}

test "simple more than one" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "a+", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(1, (try expr.checkMatch("a", &.{})).pos);
    try std.testing.expectEqual(2, (try expr.checkMatch("aa", &.{})).pos);
    try std.testing.expectEqual(1, (try expr.checkMatch("aba", &.{})).pos);
    try std.testing.expectEqual(2, (try expr.checkMatch("aad", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("daa", &.{})).pos);
}

test "group more than one" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "(ab)+", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(2, (try expr.checkMatch("ab", &.{})).pos);
    try std.testing.expectEqual(4, (try expr.checkMatch("abab", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("dab", &.{})).pos);
}

test "group nested more than one" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "(ax+b)+", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(3, (try expr.checkMatch("axb", &.{})).pos);
    try std.testing.expectEqual(6, (try expr.checkMatch("axbaxb", &.{})).pos);
    try std.testing.expectEqual(7, (try expr.checkMatch("axxbaxb", &.{})).pos);
    try std.testing.expectEqual(1, (try expr.checkMatch("ab", &.{})).pos);
}

test "simple zero or more" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "a*b", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(2, (try expr.checkMatch("ab", &.{})).pos);
    try std.testing.expectEqual(3, (try expr.checkMatch("aab", &.{})).pos);
    try std.testing.expectEqual(2, (try expr.checkMatch("aba", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("aad", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("daa", &.{})).pos);
}

test "simple greedy zero or more" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "x.*b", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(2, (try expr.checkMatch("xb", &.{})).pos);
    try std.testing.expectEqual(3, (try expr.checkMatch("xab", &.{})).pos);
    try std.testing.expectEqual(4, (try expr.checkMatch("xaab", &.{})).pos);
    try std.testing.expectEqual(8, (try expr.checkMatch("xaabxaab", &.{})).pos);
}

test "group zero or more" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "(ab)*c", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(1, (try expr.checkMatch("c", &.{})).pos);
    try std.testing.expectEqual(3, (try expr.checkMatch("abc", &.{})).pos);
    try std.testing.expectEqual(5, (try expr.checkMatch("ababc", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("xab", &.{})).pos);
}

test "group nested zero or more" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "(a(xy)*b)*c", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(1, (try expr.checkMatch("c", &.{})).pos);
    try std.testing.expectEqual(3, (try expr.checkMatch("abc", &.{})).pos);
    try std.testing.expectEqual(5, (try expr.checkMatch("ababc", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("xab", &.{})).pos);
    try std.testing.expectEqual(7, (try expr.checkMatch("axybabc", &.{})).pos);
    try std.testing.expectEqual(9, (try expr.checkMatch("axybaxybc", &.{})).pos);
}

test "simple optional" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "a?b", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(2, (try expr.checkMatch("ab", &.{})).pos);
    try std.testing.expectEqual(2, (try expr.checkMatch("aba", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("db", &.{})).pos);
    try std.testing.expectEqual(1, (try expr.checkMatch("b", &.{})).pos);
}

test "group optional" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "(ab)?c", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(3, (try expr.checkMatch("abc", &.{})).pos);
    try std.testing.expectEqual(1, (try expr.checkMatch("c", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("b", &.{})).pos);
}

test "group nested optional" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "(a(xy)?b)?c", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(3, (try expr.checkMatch("abc", &.{})).pos);
    try std.testing.expectEqual(5, (try expr.checkMatch("axybc", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("axbc", &.{})).pos);
    try std.testing.expectEqual(1, (try expr.checkMatch("c", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("b", &.{})).pos);
}

test "simple lazy zero or more" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "x.-b", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(2, (try expr.checkMatch("xb", &.{})).pos);
    try std.testing.expectEqual(3, (try expr.checkMatch("xab", &.{})).pos);
    try std.testing.expectEqual(4, (try expr.checkMatch("xaab", &.{})).pos);
    try std.testing.expectEqual(4, (try expr.checkMatch("xaabxaab", &.{})).pos);
}

test "simple range" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "[a-z]+", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(2, (try expr.checkMatch("ab0", &.{})).pos);
    try std.testing.expectEqual(3, (try expr.checkMatch("aba0", &.{})).pos);
    try std.testing.expectEqual(2, (try expr.checkMatch("db0", &.{})).pos);
    try std.testing.expectEqual(1, (try expr.checkMatch("x0", &.{})).pos);
}

test "simple range chars" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "[az]", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(1, (try expr.checkMatch("aaa", &.{})).pos);
    try std.testing.expectEqual(1, (try expr.checkMatch("zzz", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("b", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("", &.{})).pos);
}

test "simple range escape" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "[\\\\\\n]", &.{
        .is_multiline = true,
    }).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(1, (try expr.checkMatch("\\", &.{})).pos);
    try std.testing.expectEqual(1, (try expr.checkMatch("\n", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("a", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("", &.{})).pos);
}

test "simple range inverse" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "[^b]", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(1, (try expr.checkMatch("0", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("b", &.{})).pos);
}

test "simple range escape inverse" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "[^\\\\n]", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(0, (try expr.checkMatch("\\", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("\n", &.{})).pos);
    try std.testing.expectEqual(1, (try expr.checkMatch("a", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("", &.{})).pos);
}

test "group" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "([a-z]*)([A-Z]+)", &.{}).asErr();
    defer expr.deinit(allocator);
    var groups = [1]Expr.MatchGroup{.{}} ** 2;
    const opts: Expr.MatchOptions = .{
        .group_out = &groups,
    };
    try std.testing.expectEqual(4, (try expr.checkMatch("abAB0", &opts)).pos);
    try std.testing.expectEqual(0, groups[0].start);
    try std.testing.expectEqual(2, groups[0].end);
    try std.testing.expectEqual(2, groups[1].start);
    try std.testing.expectEqual(4, groups[1].end);
    try std.testing.expectEqual(2, (try expr.checkMatch("AB0", &opts)).pos);
    try std.testing.expectEqual(0, groups[0].start);
    try std.testing.expectEqual(0, groups[0].end);
    try std.testing.expectEqual(0, groups[1].start);
    try std.testing.expectEqual(2, groups[1].end);
}

test "simple alternate" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "[a-z]+|[A-Z]+", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(2, (try expr.checkMatch("ab", &.{})).pos);
    try std.testing.expectEqual(2, (try expr.checkMatch("AB", &.{})).pos);
    try std.testing.expectEqual(1, (try expr.checkMatch("aB", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("00", &.{})).pos);
}

test "group alternate" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "(a|z)(b|c)", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(2, (try expr.checkMatch("ab", &.{})).pos);
    try std.testing.expectEqual(1, (try expr.checkMatch("az", &.{})).pos);
    try std.testing.expectEqual(2, (try expr.checkMatch("zc", &.{})).pos);
    try std.testing.expectEqual(0, (try expr.checkMatch("c", &.{})).pos);
}

test "anchor start" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "^asdf", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(4, (try expr.checkMatch("asdf", &.{})).pos);
    try std.testing.expectEqual(1, (try expr.checkMatch("aasdf", &.{})).pos);
}

test "alternate anchor start" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "(^|a)b", &.{}).asErr();
    defer expr.deinit(allocator);
    {
        const match = try expr.checkMatch("b", &.{});
        try std.testing.expectEqual(1, match.pos);
        try std.testing.expectEqual(true, match.fully_matched);
    }
    {
        const match = try expr.checkMatch("ab", &.{});
        try std.testing.expectEqual(2, match.pos);
        try std.testing.expectEqual(true, match.fully_matched);
    }
}

test "anchor end" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "asdf$", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(true, (try expr.checkMatch("asdf", &.{})).fully_matched);
    try std.testing.expectEqual(false, (try expr.checkMatch("asdfx", &.{})).fully_matched);
}

test "alternate anchor end" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "a(b|$)", &.{}).asErr();
    defer expr.deinit(allocator);
    {
        const match = try expr.checkMatch("az", &.{});
        try std.testing.expectEqual(1, match.pos);
        try std.testing.expectEqual(false, match.fully_matched);
    }
    {
        const match = try expr.checkMatch("ab", &.{});
        try std.testing.expectEqual(2, match.pos);
        try std.testing.expectEqual(true, match.fully_matched);
    }
    {
        const match = try expr.checkMatch("a", &.{});
        try std.testing.expectEqual(1, match.pos);
        try std.testing.expectEqual(true, match.fully_matched);
    }
}

test "integrate: string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator,
        \\"([^"]|\\.)*"
    , &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(3, (try expr.checkMatch(
        \\"a"
    , &.{})).pos);
    try std.testing.expectEqual(4, (try expr.checkMatch(
        \\"\\"
    , &.{})).pos);
    try std.testing.expectEqual(4, (try expr.checkMatch(
        \\"ab"
    , &.{})).pos);
    try std.testing.expectEqual(6, (try expr.checkMatch(
        \\"\"\""
    , &.{})).pos);
}

test "integrate: float" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator,
        \\[0-9]+(\.[0-9]*)?
    , &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(5, (try expr.checkMatch(
        \\0.123abc
    , &.{})).pos);
    try std.testing.expectEqual(3, (try expr.checkMatch(
        \\123abc
    , &.{})).pos);
}

test "integrate: huge simple" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "a+", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(1000, (try expr.checkMatch(&([_]u8{'a'} ** 1000), &.{})).pos);
}

test "integrate: huge group" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "(ab)+", &.{}).asErr();
    defer expr.deinit(allocator);
    try std.testing.expectEqual(1000, (try expr.checkMatch(&([_]u8{ 'a', 'b' } ** 500), &.{})).pos);
}

test "find (1st pat el is string)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "asdf?b", &.{}).asErr();
    defer expr.deinit(allocator);
    {
        const res = (try expr.find("000asdfbasdfb")).?;
        try std.testing.expectEqual(3, res.start);
        try std.testing.expectEqual(8, res.end);
    }
    {
        const res = (try expr.find("000asdbasdfb")).?;
        try std.testing.expectEqual(3, res.start);
        try std.testing.expectEqual(7, res.end);
    }
}

test "find (1st pat el is char, more than one)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "xab+", &.{}).asErr();
    defer expr.deinit(allocator);
    {
        const res = (try expr.find("xabb")).?;
        try std.testing.expectEqual(0, res.start);
        try std.testing.expectEqual(4, res.end);
    }
}

test "find (1st pat el is char)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "x+asdf?b", &.{}).asErr();
    defer expr.deinit(allocator);
    {
        const res = (try expr.find("000xxxasdfbasdfb")).?;
        try std.testing.expectEqual(3, res.start);
        try std.testing.expectEqual(11, res.end);
    }
    {
        const res = (try expr.find("000xxxasdbasdfb")).?;
        try std.testing.expectEqual(3, res.start);
        try std.testing.expectEqual(10, res.end);
    }
}

test "find reverse (1st pat el is string)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "asdf?b", &.{}).asErr();
    defer expr.deinit(allocator);
    {
        const res = (try expr.findBackwards("000asdfbasdfb")).?;
        try std.testing.expectEqual(8, res.start);
        try std.testing.expectEqual(13, res.end);
    }
}

test "find reverse (1st pat el is char)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var expr = try Expr.create(allocator, "x+asdf?b", &.{}).asErr();
    defer expr.deinit(allocator);
    {
        const res = (try expr.findBackwards("000xxxasdfbasdfbxxxasdfb")).?;
        try std.testing.expectEqual(18, res.start);
        try std.testing.expectEqual(24, res.end);
    }
}
