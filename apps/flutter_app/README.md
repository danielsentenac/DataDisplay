# DATADISPLAY Flutter Shell

This directory contains the real Flutter shell scaffold for the DATADISPLAY platform.

Current scope:

- multiplatform Flutter project for Linux, macOS, Windows, Android, and iOS
- desktop-oriented workspace shell
- session, catalog, plots, and backend sections
- real source open, catalog, and preview-read commands over `dd-ffi`
- a built-in demo backend so tests and first-run UX still work when the native library is absent

The shell now prefers the native Rust engine automatically when it finds `dd-ffi` in the default search paths or via `DD_FFI_LIBRARY_PATH`. If it cannot load the shared library, it falls back to the demo backend and keeps the same UI flow.

Linux desktop builds now stage `libdd_ffi.so` into the app bundle automatically. Windows and macOS runner build hooks are also configured to build and copy the native library during desktop app builds.

## Run

```bash
source ~/.bash_profile
cd /home/sentenac/DATADISPLAY/apps/flutter_app
flutter run -d linux
```

## Verify

```bash
source ~/.bash_profile
cd /home/sentenac/DATADISPLAY/apps/flutter_app
flutter analyze
flutter test
```

## Next integration steps

1. replace the shell-side preview canvases with `dd-render` plot-scene payloads
2. add session persistence and workspace docking behavior
3. extend the same UI flow to the future `GWF` adapter
4. harden release packaging, signing, and notarization of bundled native libraries
