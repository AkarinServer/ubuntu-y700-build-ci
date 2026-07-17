#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Build Lenovo TB321FU kernel artifacts with the kernel features required by Snap
and Waydroid.

Environment inputs:
  OUTPUT_DIR                    default: out/y700-kernel-artifacts
  KERNEL_SOURCE_REPOSITORY      default: https://github.com/GUF296/linux.git
  KERNEL_SOURCE_REF             default: 5df8e852ea722929f5359a5ef28ebcec0c4443fd
  KERNEL_BASE_CONFIG_ARCHIVE    required URL/path containing kernel.config
  KERNEL_BUILD_JOBS             default: number of online processors
  CROSS_COMPILE                 default: aarch64-linux-gnu-
  DTB_NAME                      default: sm8650-lenovo-tb321fu.dtb

The base configuration is preserved except for enabling the AppArmor and
SquashFS features required by Snap, plus Binder, BinderFS, memfd, namespaces,
cgroups, and PSI for Waydroid containers.
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

for cmd in git make tar sha256sum sed grep nproc find install date; do
  ci_require_cmd "$cmd"
done

OUTPUT_DIR=${OUTPUT_DIR:-out/y700-kernel-artifacts}
KERNEL_SOURCE_REPOSITORY=${KERNEL_SOURCE_REPOSITORY:-https://github.com/GUF296/linux.git}
KERNEL_SOURCE_REF=${KERNEL_SOURCE_REF:-5df8e852ea722929f5359a5ef28ebcec0c4443fd}
KERNEL_BASE_CONFIG_ARCHIVE=${KERNEL_BASE_CONFIG_ARCHIVE:-}
KERNEL_BUILD_JOBS=${KERNEL_BUILD_JOBS:-$(nproc)}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
DTB_NAME=${DTB_NAME:-sm8650-lenovo-tb321fu.dtb}

[ -n "$KERNEL_BASE_CONFIG_ARCHIVE" ] || ci_die "KERNEL_BASE_CONFIG_ARCHIVE is required"
case "$KERNEL_BUILD_JOBS" in
  ''|*[!0-9]*) ci_die "KERNEL_BUILD_JOBS must be a positive integer" ;;
  0) ci_die "KERNEL_BUILD_JOBS must be greater than zero" ;;
esac

ci_require_cmd "${CROSS_COMPILE}gcc"
ci_require_cmd "${CROSS_COMPILE}ld"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(ci_abs_path "$OUTPUT_DIR")
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/y700-kernel-build.XXXXXX")
source_dir="$work_dir/linux"
build_dir="$work_dir/build"
base_config_dir="$work_dir/base-config"
payload_dir="$work_dir/payload"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

ci_log "fetching kernel source $KERNEL_SOURCE_REPOSITORY at $KERNEL_SOURCE_REF"
git init -q "$source_dir"
git -C "$source_dir" remote add origin "$KERNEL_SOURCE_REPOSITORY"
ci_retry 4 10 git -C "$source_dir" fetch --depth 1 origin "$KERNEL_SOURCE_REF"
git -C "$source_dir" -c advice.detachedHead=false checkout -q FETCH_HEAD

resolved_ref=$(git -C "$source_dir" rev-parse HEAD)
if printf '%s\n' "$KERNEL_SOURCE_REF" | grep -Eq '^[0-9a-fA-F]{40}$'; then
  [ "$resolved_ref" = "$KERNEL_SOURCE_REF" ] || ci_die "resolved kernel commit $resolved_ref does not match requested $KERNEL_SOURCE_REF"
fi
[ -f "$source_dir/arch/arm64/boot/dts/qcom/${DTB_NAME%.dtb}.dts" ] || ci_die "kernel source does not contain the TB321FU device tree"

base_archive="$work_dir/base-kernel-artifacts.archive"
ci_download "$KERNEL_BASE_CONFIG_ARCHIVE" "$base_archive"
ci_extract_archive "$base_archive" "$base_config_dir"
base_config=$(find "$base_config_dir" -type f -name kernel.config -print -quit)
[ -n "$base_config" ] || ci_die "base kernel artifact does not contain kernel.config"

mkdir -p "$build_dir"
cp -a "$base_config" "$build_dir/.config"

lsm_list=$(sed -n 's/^CONFIG_LSM="\(.*\)"$/\1/p' "$build_dir/.config" | head -n1)
[ -n "$lsm_list" ] || ci_die "base kernel config does not define CONFIG_LSM"
case ",$lsm_list," in
  *,apparmor,*) ;;
  *,bpf,*) lsm_list=${lsm_list%,bpf},apparmor,bpf ;;
  *) lsm_list=$lsm_list,apparmor ;;
esac

"$source_dir/scripts/config" --file "$build_dir/.config" \
  --enable ANDROID_BINDER_IPC \
  --enable ANDROID_BINDERFS \
  --set-str ANDROID_BINDER_DEVICES "binder,hwbinder,vndbinder" \
  --enable MEMFD_CREATE \
  --enable NAMESPACES \
  --enable UTS_NS \
  --enable IPC_NS \
  --enable USER_NS \
  --enable PID_NS \
  --enable NET_NS \
  --enable CGROUPS \
  --enable PSI \
  --enable SECURITY_APPARMOR \
  --enable SQUASHFS \
  --enable SQUASHFS_XATTR \
  --enable SQUASHFS_XZ \
  --enable SQUASHFS_ZSTD \
  --enable SQUASHFS_LZO \
  --set-str LSM "$lsm_list"

commit_epoch=$(git -C "$source_dir" show -s --format=%ct HEAD)
export SOURCE_DATE_EPOCH=$commit_epoch
export KBUILD_BUILD_TIMESTAMP="$(date -u -d "@$commit_epoch" '+%a %b %d %T UTC %Y')"
export KBUILD_BUILD_USER=github-actions
export KBUILD_BUILD_HOST=ubuntu-y700-build-ci

make_args=(
  -C "$source_dir"
  O="$build_dir"
  ARCH=arm64
  CROSS_COMPILE="$CROSS_COMPILE"
)

ci_log "normalizing kernel configuration"
make "${make_args[@]}" olddefconfig

grep -qx 'CONFIG_ANDROID_BINDER_IPC=y' "$build_dir/.config" || ci_die "Android Binder IPC was not enabled by Kconfig"
grep -qx 'CONFIG_ANDROID_BINDERFS=y' "$build_dir/.config" || ci_die "Android BinderFS was not enabled by Kconfig"
grep -qx 'CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"' "$build_dir/.config" || ci_die "Android Binder device list is incorrect"
grep -qx 'CONFIG_MEMFD_CREATE=y' "$build_dir/.config" || ci_die "memfd_create support was not enabled"
grep -qx 'CONFIG_NAMESPACES=y' "$build_dir/.config" || ci_die "namespace support was not enabled"
grep -qx 'CONFIG_UTS_NS=y' "$build_dir/.config" || ci_die "UTS namespace support was not enabled"
grep -qx 'CONFIG_IPC_NS=y' "$build_dir/.config" || ci_die "IPC namespace support was not enabled"
grep -qx 'CONFIG_USER_NS=y' "$build_dir/.config" || ci_die "user namespace support was not enabled"
grep -qx 'CONFIG_PID_NS=y' "$build_dir/.config" || ci_die "PID namespace support was not enabled"
grep -qx 'CONFIG_NET_NS=y' "$build_dir/.config" || ci_die "network namespace support was not enabled"
grep -qx 'CONFIG_CGROUPS=y' "$build_dir/.config" || ci_die "cgroup support was not enabled"
grep -qx 'CONFIG_PSI=y' "$build_dir/.config" || ci_die "pressure stall information was not enabled"
grep -qx 'CONFIG_SECURITY_APPARMOR=y' "$build_dir/.config" || ci_die "AppArmor was not enabled by Kconfig"
grep -qx 'CONFIG_SECURITY_NETWORK=y' "$build_dir/.config" || ci_die "AppArmor networking hooks were not enabled"
grep -qx 'CONFIG_SECURITY_PATH=y' "$build_dir/.config" || ci_die "AppArmor path hooks were not enabled"
grep -qx 'CONFIG_SQUASHFS_XATTR=y' "$build_dir/.config" || ci_die "SquashFS xattr support was not enabled"
grep -qx 'CONFIG_SQUASHFS_XZ=y' "$build_dir/.config" || ci_die "SquashFS XZ decompression was not enabled"
grep -qx 'CONFIG_SQUASHFS_ZSTD=y' "$build_dir/.config" || ci_die "SquashFS Zstandard decompression was not enabled"
grep -qx 'CONFIG_SQUASHFS_LZO=y' "$build_dir/.config" || ci_die "SquashFS LZO decompression was not enabled"
grep -q '^CONFIG_LSM="[^"]*apparmor[^"]*"$' "$build_dir/.config" || ci_die "AppArmor is missing from CONFIG_LSM"

ci_log "building arm64 Image and $DTB_NAME with $KERNEL_BUILD_JOBS jobs"
make -j"$KERNEL_BUILD_JOBS" "${make_args[@]}" Image "qcom/$DTB_NAME"

kernel_image="$build_dir/arch/arm64/boot/Image"
dtb_file="$build_dir/arch/arm64/boot/dts/qcom/$DTB_NAME"
[ -s "$kernel_image" ] || ci_die "kernel Image was not produced"
[ -s "$dtb_file" ] || ci_die "$DTB_NAME was not produced"

kernel_release=$(make -s "${make_args[@]}" kernelrelease)
kernel_describe=$(git -C "$source_dir" describe --always --dirty --tags)
archive_name="y700-kernel-artifacts-${kernel_release}-snap.tar.gz"

mkdir -p "$payload_dir"
install -m 0644 "$kernel_image" "$payload_dir/Image"
install -m 0644 "$dtb_file" "$payload_dir/$DTB_NAME"
install -m 0644 "$build_dir/.config" "$payload_dir/kernel.config"

cat > "$payload_dir/BUILD-INFO.txt" <<INFO
generated=$(date -u -Iseconds)
repository=$KERNEL_SOURCE_REPOSITORY
requested_ref=$KERNEL_SOURCE_REF
resolved_ref=$resolved_ref
describe=$kernel_describe
kernel_release=$kernel_release
cross_compile=$CROSS_COMPILE
build_jobs=$KERNEL_BUILD_JOBS
base_config_archive=$KERNEL_BASE_CONFIG_ARCHIVE
waydroid_config_android_binder_ipc=y
waydroid_config_android_binderfs=y
waydroid_config_android_binder_devices=binder,hwbinder,vndbinder
waydroid_config_memfd_create=y
waydroid_config_namespaces=y
waydroid_config_cgroups=y
waydroid_config_psi=y
snap_config_security_apparmor=y
snap_config_lsm=$lsm_list
snap_config_squashfs_xattr=y
snap_config_squashfs_xz=y
snap_config_squashfs_zstd=y
snap_config_squashfs_lzo=y
INFO

(cd "$payload_dir" && sha256sum BUILD-INFO.txt Image kernel.config "$DTB_NAME" > SHA256SUMS)
rm -f "$OUTPUT_DIR"/y700-kernel-artifacts-*-snap.tar.gz "$OUTPUT_DIR"/SHA256SUMS-y700-kernel-artifacts.txt
tar -C "$payload_dir" -czf "$OUTPUT_DIR/$archive_name" .
(cd "$OUTPUT_DIR" && sha256sum "$archive_name" > SHA256SUMS-y700-kernel-artifacts.txt)

ci_log "kernel artifact: $OUTPUT_DIR/$archive_name"
