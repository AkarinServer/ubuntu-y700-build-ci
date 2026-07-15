#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Build Lenovo TB321FU kernel artifacts with the kernel features required by Snap.

Environment inputs:
  OUTPUT_DIR                    default: out/y700-kernel-artifacts
  KERNEL_SOURCE_REPOSITORY      default: https://github.com/GUF296/linux.git
  KERNEL_SOURCE_REF             default: 5df8e852ea722929f5359a5ef28ebcec0c4443fd
  KERNEL_APPARMOR_NETWORK_PATCH default: patches/kernel/0001-apparmor-v2-network-compat.patch
  KERNEL_BASE_CONFIG_ARCHIVE    required URL/path containing kernel.config
  KERNEL_BUILD_JOBS             default: number of online processors
  CROSS_COMPILE                 default: aarch64-linux-gnu-
  DTB_NAME                      default: sm8650-lenovo-tb321fu.dtb

The base configuration is preserved except for enabling the kernel primitives
used by Snap confinement and every in-tree SquashFS decompressor. If the source
lacks Ubuntu's AppArmor v2 network compatibility ABI, the bundled patch is
applied before configuration and compilation.
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
KERNEL_APPARMOR_NETWORK_PATCH=${KERNEL_APPARMOR_NETWORK_PATCH:-$SCRIPT_DIR/../../patches/kernel/0001-apparmor-v2-network-compat.patch}
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
git -C "$source_dir" fetch --depth 1 origin "$KERNEL_SOURCE_REF"
git -C "$source_dir" -c advice.detachedHead=false checkout -q FETCH_HEAD

resolved_ref=$(git -C "$source_dir" rev-parse HEAD)
if printf '%s\n' "$KERNEL_SOURCE_REF" | grep -Eq '^[0-9a-fA-F]{40}$'; then
  [ "$resolved_ref" = "$KERNEL_SOURCE_REF" ] || ci_die "resolved kernel commit $resolved_ref does not match requested $KERNEL_SOURCE_REF"
fi
[ -f "$source_dir/arch/arm64/boot/dts/qcom/${DTB_NAME%.dtb}.dts" ] || ci_die "kernel source does not contain the TB321FU device tree"

apparmor_network_compat=upstream
apparmor_network_patch_sha256=not-applied
if ! grep -Eq 'AA_SFS_DIR\("network",[[:space:]]*aa_sfs_entry_network_compat\)' \
    "$source_dir/security/apparmor/apparmorfs.c"; then
  [ -f "$KERNEL_APPARMOR_NETWORK_PATCH" ] || \
    ci_die "kernel source lacks AppArmor v2 network compatibility and patch is missing: $KERNEL_APPARMOR_NETWORK_PATCH"
  ci_log "applying AppArmor v2 network compatibility patch"
  git -C "$source_dir" apply --check "$KERNEL_APPARMOR_NETWORK_PATCH" || \
    ci_die "AppArmor network compatibility patch does not apply to $resolved_ref"
  git -C "$source_dir" apply "$KERNEL_APPARMOR_NETWORK_PATCH"
  apparmor_network_compat=patched
  apparmor_network_patch_sha256=$(sha256sum "$KERNEL_APPARMOR_NETWORK_PATCH" | sed 's/[[:space:]].*$//')
fi
grep -Eq 'AA_SFS_DIR\("network",[[:space:]]*aa_sfs_entry_network_compat\)' \
  "$source_dir/security/apparmor/apparmorfs.c" || \
  ci_die "AppArmor v2 network compatibility ABI is still missing after patching"

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
  --enable AUDIT \
  --enable BPF \
  --enable BPF_SYSCALL \
  --enable CGROUPS \
  --enable MEMCG \
  --enable BLK_CGROUP \
  --enable CGROUP_SCHED \
  --enable CGROUP_PIDS \
  --enable CGROUP_FREEZER \
  --enable CGROUP_BPF \
  --enable CGROUP_DEVICE \
  --enable CFS_BANDWIDTH \
  --enable NAMESPACES \
  --enable UTS_NS \
  --enable IPC_NS \
  --enable USER_NS \
  --enable PID_NS \
  --enable NET_NS \
  --enable SECCOMP \
  --enable SECCOMP_FILTER \
  --enable BLK_DEV_LOOP \
  --enable TMPFS \
  --enable TMPFS_POSIX_ACL \
  --enable TMPFS_XATTR \
  --enable SQUASHFS \
  --enable SQUASHFS_XATTR \
  --enable SQUASHFS_ZLIB \
  --enable SQUASHFS_LZ4 \
  --enable SQUASHFS_LZO \
  --enable SECURITY_APPARMOR \
  --enable SQUASHFS_XZ \
  --enable SQUASHFS_ZSTD \
  --enable SECURITY \
  --enable SECURITYFS \
  --enable SECURITY_NETWORK \
  --enable SECURITY_PATH \
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

required_snap_configs=(
  AUDIT BPF BPF_SYSCALL
  CGROUPS MEMCG BLK_CGROUP CGROUP_SCHED CGROUP_PIDS CGROUP_FREEZER
  CGROUP_BPF CGROUP_DEVICE CFS_BANDWIDTH
  NAMESPACES UTS_NS IPC_NS USER_NS PID_NS NET_NS
  SECCOMP SECCOMP_FILTER BLK_DEV_LOOP
  TMPFS TMPFS_POSIX_ACL TMPFS_XATTR
  SQUASHFS SQUASHFS_XATTR
  SQUASHFS_ZLIB SQUASHFS_LZ4 SQUASHFS_LZO SQUASHFS_XZ SQUASHFS_ZSTD
  SECURITY SECURITYFS SECURITY_NETWORK SECURITY_PATH SECURITY_APPARMOR
)
for symbol in "${required_snap_configs[@]}"; do
  grep -qx "CONFIG_$symbol=y" "$build_dir/.config" || \
    ci_die "required Snap kernel option CONFIG_$symbol was not enabled by Kconfig"
done
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
snap_apparmor_network_compat=$apparmor_network_compat
snap_apparmor_network_patch_sha256=$apparmor_network_patch_sha256
snap_config_security_apparmor=y
snap_config_lsm=$lsm_list
snap_config_squashfs_xattr=y
snap_config_squashfs_zlib=y
snap_config_squashfs_lz4=y
snap_config_squashfs_lzo=y
snap_config_squashfs_xz=y
snap_config_squashfs_zstd=y
INFO

(cd "$payload_dir" && sha256sum BUILD-INFO.txt Image kernel.config "$DTB_NAME" > SHA256SUMS)
rm -f "$OUTPUT_DIR"/y700-kernel-artifacts-*-snap.tar.gz "$OUTPUT_DIR"/SHA256SUMS-y700-kernel-artifacts.txt
tar -C "$payload_dir" -czf "$OUTPUT_DIR/$archive_name" .
(cd "$OUTPUT_DIR" && sha256sum "$archive_name" > SHA256SUMS-y700-kernel-artifacts.txt)

ci_log "kernel artifact: $OUTPUT_DIR/$archive_name"
