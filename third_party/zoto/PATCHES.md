# Local patches to braheezy/zoto

Vendored from https://github.com/braheezy/zoto (see LICENSE) so the Windows build works on Zig 0.16:

* `src/driver_windows.zig`: `std.Thread.Mutex`/`Condition` no longer exist -> small wrappers over
  `std.Io.Mutex`/`Condition` (same as mux.zig); `HRESULT` and `BOOL` defined locally
  (`std.os.windows` removed/changed them).
* `build.zig`: removed the Linux ALSA `translate_c` and `zig_objc` dependency wiring, so only the
  Windows driver is supported by this copy. `build.zig.zon`: no dependencies, min Zig 0.16.0.
