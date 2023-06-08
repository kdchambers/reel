*Screen capture software for Linux / Wayland*
___

⚠️ **Early development warning** ⚠️

A MPV release is targetted for early July; until then it's not advised to attempt building Reel unless you have some familiarity with zig.

If you're interested in this project you probably want to checkout one of the following:

- [frequently asked questions](./doc/FAQ.md)
- [design document](doc/DESIGN.md)
- [discord server](https://discord.gg/fumzzQa575)

## Goals

- Visually beautiful, responsive and efficient
- Easy to build and package. Reduced number of build and runtime dependencies
- Support and keep up to date with all relevant Wayland and Vulkan extensions / protocols
- Support Wayland compositor specific extensions
- Control with scripts over an IPC interface

## Progress

The following is a course-grained summary of what features / backends have been implemented. Additional features can be found on the issue tracker.

| Feature | Status |
| ---- | ----- |
| Screenshot | ✅ |
| Record Video | ✅ |
| Stream Video | ❌ |
| Webcam Backend video4linux2 | ✅ |
| Webcam Backend Pipewire | ❌ |
| Audio Input Backend ALSA | ❌ |
| Audio Input Backend Pulse | ✅ |
| Audio Input Backend Pipewire | ⚠️ |
| Audio Input Backend Jack | ❌ |
| Screencapture Backend Pipewire | ⚠️ |
| Screencapture Backend Wlroots | ✅ |
| Screencapture Backend KDE | ❌ |

⚠️ = Partial implementation

**NOTE**: KDE and Wlroots screencapture backends refer to compositor specific extensions [kde screencast](https://wayland.app/protocols/kde-zkde-screencast-unstable-v1) and [wlr screencopy](https://wayland.app/protocols/wlr-screencopy-unstable-v1).

## Build & Run Instructions

To build, you'll need a master build of the zig compiler. The latest version tested is **0.11.0-dev.3132**, but if out of date will be updated soon.

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

(Pulseaudio audio source backend only)

- pulseaudio

(Pipewire audio source backend only)

- Pipewire

(Pipewire screencapture backend only)

- Pipewire
- Dbus

(Wlroots screencapture backend only)

- Compositor with [wlr-screencopy](https://wayland.app/protocols/wlr-screencopy-unstable-v1) extensions implemented

To build simply invoke the standard build command

```sh
git clone https://github.com/kdchambers/reel --recursive
cd reel
zig build run -Doptimize=ReleaseSafe
```

**NOTE**: If you build in Debug mode, you may run into dropped frames while recording.

## License

MIT