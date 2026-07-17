# Ubuntu Y700 Build CI

GitHub Actions CI for building Lenovo Y700/TB321FU ARM64 rootfs and GRUB/FAT boot images.

The repository is intentionally structured as a standard source-driven build pipeline. Device payloads are inputs, not hardcoded policy inside the rootfs builder.

## Workflow

Workflows:

- `.github/workflows/build-rootfs-and-grub.yml`: full rootfs, kernel and GRUB build.
- `.github/workflows/build-kernel-and-grub.yml`: fast kernel plus `grub.img.7z` build without rebuilding rootfs.

The workflow exposes common dispatch inputs directly in the GitHub Actions UI, including output prefix, Ubuntu mirror, image sizes, rootfs labels, default user settings, sudo mode, and optional GDM autologin.

It also keeps three optional advanced override inputs:

- `release_tag`: optional release tag to upload artifacts to.
- `output_prefix`: output filename prefix.
- `rootfs_config`: optional rootfs overrides as `KEY=value` lines.
- `boot_config`: optional GRUB/FAT boot overrides as `KEY=value` lines.
- `source_config`: optional input artifact URL overrides as `KEY=value` lines.

Leave the advanced override inputs empty for the built-in verified defaults. If an advanced override input is filled, its `KEY=value` lines are appended after the built-in defaults and before the common UI fields are applied.

## Fast Kernel And GRUB Workflow

Use **Build Kernel And GRUB** in the Actions UI when changing only the kernel configuration or kernel source. This workflow builds `Image`, the TB321FU DTB, and the matching in-tree modules, injects the boot files into the verified FAT/GRUB template, and uploads an artifact containing:

- `grub.img.7z`
- `y700-kernel-modules-<kernel-release>.tar.zst`
- `SHA256SUMS.txt`
- the intermediate kernel artifact archive containing `Image`, DTB, `kernel.config`, the module archive, and build metadata

It does not run debootstrap, provision a desktop, build device rootfs packages, create an ext4 rootfs image, or compress a rootfs image. The existing rootfs remains selected through `ROOT_PARTLABEL=userdata` by default.

Edit `configs/y700-kernel.config.fragment` for normal kernel configuration experiments:

```text
CONFIG_EXAMPLE_FEATURE=y
# CONFIG_EXAMPLE_DEBUG is not set
```

The fragment is merged over the verified base configuration. Required Snap/Waydroid settings are validated after Kconfig normalization, so accidentally disabling one fails the build instead of producing a misleading artifact. Boot-critical storage, filesystem, display, and device drivers must remain built in with `=y`; this direct GRUB path has no initramfs. Waydroid's netd-only extensions are deliberately built as modules and the workflow uses `KERNEL_LOCALVERSION=-waydroid`, so the new module directory is installed beside the known-good kernel's modules instead of overwriting them.

For a kernel-only update, install the matching module archive into the existing Ubuntu rootfs **before** replacing or flashing `grub.img.7z`:

```bash
modules_archive=y700-kernel-modules-<kernel-release>.tar.zst
kernel_release=$(tar --zstd -tf "$modules_archive" | sed -n 's#^usr/lib/modules/\([^/]*\)/.*#\1#p' | head -n1)
test -n "$kernel_release"
sudo tar --zstd -xf "$modules_archive" -C /
sudo depmod "$kernel_release"
```

The archive also installs `/usr/lib/modules-load.d/y700-waydroid.conf`, so the required netfilter and XFRM modules load automatically on the next boot. Only after those commands succeed should `grub.img.7z` be installed. Restoring the previous GRUB image rolls back to the known-good kernel without disturbing its old module directory. Out-of-tree camera, haptics, or other device modules must be rebuilt for the new kernel release if they are needed; they are not included in this in-tree module archive.

The kernel-only workflow uses two cache levels. An exact source/config match restores the completed kernel archive; a changed fragment restores the closest `ccache` state and recompiles only what cannot be reused. The final Actions artifact is uploaded without another compression pass because `grub.img.7z` is already compressed.

When `release_tag` is set, the kernel-only workflow creates the Release if needed or replaces `grub.img.7z`, the matching Waydroid module archive, and their entries in `SHA256SUMS.txt`. It never deletes existing `boot.img.7z` or rootfs assets.

## Rootfs Config

Optional override example:

```text
DISTRO=resolute
ARCH=arm64
MIRROR=https://ports.ubuntu.com/ubuntu-ports
DEBOOTSTRAP_RETRIES=3
APT_FORCE_IPV4=1
APT_RETRIES=6
APT_TIMEOUT_SECONDS=30
ROOTFS_IMAGE_SIZE=20G
ROOTFS_UUID=
ROOTFS_LABEL=Ubuntu
ROOTFS_PARTLABEL=userdata
HOSTNAME_NAME=y700
DEFAULT_USER_NAME=y700
DEFAULT_USER_PASSWORD=1234
ROOT_PASSWORD_MODE=locked
ROOT_PASSWORD=
USER_SUDO_MODE=password
DESKTOP_FLAVOR=gnome
DISPLAY_MANAGER=gdm3
DESKTOP_AUTOLOGIN=0
DESKTOP_SESSION=ubuntu
TZ_REGION=Asia/Shanghai
LANG_NAME=zh_CN.UTF-8
PACKAGE_LIST=
DESKTOP_ENV=ubuntu-desktop-minimal
INSTALL_FIREFOX=1
INSTALL_IBUS_CHINESE=1
DISABLE_SNAPD=0
REBUILD_TB321FU_CAMERA_GNOME_PLUGIN=1
CAMERA_PIPEWIRE_VERSION=1.6.2
OVERLAY_ARCHIVE=
DEB_ARCHIVE=
SENSOR_DEB_ARCHIVE=https://github.com/GUF296/tb321fu-sensor-debs/releases/download/tb321fu-sensor-debs-20260627.1/tb321fu-sensor-debs_20260627.1_arm64.tar.gz
HAPTICS_DEB_ARCHIVE=https://github.com/GUF296/tb321fu-haptics-debs/releases/download/tb321fu-haptics-debs-20260627.2/tb321fu-haptics-debs_20260627.2_arm64.tar.gz
CLEAN_APT_CACHE=1
COMPRESS=7z
CHUNK_SIZE=
KEEP_RAW_IMAGE=0
```

The workflow retries transient `curl`, APT, and debootstrap failures, forces `curl` and APT to IPv4 by default, and caches host APT packages, rootfs/debootstrap packages, and the rebuilt kernel artifact. Cache keys include the relevant architecture, source/config identity, and a UTC date so older package caches can be restored without remaining immutable forever.

## Boot Config

Optional override example:

```text
BOOT_IMAGE_SIZE=14G
BOOT_FAT_BITS=32
BOOT_FAT_LABEL=Y700GRUB
BOOT_SECTOR_SIZE=512
BOOT_CLUSTER_SECTORS=
ROOT_SELECTOR=partlabel
ROOT_PARTLABEL=userdata
ROOT_UUID=
ROOTARGS=
ROOTARGS_EXTRA=
STABLEARGS=drm_client_lib.active=none
BOOT_COMPRESS=7z
BOOT_CHUNK_SIZE=
KEEP_BOOT_IMAGE=0
```

## Source Config

Optional override example:

```text
BUILD_Y700_KERNEL=1
KERNEL_SOURCE_REPOSITORY=https://github.com/GUF296/linux.git
KERNEL_SOURCE_REF=5df8e852ea722929f5359a5ef28ebcec0c4443fd
KERNEL_LOCALVERSION=-waydroid
KERNEL_BUILD_JOBS=4
KERNEL_BASE_CONFIG_ARCHIVE=
KERNEL_CONFIG_FRAGMENT=configs/y700-kernel.config.fragment
KERNEL_MODULES_ARCHIVE=
KERNEL_ARTIFACT_ARCHIVE=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/bootstrap-y700-20260625/y700-kernel-artifacts-7.1.1-g5df8e852ea72.tar.gz
BOOTAA64_EFI_URL=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/bootstrap-y700-20260625/BOOTAA64.EFI
QCOMRAMP_EFI_URL=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/bootstrap-y700-20260625/QCOMRAMP-CONFIGFILE.EFI
QCOMRAMP_CFG_NAME=qcomramp.cfg
GRUB_BUILD_ARCHIVE=
DTB_NAME=sm8650-lenovo-tb321fu.dtb
```

## Scripts

- `scripts/ci/build-rootfs-image.sh`: builds an ext4 rootfs image from debootstrap plus declared overlays/debs.
- `scripts/ci/build-y700-kernel-artifacts.sh`: rebuilds the verified TB321FU kernel commit with the AppArmor and SquashFS features required by Snap, plus Binder/BinderFS and container features for Waydroid.
- `scripts/ci/build-grub-image.sh`: builds a FAT boot image containing BOOTAA64.EFI, a prebuilt or generated QCOMRAMP.EFI, Image, DTB and GRUB config.
- `scripts/ci/build-tb321fu-camera-stack-deb.sh`: builds the live-verified TB321FU camera stack deb from `source/tb321fu-camera-rootfs-overlay` or an explicit camera overlay archive.
- `scripts/ci/pack-disk-image.sh`: optional GPT disk image packer for a FAT boot image plus ext4 rootfs image.
- `scripts/ci/apply-workflow-config.sh`: validates dispatch config blocks and exports allowed keys into the workflow environment.

## Policy Boundary

The rootfs builder does not hardcode one historical verified Y700 state. Use `OVERLAY_ARCHIVE`, `DEB_ARCHIVE`, and the source artifact inputs to select the device payload for each build. Separate verification profiles can be added as independent workflow steps without making the rootfs construction script depend on one fixed baseline.

## Release Assets

When `release_tag` is set, the full rootfs workflow uploads these user-facing boot/rootfs artifacts:

- `boot.img.7z`
- `grub.img.7z`
- `rootfs.img.7z` or split parts such as `rootfs.img.7z.000` and `rootfs.img.7z.001`
- `SHA256SUMS.txt`

The release notes include the rootfs, boot and source config used for that build. Password-like values are redacted from the notes. Release uploads require single-file archives; leave `CHUNK_SIZE` and `BOOT_CHUNK_SIZE` empty when creating a release. The UEFI `boot.img.7z` asset is committed under `source/boot-image/` so release builds do not depend on a previous release to supply it.

The full rootfs workflow installs its freshly built matching modules into `rootfs.img` automatically. The kernel-only workflow instead uploads the module archive as a separate Release asset because it reuses the rootfs already on the device.

New releases created by the workflow are normal GitHub Releases, not prereleases.

## GNOME, Snap, And Waydroid

The default rootfs uses the Ubuntu GNOME session with GDM and enables Snap support through `snapd`, AppArmor, GNOME Software, and the GNOME Software Snap plugin. Snap applications are installed after the device boots; the rootfs builder does not attempt to run the Snap daemon inside the provisioning chroot.

The bootstrap kernel artifact supplies the verified TB321FU base configuration. By default, the workflow fetches the exact matching public source commit from `GUF296/linux`, enables `CONFIG_SECURITY_APPARMOR=y`, the required SquashFS decompressors, Android Binder IPC and BinderFS, memfd, namespaces, cgroups, PSI, bridge/veth networking, and the legacy iptables capabilities required by Android netd. Boot-critical IPv4 filter/NAT/mangle support remains built in. The unavoidable XFRM and conntrack-mark cores are built in, while XFRM userspace control, netfilter netlink/NFLOG, MARK/CONNMARK, TCPMSS, BPF, owner, socket, state, u32, policy, reject, raw, and IPv6 legacy tables are matching modules. The dedicated `-waydroid` kernel release keeps this complete in-tree module set separate from the known-good bootstrap modules. GRUB is packaged with the rebuilt `Image` and DTB; the full rootfs workflow installs the modules automatically, while the kernel-only workflow exposes them as a separate archive.

Set `BUILD_Y700_KERNEL=0` in `source_config` only when intentionally supplying a replacement `KERNEL_ARTIFACT_ARCHIVE` that already has the required Snap and Waydroid kernel features.

The rootfs builder removes KDE-only KWin, Plasma Keyboard, and Plasma workspace configuration after all external device debs are installed. The KDE-only KSystemStats GPU plugin is disabled for GNOME builds.

## Chinese Input

The default rootfs includes GNOME-native IBus Chinese input support:

- `ibus`, `ibus-libpinyin`, GTK input modules, `im-config`, and Noto CJK fonts.
- GNOME dconf defaults select US keyboard plus LibPinyin.
- GNOME's on-screen keyboard is enabled and display orientation lock is disabled for tablet use.

Set `INSTALL_IBUS_CHINESE=0` in `rootfs_config` to opt out.

## Camera Rotation

The committed camera overlay remains the verified base payload, but the rootfs builder replaces its PipeWire SPA plugin with a native Resolute build. The rebuilt plugin queries `org.gnome.Mutter.DisplayConfig` on the current user session bus, prefers the built-in `DSI-1` display, and contains no fixed username, UID, runtime directory, KScreen command, or KWin configuration path.

## External Device Debs

The rootfs workflow can consume prebuilt device deb archives instead of rebuilding every device package inline:

- `SENSOR_DEB_ARCHIVE`: tar/zip archive containing the verified `qcom-sns-*` and `tb321fu-sensors` debs. Current default: `https://github.com/GUF296/tb321fu-sensor-debs/releases/download/tb321fu-sensor-debs-20260626.1/tb321fu-sensor-debs_20260626.1_arm64.tar.gz`.
- `HAPTICS_DEB_ARCHIVE`: tar/zip archive containing the verified `tb321fu-haptics` deb. Current default: `https://github.com/GUF296/tb321fu-haptics-debs/releases/download/tb321fu-haptics-debs-20260627.1/tb321fu-haptics-debs_20260627.1_arm64.tar.gz`.

When `BUILD_Y700_SENSOR_DEBS=1` or `BUILD_TB321FU_HAPTICS_DEB=1`, the workflow now requires either a prebuilt deb archive/directory or all source inputs needed to build that component. It intentionally fails on missing inputs rather than producing a successful rootfs with missing sensor or haptics support.

Recommended split:

- `tb321fu-sensor-debs`: build from the upstream-derived `libssc`, `iio-sensor-proxy`, and `hexagonrpc` sources plus TB321FU patches/registry data, then release a sensor deb archive.
- `tb321fu-haptics-debs`: build the AW86937 external module from the matching Linux source/build artifacts plus TB321FU haptics glue, then release a haptics deb archive.

The rootfs workflow references those release assets through `SENSOR_DEB_ARCHIVE` and `HAPTICS_DEB_ARCHIVE` by default.
