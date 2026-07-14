# Y700 Camera Rootfs Overlay

This overlay captures the Lenovo Y700 TB321FU daily camera stack verified on Ubuntu 26.04. It includes the known-good `/opt/libcamera-y700` app-chain, PipeWire SPA plugin, IPA/tuning files, PipeWire/WirePlumber environment drop-ins, and DMA heap udev rule restored from the 2026-06-22 live rootfs backup.

## Install Into A Mounted Rootfs

```sh
sudo ./install.sh /path/to/rootfs
```

Use `/` as the target only when intentionally applying it to a live system.

## Contents

- `rootfs-overlay/opt/libcamera-y700`: verified libcamera app-chain, IPA proxy, SoftISP IPA, and Y700 tuning files.
- `rootfs-overlay/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so`: verified base `spa-libcamera` plugin. GNOME rootfs builds replace it with a native target-rootfs build.
- `rootfs-overlay/etc/systemd/user/pipewire.service.d`: PipeWire namespace and libcamera path drop-ins.
- `rootfs-overlay/etc/systemd/user/wireplumber.service.d`: WirePlumber libcamera path drop-in.
- `rootfs-overlay/etc/udev/rules.d/70-y700-camera-dma-heap.rules`: DMA heap access for camera users.
- `source/libcamera-source.cpp.clean-minimal-daily`: full patched source used to build the plugin.

## Runtime Model

- Applies only to Y700 built-in cameras detected by libcamera IDs containing `/base/soc@0/cci@ac15000` or `/base/soc@0/cci@ac16000`.
- Preserves libcamera's original camera orientation transform.
- Queries `org.gnome.Mutter.DisplayConfig.GetCurrentState` on the current GNOME session bus and prefers connector `DSI-1`.
- Caches the Mutter transform for one second to avoid a D-Bus round trip on every camera frame.
- Does not use fixed usernames, fixed UIDs, KScreen, KWin configuration files, or an external systemd updater.

## Verified Tags

- `normal`: rear main/macro `rotate-90`, front `rotate-270`.
- `left`: all three `rotate-180`.
- `inverted`: rear main/macro `rotate-270`, front `rotate-90`.
- `right`: all three `rotate-0`.

Snapshot physical testing after restoring the 2026-06-22 backup payload confirmed that color output and camera rotation are correct under the original Plasma integration. GNOME builds retain the verified libcamera/IPA payload and rebuild only the PipeWire SPA plugin inside the Resolute target rootfs. The installer validates hashes and fails on the rejected `opt/libcamera-y700-test` app-chain path.
