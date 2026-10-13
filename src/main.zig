//! lmp3 — a small audio player.
//!
//!   UI        ddalcu/zigui        (single page: now playing + play list)
//!   decoding  mackron/dr_libs     (MP3 / FLAC / WAV, see decoder.zig)
//!   playback  braheezy/zoto       (see audio.zig)
//!
//! Usage:  lmp3 [file-or-folder ...]

const std = @import("std");
const zigui = @import("zigui");
const app = @import("zigui_app");
const decoder = @import("decoder.zig");
const Audio = @import("audio.zig").Audio;

const sdl = app.c;

// --- theme ------------------------------------------------------------------

var g_theme = zigui.default_theme;

fn themeProvider() zigui.Theme {
    g_theme = zigui.themeForScheme(.macos, app.colorScheme());
    return g_theme;
}

inline fn colors() zigui.Palette {
    return g_theme.colors;
}

// --- state ------------------------------------------------------------------

const Entry = struct {
    path: []u8,
    /// File name without directory or extension.
    title: []u8,
};

const AppState = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Index of the track loaded into `audio` (playing or paused).
    current: ?usize = null,
    /// The user paused playback (as opposed to the track having ended).
    paused: bool = false,
    audio: ?Audio = null,
    volume: zigui.State(f32),
    list_scroll: zigui.ScrollState = .{},
    /// `SDL_GetTicks` when the current track was first seen to have ended; the
    /// next track starts shortly after so the device can drain its buffer.
    ended_at: ?u64 = null,
    status_buf: [320]u8 = undefined,
    status_len: usize = 0,

    fn status(self: *const AppState) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    fn setStatus(self: *AppState, comptime f: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.status_buf, f, args) catch return;
        self.status_len = s.len;
    }

    fn isPlaying(self: *const AppState) bool {
        return self.current != null and !self.paused;
    }
};

var g_app: ?*AppState = null;

// --- play list --------------------------------------------------------------

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\");
    return if (slash) |i| path[i + 1 ..] else path;
}

fn titleOf(path: []const u8) []const u8 {
    const name = baseName(path);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return if (dot == 0) name else name[0..dot];
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return std.ascii.lessThanIgnoreCase(a.path, b.path);
}

/// Append one audio file to the play list (unsupported extensions are ignored).
fn addFile(st: *AppState, path: []const u8) void {
    if (!decoder.isSupported(path)) return;
    const owned = st.gpa.dupe(u8, path) catch return;
    const title = st.gpa.dupe(u8, titleOf(path)) catch {
        st.gpa.free(owned);
        return;
    };
    st.entries.append(st.gpa, .{ .path = owned, .title = title }) catch {
        st.gpa.free(owned);
        st.gpa.free(title);
    };
}

/// Add a file, or every supported file found under a folder (sorted by path).
fn addPath(st: *AppState, path: []const u8) void {
    const cpath = st.gpa.dupeZ(u8, path) catch return;
    defer st.gpa.free(cpath);

    var info: sdl.SDL_PathInfo = undefined;
    if (!sdl.SDL_GetPathInfo(cpath.ptr, &info) or info.type != sdl.SDL_PATHTYPE_DIRECTORY) {
        addFile(st, path);
        return;
    }

    var count: c_int = 0;
    const list = sdl.SDL_GlobDirectory(cpath.ptr, null, 0, &count);
    if (list == null) return;
    defer sdl.SDL_free(@ptrCast(list));

    const first_new = st.entries.items.len;
    var i: usize = 0;
    while (i < @as(usize, @intCast(count))) : (i += 1) {
        const rel = std.mem.span(list[i]);
        const full = std.fmt.allocPrint(st.gpa, "{s}/{s}", .{ path, rel }) catch continue;
        defer st.gpa.free(full);
        addFile(st, full);
    }
    std.mem.sort(Entry, st.entries.items[first_new..], {}, lessThan);
}

fn freeEntries(st: *AppState) void {
    for (st.entries.items) |e| {
        st.gpa.free(e.path);
        st.gpa.free(e.title);
    }
    st.entries.clearRetainingCapacity();
}

fn clearPlaylist(st: *AppState) void {
    stopAudio(st);
    freeEntries(st);
    st.setStatus("Play list cleared", .{});
}

// --- transport --------------------------------------------------------------

fn stopAudio(st: *AppState) void {
    if (st.audio) |*au| au.unload();
    st.current = null;
    st.paused = false;
}

fn playIndex(st: *AppState, index: usize) void {
    if (index >= st.entries.items.len) return;
    const a = if (st.audio) |*au| au else {
        st.setStatus("No audio device available", .{});
        return;
    };
    const e = st.entries.items[index];
    a.load(e.path) catch |err| {
        a.unload();
        st.current = null;
        st.paused = false;
        st.setStatus("Could not play \"{s}\": {s}", .{ e.title, @errorName(err) });
        return;
    };
    st.current = index;
    st.paused = false;
    st.setStatus("Playing", .{});
}

fn togglePlayPause(st: *AppState) void {
    if (st.current == null) {
        if (st.entries.items.len > 0) playIndex(st, 0);
        return;
    }
    const a = if (st.audio) |*au| au else return;
    if (st.paused) {
        a.resumePlayback() catch |err| {
            st.setStatus("Resume failed: {s}", .{@errorName(err)});
            return;
        };
        st.paused = false;
    } else {
        a.pause();
        st.paused = true;
    }
}

fn nextTrack(st: *AppState) void {
    const n = st.entries.items.len;
    if (n == 0) return;
    playIndex(st, if (st.current) |c| (c + 1) % n else 0);
}

fn prevTrack(st: *AppState) void {
    const n = st.entries.items.len;
    if (n == 0) return;
    playIndex(st, if (st.current) |c| (c + n - 1) % n else 0);
}

// --- callbacks --------------------------------------------------------------

fn onPlayPause(st: *AppState) void {
    togglePlayPause(st);
}
fn onNext(st: *AppState) void {
    nextTrack(st);
}
fn onPrev(st: *AppState) void {
    prevTrack(st);
}
fn onClear(st: *AppState) void {
    clearPlaylist(st);
}

const audio_filters = [_]app.FileFilter{
    .{ .name = "Audio files (mp3, flac, wav)", .pattern = "mp3;flac;wav" },
    .{ .name = "All files", .pattern = "*" },
};

fn onAddFile(_: *AppState) void {
    _ = app.openFileDialog(&audio_filters, null);
}
fn onAddFolder(_: *AppState) void {
    _ = app.openFolderDialog(null);
}

const RowCtx = struct { st: *AppState, index: usize };

fn onRowTap(p: ?*anyopaque) void {
    const ctx: *RowCtx = @ptrCast(@alignCast(p.?));
    playIndex(ctx.st, ctx.index);
}

// --- per-frame housekeeping (main thread) ----------------------------------

fn frameHook() void {
    const st = g_app orelse return;

    // Finished file / folder pickers.
    switch (app.takeFileDialogResult(st.gpa)) {
        .none, .canceled => {},
        .picked => |path| {
            defer st.gpa.free(path);
            const before = st.entries.items.len;
            addPath(st, path);
            st.setStatus("Added {d} track(s)", .{st.entries.items.len - before});
        },
    }

    const a = if (st.audio) |*au| au else return;
    a.setVolume(st.volume.get());

    // A track that was playing and has stopped by itself has ended: advance
    // (after a short grace period so the device can play out its buffer).
    if (st.isPlaying() and !a.isPlaying()) {
        const now = sdl.SDL_GetTicks();
        const since = st.ended_at orelse blk: {
            st.ended_at = now;
            break :blk now;
        };
        if (now - since < 400) return;
        st.ended_at = null;
        const cur = st.current.?;
        if (cur + 1 < st.entries.items.len) {
            playIndex(st, cur + 1);
        } else {
            stopAudio(st);
            st.setStatus("Reached the end of the play list", .{});
        }
    } else {
        st.ended_at = null;
    }
}

/// Keep the loop redrawing (~60 fps) while music plays so the clock and progress
/// bar move.
fn busyCheck() bool {
    const st = g_app orelse return false;
    return st.isPlaying();
}

// --- views ------------------------------------------------------------------

fn fmtTime(seconds: f64) []const u8 {
    const total: u64 = @intFromFloat(@max(seconds, 0));
    return zigui.components.fmt("{d}:{d:0>2}", .{ total / 60, total % 60 });
}

/// The seek slider's binding: reads the playback position as a 0..1 fraction and
/// seeks when the user clicks or drags it.
fn seekGet(ctx: *anyopaque) f32 {
    const st: *AppState = @ptrCast(@alignCast(ctx));
    if (st.current == null) return 0;
    const a = if (st.audio) |*au| au else return 0;
    const dur = a.durationSeconds();
    if (dur <= 0) return 0;
    return @floatCast(@min(a.positionSeconds() / dur, 1.0));
}

fn seekSet(ctx: *anyopaque, v: f32) void {
    const st: *AppState = @ptrCast(@alignCast(ctx));
    if (st.current == null) return;
    const a = if (st.audio) |*au| au else return;
    a.seekSeconds(@as(f64, v) * a.durationSeconds(), !st.paused) catch |err| {
        st.setStatus("Seek failed: {s}", .{@errorName(err)});
    };
}

fn nowPlaying(st: *AppState) zigui.View {
    const c = colors();

    var title: []const u8 = "Nothing playing";
    var subtitle: []const u8 = "Add some music, then pick a track";
    var pos: f64 = 0;
    var dur: f64 = 0;
    if (st.current) |i| {
        title = st.entries.items[i].title;
        subtitle = zigui.components.fmt("{s} · track {d} of {d}", .{
            if (st.paused) "Paused" else "Now playing",
            i + 1,
            st.entries.items.len,
        });
        if (st.audio) |*au| {
            pos = au.positionSeconds();
            dur = au.durationSeconds();
        }
    }

    return zigui.VStack(.{
        zigui.Icon(.audio_lines, 44, c.accent),
        zigui.Text(title).font(.title2).truncated(),
        zigui.Text(subtitle).font(.subheadline).foreground(c.secondary_label),
        zigui.Slider(.{ .ctx = st, .getFn = seekGet, .setFn = seekSet }, 0, 1).frameMaxWidth(),
        zigui.HStack(.{
            zigui.Text(fmtTime(pos)).font(.caption).foreground(c.secondary_label),
            zigui.Spacer(),
            zigui.Text(fmtTime(dur)).font(.caption).foreground(c.secondary_label),
        }),
    }).spacing(8).padding(20).frameMaxWidth();
}

fn controls(st: *AppState) zigui.View {
    const playing = st.isPlaying();
    return zigui.HStack(.{
        zigui.IconButton(.chevron_left, 24, zigui.actionCtx(AppState, st, onPrev)),
        zigui.IconButton(if (playing) .pause else .play, 30, zigui.actionCtx(AppState, st, onPlayPause)),
        zigui.IconButton(.chevron_right, 24, zigui.actionCtx(AppState, st, onNext)),
        zigui.Spacer(),
        zigui.Icon(.volume, 18, null),
        zigui.Slider(st.volume.binding(), 0, 1).frameWidth(140),
    }).spacing(14).paddingInsets(.{ .top = 10, .leading = 16, .bottom = 10, .trailing = 16 });
}

fn playlistHeader(st: *AppState) zigui.View {
    return zigui.HStack(.{
        zigui.Text(zigui.components.fmt("Play list · {d}", .{st.entries.items.len})).font(.headline),
        zigui.Spacer(),
        zigui.Button("Add files…", zigui.actionCtx(AppState, st, onAddFile)),
        zigui.Button("Add folder…", zigui.actionCtx(AppState, st, onAddFolder)),
        zigui.Button("Clear", zigui.actionCtx(AppState, st, onClear)),
    }).spacing(8).paddingInsets(.{ .top = 8, .leading = 16, .bottom = 8, .trailing = 16 });
}

fn playlist(st: *AppState) zigui.View {
    const c = colors();
    if (st.entries.items.len == 0) {
        return zigui.VStack(.{
            zigui.Spacer(),
            zigui.Text("The play list is empty").font(.headline).foreground(c.secondary_label),
            zigui.Text("Use “Add files…” or “Add folder…”, or start lmp3 with paths.")
                .font(.subheadline).foreground(c.tertiary_label),
            zigui.Spacer(),
        }).spacing(6).frameMaxWidth().frameMaxHeight();
    }

    const arena = zigui.view.buildAlloc();
    const rows = arena.alloc(zigui.View, st.entries.items.len * 2) catch @panic("oom");
    for (st.entries.items, 0..) |e, i| {
        const ctx = arena.create(RowCtx) catch @panic("oom");
        ctx.* = .{ .st = st, .index = i };
        const is_current = st.current != null and st.current.? == i;

        const lead = if (is_current)
            zigui.Icon(if (st.paused) .pause else .play, 14, c.accent)
        else
            zigui.Text(zigui.components.fmt("{d}", .{i + 1})).font(.caption).foreground(c.tertiary_label);

        var row = zigui.HStack(.{
            lead.frameWidth(28),
            zigui.Text(e.title).truncated(),
            zigui.Spacer(),
        }).spacing(8)
            .paddingInsets(.{ .top = 8, .leading = 16, .bottom = 8, .trailing = 16 })
            .frameMaxWidth()
            .hoverFill(c.hover)
            .onTap(.{ .ctx = ctx, .func = onRowTap });
        if (is_current) row = row.background(c.selection);

        rows[i * 2] = row;
        rows[i * 2 + 1] = zigui.Divider();
    }

    return zigui.ScrollViewState(&st.list_scroll, zigui.VStack(rows[0 .. rows.len - 1]).spacing(0))
        .frameMaxWidth()
        .frameMaxHeight();
}

fn statusBar(st: *AppState) zigui.View {
    return zigui.HStack(.{
        zigui.Text(st.status()).font(.caption).foreground(colors().secondary_label).truncated(),
        zigui.Spacer(),
    }).paddingInsets(.{ .top = 6, .leading = 16, .bottom = 6, .trailing = 16 });
}

fn body(st: *AppState) zigui.View {
    return zigui.VStack(.{
        nowPlaying(st),
        controls(st),
        zigui.Divider(),
        playlistHeader(st),
        zigui.Divider(),
        playlist(st),
        zigui.Divider(),
        statusBar(st),
    }).spacing(0).frameMaxWidth().frameMaxHeight();
}

// --- entry point ------------------------------------------------------------

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var st = AppState{
        .gpa = gpa,
        .volume = zigui.State(f32).init(gpa, 0.8),
    };
    defer {
        freeEntries(&st);
        st.entries.deinit(gpa);
        st.volume.deinit();
    }
    g_app = &st;

    st.audio = Audio.init(gpa) catch |err| blk: {
        st.setStatus("Audio output unavailable: {s}", .{@errorName(err)});
        break :blk null;
    };
    defer if (st.audio) |*au| au.deinit();
    if (st.audio != null) st.setStatus("Ready", .{});

    // Files and folders given on the command line fill the play list.
    var args = try std.process.Args.iterateAllocator(init.args, gpa);
    defer args.deinit();
    _ = args.next(); // argv[0]
    while (args.next()) |a| addPath(&st, a);
    if (st.entries.items.len > 0) st.setStatus("Loaded {d} track(s)", .{st.entries.items.len});

    app.setThemeProvider(themeProvider);
    app.setFrameHook(frameHook);
    app.setBusyCheck(busyCheck);

    try app.run(gpa, AppState, &st, .{
        .title = "lmp3 — zigui audio player",
        .width = 640,
        .height = 720,
        .min_width = 460,
        .min_height = 480,
    }, body);
}
