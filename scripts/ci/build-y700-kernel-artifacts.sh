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
  KERNEL_CONFIG_FRAGMENT        optional local Kconfig fragment applied after required features
  KERNEL_BUILD_JOBS             default: number of online processors
  KERNEL_CCACHE_DIR             optional persistent ccache directory
  KERNEL_CCACHE_MAXSIZE         default: 4G
  CROSS_COMPILE                 default: aarch64-linux-gnu-
  DTB_NAME                      default: sm8650-lenovo-tb321fu.dtb

The base configuration is preserved except for enabling the AppArmor and
SquashFS features required by Snap, plus Binder, BinderFS, memfd, namespaces,
cgroups, PSI, bridge/veth networking, and the legacy iptables features that do
not change the ABI of the kernel modules already installed in the rootfs.
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
KERNEL_CONFIG_FRAGMENT=${KERNEL_CONFIG_FRAGMENT:-}
kernel_config_fragment_source=$KERNEL_CONFIG_FRAGMENT
KERNEL_BUILD_JOBS=${KERNEL_BUILD_JOBS:-$(nproc)}
KERNEL_CCACHE_DIR=${KERNEL_CCACHE_DIR:-}
KERNEL_CCACHE_MAXSIZE=${KERNEL_CCACHE_MAXSIZE:-4G}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
DTB_NAME=${DTB_NAME:-sm8650-lenovo-tb321fu.dtb}

[ -n "$KERNEL_BASE_CONFIG_ARCHIVE" ] || ci_die "KERNEL_BASE_CONFIG_ARCHIVE is required"
[ -z "$KERNEL_CONFIG_FRAGMENT" ] || [ -f "$KERNEL_CONFIG_FRAGMENT" ] || ci_die "KERNEL_CONFIG_FRAGMENT does not exist: $KERNEL_CONFIG_FRAGMENT"
case "$KERNEL_BUILD_JOBS" in
  ''|*[!0-9]*) ci_die "KERNEL_BUILD_JOBS must be a positive integer" ;;
  0) ci_die "KERNEL_BUILD_JOBS must be greater than zero" ;;
esac

ci_require_cmd "${CROSS_COMPILE}gcc"
ci_require_cmd "${CROSS_COMPILE}ld"

kernel_cc=${CROSS_COMPILE}gcc
if [ -n "$KERNEL_CCACHE_DIR" ]; then
  ci_require_cmd ccache
  mkdir -p "$KERNEL_CCACHE_DIR"
  KERNEL_CCACHE_DIR=$(ci_abs_path "$KERNEL_CCACHE_DIR")
  export CCACHE_DIR=$KERNEL_CCACHE_DIR
  export CCACHE_COMPILERCHECK=content
  ccache --max-size "$KERNEL_CCACHE_MAXSIZE"
  kernel_cc="ccache $kernel_cc"
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(ci_abs_path "$OUTPUT_DIR")
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/y700-kernel-build.XXXXXX")
source_dir="$work_dir/linux"
build_dir="$work_dir/build"
base_config_dir="$work_dir/base-config"
payload_dir="$work_dir/payload"

if [ -n "$KERNEL_CCACHE_DIR" ]; then
  export CCACHE_BASEDIR=$work_dir
  export CCACHE_NOHASHDIR=true
fi

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
  --enable NETFILTER \
  --enable NETFILTER_ADVANCED \
  --enable NETFILTER_XTABLES \
  --enable NETFILTER_XTABLES_LEGACY \
  --enable IP_NF_IPTABLES_LEGACY \
  --enable NF_CONNTRACK \
  --enable NF_DEFRAG_IPV4 \
  --enable NF_NAT \
  --enable NETFILTER_NETLINK_LOG \
  --enable NF_CT_NETLINK \
  --enable NETFILTER_XT_MARK \
  --enable NETFILTER_XT_TARGET_CHECKSUM \
  --enable NETFILTER_XT_TARGET_MASQUERADE \
  --enable NETFILTER_XT_TARGET_NFLOG \
  --enable NETFILTER_XT_TARGET_TCPMSS \
  --enable NETFILTER_XT_MATCH_BPF \
  --enable NETFILTER_XT_MATCH_COMMENT \
  --enable NETFILTER_XT_MATCH_CONNTRACK \
  --enable NETFILTER_XT_MATCH_LIMIT \
  --enable NETFILTER_XT_MATCH_OWNER \
  --enable NETFILTER_XT_MATCH_SOCKET \
  --enable NETFILTER_XT_MATCH_STATE \
  --enable IP_NF_IPTABLES \
  --enable IP_NF_FILTER \
  --enable IP_NF_TARGET_REJECT \
  --enable IP_NF_NAT \
  --enable IP_NF_MANGLE \
  --enable IP_NF_RAW \
  --enable IP6_NF_IPTABLES_LEGACY \
  --enable IP6_NF_IPTABLES \
  --enable IP6_NF_FILTER \
  --enable IP6_NF_TARGET_REJECT \
  --enable IP6_NF_MANGLE \
  --enable IP6_NF_RAW \
  --enable IP6_NF_MATCH_RPFILTER \
  --enable BRIDGE \
  --enable BRIDGE_NETFILTER \
  --enable VETH \
  --enable SECURITY_APPARMOR \
  --enable SQUASHFS \
  --enable SQUASHFS_XATTR \
  --enable SQUASHFS_XZ \
  --enable SQUASHFS_ZSTD \
  --enable SQUASHFS_LZO \
  --set-str LSM "$lsm_list"

kernel_config_fragment_sha256=
if [ -n "$KERNEL_CONFIG_FRAGMENT" ]; then
  KERNEL_CONFIG_FRAGMENT=$(ci_abs_path "$KERNEL_CONFIG_FRAGMENT")
  kernel_config_fragment_sha256=$(sha256sum "$KERNEL_CONFIG_FRAGMENT")
  kernel_config_fragment_sha256=${kernel_config_fragment_sha256%% *}
  ci_log "merging kernel configuration fragment: $KERNEL_CONFIG_FRAGMENT"
  "$source_dir/scripts/kconfig/merge_config.sh" \
    -m \
    -O "$build_dir" \
    "$build_dir/.config" \
    "$KERNEL_CONFIG_FRAGMENT"
fi

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
  CC="$kernel_cc"
)

ci_log "normalizing kernel configuration"
make "${make_args[@]}" olddefconfig
lsm_list=$(sed -n 's/^CONFIG_LSM="\(.*\)"$/\1/p' "$build_dir/.config" | head -n1)

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
grep -qx 'CONFIG_NETFILTER=y' "$build_dir/.config" || ci_die "netfilter support was not enabled"
grep -qx 'CONFIG_NETFILTER_ADVANCED=y' "$build_dir/.config" || ci_die "advanced netfilter support was not enabled"
grep -qx 'CONFIG_NETFILTER_XTABLES=y' "$build_dir/.config" || ci_die "x_tables support was not built into the kernel"
grep -qx 'CONFIG_NETFILTER_XTABLES_LEGACY=y' "$build_dir/.config" || ci_die "legacy x_tables support required by Waydroid was not built into the kernel"
grep -qx 'CONFIG_IP_NF_IPTABLES_LEGACY=y' "$build_dir/.config" || ci_die "legacy IPv4 iptables support required by Waydroid was not built into the kernel"
grep -qx 'CONFIG_NF_CONNTRACK=y' "$build_dir/.config" || ci_die "netfilter connection tracking was not built into the kernel"
grep -qx 'CONFIG_NF_DEFRAG_IPV4=y' "$build_dir/.config" || ci_die "IPv4 netfilter defragmentation was not built into the kernel"
grep -qx 'CONFIG_NF_DEFRAG_IPV6=y' "$build_dir/.config" || ci_die "IPv6 netfilter defragmentation was not built into the kernel"
grep -qx 'CONFIG_NF_NAT=y' "$build_dir/.config" || ci_die "netfilter NAT was not built into the kernel"
if grep -qx 'CONFIG_XFRM=y' "$build_dir/.config"; then
  ci_die "XFRM changes the ABI of struct sock and struct net; rebuild and install all rootfs modules before enabling it"
fi
grep -qx '# CONFIG_XFRM_USER is not set' "$build_dir/.config" || ci_die "XFRM_USER must remain disabled while using the bootstrap rootfs modules"
grep -qx '# CONFIG_NF_CONNTRACK_MARK is not set' "$build_dir/.config" || ci_die "NF_CONNTRACK_MARK changes the nf_conn module ABI and requires rebuilding the rootfs modules"
grep -qx 'CONFIG_NETFILTER_NETLINK=y' "$build_dir/.config" || ci_die "netfilter netlink support was not built into the kernel"
grep -qx 'CONFIG_NETFILTER_NETLINK_LOG=y' "$build_dir/.config" || ci_die "netfilter NFLOG interface required by Android netd was not built into the kernel"
grep -qx 'CONFIG_NF_CT_NETLINK=y' "$build_dir/.config" || ci_die "conntrack netlink support required by Android netd was not built into the kernel"
grep -qx 'CONFIG_NETFILTER_XT_MARK=y' "$build_dir/.config" || ci_die "iptables mark match and MARK target were not built into the kernel"
grep -qx 'CONFIG_NETFILTER_XT_TARGET_CHECKSUM=y' "$build_dir/.config" || ci_die "iptables CHECKSUM target was not built into the kernel"
grep -qx 'CONFIG_NETFILTER_XT_TARGET_MASQUERADE=y' "$build_dir/.config" || ci_die "iptables MASQUERADE target was not built into the kernel"
grep -qx 'CONFIG_NETFILTER_XT_TARGET_NFLOG=y' "$build_dir/.config" || ci_die "iptables NFLOG target required by Android netd was not built into the kernel"
grep -qx 'CONFIG_NETFILTER_XT_TARGET_TCPMSS=y' "$build_dir/.config" || ci_die "iptables TCPMSS target required by Android networking was not built into the kernel"
grep -qx 'CONFIG_NETFILTER_XT_MATCH_BPF=y' "$build_dir/.config" || ci_die "iptables BPF match required by Android netd was not built into the kernel"
grep -qx 'CONFIG_NETFILTER_XT_MATCH_COMMENT=y' "$build_dir/.config" || ci_die "iptables comment match required by Android networking was not built into the kernel"
grep -qx 'CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y' "$build_dir/.config" || ci_die "iptables conntrack match was not built into the kernel"
grep -qx 'CONFIG_NETFILTER_XT_MATCH_LIMIT=y' "$build_dir/.config" || ci_die "iptables limit match required by Android netd was not built into the kernel"
grep -qx 'CONFIG_NETFILTER_XT_MATCH_OWNER=y' "$build_dir/.config" || ci_die "iptables owner match required by Android netd was not built into the kernel"
grep -qx 'CONFIG_NETFILTER_XT_MATCH_SOCKET=y' "$build_dir/.config" || ci_die "iptables socket match required by Android networking was not built into the kernel"
grep -qx 'CONFIG_NETFILTER_XT_MATCH_STATE=y' "$build_dir/.config" || ci_die "iptables state match required by Android networking was not built into the kernel"
grep -qx 'CONFIG_IP_NF_IPTABLES=y' "$build_dir/.config" || ci_die "IPv4 iptables was not built into the kernel"
grep -qx 'CONFIG_IP_NF_FILTER=y' "$build_dir/.config" || ci_die "IPv4 iptables filter table was not built into the kernel"
grep -qx 'CONFIG_IP_NF_TARGET_REJECT=y' "$build_dir/.config" || ci_die "IPv4 iptables REJECT target was not built into the kernel"
grep -qx 'CONFIG_IP_NF_NAT=y' "$build_dir/.config" || ci_die "IPv4 iptables NAT table was not built into the kernel"
grep -qx 'CONFIG_IP_NF_MANGLE=y' "$build_dir/.config" || ci_die "IPv4 iptables mangle table was not built into the kernel"
grep -qx 'CONFIG_IP_NF_RAW=y' "$build_dir/.config" || ci_die "IPv4 iptables raw table required by Android netd was not built into the kernel"
grep -qx 'CONFIG_IP6_NF_IPTABLES_LEGACY=y' "$build_dir/.config" || ci_die "legacy IPv6 iptables support required by Android netd was not built into the kernel"
grep -qx 'CONFIG_IP6_NF_IPTABLES=y' "$build_dir/.config" || ci_die "IPv6 iptables was not built into the kernel"
grep -qx 'CONFIG_IP6_NF_FILTER=y' "$build_dir/.config" || ci_die "IPv6 iptables filter table was not built into the kernel"
grep -qx 'CONFIG_IP6_NF_TARGET_REJECT=y' "$build_dir/.config" || ci_die "IPv6 iptables REJECT target was not built into the kernel"
grep -qx 'CONFIG_IP6_NF_MANGLE=y' "$build_dir/.config" || ci_die "IPv6 iptables mangle table was not built into the kernel"
grep -qx 'CONFIG_IP6_NF_RAW=y' "$build_dir/.config" || ci_die "IPv6 iptables raw table required by Android netd was not built into the kernel"
grep -qx 'CONFIG_IP6_NF_MATCH_RPFILTER=y' "$build_dir/.config" || ci_die "IPv6 reverse-path filter match required by Android networking was not built into the kernel"
grep -qx 'CONFIG_BRIDGE=y' "$build_dir/.config" || ci_die "Ethernet bridge support was not built into the kernel"
grep -qx 'CONFIG_BRIDGE_NETFILTER=y' "$build_dir/.config" || ci_die "bridge netfilter support was not built into the kernel"
grep -qx 'CONFIG_VETH=y' "$build_dir/.config" || ci_die "virtual Ethernet pair support was not built into the kernel"
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

if [ -n "$KERNEL_CCACHE_DIR" ]; then
  ccache --show-stats || true
fi

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
config_fragment=$kernel_config_fragment_source
config_fragment_sha256=$kernel_config_fragment_sha256
ccache_enabled=$([ -n "$KERNEL_CCACHE_DIR" ] && printf yes || printf no)
waydroid_config_android_binder_ipc=y
waydroid_config_android_binderfs=y
waydroid_config_android_binder_devices=binder,hwbinder,vndbinder
waydroid_config_memfd_create=y
waydroid_config_namespaces=y
waydroid_config_cgroups=y
waydroid_config_psi=y
waydroid_config_netfilter=y
waydroid_config_nf_nat=y
waydroid_config_iptables=y
waydroid_config_iptables_legacy=y
waydroid_config_bridge=y
waydroid_config_bridge_netfilter=y
waydroid_config_veth=y
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
