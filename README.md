![Reel running on Fedora KDE](https://github.com/kdchambers/reel/assets/14359115/7292fa9e-d270-4552-8e3e-f8db05f07ea5)

<h1 align="center">Reel</h1>

<p align="center">Screen capture software for Linux / Wayland</p>
<br/>

#### ⚠️ **Early development warning** ⚠️

If you're interested in this project now you can checkout one of the following.

- [frequently asked questions](./doc/FAQ.md)
- [design document](doc/DESIGN.md)
- [discord server](https://discord.gg/fumzzQa575)

## Goals

- Visually beautiful, responsive and efficient
- Easy to build and package. Reduced number of build and runtime dependencies
- Support and keep up to date with all relevant Wayland and Vulkan extensions / protocols
- Support Wayland compositor specific extensions
- Control with scripts over an IPC interface

## Installation

First install the required dependencies for your distribution.

- [Fedora](doc/BUILD.md#Fedora)
- [Ubuntu](doc/BUILD.md#Ubuntu)

To build, you'll need a build of the zig compiler. The latest verified version is **0.12.0-dev.3180**, but if out of date will be updated soon.

```sh
git clone https://github.com/kdchambers/reel --recursive
cd reel
zig build run -Doptimize=ReleaseSafe
```
