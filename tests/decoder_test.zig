//! Decoder tests. This file only proves the test wiring for now (`zig build test`
//! compiles the decoder module together with the C shim); real cases follow.

const std = @import("std");
const decoder = @import("decoder");

test "isSupported accepts the three formats, case-insensitively" {
    try std.testing.expect(decoder.isSupported("a.mp3"));
    try std.testing.expect(decoder.isSupported("a.FLAC"));
    try std.testing.expect(decoder.isSupported("dir/a.Wav"));
}

test "isSupported rejects other files" {
    try std.testing.expect(!decoder.isSupported("a.ogg"));
    try std.testing.expect(!decoder.isSupported("mp3"));
}
