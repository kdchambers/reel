// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

pub const RendererBackend = enum {
    software,
    opengl,
    vulkan,
};

pub const ScreencastBackend = enum {
    wlroots,
    pipewire,
};

pub const UserInterfaceBackend = enum {
    headless,
    cli,
    wayland,
};

pub var renderer: RendererBackend = .vulkan;
pub var user_interface: UserInterfaceBackend = .wayland;
pub var preferred_screencast: ScreencastBackend = .pipewire;
