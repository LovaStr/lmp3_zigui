//! Track-end decisions as a pure function (no SDL, zigui or audio device), so
//! it can be unit-tested (see tests/transport_test.zig). main.zig gathers the
//! inputs, calls `trackEnd`, and carries out the result.

/// After a track stops by itself, wait this long (SDL ticks, ms) before acting
/// so the audio device can play out its buffer.
pub const grace_ms: u64 = 400;

pub const Action = union(enum) {
    none,
    /// Start the track at this index.
    play: usize,
    /// The track ended and "stop after current track" is on.
    stop_after_track,
    /// The last track of the list ended.
    stop_end_of_list,
};

pub const Input = struct {
    /// Index of the loaded track, if any.
    current: ?usize,
    /// The user paused playback.
    paused: bool,
    /// The audio device reports that the player is still playing.
    device_playing: bool,
    /// Current time in ms (SDL ticks).
    now: u64,
    /// `Step.ended_at` from the previous call.
    ended_at: ?u64,
    /// Number of tracks in the play list.
    len: usize,
    auto_advance: bool,
};

pub const Step = struct {
    /// Time the end of the track was first noticed; feed back as `Input.ended_at`.
    ended_at: ?u64,
    action: Action,
};

/// Decide what to do this frame. A track "has ended" when the user did not pause
/// and the device has stopped playing; the action fires once `grace_ms` have
/// passed since that was first noticed.
pub fn trackEnd(in: Input) Step {
    const wants_playing = in.current != null and !in.paused;
    if (!wants_playing or in.device_playing) return .{ .ended_at = null, .action = .none };

    const since = in.ended_at orelse in.now;
    if (in.now - since < grace_ms) return .{ .ended_at = since, .action = .none };

    const cur = in.current.?;
    const action: Action = if (!in.auto_advance)
        .stop_after_track
    else if (cur + 1 < in.len)
        .{ .play = cur + 1 }
    else
        .stop_end_of_list;
    return .{ .ended_at = null, .action = action };
}
