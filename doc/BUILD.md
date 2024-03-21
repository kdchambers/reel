# Build Dependencies

# Fedora

```sh
sudo dnf install \
    wayland-devel \
    dbus-devel \
    libavcodec-free-devel \
    libavformat-free-devel \
    libavdevice-free-devel \
    pipewire0.2-devel \
    pipewire-devel \
    mesa-vulkan-drivers \
    vulkan-validation-layers
```

NOTE: You may also need to enable vaapi support (For hardware accelerated encoding). See [this](https://fedoraproject.org/wiki/Firefox_Hardware_acceleration) guide for instructions

# Ubuntu

```sh
sudo apt install libwayland-dev \
                 libdbus-1-dev \
                 libpipewire-0.3-dev \
                 libswscale-dev \
                 libavfilter-dev \
                 libavdevice-dev \
                 vulkan-validationlayers \
                 mesa-vulkan-drivers
```