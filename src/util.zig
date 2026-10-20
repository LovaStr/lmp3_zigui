//! Small pure helpers used by main.zig. They live here, free of zigui/SDL, so
//! they can be unit-tested (see tests/util_test.zig).

const std = @import("std");

/// The file name part of a path (everything after the last `/` or `\`).
pub fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\");
    return if (slash) |i| path[i + 1 ..] else path;
}

/// File name without directory or extension. A leading dot (".hidden") is not
/// treated as an extension separator.
pub fn titleOf(path: []const u8) []const u8 {
    const name = baseName(path);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return if (dot == 0) name else name[0..dot];
}

/// Case-insensitive path ordering used to sort the files found in a folder.
pub fn pathLessThan(a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

pub const MinSec = struct { minutes: u64, seconds: u64 };

/// Split a duration in seconds into whole minutes and seconds. Negative values
/// (and NaN) count as zero; fractions are truncated.
pub fn splitTime(seconds: f64) MinSec {
    const total: u64 = @intFromFloat(@max(seconds, 0));
    return .{ .minutes = total / 60, .seconds = total % 60 };
}
