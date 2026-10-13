# lmp3_zigui

A small audio player written in Zig. One window: a "now playing" panel, transport
controls and volume, and the play list.

| Job | Library |
|---|---|
| UI | [ddalcu/zigui](https://github.com/ddalcu/zigui) |
| Decoding (MP3 / FLAC / WAV) | [mackron/dr_libs](https://github.com/mackron/dr_libs) (compiled via `src/lm_decode.c`) |
| Playback | [braheezy/zoto](https://github.com/braheezy/zoto) |

## Build (Windows)

A prebuilt `dist/lmp3.exe` (+ `SDL3.dll`) is included. To rebuild you need **Zig 0.16.0**
(zigui does not build on 0.17; zoto upstream does not build its Windows driver on 0.16 or
0.17, so a patched copy is vendored in `third_party/zoto`, see `PATCHES.md`).

```sh
zig fetch --save git+https://github.com/ddalcu/zigui
zig fetch --save git+https://github.com/mackron/dr_libs

# SDL3-devel-3.4.8-mingw.tar.gz from https://github.com/libsdl-org/SDL/releases, extracted to C:\sdk
zig build -Doptimize=ReleaseFast -Dsdl3-prefix=C:\sdk\SDL3-3.4.8\x86_64-w64-mingw32 -Dsdl3-dll=C:\sdk\SDL3-3.4.8\x86_64-w64-mingw32\bin\SDL3.dll
zig-out\bin\lmp3.exe "C:\Users\you\Music"
```

The exe is a GUI-subsystem program (no console window). Add `-Dconsole=true` to get a console for logs/errors.

Linux/macOS are not set up in this copy (the vendored zoto only wires the Windows driver).

## Use

`lmp3 [file-or-folder ...]`, or use **Add files…** / **Add folder…** in the window.
Click a track to play it; the next track starts automatically.

## Notes

* Each track is decoded fully into memory as stereo float32 @ 44.1 kHz (other rates
  are linearly resampled; >2 channels use the first two) and handed to zoto through a
  `std.Io.Reader`. Use `-Doptimize=ReleaseFast` for the UI; the decoders are always built `-O2`.
* There is no seek bar yet; the progress bar is display-only.
