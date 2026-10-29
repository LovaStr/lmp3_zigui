const std = @import("std");
const transport = @import("transport");

const expectEqual = std.testing.expectEqual;
const Action = transport.Action;

// --- trackEnd ---------------------------------------------------------------

/// A playing track at index 1 of 3 whose device has just stopped.
fn ended(now: u64, ended_at: ?u64) transport.Input {
    return .{
        .current = 1,
        .paused = false,
        .device_playing = false,
        .now = now,
        .ended_at = ended_at,
        .len = 3,
        .auto_advance = true,
    };
}

test "trackEnd does nothing while the device is still playing" {
    var in = ended(5000, null);
    in.device_playing = true;
    const s = transport.trackEnd(in);
    try expectEqual(Action.none, s.action);
    try expectEqual(@as(?u64, null), s.ended_at);
}

test "trackEnd forgets a pending end when the device plays again" {
    var in = ended(5000, 4900);
    in.device_playing = true;
    const s = transport.trackEnd(in);
    try expectEqual(Action.none, s.action);
    try expectEqual(@as(?u64, null), s.ended_at);
}

test "trackEnd does not treat a pause as the end of a track" {
    var in = ended(5000, null);
    in.paused = true;
    const s = transport.trackEnd(in);
    try expectEqual(Action.none, s.action);
    try expectEqual(@as(?u64, null), s.ended_at);
}

test "trackEnd does nothing when no track is loaded" {
    var in = ended(5000, null);
    in.current = null;
    const s = transport.trackEnd(in);
    try expectEqual(Action.none, s.action);
    try expectEqual(@as(?u64, null), s.ended_at);
}

test "trackEnd records when the end was first noticed" {
    const s = transport.trackEnd(ended(1000, null));
    try expectEqual(Action.none, s.action);
    try expectEqual(@as(?u64, 1000), s.ended_at);
}

test "trackEnd waits for the grace period" {
    const s = transport.trackEnd(ended(1399, 1000));
    try expectEqual(Action.none, s.action);
    try expectEqual(@as(?u64, 1000), s.ended_at); // keeps the original timestamp
}

test "trackEnd acts exactly when the grace period has passed" {
    const s = transport.trackEnd(ended(1000 + transport.grace_ms, 1000));
    try expectEqual(Action{ .play = 2 }, s.action);
    try expectEqual(@as(?u64, null), s.ended_at);
}

test "trackEnd advances to the next track when auto-advance is on" {
    const s = transport.trackEnd(ended(2000, 1000));
    try expectEqual(Action{ .play = 2 }, s.action);
}

test "trackEnd stops at the end of the list instead of wrapping" {
    var in = ended(2000, 1000);
    in.current = 2; // last of 3
    const s = transport.trackEnd(in);
    try expectEqual(Action.stop_end_of_list, s.action);
    try expectEqual(@as(?u64, null), s.ended_at);
}

test "trackEnd stops after the current track when auto-advance is off" {
    var in = ended(2000, 1000);
    in.auto_advance = false;
    try expectEqual(Action.stop_after_track, transport.trackEnd(in).action);
    in.current = 2; // also on the last track: the "stop after track" reason wins
    try expectEqual(Action.stop_after_track, transport.trackEnd(in).action);
}

test "trackEnd with a single-track list stops at the end" {
    var in = ended(2000, 1000);
    in.current = 0;
    in.len = 1;
    try expectEqual(Action.stop_end_of_list, transport.trackEnd(in).action);
}

test "trackEnd fires once over a run of 16 ms frames" {
    // The device stops at t=1000; simulate frames until something happens.
    var ended_at: ?u64 = null;
    var t: u64 = 1000;
    var fired_at: ?u64 = null;
    while (t < 2000) : (t += 16) {
        const s = transport.trackEnd(ended(t, ended_at));
        ended_at = s.ended_at;
        if (s.action != .none) {
            fired_at = t;
            break;
        }
    }
    const at = fired_at orelse return error.TestUnexpectedResult;
    try std.testing.expect(at >= 1000 + transport.grace_ms);
    try std.testing.expect(at < 1000 + transport.grace_ms + 16);
    try expectEqual(@as(?u64, null), ended_at);
}
