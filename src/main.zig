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
const util = @import("util.zig");
const transport = @import("transport.zig");
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
    /// true: start the next track when one ends; false: stop after the current track.
    auto_advance: bool = true,
    /// true: a track that has finished playing is removed from the play list.
    remove_played: bool = false,
    /// Track that play starts from when nothing is loaded (see `stopAndCueNext`).
    cue: usize = 0,
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

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return util.pathLessThan(a.path, b.path);
}

const AddError = error{
    OutOfMemory,
    /// The path does not exist or cannot be accessed.
    NotFound,
    /// The folder exists but its contents could not be listed.
    FolderUnreadable,
};

/// Append one audio file to the play list (unsupported extensions are ignored).
fn addFile(st: *AppState, path: []const u8) error{OutOfMemory}!void {
    if (!decoder.isSupported(path)) return;
    const owned = try st.gpa.dupe(u8, path);
    errdefer st.gpa.free(owned);
    const title = try st.gpa.dupe(u8, util.titleOf(path));
    errdefer st.gpa.free(title);
    try st.entries.append(st.gpa, .{ .path = owned, .title = title });
}

/// Add a file, or every supported file found under a folder (sorted by path).
/// Files added before an error occurs stay in the play list.
fn addPath(st: *AppState, path: []const u8) AddError!void {
    const cpath = try st.gpa.dupeZ(u8, path);
    defer st.gpa.free(cpath);

    var info: sdl.SDL_PathInfo = undefined;
    if (!sdl.SDL_GetPathInfo(cpath.ptr, &info)) return error.NotFound;
    if (info.type != sdl.SDL_PATHTYPE_DIRECTORY) return addFile(st, path);

    var count: c_int = 0;
    const list = sdl.SDL_GlobDirectory(cpath.ptr, null, 0, &count) orelse return error.FolderUnreadable;
    defer sdl.SDL_free(@ptrCast(list));

    const first_new = st.entries.items.len;
    defer std.mem.sort(Entry, st.entries.items[first_new..], {}, lessThan);
    var i: usize = 0;
    while (i < @as(usize, @intCast(count))) : (i += 1) {
        const rel = std.mem.span(list[i]);
        const full = try std.fmt.allocPrint(st.gpa, "{s}/{s}", .{ path, rel });
        defer st.gpa.free(full);
        try addFile(st, full);
    }
}

/// Add `path` and report the outcome in the status bar.
fn addPathReportingStatus(st: *AppState, path: []const u8) void {
    const before = st.entries.items.len;
    addPath(st, path) catch |err| {
        st.setStatus("Could not add \"{s}\": {s}", .{ util.baseName(path), @errorName(err) });
        return;
    };
    const added = st.entries.items.len - before;
    if (added == 0) {
        st.setStatus("No supported audio files found in \"{s}\"", .{util.baseName(path)});
    } else {
        st.setStatus("Added {d} track(s)", .{added});
    }
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
    st.cue = 0;
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

/// Stop after a track ended on its own. If played tracks are removed, drop the
/// finished one and cue the track that followed it, so the next press of play
/// starts that one (wrapping to the first track past the end of the list).
fn stopAndCueNext(st: *AppState, finished: ?usize) void {
    stopAudio(st);
    st.cue = 0;
    if (!st.remove_played) return;
    if (finished) |f| {
        removeEntry(st, f);
        st.cue = f;
    }
}

fn togglePlayPause(st: *AppState) void {
    if (st.current == null) {
        const len = st.entries.items.len;
        if (len > 0) playIndex(st, if (st.cue < len) st.cue else 0);
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

/// Remove one entry from the play list. `index` must not be the loaded track.
fn removeEntry(st: *AppState, index: usize) void {
    const e = st.entries.orderedRemove(index);
    st.gpa.free(e.path);
    st.gpa.free(e.title);
    if (st.current) |c| {
        if (c > index) st.current = c - 1;
    }
}

// --- callbacks --------------------------------------------------------------

fn onPlayPause(st: *AppState) void {
    togglePlayPause(st);
}
fn onClear(st: *AppState) void {
    clearPlaylist(st);
}
fn onToggleRemovePlayed(st: *AppState) void {
    st.remove_played = !st.remove_played;
    st.setStatus("{s}", .{if (st.remove_played) "Played tracks are removed from the list" else "Played tracks stay in the list"});
}
fn onToggleAutoAdvance(st: *AppState) void {
    st.auto_advance = !st.auto_advance;
    st.setStatus("{s}", .{if (st.auto_advance) "Continuous playback" else "Stop after current track"});
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
            addPathReportingStatus(st, path);
        },
    }

    const a = if (st.audio) |*au| au else return;
    a.setVolume(st.volume.get());

    // A track that was playing and has stopped by itself has ended: advance
    // (after a short grace period so the device can play out its buffer). With
    // no player at all (e.g. a failed seek) nothing ended, so do not advance.
    if (!a.hasPlayer()) {
        st.ended_at = null;
        return;
    }
    const step = transport.trackEnd(.{
        .current = st.current,
        .paused = st.paused,
        .device_playing = a.isPlaying(),
        .now = sdl.SDL_GetTicks(),
        .ended_at = st.ended_at,
        .len = st.entries.items.len,
        .auto_advance = st.auto_advance,
    });
    st.ended_at = step.ended_at;
    const finished = st.current;
    switch (step.action) {
        .none => {},
        .play => |i| {
            // Start the next track first (this unloads the finished one), then drop
            // the finished entry, which sits before it in the list.
            playIndex(st, i);
            if (st.remove_played) if (finished) |f| removeEntry(st, f);
        },
        .stop_after_track => {
            stopAndCueNext(st, finished);
            st.setStatus("Stopped after current track", .{});
        },
        .stop_end_of_list => {
            stopAndCueNext(st, finished);
            st.setStatus("Reached the end of the play list", .{});
        },
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
    const t = util.splitTime(seconds);
    return zigui.components.fmt("{d}:{d:0>2}", .{ t.minutes, t.seconds });
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
        // The old player is already gone; stop instead of letting the track-end
        // detection mistake the missing player for a finished track.
        stopAudio(st);
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
        zigui.IconButton(if (playing) .pause else .play, 30, zigui.actionCtx(AppState, st, onPlayPause)),
        autoAdvanceToggle(st),
        removePlayedToggle(st),
        zigui.Spacer(),
        zigui.Icon(.volume, 18, null),
        zigui.Slider(st.volume.binding(), 0, 1).frameWidth(140),
    }).spacing(14).paddingInsets(.{ .top = 10, .leading = 16, .bottom = 10, .trailing = 16 });
}

/// Arrow button: full strength while playback continues with the next track,
/// dimmed grey (like the trash button) while it stops after the current one.
fn autoAdvanceToggle(st: *AppState) zigui.View {
    const btn = zigui.IconButton(.arrow_right, 30, zigui.actionCtx(AppState, st, onToggleAutoAdvance));
    return if (st.auto_advance) btn else btn.opacity(0.35);
}

/// Trash button: dimmed grey while played tracks stay in the list, full strength
/// while they are removed. Same size as the play/pause button.
fn removePlayedToggle(st: *AppState) zigui.View {
    const btn = zigui.IconButton(.trash, 30, zigui.actionCtx(AppState, st, onToggleRemovePlayed));
    return if (st.remove_played) btn else btn.opacity(0.35);
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

/// Shown instead of the play list when the per-frame build arena is exhausted.
fn outOfMemoryView() zigui.View {
    return zigui.VStack(.{
        zigui.Spacer(),
        zigui.Text("Out of memory: cannot draw the play list").font(.headline).foreground(colors().secondary_label),
        zigui.Spacer(),
    }).frameMaxWidth().frameMaxHeight();
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
    const rows = arena.alloc(zigui.View, st.entries.items.len * 2) catch return outOfMemoryView();
    for (st.entries.items, 0..) |e, i| {
        const ctx = arena.create(RowCtx) catch return outOfMemoryView();
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
        // Blue: the loaded track, or with nothing loaded the one play will start.
        const is_cued = st.current == null and i == (if (st.cue < st.entries.items.len) st.cue else 0);
        if (is_current or is_cued) row = row.background(c.selection);

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
    var arg_failed = false;
    while (args.next()) |arg| {
        addPath(&st, arg) catch |err| {
            arg_failed = true;
            st.setStatus("Could not add \"{s}\": {s}", .{ util.baseName(arg), @errorName(err) });
        };
    }
    // Keep the error message if any argument failed; otherwise summarize.
    if (!arg_failed and st.entries.items.len > 0) st.setStatus("Loaded {d} track(s)", .{st.entries.items.len});

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
