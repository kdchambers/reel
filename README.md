*Screen capture software for Linux / Wayland*
___

⚠️ **Reel is still in early development but can be used for some simple use-cases** ⚠️

## Goals

- Visually beautiful, responsive and efficient
- Easy to build and package. Reduced number of build and runtime dependencies
- Support and keep up to date with all relevant Wayland and Vulkan extensions / protocols
- Support Wayland compositor specific extensions
- GUI is optional, should work via an IPC interface

## Progress

The following is a course-grained summary of what features / backends have been implemented. For a more complete list of features, check out the issue tracker.

| Feature | Status |
| ---- | ----- |
| Screenshot | ✅ |
| Record Video | ✅ |
| Stream Video | ❌ |
| Webcam Input | ❌ |
| Audio Input Backend ALSA | ❌ |
| Audio Input Backend Pulse | ✅ |
| Audio Input Backend Pipewire | ❌ |
| Audio Input Backend Jack | ❌ |
| Screencapture Backend Pipewire | ✅ |
| Screencapture Backend Wlroots | ✅ |
| Screencapture Backend KDE | ❌ |

**NOTE**: KDE and Wlroots screencapture backends refer to compositor specific extensions [kde screencast](https://wayland.app/protocols/kde-zkde-screencast-unstable-v1) and [wlr screencopy](https://wayland.app/protocols/wlr-screencopy-unstable-v1).

## Build & Run Instructions

To build, you'll need a master build of the zig compiler. The latest version tested is **0.11.0-dev.2560**, but if out of date will be updated soon.

### Build requirements

- Pipewire
- SPA
- FFMPEG

### Runtime requirements:

- Vulkan
- FFMPEG
- Freetype
- Harfbuzz
- wayland-client
- wayland-cursor

(Pipewire screencapture backend only)

- Pipewire
- Dbus 
- SPA

(Wlroots screencapture backend only)

- Compositor with [wlr-screencopy](https://wayland.app/protocols/wlr-screencopy-unstable-v1) extensions implemented

To build simply invoke the standard build command

```sh
git clone https://github.com/kdchambers/reel --recursive
cd reel
zig build run -Doptimize=ReleaseSafe
```

**NOTE**: If you build in Debug mode, you may run into dropped frames while recording.

If you've attempted to build this project and ran into any sort of problem, please submit a bug report so that I can fix it! 

Although I've done my best to test across Linux distributions, there are areas where different hardware configurations (Screens dimension / resolution, refresh rates, graphics card, etc) need to be taken into account and handled properly.

Thank you!


## License

MIT