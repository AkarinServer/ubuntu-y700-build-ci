#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Build a standard ARM64 rootfs disk image from declared inputs.

Required host tools: debootstrap, mount, chroot, mkfs.ext4, e2fsck, tar.

Environment inputs:
  OUTPUT_DIR                 default: out/ci-rootfs
  OUTPUT_PREFIX              default: <DISTRO>-<ARCH>
  DISTRO                     default: resolute
  ARCH                       default: arm64
  MIRROR                     default: http://ports.ubuntu.com/ubuntu-ports
  DEBOOTSTRAP_VARIANT        default: minbase; set empty for debootstrap default
  RESOLV_CONF_CONTENT        optional /etc/resolv.conf contents for chroot
  APT_HTTP_PROXY             optional apt proxy used only during provisioning
  APT_HTTPS_PROXY            optional apt https proxy; defaults to APT_HTTP_PROXY
  APT_SOURCES_LIST           optional full sources.list replacement
  ROOTFS_IMAGE_SIZE          default: 14G
  ROOTFS_UUID                optional ext4 UUID
  ROOTFS_LABEL               default: Ubuntu
  ROOTFS_PARTLABEL           metadata only, default: userdata
  HOSTNAME_NAME              default: y700
  DEFAULT_USER_NAME          default: y700
  DEFAULT_USER_PASSWORD      default: 1234
  ROOT_PASSWORD_MODE         locked|set|empty, default: locked
  ROOT_PASSWORD              used when ROOT_PASSWORD_MODE=set
  USER_SUDO_MODE             password|nopasswd|none, default: password
  DESKTOP_FLAVOR             gnome|plasma, default: gnome
  DISPLAY_MANAGER            gdm3|sddm, default follows DESKTOP_FLAVOR
  DESKTOP_AUTOLOGIN          enable display-manager autologin, default: 0
  DESKTOP_SESSION            session desktop name, default: ubuntu for GNOME
  TZ_REGION                  default: Asia/Shanghai
  LOCALES                    default: en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8
  LANG_NAME                  default: zh_CN.UTF-8
  PACKAGE_LIST               newline/space separated packages
  DESKTOP_ENV                optional package token appended to PACKAGE_LIST
  OVERLAY_ARCHIVE            optional local path or URL; extracted into rootfs
  OVERLAY_DIR                optional directory copied into rootfs
  DEB_ARCHIVE                optional local path or URL containing .deb files
  DEB_DIR                    optional directory containing .deb files
  SENSOR_DEB_ARCHIVE         optional local path or URL containing sensor .deb files
  SENSOR_DEB_DIR             optional directory containing source-built sensor .deb files
  HAPTICS_DEB_ARCHIVE        optional local path or URL containing haptics .deb files
  HAPTICS_DEB_DIR            optional directory containing source-built haptics .deb files
  CAMERA_STACK_DEB_DIR       optional directory containing source-built camera stack .deb files
  BUILD_TB321FU_GPU_SENSOR   build/install TB321FU KSystemStats Adreno frequency plugin, default: 0
  TB321FU_GPU_SENSOR_SOURCE_DIR
                              optional source directory for the plugin; defaults to repo source/
  INSTALL_GNOME_SNAPSHOT     install GNOME Snapshot camera app, default: 1
  INSTALL_FIREFOX            install Firefox browser, default: 1
  INSTALL_IBUS_CHINESE       install and configure GNOME IBus Chinese input, default: 1
  IBUS_CHINESE_PACKAGES      optional package list for IBus Chinese input
  DISABLE_SNAPD              purge snapd and snap integration from rootfs, default: 0
  REBUILD_TB321FU_CAMERA_GNOME_PLUGIN
                              rebuild the PipeWire camera plugin for Mutter, default: 1
  CAMERA_PIPEWIRE_VERSION    PipeWire source version for camera plugin, default: 1.6.2
  CAMERA_PIPEWIRE_SOURCE_URL optional source archive URL override
  APPLY_Y700_FIRMWARE_FIXES  copy/verify required Y700 firmware paths only, default: 1
  APPLY_Y700_AUDIO_POLICY_FIXES
                              install Y700 WirePlumber ALSA policy for headset mic, default: 1
  CLEAN_APT_CACHE            default: 1
  COMPRESS                   none|zstd|xz|7z, default: 7z
  CHUNK_SIZE                 optional 7z volume size; empty disables volumes
  KEEP_RAW_IMAGE             keep uncompressed rootfs image after packaging, default: 0
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ci_require_cmd debootstrap
ci_require_cmd mkfs.ext4
ci_require_cmd mount
ci_require_cmd umount
ci_require_cmd chroot
ci_require_cmd e2fsck
ci_require_cmd rsync
ci_require_cmd sha256sum
ci_require_cmd strings

DISTRO=${DISTRO:-resolute}
ARCH=${ARCH:-arm64}
MIRROR=${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}
DEBOOTSTRAP_VARIANT=${DEBOOTSTRAP_VARIANT-minbase}
RESOLV_CONF_CONTENT=${RESOLV_CONF_CONTENT:-}
APT_HTTP_PROXY=${APT_HTTP_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}
APT_HTTPS_PROXY=${APT_HTTPS_PROXY:-${https_proxy:-${HTTPS_PROXY:-${APT_HTTP_PROXY:-}}}}
OUTPUT_PREFIX=${OUTPUT_PREFIX:-${DISTRO}-${ARCH}}
OUTPUT_DIR=${OUTPUT_DIR:-out/ci-rootfs}
ROOTFS_IMAGE_SIZE=${ROOTFS_IMAGE_SIZE:-14G}
ROOTFS_LABEL=${ROOTFS_LABEL:-Ubuntu}
ROOTFS_PARTLABEL=${ROOTFS_PARTLABEL:-userdata}
HOSTNAME_NAME=${HOSTNAME_NAME:-y700}
DEFAULT_USER_NAME=${DEFAULT_USER_NAME:-y700}
DEFAULT_USER_PASSWORD=${DEFAULT_USER_PASSWORD:-1234}
ROOT_PASSWORD_MODE=${ROOT_PASSWORD_MODE:-locked}
ROOT_PASSWORD=${ROOT_PASSWORD:-}
USER_SUDO_MODE=${USER_SUDO_MODE:-password}
DESKTOP_FLAVOR=${DESKTOP_FLAVOR:-gnome}
case "$DESKTOP_FLAVOR" in
  gnome)
    DISPLAY_MANAGER=${DISPLAY_MANAGER:-gdm3}
    DESKTOP_SESSION=${DESKTOP_SESSION:-ubuntu}
    ;;
  plasma)
    DISPLAY_MANAGER=${DISPLAY_MANAGER:-sddm}
    DESKTOP_SESSION=${DESKTOP_SESSION:-plasma}
    ;;
  *) ci_die "unsupported DESKTOP_FLAVOR=$DESKTOP_FLAVOR" ;;
esac
DESKTOP_AUTOLOGIN=${DESKTOP_AUTOLOGIN:-0}
case "$DESKTOP_FLAVOR:$DISPLAY_MANAGER" in
  gnome:gdm3|plasma:sddm) ;;
  *) ci_die "unsupported desktop/display-manager combination: $DESKTOP_FLAVOR/$DISPLAY_MANAGER" ;;
esac
TZ_REGION=${TZ_REGION:-Asia/Shanghai}
LANG_NAME=${LANG_NAME:-zh_CN.UTF-8}
LOCALES=${LOCALES:-$'en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8'}
CLEAN_APT_CACHE=${CLEAN_APT_CACHE:-1}
APPLY_Y700_FIRMWARE_FIXES=${APPLY_Y700_FIRMWARE_FIXES:-1}
APPLY_Y700_AUDIO_POLICY_FIXES=${APPLY_Y700_AUDIO_POLICY_FIXES:-1}
BUILD_TB321FU_GPU_SENSOR=${BUILD_TB321FU_GPU_SENSOR:-0}
TB321FU_GPU_SENSOR_SOURCE_DIR=${TB321FU_GPU_SENSOR_SOURCE_DIR:-}
INSTALL_GNOME_SNAPSHOT=${INSTALL_GNOME_SNAPSHOT:-1}
INSTALL_FIREFOX=${INSTALL_FIREFOX:-1}
INSTALL_IBUS_CHINESE=${INSTALL_IBUS_CHINESE:-1}
IBUS_CHINESE_PACKAGES=${IBUS_CHINESE_PACKAGES:-"fonts-noto-cjk im-config ibus ibus-libpinyin ibus-gtk ibus-gtk3 ibus-gtk4"}
DISABLE_SNAPD=${DISABLE_SNAPD:-0}
REBUILD_TB321FU_CAMERA_GNOME_PLUGIN=${REBUILD_TB321FU_CAMERA_GNOME_PLUGIN:-1}
CAMERA_PIPEWIRE_VERSION=${CAMERA_PIPEWIRE_VERSION:-1.6.2}
CAMERA_PIPEWIRE_SOURCE_URL=${CAMERA_PIPEWIRE_SOURCE_URL:-https://github.com/PipeWire/pipewire/archive/refs/tags/${CAMERA_PIPEWIRE_VERSION}.tar.gz}
COMPRESS=${COMPRESS:-7z}
CHUNK_SIZE=${CHUNK_SIZE:-}
KEEP_RAW_IMAGE=${KEEP_RAW_IMAGE:-0}

default_packages="systemd systemd-sysv dbus sudo locales tzdata ca-certificates gnupg curl wget network-manager openssh-server nano vim rsync kmod initramfs-tools"
PACKAGE_LIST=${PACKAGE_LIST:-$default_packages}
if [ -n "${DESKTOP_ENV:-}" ]; then
  PACKAGE_LIST="$PACKAGE_LIST $DESKTOP_ENV"
fi
if [ "$DESKTOP_FLAVOR" = gnome ]; then
  PACKAGE_LIST="$PACKAGE_LIST dconf-cli"
fi
if ci_bool "$INSTALL_GNOME_SNAPSHOT"; then
  PACKAGE_LIST="$PACKAGE_LIST gnome-snapshot"
fi
if ci_bool "$INSTALL_FIREFOX"; then
  PACKAGE_LIST="$PACKAGE_LIST firefox"
fi
if ci_bool "$INSTALL_IBUS_CHINESE"; then
  PACKAGE_LIST="$PACKAGE_LIST $IBUS_CHINESE_PACKAGES"
fi
if ! ci_bool "$DISABLE_SNAPD"; then
  PACKAGE_LIST="$PACKAGE_LIST snapd apparmor gnome-software gnome-software-plugin-snap"
fi

configure_mozilla_firefox_repo() {
  local root=$1
  local keyring_dir="$root/etc/apt/keyrings"
  local source_dir="$root/etc/apt/sources.list.d"
  local pref_dir="$root/etc/apt/preferences.d"
  local keyring="$keyring_dir/packages.mozilla.org.asc"
  local key_tmp="$work_dir/packages.mozilla.org.asc"

  ci_log "configuring Mozilla APT repository for non-snap Firefox"
  install -d -m 0755 "$keyring_dir" "$source_dir" "$pref_dir"
  ci_download "https://packages.mozilla.org/apt/repo-signing-key.gpg" "$key_tmp"
  install -m 0644 "$key_tmp" "$keyring"

  cat > "$source_dir/mozilla.list" <<'MOZILLA_APT'
deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main
MOZILLA_APT
  chmod 0644 "$source_dir/mozilla.list"

  cat > "$pref_dir/mozilla-firefox" <<'MOZILLA_PREF'
Package: firefox firefox-*
Pin: origin packages.mozilla.org
Pin-Priority: 1001

Package: firefox
Pin: version 1:*snap*
Pin-Priority: -1
MOZILLA_PREF
  chmod 0644 "$pref_dir/mozilla-firefox"
}

include_deb_archive() {
  local label=$1 src=$2
  local archive extract copied deb

  [ -n "$src" ] || return 0

  archive="$work_dir/${label}.archive"
  extract="$work_dir/${label}-debs"
  rm -rf "$extract"
  mkdir -p "$rootfs_dir/var/tmp/ci-debs" "$extract"

  ci_log "including $label deb archive: $src"
  ci_download "$src" "$archive"
  ci_extract_archive "$archive" "$extract"

  copied=0
  while IFS= read -r -d '' deb; do
    cp -a "$deb" "$rootfs_dir/var/tmp/ci-debs/"
    copied=$((copied + 1))
  done < <(find "$extract" -type f -name '*.deb' -print0)

  [ "$copied" -gt 0 ] || ci_die "$label deb archive did not contain any .deb files: $src"
}

mkdir -p "$OUTPUT_DIR"
work_dir=$(mktemp -d "$OUTPUT_DIR/.rootfs-build.XXXXXX")
rootfs_dir="$work_dir/rootfs"
rootfs_img="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.img"
build_info="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.BUILD-INFO.txt"
manifest="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.manifest"
mounted=0

apply_y700_firmware_fixes() {
  local root=$1

  ci_log "applying Y700 firmware path fixes"

  install -d -m 0755 "$root/lib/firmware/qcom" "$root/lib/firmware/qcom/sm8650" "$root/lib/firmware/qcom/vpu"

  copy_firmware_if_missing() {
    local source_rel=$1
    local dest_rel=$2
    [ -f "$root/$source_rel" ] || return 1
    if [ -e "$root/$dest_rel" ]; then
      return 0
    fi
    install -d -m 0755 "$(dirname "$root/$dest_rel")"
    install -m 0644 "$root/$source_rel" "$root/$dest_rel"
  }

  # The device overlay stores some firmware under /usr/lib/firmware or vendor-specific
  # subdirectories, while the kernel requests the canonical /lib/firmware/qcom paths.
  local src dst
  for src in \
    usr/lib/firmware/qcom/sm8650/lenovo/tb321fu/gen70900_zap.mbn \
    lib/firmware/qcom/sm8650/lenovo/tb321fu/gen70900_zap.mbn; do
    if copy_firmware_if_missing "$src" lib/firmware/qcom/gen70900_zap.mbn; then
      break
    fi
  done
  for src in \
    usr/lib/firmware/qcom-tb321fu/Lenovo-Y700-TB321FU-tplg.bin \
    lib/firmware/qcom-tb321fu/Lenovo-Y700-TB321FU-tplg.bin; do
    if copy_firmware_if_missing "$src" lib/firmware/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin; then
      break
    fi
  done

  for src in \
    usr/lib/firmware/qcom/gen70900_aqe.fw \
    usr/lib/firmware/qcom/gen70900_sqe.fw \
    usr/lib/firmware/qcom/gmu_gen70900.bin \
    usr/lib/firmware/qcom/vpu/vpu33_p4.mbn; do
    dst=${src#usr/}
    copy_firmware_if_missing "$src" "$dst" || true
  done

  local required=(
    lib/firmware/qcom/gen70900_aqe.fw
    lib/firmware/qcom/gen70900_sqe.fw
    lib/firmware/qcom/gen70900_zap.mbn
    lib/firmware/qcom/gmu_gen70900.bin
    lib/firmware/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin
    lib/firmware/qcom/vpu/vpu33_p4.mbn
  )
  local rel
  for rel in "${required[@]}"; do
    [ -e "$root/$rel" ] || [ -L "$root/$rel" ] || ci_die "missing Y700 required compatibility file: $rel"
  done
}


apply_y700_audio_policy_fixes() {
  local root=$1
  local conf_dir="$root/etc/wireplumber/wireplumber.conf.d"
  local conf="$conf_dir/51-y700-alsa-auto.conf"

  ci_log "installing Y700 WirePlumber ALSA policy fix"

  install -d -m 0755 "$conf_dir"
  cat > "$conf" <<'CONF'
monitor.alsa.rules = [
  {
    matches = [
      {
        device.name = "alsa_card.platform-sound"
      }
    ]
    actions = {
      update-props = {
        api.alsa.use-acp = true
        api.alsa.use-ucm = true
        api.acp.auto-profile = true
        api.acp.auto-port = true
        api.alsa.split-enable = false
      }
    }
  }
]
CONF
  chmod 0644 "$conf"
  chown 0:0 "$conf" 2>/dev/null || true

  grep -q 'api.acp.auto-profile = true' "$conf" || ci_die "Y700 ALSA policy missing auto-profile=true"
  grep -q 'api.acp.auto-port = true' "$conf" || ci_die "Y700 ALSA policy missing auto-port=true"
  grep -q 'api.alsa.split-enable = false' "$conf" || ci_die "Y700 ALSA policy missing split-enable=false"
}

apply_desktop_manager_config() {
  local root=$1
  local session=${DESKTOP_SESSION%.desktop}

  install -d -m 0755 "$root/etc/systemd/system"
  ln -sfn /usr/lib/systemd/system/graphical.target "$root/etc/systemd/system/default.target"

  case "$DISPLAY_MANAGER" in
    gdm3)
      local gdm_conf="$root/etc/gdm3/custom.conf"
      local accounts_conf="$root/var/lib/AccountsService/users/$DEFAULT_USER_NAME"

      [ -x "$root/usr/sbin/gdm3" ] || ci_die "gdm3 is not installed in the rootfs"
      [ -f "$root/usr/share/wayland-sessions/$session.desktop" ] || \
        [ -f "$root/usr/share/xsessions/$session.desktop" ] || \
        ci_die "GNOME session is not installed: $session"
      install -d -m 0755 "$root/etc/gdm3" "$root/var/lib/AccountsService/users"
      {
        echo '[daemon]'
        if ci_bool "$DESKTOP_AUTOLOGIN"; then
          echo 'AutomaticLoginEnable=true'
          printf 'AutomaticLogin=%s\n' "$DEFAULT_USER_NAME"
        else
          echo 'AutomaticLoginEnable=false'
        fi
      } > "$gdm_conf"
      chmod 0644 "$gdm_conf"

      cat > "$accounts_conf" <<CONF
[User]
Session=$session
XSession=$session
SystemAccount=false
CONF
      chmod 0600 "$accounts_conf"

      install -d -m 0755 "$root/etc/X11"
      printf '/usr/sbin/gdm3\n' > "$root/etc/X11/default-display-manager"
      ln -sfn /usr/lib/systemd/system/gdm3.service "$root/etc/systemd/system/display-manager.service"
      if [ -f "$root/etc/systemd/system/y700-audio-card-guard.service" ]; then
        install -d -m 0755 "$root/etc/systemd/system/gdm3.service.d"
        cat > "$root/etc/systemd/system/gdm3.service.d/10-y700-audio-card-guard.conf" <<'CONF'
[Unit]
Requires=y700-audio-card-guard.service
After=y700-audio-card-guard.service
CONF
        chmod 0644 "$root/etc/systemd/system/gdm3.service.d/10-y700-audio-card-guard.conf"
      fi
      rm -rf "$root/etc/sddm.conf.d"
      rm -rf "$root/etc/systemd/system/sddm.service.d"
      ;;
    sddm)
      local conf_dir="$root/etc/sddm.conf.d"
      local conf="$conf_dir/zz-tb321fu-autologin.conf"

      rm -f "$conf" "$conf_dir/30-autologin.conf" "$conf_dir/10-y700-autologin.conf"
      if ci_bool "$DESKTOP_AUTOLOGIN"; then
        install -d -m 0755 "$conf_dir"
        cat > "$conf" <<CONF
[Autologin]
User=$DEFAULT_USER_NAME
Session=$session
Relogin=false
CONF
        chmod 0644 "$conf"
      fi
      printf '/usr/bin/sddm\n' > "$root/etc/X11/default-display-manager"
      ln -sfn /usr/lib/systemd/system/sddm.service "$root/etc/systemd/system/display-manager.service"
      ;;
  esac

  chown 0:0 "$root/etc/X11/default-display-manager" 2>/dev/null || true
  [ "$(cat "$root/etc/X11/default-display-manager")" = "/usr/sbin/gdm3" ] || \
    [ "$DISPLAY_MANAGER" = sddm ] || ci_die "gdm3 was not selected as the default display manager"
}

apply_gnome_desktop_cleanup() {
  local root=$1

  [ "$DESKTOP_FLAVOR" = gnome ] || return 0
  ci_log "removing KDE-only configuration from the GNOME rootfs"
  rm -f \
    "$root/etc/xdg/kwinrc" \
    "$root/etc/skel/.config/kwinrc" \
    "$root/etc/skel/.config/kwinoutputconfig.json" \
    "$root/etc/skel/.config/plasmakeyboardrc" \
    "$root/home/$DEFAULT_USER_NAME/.config/kwinrc" \
    "$root/home/$DEFAULT_USER_NAME/.config/kwinoutputconfig.json" \
    "$root/home/$DEFAULT_USER_NAME/.config/plasmakeyboardrc"
  rm -rf \
    "$root/etc/skel/.config/plasma-workspace" \
    "$root/home/$DEFAULT_USER_NAME/.config/plasma-workspace"

  if strings -a "$root/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so" \
      | grep -Eq 'kscreen-doctor|kwinoutputconfig.json|/home/y700/.config|/run/user/1000'; then
    ci_die "PipeWire camera plugin still contains KDE or fixed-user rotation integration"
  fi
}

apply_tb321fu_legacy_cleanup() {
  local root=$1

  ci_log "removing legacy y700 sensor and haptics glue that conflicts with TB321FU packages"
  rm -f \
    "$root/etc/systemd/system/iio-sensor-proxy.service.d/10-y700-ssc.conf" \
    "$root/etc/systemd/system/y700-sns-init.service" \
    "$root/etc/systemd/system/y700-aw86937-haptics.service" \
    "$root/etc/udev/rules.d/90-y700-haptics.rules" \
    "$root/usr/local/libexec/y700-iio-sensor-proxy" \
    "$root/usr/local/sbin/y700-aw86937-bind"
  rm -rf \
    "$root/usr/local/lib/y700-sns" \
    "$root/usr/local/share/y700-sns"

  if [ -d "$root/etc/systemd/system/multi-user.target.wants" ]; then
    rm -f \
      "$root/etc/systemd/system/multi-user.target.wants/y700-sns-init.service" \
      "$root/etc/systemd/system/multi-user.target.wants/y700-aw86937-haptics.service"
  fi

  if [ -f "$root/usr/lib/systemd/system/qcom-sns-init.service" ]; then
    install -d -m 0755 "$root/etc/systemd/system/multi-user.target.wants"
    ln -sfn /usr/lib/systemd/system/qcom-sns-init.service \
      "$root/etc/systemd/system/multi-user.target.wants/qcom-sns-init.service"
  fi
  if [ -f "$root/usr/lib/systemd/system/tb321fu-haptics.service" ]; then
    install -d -m 0755 "$root/etc/systemd/system/multi-user.target.wants"
    ln -sfn /usr/lib/systemd/system/tb321fu-haptics.service \
      "$root/etc/systemd/system/multi-user.target.wants/tb321fu-haptics.service"
  fi

  if [ -x "$root/usr/libexec/iio-sensor-proxy" ]; then
    install -d -m 0755 "$root/usr/share/dbus-1/system-services"
    cat > "$root/usr/share/dbus-1/system-services/net.hadess.SensorProxy.service" <<'DBUS_SERVICE'
[D-BUS Service]
Name=net.hadess.SensorProxy
Exec=/usr/libexec/iio-sensor-proxy
User=root
SystemdService=iio-sensor-proxy.service
DBUS_SERVICE
    chmod 0644 "$root/usr/share/dbus-1/system-services/net.hadess.SensorProxy.service"
  fi
}

apply_tb321fu_camera_gnome_plugin() {
  local root=$1
  local camera_source=${TB321FU_CAMERA_PLUGIN_SOURCE:-"$SCRIPT_DIR/../../source/tb321fu-camera-rootfs-overlay/source/libcamera-source.cpp.clean-minimal-daily"}
  local archive="$work_dir/pipewire-${CAMERA_PIPEWIRE_VERSION}.tar.gz"
  local extract="$work_dir/pipewire-${CAMERA_PIPEWIRE_VERSION}-source"
  local pipewire_source
  local rootfs_src=/tmp/pipewire-y700-src
  local rootfs_build=/tmp/pipewire-y700-build
  local plugin_rel=usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so

  [ "$DESKTOP_FLAVOR" = gnome ] || ci_die "GNOME camera plugin rebuild requires DESKTOP_FLAVOR=gnome"
  [ -f "$camera_source" ] || ci_die "missing GNOME camera source: $camera_source"
  ci_log "rebuilding the TB321FU PipeWire camera plugin for GNOME/Mutter"

  rm -rf "$extract" "$root$rootfs_src" "$root$rootfs_build"
  mkdir -p "$extract" "$root$rootfs_src"
  ci_download "$CAMERA_PIPEWIRE_SOURCE_URL" "$archive"
  ci_extract_archive "$archive" "$extract"
  pipewire_source=$(find "$extract" -type f -name meson.build -path '*/spa/plugins/libcamera/meson.build' -print -quit)
  [ -n "$pipewire_source" ] || ci_die "PipeWire source archive is missing the libcamera plugin"
  pipewire_source=${pipewire_source%/spa/plugins/libcamera/meson.build}
  rsync -a --delete "$pipewire_source"/ "$root$rootfs_src"/
  install -m 0644 "$camera_source" "$root$rootfs_src/spa/plugins/libcamera/libcamera-source.cpp"
  cat > "$root$rootfs_src/spa/plugins/libcamera/meson.build" <<'MESON'
libcamera_sources = [
  'libcamera.c',
  'libcamera-manager.cpp',
  'libcamera-device.cpp',
  'libcamera-source.cpp'
]

gio_dep = dependency('gio-2.0')
libcameralib = shared_library('spa-libcamera',
  libcamera_sources,
  include_directories : [ configinc ],
  dependencies : [ spa_dep, libcamera_dep, pthread_lib, gio_dep ],
  install : true,
  install_dir : spa_plugindir / 'libcamera')
MESON

  cat > "$root/root/ci-build-tb321fu-camera-plugin.sh" <<'CAMERA_PLUGIN_BUILD'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [ -n "${APT_HTTP_PROXY:-}" ] || [ -n "${APT_HTTPS_PROXY:-}" ]; then
  mkdir -p /etc/apt/apt.conf.d
  : > /etc/apt/apt.conf.d/99ci-proxy
  [ -z "${APT_HTTP_PROXY:-}" ] || printf 'Acquire::http::Proxy "%s";\n' "$APT_HTTP_PROXY" >> /etc/apt/apt.conf.d/99ci-proxy
  [ -z "${APT_HTTPS_PROXY:-}" ] || printf 'Acquire::https::Proxy "%s";\n' "$APT_HTTPS_PROXY" >> /etc/apt/apt.conf.d/99ci-proxy
fi

src=/tmp/pipewire-y700-src
build=/tmp/pipewire-y700-build
plugin=/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so
build_deps="binutils build-essential meson ninja-build pkg-config libcamera-dev libglib2.0-dev"
new_build_deps=""
for pkg in $build_deps; do
  if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
    new_build_deps="$new_build_deps $pkg"
  fi
done

apt-get update
apt-get install -y --no-install-recommends $build_deps
meson setup "$build" "$src" \
  --buildtype=release \
  --prefix=/usr \
  -Ddocs=disabled \
  -Dman=disabled \
  -Dexamples=disabled \
  -Dtests=disabled \
  -Dinstalled_tests=disabled \
  -Ddbus=disabled \
  -Dgstreamer=disabled \
  -Dpipewire-alsa=disabled \
  -Dpipewire-jack=disabled \
  -Dpipewire-v4l2=disabled \
  -Dsystemd-user-service=disabled \
  -Dlibcamera=enabled
ninja -C "$build" spa/plugins/libcamera/libspa-libcamera.so
install -m 0644 "$build/spa/plugins/libcamera/libspa-libcamera.so" "$plugin"

strings -a "$plugin" | grep -q 'org.gnome.Mutter.DisplayConfig'
if strings -a "$plugin" | grep -Eq 'kscreen-doctor|kwinoutputconfig.json|/home/y700/.config|/run/user/1000'; then
  echo 'rebuilt camera plugin still contains KDE or fixed-user integration' >&2
  exit 1
fi
readelf -d "$plugin" | grep -q 'libgio-2.0.so'
readelf -d "$plugin" | grep -Eq 'libcamera\.so\.0\.7|libcamera\.so'
install -d -m 0755 /usr/share/tb321fu-camera-stack
sha256sum "$plugin" > /usr/share/tb321fu-camera-stack/libspa-libcamera.so.sha256

rm -rf "$src" "$build"
if [ -n "$new_build_deps" ]; then
  apt-get purge -y $new_build_deps
  apt-get autoremove -y --purge
fi
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /etc/apt/apt.conf.d/99ci-proxy
CAMERA_PLUGIN_BUILD
  chmod +x "$root/root/ci-build-tb321fu-camera-plugin.sh"

  local resolv_backup="$work_dir/camera-plugin-resolv.conf.original"
  local resolv_link="$work_dir/camera-plugin-resolv.conf.link"
  rm -f "$resolv_backup" "$resolv_link"
  if [ -L "$root/etc/resolv.conf" ]; then
    readlink "$root/etc/resolv.conf" > "$resolv_link"
  elif [ -e "$root/etc/resolv.conf" ]; then
    cp -a "$root/etc/resolv.conf" "$resolv_backup"
  fi
  rm -f "$root/etc/resolv.conf"
  if [ -n "$RESOLV_CONF_CONTENT" ]; then
    printf '%s\n' "$RESOLV_CONF_CONTENT" > "$root/etc/resolv.conf"
  elif [ -f /run/systemd/resolve/resolv.conf ]; then
    cp /run/systemd/resolve/resolv.conf "$root/etc/resolv.conf"
  else
    cp /etc/resolv.conf "$root/etc/resolv.conf"
  fi

  chroot "$root" env -i \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/root \
    LANG=C.UTF-8 \
    APT_HTTP_PROXY="$APT_HTTP_PROXY" \
    APT_HTTPS_PROXY="$APT_HTTPS_PROXY" \
    http_proxy="$APT_HTTP_PROXY" \
    https_proxy="$APT_HTTPS_PROXY" \
    HTTP_PROXY="$APT_HTTP_PROXY" \
    HTTPS_PROXY="$APT_HTTPS_PROXY" \
    bash /root/ci-build-tb321fu-camera-plugin.sh

  rm -f "$root/etc/resolv.conf"
  if [ -f "$resolv_link" ]; then
    ln -s "$(cat "$resolv_link")" "$root/etc/resolv.conf"
  elif [ -f "$resolv_backup" ]; then
    cp -a "$resolv_backup" "$root/etc/resolv.conf"
  else
    ln -s ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
  fi
  rm -f "$root/root/ci-build-tb321fu-camera-plugin.sh"

  [ -f "$root/$plugin_rel" ] || ci_die "rebuilt GNOME camera plugin is missing: /$plugin_rel"
  strings -a "$root/$plugin_rel" | grep -q 'org.gnome.Mutter.DisplayConfig' || \
    ci_die "rebuilt camera plugin is missing Mutter integration"
}

apply_tb321fu_gpu_sensor() {
  local root=$1
  local source_dir=${TB321FU_GPU_SENSOR_SOURCE_DIR:-"$SCRIPT_DIR/../../source/tb321fu-ksystemstats-adreno-freq"}
  local rootfs_src=/tmp/tb321fu-ksystemstats-adreno-freq-src
  local rootfs_build=/tmp/tb321fu-ksystemstats-adreno-freq-build
  local plugin_rel=usr/lib/aarch64-linux-gnu/qt6/plugins/ksystemstats/ksystemstats_plugin_tb321fu_gpu.so
  local stock_plugin_rel=usr/lib/aarch64-linux-gnu/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so
  local disabled_stock_plugin_rel=$stock_plugin_rel.disabled-tb321fu-adreno

  ci_log "building TB321FU KSystemStats Adreno GPU frequency plugin"

  [ -f "$source_dir/CMakeLists.txt" ] || ci_die "missing TB321FU GPU sensor source: $source_dir/CMakeLists.txt"
  [ -f "$source_dir/tb321fu_gpu.cpp" ] || ci_die "missing TB321FU GPU sensor source: $source_dir/tb321fu_gpu.cpp"
  [ -f "$source_dir/metadata.json" ] || ci_die "missing TB321FU GPU sensor source: $source_dir/metadata.json"

  rm -rf "$root$rootfs_src" "$root$rootfs_build"
  install -d -m 0755 "$root$rootfs_src"
  rsync -a --delete "$source_dir"/ "$root$rootfs_src"/

  cat > "$root/root/ci-build-tb321fu-gpu-sensor.sh" <<'GPU_SENSOR_BUILD'
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

ci_bool_chroot()
{
  case "${1:-}" in
    1|yes|true|on) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -n "${APT_HTTP_PROXY:-}" ] || [ -n "${APT_HTTPS_PROXY:-}" ]; then
  mkdir -p /etc/apt/apt.conf.d
  : > /etc/apt/apt.conf.d/99ci-proxy
  if [ -n "${APT_HTTP_PROXY:-}" ]; then
    printf 'Acquire::http::Proxy "%s";\n' "$APT_HTTP_PROXY" >> /etc/apt/apt.conf.d/99ci-proxy
  fi
  if [ -n "${APT_HTTPS_PROXY:-}" ]; then
    printf 'Acquire::https::Proxy "%s";\n' "$APT_HTTPS_PROXY" >> /etc/apt/apt.conf.d/99ci-proxy
  fi
fi

src=/tmp/tb321fu-ksystemstats-adreno-freq-src
build=/tmp/tb321fu-ksystemstats-adreno-freq-build
plugin=/usr/lib/aarch64-linux-gnu/qt6/plugins/ksystemstats/ksystemstats_plugin_tb321fu_gpu.so
stock=/usr/lib/aarch64-linux-gnu/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so
disabled=/usr/lib/aarch64-linux-gnu/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so.disabled-tb321fu-adreno
build_deps="cmake extra-cmake-modules g++ make libksysguard-dev libkf6coreaddons-dev libsensors-dev"

new_build_deps=""
for pkg in $build_deps; do
  if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
    :
  else
    new_build_deps="$new_build_deps $pkg"
  fi
done

apt-get update
apt-get install -y --no-install-recommends $build_deps

cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/usr
cmake --build "$build" -j"${TB321FU_GPU_SENSOR_BUILD_JOBS:-2}"
cmake --install "$build"

test -f "$plugin"
if [ -f "$stock" ]; then
  rm -f "$disabled"
  mv "$stock" "$disabled"
fi
test ! -e "$stock"

install -d -m 0755 /usr/share/tb321fu-ksystemstats-gpu
sha256sum "$plugin" > /usr/share/tb321fu-ksystemstats-gpu/ksystemstats_plugin_tb321fu_gpu.so.sha256

rm -rf "$src" "$build"

if [ -n "$new_build_deps" ]; then
  apt-get purge -y $new_build_deps
  apt-get autoremove -y --purge
fi
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /etc/apt/apt.conf.d/99ci-proxy

test -f "$plugin"
test ! -e "$stock"
test ! -e "$src"
test ! -e "$build"
GPU_SENSOR_BUILD
  chmod +x "$root/root/ci-build-tb321fu-gpu-sensor.sh"

  local gpu_resolv_backup="$work_dir/gpu-sensor-resolv.conf.original"
  local gpu_resolv_link="$work_dir/gpu-sensor-resolv.conf.link"
  rm -f "$gpu_resolv_backup" "$gpu_resolv_link"
  if [ -L "$root/etc/resolv.conf" ]; then
    readlink "$root/etc/resolv.conf" > "$gpu_resolv_link"
  elif [ -e "$root/etc/resolv.conf" ]; then
    cp -a "$root/etc/resolv.conf" "$gpu_resolv_backup"
  fi
  rm -f "$root/etc/resolv.conf"
  if [ -n "$RESOLV_CONF_CONTENT" ]; then
    printf '%s\n' "$RESOLV_CONF_CONTENT" > "$root/etc/resolv.conf"
  elif [ -f /run/systemd/resolve/resolv.conf ]; then
    cp /run/systemd/resolve/resolv.conf "$root/etc/resolv.conf"
  else
    cp /etc/resolv.conf "$root/etc/resolv.conf"
  fi

  chroot "$root" env -i \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/root \
    LANG=C.UTF-8 \
    APT_HTTP_PROXY="$APT_HTTP_PROXY" \
    APT_HTTPS_PROXY="$APT_HTTPS_PROXY" \
    http_proxy="$APT_HTTP_PROXY" \
    https_proxy="$APT_HTTPS_PROXY" \
    HTTP_PROXY="$APT_HTTP_PROXY" \
    HTTPS_PROXY="$APT_HTTPS_PROXY" \
    TB321FU_GPU_SENSOR_BUILD_JOBS="${TB321FU_GPU_SENSOR_BUILD_JOBS:-2}" \
    bash /root/ci-build-tb321fu-gpu-sensor.sh

  rm -f "$root/etc/resolv.conf"
  if [ -f "$gpu_resolv_link" ]; then
    ln -s "$(cat "$gpu_resolv_link")" "$root/etc/resolv.conf"
  elif [ -f "$gpu_resolv_backup" ]; then
    cp -a "$gpu_resolv_backup" "$root/etc/resolv.conf"
  else
    ln -s ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
  fi

  rm -f "$root/root/ci-build-tb321fu-gpu-sensor.sh"
  [ -f "$root/$plugin_rel" ] || ci_die "TB321FU GPU sensor plugin missing after build: /$plugin_rel"
  [ ! -e "$root/$stock_plugin_rel" ] || ci_die "stock KSystemStats GPU plugin still enabled: /$stock_plugin_rel"
  [ -f "$root/$disabled_stock_plugin_rel" ] || ci_die "disabled stock KSystemStats GPU plugin missing: /$disabled_stock_plugin_rel"
}

cleanup() {
  set +e
  if [ "$mounted" = 1 ]; then
    for p in dev/pts dev proc sys run; do
      mountpoint -q "$rootfs_dir/$p" && umount -l "$rootfs_dir/$p"
    done
    mountpoint -q "$rootfs_dir" && umount "$rootfs_dir"
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

ci_log "creating ext4 image: $rootfs_img"
rm -f "$rootfs_img"
truncate -s "$ROOTFS_IMAGE_SIZE" "$rootfs_img"
mkfs_args=(-F -L "$ROOTFS_LABEL")
if [ -n "${ROOTFS_UUID:-}" ]; then
  mkfs_args+=(-U "$ROOTFS_UUID")
fi
mkfs.ext4 "${mkfs_args[@]}" "$rootfs_img"

mkdir -p "$rootfs_dir"
mount -o loop "$rootfs_img" "$rootfs_dir"
mounted=1

ci_log "debootstrap $DISTRO/$ARCH from $MIRROR"
debootstrap_args=(--arch="$ARCH")
if [ -n "$DEBOOTSTRAP_VARIANT" ]; then
  debootstrap_args+=(--variant="$DEBOOTSTRAP_VARIANT")
fi
debootstrap "${debootstrap_args[@]}" "$DISTRO" "$rootfs_dir" "$MIRROR"

if [ -n "${APT_SOURCES_LIST:-}" ]; then
  printf '%s\n' "$APT_SOURCES_LIST" > "$rootfs_dir/etc/apt/sources.list"
else
  cat > "$rootfs_dir/etc/apt/sources.list" <<APT
deb $MIRROR $DISTRO main restricted universe multiverse
deb $MIRROR $DISTRO-updates main restricted universe multiverse
deb $MIRROR $DISTRO-backports main restricted universe multiverse
deb $MIRROR $DISTRO-security main restricted universe multiverse
APT
fi

printf '%s\n' "$HOSTNAME_NAME" > "$rootfs_dir/etc/hostname"
touch "$rootfs_dir/etc/hosts"
sed -i '/^127\.0\.1\.1\b/d' "$rootfs_dir/etc/hosts"
printf '127.0.1.1 %s\n' "$HOSTNAME_NAME" >> "$rootfs_dir/etc/hosts"
original_resolv="$work_dir/resolv.conf.original"
original_resolv_link="$work_dir/resolv.conf.link"
if [ -L "$rootfs_dir/etc/resolv.conf" ]; then
  readlink "$rootfs_dir/etc/resolv.conf" > "$original_resolv_link"
elif [ -e "$rootfs_dir/etc/resolv.conf" ]; then
  cp -a "$rootfs_dir/etc/resolv.conf" "$original_resolv"
fi
rm -f "$rootfs_dir/etc/resolv.conf"
if [ -n "$RESOLV_CONF_CONTENT" ]; then
  printf '%s\n' "$RESOLV_CONF_CONTENT" > "$rootfs_dir/etc/resolv.conf"
elif [ -f /run/systemd/resolve/resolv.conf ]; then
  cp /run/systemd/resolve/resolv.conf "$rootfs_dir/etc/resolv.conf"
else
  cp /etc/resolv.conf "$rootfs_dir/etc/resolv.conf"
fi
if ! awk '
  /^[[:space:]]*nameserver[[:space:]]+/ {
    ns=$2
    if (ns !~ /^(127\.|::1$|0\.0\.0\.0$)/) good=1
  }
  END { exit good ? 0 : 1 }
' "$rootfs_dir/etc/resolv.conf"; then
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$rootfs_dir/etc/resolv.conf"
fi

mount --bind /dev "$rootfs_dir/dev"
mount --bind /dev/pts "$rootfs_dir/dev/pts"
mount -t proc proc "$rootfs_dir/proc"
mount -t sysfs sysfs "$rootfs_dir/sys"
mount -t tmpfs tmpfs "$rootfs_dir/run"

cat > "$rootfs_dir/root/ci-provision.sh" <<'PROVISION'
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

ci_bool_chroot()
{
  case "${1:-}" in
    1|yes|true|on) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -n "${APT_HTTP_PROXY:-}" ] || [ -n "${APT_HTTPS_PROXY:-}" ]; then
  mkdir -p /etc/apt/apt.conf.d
  : > /etc/apt/apt.conf.d/99ci-proxy
  if [ -n "${APT_HTTP_PROXY:-}" ]; then
    printf 'Acquire::http::Proxy "%s";\n' "$APT_HTTP_PROXY" >> /etc/apt/apt.conf.d/99ci-proxy
  fi
  if [ -n "${APT_HTTPS_PROXY:-}" ]; then
    printf 'Acquire::https::Proxy "%s";\n' "$APT_HTTPS_PROXY" >> /etc/apt/apt.conf.d/99ci-proxy
  fi
fi

apt-get update
apt-get install -y $PACKAGE_LIST

if ci_bool_chroot "$INSTALL_FIREFOX"; then
  firefox_version=$(dpkg-query -W -f='${Version}' firefox 2>/dev/null || true)
  [ -n "$firefox_version" ] || { echo 'firefox package was not installed' >&2; exit 1; }
  case "$firefox_version" in
    *snap*) echo "refusing snap transition Firefox package version: $firefox_version" >&2; exit 1 ;;
  esac
fi

if ci_bool_chroot "$INSTALL_IBUS_CHINESE"; then
  for pkg in ibus ibus-libpinyin im-config fonts-noto-cjk; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || {
      echo "required IBus Chinese input package missing: $pkg" >&2
      exit 1
    }
  done

  install -d -m 0755 \
    /etc/dconf/profile \
    /etc/dconf/db/local.d \
    /etc/skel

  cat > /etc/dconf/profile/user <<'DCONF_PROFILE'
user-db:user
system-db:local
DCONF_PROFILE
  cat > /etc/dconf/db/local.d/00-y700-gnome <<'GNOME_DEFAULTS'
[org/gnome/desktop/input-sources]
sources=[('xkb', 'us'), ('ibus', 'libpinyin')]
mru-sources=[('ibus', 'libpinyin'), ('xkb', 'us')]

[org/gnome/desktop/a11y/applications]
screen-keyboard-enabled=true

[org/gnome/settings-daemon/peripherals/touchscreen]
orientation-lock=false
GNOME_DEFAULTS
  chmod 0644 /etc/dconf/profile/user /etc/dconf/db/local.d/00-y700-gnome
  dconf update
  cat > /etc/skel/.xinputrc <<'IBUS_XINPUT'
run_im ibus
IBUS_XINPUT
  chmod 0644 /etc/skel/.xinputrc
fi

systemctl enable NetworkManager || true
systemctl enable ssh || true

if ! id -u "$DEFAULT_USER_NAME" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$DEFAULT_USER_NAME"
fi
printf '%s:%s\n' "$DEFAULT_USER_NAME" "$DEFAULT_USER_PASSWORD" | chpasswd

default_user_group=$(id -gn "$DEFAULT_USER_NAME")
if ci_bool_chroot "$INSTALL_IBUS_CHINESE" && [ -d "/home/$DEFAULT_USER_NAME" ]; then
  cp -a /etc/skel/.xinputrc "/home/$DEFAULT_USER_NAME/.xinputrc"
  chown "$DEFAULT_USER_NAME:$default_user_group" "/home/$DEFAULT_USER_NAME/.xinputrc"
fi

case "$ROOT_PASSWORD_MODE" in
  locked)
    passwd -l root || true
    ;;
  set)
    [ -n "$ROOT_PASSWORD" ] || { echo 'ROOT_PASSWORD_MODE=set requires ROOT_PASSWORD' >&2; exit 1; }
    printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
    ;;
  empty)
    passwd -d root || true
    ;;
  *)
    echo "unsupported ROOT_PASSWORD_MODE=$ROOT_PASSWORD_MODE" >&2
    exit 1
    ;;
esac

case "$USER_SUDO_MODE" in
  password)
    usermod -aG sudo "$DEFAULT_USER_NAME"
    rm -f "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    ;;
  nopasswd)
    usermod -aG sudo "$DEFAULT_USER_NAME"
    mkdir -p /etc/sudoers.d
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$DEFAULT_USER_NAME" > "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    chmod 0440 "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    visudo -cf "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    ;;
  none)
    gpasswd -d "$DEFAULT_USER_NAME" sudo >/dev/null 2>&1 || true
    rm -f "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    ;;
  *)
    echo "unsupported USER_SUDO_MODE=$USER_SUDO_MODE" >&2
    exit 1
    ;;
esac

if [ -n "$TZ_REGION" ] && [ -f "/usr/share/zoneinfo/$TZ_REGION" ]; then
  ln -sf "/usr/share/zoneinfo/$TZ_REGION" /etc/localtime
  dpkg-reconfigure -f noninteractive tzdata || true
fi

while IFS= read -r locale_line; do
  [ -n "$locale_line" ] || continue
  sed -i "s/^# *\($locale_line\)/\1/" /etc/locale.gen || true
done <<LOCALES_EOF
$LOCALES
LOCALES_EOF
locale-gen || true
update-locale LANG="$LANG_NAME" || true

if compgen -G "/var/tmp/ci-debs/*.deb" >/dev/null; then
  dpkg -i --force-overwrite /var/tmp/ci-debs/*.deb || apt-get -f install -y
fi

for ci_overlay in /var/tmp/ci-debs/*.tar /var/tmp/ci-debs/*.tar.gz /var/tmp/ci-debs/*.tgz /var/tmp/ci-debs/*.tar.xz /var/tmp/ci-debs/*.tar.zst; do
  [ -e "$ci_overlay" ] || continue
  case "$ci_overlay" in
    *.tar) tar -C / -xf "$ci_overlay" ;;
    *.tar.gz|*.tgz) tar -C / -xzf "$ci_overlay" ;;
    *.tar.xz) tar -C / -xJf "$ci_overlay" ;;
    *.tar.zst) tar -C / --zstd -xf "$ci_overlay" ;;
  esac
done

if ci_bool_chroot "$DISABLE_SNAPD"; then
  apt-get purge -y snapd plasma-discover-backend-snap || true
  apt-get autoremove -y --purge || true
  rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd
  if dpkg-query -W -f='${Status}' snapd 2>/dev/null | grep -q 'install ok installed'; then
    echo 'snapd is still installed despite DISABLE_SNAPD=1' >&2
    exit 1
  fi
else
  for pkg in snapd apparmor gnome-software-plugin-snap; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || {
      echo "required Snap integration package missing: $pkg" >&2
      exit 1
    }
  done
  systemctl enable snapd.socket
  systemctl enable apparmor.service
fi

if [ "$CLEAN_APT_CACHE" = 1 ]; then
  apt-get clean
  rm -rf /var/lib/apt/lists/*
fi
rm -f /etc/apt/apt.conf.d/99ci-proxy

rm -f /etc/machine-id
touch /etc/machine-id
rm -f /root/.bash_history "/home/${DEFAULT_USER_NAME}/.bash_history"
rm -rf /tmp/* /var/tmp/ci-debs /root/ci-provision.sh
PROVISION
chmod +x "$rootfs_dir/root/ci-provision.sh"

if [ -n "${DEB_ARCHIVE:-}" ]; then
  tmp_archive="$work_dir/debs.archive"
  mkdir -p "$rootfs_dir/var/tmp/ci-debs"
  ci_download "$DEB_ARCHIVE" "$tmp_archive"
  ci_extract_archive "$tmp_archive" "$rootfs_dir/var/tmp/ci-debs"
fi
if [ -n "${DEB_DIR:-}" ]; then
  mkdir -p "$rootfs_dir/var/tmp/ci-debs"
  find "$DEB_DIR" -maxdepth 1 -type f -name '*.deb' -exec cp -a {} "$rootfs_dir/var/tmp/ci-debs/" \;
fi
if [ -n "${SENSOR_DEB_ARCHIVE:-}" ]; then
  include_deb_archive sensor "$SENSOR_DEB_ARCHIVE"
fi
if [ -n "${SENSOR_DEB_DIR:-}" ]; then
  mkdir -p "$rootfs_dir/var/tmp/ci-debs"
  ci_log "including source-built sensor debs from: $SENSOR_DEB_DIR"
  find "$SENSOR_DEB_DIR" -maxdepth 1 -type f -name '*.deb' -exec cp -a {} "$rootfs_dir/var/tmp/ci-debs/" \;
fi
if [ -n "${HAPTICS_DEB_ARCHIVE:-}" ]; then
  include_deb_archive haptics "$HAPTICS_DEB_ARCHIVE"
fi
if [ -n "${HAPTICS_DEB_DIR:-}" ]; then
  mkdir -p "$rootfs_dir/var/tmp/ci-debs"
  ci_log "including source-built haptics debs from: $HAPTICS_DEB_DIR"
  find "$HAPTICS_DEB_DIR" -maxdepth 1 -type f -name '*.deb' -exec cp -a {} "$rootfs_dir/var/tmp/ci-debs/" \;
fi
if [ -n "${CAMERA_STACK_DEB_DIR:-}" ]; then
  mkdir -p "$rootfs_dir/var/tmp/ci-debs"
  ci_log "including source-built camera stack debs from: $CAMERA_STACK_DEB_DIR"
  find "$CAMERA_STACK_DEB_DIR" -maxdepth 1 -type f -name '*.deb' -exec cp -a {} "$rootfs_dir/var/tmp/ci-debs/" \;
fi

if ci_bool "$INSTALL_FIREFOX"; then
  configure_mozilla_firefox_repo "$rootfs_dir"
fi

ci_log "provisioning rootfs"
chroot "$rootfs_dir" env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root \
  LANG=C.UTF-8 \
  PACKAGE_LIST="$PACKAGE_LIST" \
  INSTALL_IBUS_CHINESE="$INSTALL_IBUS_CHINESE" \
  DESKTOP_FLAVOR="$DESKTOP_FLAVOR" \
  DEFAULT_USER_NAME="$DEFAULT_USER_NAME" \
  DEFAULT_USER_PASSWORD="$DEFAULT_USER_PASSWORD" \
  ROOT_PASSWORD_MODE="$ROOT_PASSWORD_MODE" \
  ROOT_PASSWORD="$ROOT_PASSWORD" \
  USER_SUDO_MODE="$USER_SUDO_MODE" \
  INSTALL_FIREFOX="$INSTALL_FIREFOX" \
  DISABLE_SNAPD="$DISABLE_SNAPD" \
  TZ_REGION="$TZ_REGION" \
  LOCALES="$LOCALES" \
  LANG_NAME="$LANG_NAME" \
  APT_HTTP_PROXY="$APT_HTTP_PROXY" \
  APT_HTTPS_PROXY="$APT_HTTPS_PROXY" \
  http_proxy="$APT_HTTP_PROXY" \
  https_proxy="$APT_HTTPS_PROXY" \
  HTTP_PROXY="$APT_HTTP_PROXY" \
  HTTPS_PROXY="$APT_HTTPS_PROXY" \
  CLEAN_APT_CACHE="$CLEAN_APT_CACHE" \
  bash /root/ci-provision.sh

rm -f "$rootfs_dir/etc/resolv.conf"
if [ -f "$original_resolv_link" ]; then
  ln -s "$(cat "$original_resolv_link")" "$rootfs_dir/etc/resolv.conf"
elif [ -f "$original_resolv" ]; then
  cp -a "$original_resolv" "$rootfs_dir/etc/resolv.conf"
else
  ln -s ../run/systemd/resolve/stub-resolv.conf "$rootfs_dir/etc/resolv.conf"
fi

if [ -n "${OVERLAY_ARCHIVE:-}" ]; then
  tmp_overlay="$work_dir/overlay.archive"
  ci_log "applying overlay archive: $OVERLAY_ARCHIVE"
  ci_download "$OVERLAY_ARCHIVE" "$tmp_overlay"
  ci_extract_archive "$tmp_overlay" "$rootfs_dir"
fi
if [ -n "${OVERLAY_DIR:-}" ]; then
  ci_log "applying overlay directory: $OVERLAY_DIR"
  rsync -aH --numeric-ids "$OVERLAY_DIR"/ "$rootfs_dir"/
fi

apply_desktop_manager_config "$rootfs_dir"
apply_tb321fu_legacy_cleanup "$rootfs_dir"

if ci_bool "$APPLY_Y700_FIRMWARE_FIXES"; then
  apply_y700_firmware_fixes "$rootfs_dir"
fi
if ci_bool "$APPLY_Y700_AUDIO_POLICY_FIXES"; then
  apply_y700_audio_policy_fixes "$rootfs_dir"
fi
if ci_bool "$REBUILD_TB321FU_CAMERA_GNOME_PLUGIN"; then
  apply_tb321fu_camera_gnome_plugin "$rootfs_dir"
fi
if ci_bool "$BUILD_TB321FU_GPU_SENSOR"; then
  apply_tb321fu_gpu_sensor "$rootfs_dir"
fi
apply_gnome_desktop_cleanup "$rootfs_dir"

cat > "$build_info" <<INFO
generated=$(date -u -Iseconds)
distro=$DISTRO
arch=$ARCH
debootstrap_variant=$DEBOOTSTRAP_VARIANT
mirror=$MIRROR
hostname=$HOSTNAME_NAME
default_user=$DEFAULT_USER_NAME
root_password_mode=$ROOT_PASSWORD_MODE
user_sudo_mode=$USER_SUDO_MODE
desktop_flavor=$DESKTOP_FLAVOR
display_manager=$DISPLAY_MANAGER
desktop_autologin=$DESKTOP_AUTOLOGIN
desktop_session=$DESKTOP_SESSION
rootfs_label=$ROOTFS_LABEL
rootfs_uuid=${ROOTFS_UUID:-}
rootfs_partlabel=$ROOTFS_PARTLABEL
overlay_archive=${OVERLAY_ARCHIVE:-}
overlay_dir=${OVERLAY_DIR:-}
deb_archive=${DEB_ARCHIVE:-}
deb_dir=${DEB_DIR:-}
sensor_deb_archive=${SENSOR_DEB_ARCHIVE:-}
sensor_deb_dir=${SENSOR_DEB_DIR:-}
haptics_deb_archive=${HAPTICS_DEB_ARCHIVE:-}
haptics_deb_dir=${HAPTICS_DEB_DIR:-}
camera_stack_deb_dir=${CAMERA_STACK_DEB_DIR:-}
build_tb321fu_gpu_sensor=$BUILD_TB321FU_GPU_SENSOR
tb321fu_gpu_sensor_source_dir=${TB321FU_GPU_SENSOR_SOURCE_DIR:-repo-default}
install_gnome_snapshot=$INSTALL_GNOME_SNAPSHOT
install_firefox=$INSTALL_FIREFOX
install_ibus_chinese=$INSTALL_IBUS_CHINESE
disable_snapd=$DISABLE_SNAPD
rebuild_tb321fu_camera_gnome_plugin=$REBUILD_TB321FU_CAMERA_GNOME_PLUGIN
camera_pipewire_version=$CAMERA_PIPEWIRE_VERSION
apply_y700_firmware_fixes=$APPLY_Y700_FIRMWARE_FIXES
apply_y700_audio_policy_fixes=$APPLY_Y700_AUDIO_POLICY_FIXES
INFO

rm -f \
  "$rootfs_dir/BUILD-INFO.txt" \
  "$rootfs_dir/SHA256SUMS" \
  "$rootfs_dir/SHA256SUMS.txt" \
  "$rootfs_dir/Y700-ROOTFS-OVERLAY-MANIFEST.tsv"

ci_log "writing manifest"
(cd "$rootfs_dir" && find . -xdev -printf '%y\t%u\t%g\t%m\t%s\t%p\n' | sort) > "$manifest"

for p in dev/pts dev proc sys run; do
  mountpoint -q "$rootfs_dir/$p" && umount -l "$rootfs_dir/$p"
done
umount "$rootfs_dir"
mounted=0
e2fsck -f -y "$rootfs_img"

ci_log "checksumming rootfs image"
raw_sha_file="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.raw.sha256"
(cd "$OUTPUT_DIR" && sha256sum "$(basename "$rootfs_img")" > "$(basename "$raw_sha_file")")

checksum_file="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.SHA256SUMS"
rm -f "$checksum_file"
(cd "$OUTPUT_DIR" && sha256sum "$(basename "$build_info")" "$(basename "$manifest")" "$(basename "$raw_sha_file")" > "$(basename "$checksum_file")")

case "$COMPRESS" in
  none)
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$rootfs_img")" >> "$(basename "$checksum_file")")
    ;;
  zstd)
    ci_require_cmd zstd
    zstd -T0 -19 -f "$rootfs_img" -o "$rootfs_img.zst"
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$rootfs_img").zst" >> "$(basename "$checksum_file")")
    ;;
  xz)
    xz -T0 -k -f "$rootfs_img"
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$rootfs_img").xz" >> "$(basename "$checksum_file")")
    ;;
  7z)
    ci_require_cmd 7z
    sevenz_out="$rootfs_img.7z"
    rm -f "$sevenz_out" "$sevenz_out".*
    if [ -n "${CHUNK_SIZE:-}" ]; then
      7z a "$sevenz_out" "$rootfs_img" -t7z -m0=lzma2 -mx=9 -mmt=on "-v$CHUNK_SIZE" >/dev/null
      (cd "$OUTPUT_DIR" && sha256sum "$(basename "$sevenz_out")".* >> "$(basename "$checksum_file")")
    else
      7z a "$sevenz_out" "$rootfs_img" -t7z -m0=lzma2 -mx=9 -mmt=on >/dev/null
      (cd "$OUTPUT_DIR" && sha256sum "$(basename "$sevenz_out")" >> "$(basename "$checksum_file")")
    fi
    ;;
  *) ci_die "unsupported COMPRESS=$COMPRESS" ;;
esac

if [ "$COMPRESS" != none ] && [ "$KEEP_RAW_IMAGE" != 1 ]; then
  rm -f "$rootfs_img"
fi

ci_log "rootfs build complete: $OUTPUT_DIR"
