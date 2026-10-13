# lmp3_zigui

A small audio player written in Zig. One window: a "now playing" panel, transport
controls and volume, and the play list.

| Job | Library |
|---|---|
| UI | [ddalcu/zigui](https://github.com/ddalcu/zigui) |
| Decoding (MP3 / FLAC / WAV) | [mackron/dr_libs](https://github.com/mackron/dr_libs) (compiled via `src/lm_decode.c`) |
| Playback | [braheezy/zoto](https://github.com/braheezy/zoto) |

## Build

Needs **Zig 0.17.0** (zoto requires it; zigui needs >= 0.16), plus SDL3
(zigui's window layer).

```sh
# one-time: record the dependencies (writes URLs + hashes into build.zig.zon)
zig fetch --save git+https://github.com/ddalcu/zigui
zig fetch --save git+https://github.com/braheezy/zoto
zig fetch --save git+https://github.com/mackron/dr_libs

zig build -Doptimize=ReleaseFast run -- "C:\Users\you\Music"
```

SDL3 development files:

* **Windows**: download `SDL3-devel-<ver>-mingw.tar.gz` from the SDL releases page,
  extract it, then pass the `x86_64-w64-mingw32` folder and the DLL:
  `zig build -Doptimize=ReleaseFast -Dsdl3-prefix=C:\sdk\SDL3\x86_64-w64-mingw32 -Dsdl3-dll=C:\sdk\SDL3\x86_64-w64-mingw32\bin\SDL3.dll`
* **macOS**: `brew install sdl3`
* **Linux**: install your distro's SDL3 and ALSA dev packages (`libasound2-dev`).

## Use

`lmp3 [file-or-folder ...]`, or use **Add files…** / **Add folder…** in the window.
Click a track to play it; the next track starts automatically.

## Notes

* Each track is decoded fully into memory as stereo float32 @ 44.1 kHz (other rates
  are linearly resampled; >2 channels use the first two) and handed to zoto through a
  `std.Io.Reader`. Use `-Doptimize=ReleaseFast` for the UI; the decoders are always built `-O2`.
* The progress bar is a slider: click or drag it to jump to a different time in the song.
