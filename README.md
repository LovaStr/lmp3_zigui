# lmp3_zigui

A small audio player for Windows, written in Zig. One window: a "now playing" panel
with a seek slider, play/pause and play-list toggles, a volume slider, and the play list.
Supported formats: MP3, FLAC and WAV.

| Job | Library |
|---|---|
| UI | [ddalcu/zigui](https://github.com/ddalcu/zigui) (SDL3 window layer) |
| Decoding (MP3 / FLAC / WAV) | [mackron/dr_libs](https://github.com/mackron/dr_libs) (compiled via `src/lm_decode.c`) |
| Playback | [braheezy/zoto](https://github.com/braheezy/zoto), vendored and patched in `third_party/zoto` (WASAPI, Windows only) |

## Download

Every merge to `main` publishes a release on the GitHub Releases page with
`lmp3-windows-x64.zip` (`lmp3.exe` + `SDL3.dll`). Unzip it and run `lmp3.exe`.

## Build

Needs **Zig 0.16.0** (do not use 0.17: zigui uses `@cImport`, which 0.17 removed)
and the SDL3 development files for MinGW.

1. Download `SDL3-devel-<ver>-mingw.tar.gz` from the
   [SDL releases page](https://github.com/libsdl-org/SDL/releases) and extract it.
2. Build, passing the `x86_64-w64-mingw32` folder and the DLL:

```sh
zig build -Doptimize=ReleaseFast -Dsdl3-prefix=C:\sdk\SDL3\x86_64-w64-mingw32 -Dsdl3-dll=C:\sdk\SDL3\x86_64-w64-mingw32\bin\SDL3.dll
```

The exe and `SDL3.dll` end up in `zig-out\bin`. It can be cross-compiled from other
systems with `-Dtarget=x86_64-windows-gnu`, which is what CI does.

Options:

* `-Dconsole=true` keeps a console window (for logs and errors). Off by default.
* `zig build run -- "C:\Users\you\Music"` builds and starts the player.
* `zig build test` runs the unit tests; they need neither SDL3 nor a window.

The dependencies are recorded with hashes in `build.zig.zon` (added with
`zig fetch --save`), so a plain `zig build` fetches them.

## Use

`lmp3 [file-or-folder ...]`, or use **Add files…** / **Add folder…** in the window.
A folder adds the supported audio files in it.

* Click a track in the play list to play it.
* **Play/pause** button: pause and resume.
* **Arrow** button: full strength = continue with the next track when one ends;
  dimmed = stop after the current track (the next track is cued, press play to start it).
* **Trash** button: full strength = played tracks are removed from the list;
  dimmed = they stay.
* The progress bar is a slider: click or drag it to jump to another time in the song.
* **Random** shuffles the play list, stops any current playback and cues the first track
  of the new order; press play to start it.
* **Volume** slider on the right. **Clear** empties the play list.
* Errors (unreadable files, a missing audio device, a failed seek) show in the status
  bar instead of crashing the player.

Defaults at start: volume 100 %, continuous playback off, remove played tracks on.

## Notes

* Each track is decoded fully into memory as stereo float32 @ 44.1 kHz (other rates
  are linearly resampled; more than 2 channels use the first two) and handed to zoto
  through a `std.Io.Reader`. The decoders are always built `-O2`; use
  `-Doptimize=ReleaseFast` for the UI.
* Only Windows is supported: zoto is vendored with just its WASAPI driver. The changes
  to zoto are listed in `third_party/zoto/PATCHES.md`.
