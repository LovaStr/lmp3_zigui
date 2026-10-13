//! Playback engine: one zoto `Context` (opened as stereo float32 @ 44.1 kHz) and
//! at most one `Player` streaming the currently loaded, fully decoded track.

const std = @import("std");
const zoto = @import("zoto");
const decoder = @import("decoder.zig");

pub const Audio = struct {
    gpa: std.mem.Allocator,
    ctx: *zoto.Context,
    track: ?*decoder.Track = null,
    player: ?*zoto.Player = null,
    volume: f64 = 0.8,

    pub fn init(gpa: std.mem.Allocator) !Audio {
        // Only one context may exist per process.
        const ctx = try zoto.newContext(gpa, .{
            .sample_rate = decoder.sample_rate,
            .channel_count = decoder.channels,
            .format = .float32_le,
            .buffer_size = 0, // let zoto choose
        });
        ctx.waitForReady();
        return .{ .gpa = gpa, .ctx = ctx };
    }

    pub fn deinit(self: *Audio) void {
        self.unload();
        self.ctx.deinit();
    }

    /// Stop and release the current track, if any.
    pub fn unload(self: *Audio) void {
        if (self.player) |p| {
            p.pause();
            p.deinit(); // must precede freeing the reader it points at
            self.player = null;
        }
        if (self.track) |t| {
            t.destroy(self.gpa);
            self.track = null;
        }
    }

    /// Decode `path` and start playing it from the beginning.
    pub fn load(self: *Audio, path: []const u8) !void {
        self.unload();
        const t = try decoder.load(self.gpa, path);
        errdefer t.destroy(self.gpa);
        const p = try self.ctx.newPlayer(&t.reader);
        errdefer p.deinit();
        p.setVolume(self.volume);
        try p.play();
        self.track = t;
        self.player = p;
    }

    pub fn pause(self: *Audio) void {
        if (self.player) |p| p.pause();
    }

    pub fn resumePlayback(self: *Audio) !void {
        if (self.player) |p| try p.play();
    }

    pub fn isPlaying(self: *Audio) bool {
        return if (self.player) |p| p.isPlaying() else false;
    }

    pub fn setVolume(self: *Audio, v: f64) void {
        if (v == self.volume) return;
        self.volume = v;
        if (self.player) |p| p.setVolume(v);
    }

    /// Seconds of the loaded track that have been handed to the audio device
    /// (bytes consumed from the source minus what zoto still has buffered).
    pub fn positionSeconds(self: *Audio) f64 {
        const t = self.track orelse return 0;
        const p = self.player orelse return 0;
        const consumed = t.reader.seek -| p.bufferedSize();
        return @as(f64, @floatFromInt(consumed / decoder.bytes_per_frame)) / @as(f64, decoder.sample_rate);
    }

    pub fn durationSeconds(self: *Audio) f64 {
        return if (self.track) |t| t.durationSeconds() else 0;
    }
};
