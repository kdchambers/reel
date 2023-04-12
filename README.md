# reel

*Screen capture software for Linux / Wayland*

___

**TLDR:**

- Record and stream desktop (E.g OBS-Studio)
- Linux Wayland only
- Custom GUI, Vulkan rendering backend 

## Goals

- Visually beautiful
- Performant and dependency light
- Simple to compile and modify source code
- Support all relevant Wayland and Vulkan extensions / protocols
- Support Wayland compositor specific extensions
- Expose core funcionality via IPC

## Progress

This project is very new and can be considered a minimally viable product. The following is a course-grained summary of what features / backends have been implemented. In reality there are far far many more features to implement, especially in regards to the GUI which is often a limiting factor.

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
| IPC interface | ❌ |
| Custom font rendering | ❌ |

**NOTE**: KDE and Wlroots screencapture backends refer to compositor specific extensions [kde screencast](https://wayland.app/protocols/kde-zkde-screencast-unstable-v1) and [wlr screencopy](https://wayland.app/protocols/wlr-screencopy-unstable-v1).

## Build & Run Instructions

To build, you'll need a master build of the zig compiler. The latest version tested is **0.11.0-dev.1910**, but if out of date will be updated soon.

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

If you've attempted to build / run this project and ran into any sort of problem. Please submit an issue so that I can fix it. There are many areas that could cause errors and I don't have a lot of hardware to test various systems. Thank you!

## License

MIT