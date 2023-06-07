*Screen capture software for Linux / Wayland*
___

⚠️ **Early development warning** ⚠️

If you're interested in this project you probably want to checkout the [design document](doc/DESIGN.md) and/or join the [discord server](https://discord.gg/fumzzQa575). 

A 0.1 MPV release is targetting for the end of June; until then it's not advised to attempt building the project unless you have some familiarity with zig and are willing to manually install dependencies.

## Goals

- Visually beautiful, responsive and efficient
- Easy to build and package. Reduced number of build and runtime dependencies
- Support and keep up to date with all relevant Wayland and Vulkan extensions / protocols
- Support Wayland compositor specific extensions
- Control with scripts over an IPC interface

## FAQ

### **Why Wayland? Will other systems be supported later on?**

Most likely yes, but not until Reel is more stable and feature complete. The reasoning for this is that I want to provide the best experience possible for those whom Reel is being offered to, and not take on additional mantainance work while the core design is still in-flux. The user interface is already implemented as an optional part of the system, so adding Windows, MacOS, etc windowing and screencasting support shouldn't cause significant incompatibilties later on.

### **Performance Metrics?**

Setting up automated performance metrics is a TODO, but anecdotally Reel generally has a ~35% memory consumption compared to OBS.

|Activity | Reel | OBS |
| ---- | ----- | ----- |
| Idle | 80MB | 220MB|
| *Recording | 160MB | 500MB |

\* Recording with 2 video sources (Screencast & webcam) as well as audio input.

CPU utilization is a little tricker to give a useful estimate for, but performance that isn't on-par or better than OBS will always be considered a bug.

### **Who should consider Reel?**

The first users who might benefit from this project are Wayland users who want to be able to take advantage of compositor specific screencast extensions. For example, if you're using a Wlroots based compositor (Such as sway), Reel doesn't require any additional dependencies (Such as Pipewire) for screencasting.

Additionally, those who are looking for a slightly less resource heavy alternative to OBS and have simple recording requirements might find Reel adecuate early in it's development.

### **Is there a development roadmap?**

No. It's still quite early to release a useful roadmap but check-in later on!

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
| Audio Input Backend Pipewire | ✅ |
| Audio Input Backend Jack | ❌ |
| Screencapture Backend Pipewire | ✅ |
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