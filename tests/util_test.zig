const std = @import("std");
const util = @import("util");

const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqual = std.testing.expectEqual;

test "baseName handles both separators and bare names" {
    try expectEqualStrings("song.mp3", util.baseName("C:\\Music\\song.mp3"));
    try expectEqualStrings("song.mp3", util.baseName("/home/me/song.mp3"));
    try expectEqualStrings("song.mp3", util.baseName("dir\\sub/song.mp3"));
    try expectEqualStrings("song.mp3", util.baseName("song.mp3"));
    try expectEqualStrings("", util.baseName("dir/"));
    try expectEqualStrings("", util.baseName(""));
}

test "titleOf strips directory and the last extension" {
    try expectEqualStrings("song", util.titleOf("C:\\Music\\song.mp3"));
    try expectEqualStrings("a.b", util.titleOf("a.b.flac"));
    try expectEqualStrings("noext", util.titleOf("dir/noext"));
    try expectEqualStrings("", util.titleOf(""));
}

test "titleOf keeps a leading dot (hidden-file style names)" {
    try expectEqualStrings(".mp3", util.titleOf(".mp3"));
    try expectEqualStrings(".hidden", util.titleOf("dir/.hidden"));
}

test "titleOf ignores dots in directory names" {
    try expectEqualStrings("track", util.titleOf("my.album/track"));
}

test "pathLessThan ignores case" {
    try std.testing.expect(util.pathLessThan("a.mp3", "B.mp3"));
    try std.testing.expect(!util.pathLessThan("B.mp3", "a.mp3"));
    try std.testing.expect(!util.pathLessThan("a.mp3", "A.mp3"));
    try std.testing.expect(util.pathLessThan("a", "ab"));
}

test "splitTime splits minutes and seconds" {
    try expectEqual(util.MinSec{ .minutes = 0, .seconds = 0 }, util.splitTime(0));
    try expectEqual(util.MinSec{ .minutes = 0, .seconds = 59 }, util.splitTime(59.9));
    try expectEqual(util.MinSec{ .minutes = 1, .seconds = 0 }, util.splitTime(60));
    try expectEqual(util.MinSec{ .minutes = 59, .seconds = 59 }, util.splitTime(3599));
    try expectEqual(util.MinSec{ .minutes = 61, .seconds = 1 }, util.splitTime(3661));
}

test "splitTime treats negative values and NaN as zero" {
    try expectEqual(util.MinSec{ .minutes = 0, .seconds = 0 }, util.splitTime(-5));
    try expectEqual(util.MinSec{ .minutes = 0, .seconds = 0 }, util.splitTime(std.math.nan(f64)));
}
