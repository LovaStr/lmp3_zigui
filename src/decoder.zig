//! Decodes MP3 / FLAC / WAV files with mackron/dr_libs (through `lm_decode.c`)
//! into interleaved stereo float32 PCM at a fixed sample rate, the single format
//! the zoto audio context is opened with.

const std = @import("std");

/// The format of the one-and-only zoto context (see audio.zig).
pub const sample_rate: u32 = 44100;
pub const channels: u8 = 2;
pub const bytes_per_frame: usize = channels * @sizeOf(f32);

const Handle = opaque {};
extern "c" fn lm_open(path: [*:0]const u8, channels: *u32, sample_rate: *u32) ?*Handle;
extern "c" fn lm_read_f32(h: *Handle, frames: u64, out: [*]f32) u64;
extern "c" fn lm_close(h: *Handle) void;

pub const Error = error{ OpenFailed, UnsupportedChannelCount, EmptyAudio, OutOfMemory };

/// A fully decoded track. Heap-allocated (see `load`) so `reader` has a stable
/// address: zoto's player keeps a pointer to it.
pub const Track = struct {
    /// Interleaved L/R frames at `sample_rate`.
    samples: []f32,
    /// zoto pulls PCM bytes from here.
    reader: std.Io.Reader,

    pub fn frameCount(self: *const Track) usize {
        return self.samples.len / channels;
    }

    pub fn durationSeconds(self: *const Track) f64 {
        return @as(f64, @floatFromInt(self.frameCount())) / @as(f64, sample_rate);
    }

    pub fn destroy(self: *Track, gpa: std.mem.Allocator) void {
        gpa.free(self.samples);
        gpa.destroy(self);
    }
};

/// True for the file extensions the decoder understands.
pub fn isSupported(path: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const ext = path[dot..];
    return std.ascii.eqlIgnoreCase(ext, ".mp3") or
        std.ascii.eqlIgnoreCase(ext, ".flac") or
        std.ascii.eqlIgnoreCase(ext, ".wav");
}

/// Decode the whole file to stereo @ 44.1 kHz float32.
pub fn load(gpa: std.mem.Allocator, path: []const u8) Error!*Track {
    const cpath = try gpa.dupeZ(u8, path);
    defer gpa.free(cpath);

    var src_channels: u32 = 0;
    var src_rate: u32 = 0;
    const h = lm_open(cpath.ptr, &src_channels, &src_rate) orelse return error.OpenFailed;
    defer lm_close(h);
    if (src_channels == 0 or src_channels > 8 or src_rate == 0) return error.UnsupportedChannelCount;

    const chunk_frames: usize = 4096;
    const chunk = try gpa.alloc(f32, chunk_frames * src_channels);
    defer gpa.free(chunk);

    // 1) Read everything, folding to stereo at the source rate.
    var stereo: std.ArrayList(f32) = .empty;
    defer stereo.deinit(gpa);
    while (true) {
        const got: usize = @intCast(lm_read_f32(h, chunk_frames, chunk.ptr));
        if (got == 0) break;
        try stereo.ensureUnusedCapacity(gpa, got * 2);
        for (0..got) |i| {
            const f = chunk[i * src_channels ..][0..src_channels];
            const l = f[0];
            const r = if (src_channels == 1) f[0] else f[1];
            stereo.appendAssumeCapacity(l);
            stereo.appendAssumeCapacity(r);
        }
    }
    if (stereo.items.len == 0) return error.EmptyAudio;

    // 2) Resample (linear interpolation) to the context rate if needed.
    const samples: []f32 = if (src_rate == sample_rate)
        try stereo.toOwnedSlice(gpa)
    else
        try resample(gpa, stereo.items, src_rate);
    errdefer gpa.free(samples);

    for (samples) |*s| s.* = std.math.clamp(s.*, -1.0, 1.0);

    const track = try gpa.create(Track);
    track.* = .{
        .samples = samples,
        .reader = std.Io.Reader.fixed(std.mem.sliceAsBytes(samples)),
    };
    return track;
}

fn resample(gpa: std.mem.Allocator, in: []const f32, in_rate: u32) Error![]f32 {
    const in_frames = in.len / 2;
    const ratio = @as(f64, @floatFromInt(in_rate)) / @as(f64, sample_rate);
    const out_frames: usize = @intFromFloat(@as(f64, @floatFromInt(in_frames)) / ratio);
    const out = try gpa.alloc(f32, out_frames * 2);
    for (0..out_frames) |i| {
        const pos = @as(f64, @floatFromInt(i)) * ratio;
        const i0: usize = @intFromFloat(pos);
        const i1 = @min(i0 + 1, in_frames - 1);
        const t: f32 = @floatCast(pos - @as(f64, @floatFromInt(i0)));
        inline for (0..2) |ch| {
            const a = in[i0 * 2 + ch];
            const b = in[i1 * 2 + ch];
            out[i * 2 + ch] = a + (b - a) * t;
        }
    }
    return out;
}
