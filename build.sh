#!/usr/bin/env bash
#
# Personal ESK Kernel build script
#

set -Ee

################################################################################
# Generic helpers
################################################################################

# ANSI colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[$(date '+%F %T')] [INFO]${NC} $*"; }
success() { echo -e "${GREEN}[$(date '+%F %T')] [SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%F %T')] [WARN]${NC} $*"; }

# Escape a string for Telegram MarkdownV2
escape_md_v2() {
    local s=$*
    s=${s//\\/\\\\}
    s=${s//_/\\_}
    s=${s//\*/\\*}
    s=${s//\[/\\[}
    s=${s//\]/\\]}
    s=${s//\(/\\(}
    s=${s//\)/\\)}
    s=${s//~/\\~}
    s=${s//\`/\\\`}
    s=${s//>/\\>}
    s=${s//#/\\#}
    s=${s//+/\\+}
    s=${s//-/\\-}
    s=${s//=/\\=}
    s=${s//|/\\|}
    s=${s//\{/\\\{}
    s=${s//\}/\\\}}
    s=${s//\./\\.}
    s=${s//\!/\\!}
    echo "$s"
}

# Bool helpers
norm_bool() {
    local value=$1
    case "${value,,}" in
        1 | y | yes | t | true | on) echo "true" ;;
        0 | n | no | f | false | off) echo "false" ;;
        *) echo "false" ;;
    esac
}

is_true() {
    [[ $1 == true ]]
}

parse_bool() {
    if is_true "$1"; then
        echo "Enabled"
    else
        echo "Disabled"
    fi
}

# Recreate directory
reset_dir() {
    local path="$1"
    [[ -d $path ]] && rm -rf -- "$path"
    mkdir -p -- "$path"
}

# Shallow clone host:owner/repo@branch into a destination
git_clone() {
    local source="$1"
    local dest="$2"
    local host repo branch
    IFS=':@' read -r host repo branch <<<"$source"
    git clone -q --depth=1 --single-branch --no-tags \
        "https://${host}/${repo}" -b "${branch}" "${dest}"
}


################################################################################
# Error handling
################################################################################

error() {
    trap - ERR
    echo -e "${RED}[$(date '+%F %T')] [ERROR]${NC} $*" >&2

    local msg
    msg=$(
        cat <<EOF
*$(escape_md_v2 "$KERNEL_NAME Kernel CI")*

*Tags*: \#$(escape_md_v2 "$BUILD_TAG") \#error

$(escape_md_v2 "ERROR: $*")
EOF
    )

    exit 1
}

trap 'error "Build failed at line $LINENO: $BASH_COMMAND"' ERR

################################################################################
# Build configuration
################################################################################

# General
KERNEL_NAME="ESK"
KERNEL_DEFCONFIG="gki_defconfig"
KBUILD_BUILD_USER="build-user"
KBUILD_BUILD_HOST="build-host"

# --- Kernel flavour
# KernelSU variant: NONE | OFFICIAL | NEXT | SUKI
KSU="${KSU:-NONE}"
# Include SuSFS?
SUSFS="$(norm_bool "${SUSFS:-false}")"
# Apply LXC patch?
LXC="$(norm_bool "${LXC:-false}")"
BBG="$(norm_bool "${BBG:-false}")"

# --- Compiler
# Clang LTO mode: thin | full
CLANG_LTO="thin"
# Parallel build jobs
JOBS="$(nproc --all)"

# --- Paths
WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_PATCHES="$WORKSPACE/kernel_patches"
CLANG="$WORKSPACE/clang"
CLANG_BIN="$CLANG/clang-r536225/bin"
SIGN_KEY="$WORKSPACE/key"
OUT_DIR="$WORKSPACE/out"
LOGFILE="$WORKSPACE/build.log"
BOOT_SIGN_KEY="$SIGN_KEY/boot_sign_key.pem"

# --- Sources (host:owner/repo@ref)
KERNEL_REPO="github.com:qweraqq/android_kernel_xiaomi_mt6895@ksu-susfs"
KERNEL="$WORKSPACE/kernel"
ANYKERNEL_REPO="github.com:ESK-Project/AnyKernel3@android12-5.10"
ANYKERNEL="$WORKSPACE/anykernel3"
GKI_URL="https://dl.google.com/android/gki/gki-certified-boot-android12-5.10-2025-09_r1.zip"


KERNEL_OUT="$KERNEL/out"

################################################################################
# Initialize build environment
################################################################################

# Set timezone
sudo timedatectl set-timezone "$TIMEZONE" || export TZ="$TIMEZONE"

################################################################################
# Feature-specific helpers
################################################################################

install_ksu() {
    local repo="$1"
    local ref="$2"
    info "Install KernelSU: $repo@$ref"
    curl -fsSL "https://raw.githubusercontent.com/$repo/$ref/kernel/setup.sh" | bash -s "$ref"
}

# Wrapper for scripts/config
config() {
    local cfg="$KERNEL_OUT/.config"
    if [[ -f $cfg ]]; then
        "$KERNEL/scripts/config" --file "$cfg" "$@"
    else
        "$KERNEL/scripts/config" --file "$KERNEL/arch/arm64/configs/$KERNEL_DEFCONFIG" "$@"
    fi
}

regenerate_defconfig() {
    make "${MAKE_ARGS[@]}" -s olddefconfig
}

clang_lto() {
    config --enable CONFIG_LTO_CLANG
    case "$1" in
        thin)
            config --enable CONFIG_LTO_CLANG_THIN
            config --disable CONFIG_LTO_CLANG_FULL
            ;;
        full)
            config --enable CONFIG_LTO_CLANG_FULL
            config --disable CONFIG_LTO_CLANG_THIN
            ;;
        *)
            warn "Unknown LTO mode, using thin"
            config --enable CONFIG_LTO_CLANG_THIN
            config --disable CONFIG_LTO_CLANG_FULL
            ;;
    esac
    regenerate_defconfig
}

################################################################################
# Build steps
################################################################################

prepare_dirs() {
    RESET_DIR_LIST=(
        "$KERNEL" "$OUT_DIR" "$WORKSPACE/susfs" "$WORKSPACE/wild_patches"
    )
    info "Resetting directories: ${RESET_DIR_LIST[*]}"
    for dir in "${RESET_DIR_LIST[@]}"; do
        reset_dir "$dir"
    done
}

fetch_sources() {
    info "Cloning kernel source..."
    git_clone "$KERNEL_REPO" "$KERNEL"
}

setup_toolchain() {
    info "Fetching AOSP Clang toolchain"
    mkdir -p "$CLANG"
    git clone --branch llvm-r536225-release --depth=1 https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 $CLANG
    export PATH="${CLANG_BIN}:$PATH"
    
    COMPILER_STRING="$("$CLANG_BIN/clang" -v 2>&1 | head -n 1 | sed 's/(https..*//')"
    export KBUILD_BUILD_USER=build-user
    export KBUILD_BUILD_HOST=build-host
    export KBUILD_BUILD_TIMESTAMP="Wed Aug 28 22:16:09 UTC 2024"
    KBUILD_BUILD_TIMESTAMP="Wed Aug 28 22:16:09 UTC 2024"
}

apply_susfs() {
    info "Applying SuSFS patches for $KSU variant"

    local SUSFS_PATCHES

    if [[ $KSU == "NEXT" ]]; then
        info "Apply SuSFS patches for KernelSU Next"

        SUSFS_PATCHES="$KERNEL_PATCHES/next/susfs"

        local NEXT_PATCH="$SUSFS_PATCHES/10_enable_susfs_for_ksu.patch"
        local WILD_PATCHES="$WORKSPACE/wild_patches"

        pushd KernelSU-Next >/dev/null
        patch -s -p1 --no-backup-if-mismatch <"$NEXT_PATCH" || true

        info "Apply SuSFS fix patches for KernelSU Next"
        git_clone "github.com:WildKernels/kernel_patches@main" "$WILD_PATCHES"

        SUSFS_VERSION="$(grep -E '^#define SUSFS_VERSION' "$SUSFS_PATCHES/include/linux/susfs.h" | cut -d' ' -f3 | sed 's/\"//g')"
        local SUSFS_FIX_PATCHES="$WILD_PATCHES/next/susfs_fix_patches/$SUSFS_VERSION"
        [[ -d $SUSFS_FIX_PATCHES ]] || error "SuSFS fix patches are unavailable for SuSFS $SUSFS_VERSION"
        for p in "$SUSFS_FIX_PATCHES"/*.patch; do
            patch -s -p1 --no-backup-if-mismatch <"$p"
        done

        popd >/dev/null

        # For SuSFS 1.5.12
        config --disable CONFIG_KSU_SUSFS_SUS_SU
    else
        info "Apply SuSFS kernel-side patches"

        local SUSFS_DIR="$WORKSPACE/susfs"
        local SUSFS_BRANCH=gki-android12-5.10

        SUSFS_PATCHES="$SUSFS_DIR/kernel_patches"

        git_clone "gitlab.com:simonpunk/susfs4ksu@$SUSFS_BRANCH" "$SUSFS_DIR"

        SUSFS_VERSION="$(grep -E '^#define SUSFS_VERSION' "$SUSFS_PATCHES/include/linux/susfs.h" | cut -d' ' -f3 | sed 's/\"//g')"

        if [[ $KSU == "OFFICIAL" ]]; then
            pushd KernelSU >/dev/null
            info "Apply KernelSU-side SuSFS patches"
            patch -s -p1 --no-backup-if-mismatch <"$SUSFS_PATCHES/KernelSU/10_enable_susfs_for_ksu.patch"
            popd >/dev/null
        fi
    fi

    cp -R "$SUSFS_PATCHES"/fs/* ./fs
    cp -R "$SUSFS_PATCHES"/include/* ./include
    patch -s -p1 --fuzz=3 --no-backup-if-mismatch <"$SUSFS_PATCHES"/50_add_susfs_in_gki-android*-*.patch

    config --enable CONFIG_KSU_SUSFS
    success "SuSFS $SUSFS_VERSION applied!"
}

prebuild_kernel() {
    cd "$KERNEL"

    # Defconfig existence check (for config())
    DEFCONFIG_FILE="$KERNEL/arch/arm64/configs/$KERNEL_DEFCONFIG"
    [[ -f $DEFCONFIG_FILE ]] || error "Defconfig not found: $KERNEL_DEFCONFIG"

    # KernelSU
    local ksu_included="true"
    [[ $KSU == "NONE" ]] && ksu_included="false"

    if is_true "$ksu_included"; then
        info "Setup KernelSU"
        case "$KSU" in
            OFFICIAL) install_ksu tiann/KernelSU main ;;
            NEXT) install_ksu KernelSU-Next/KernelSU-Next next ;;
            SUKI)
                install_ksu SukiSU-Ultra/SukiSU-Ultra "$(is_true "$SUSFS" && echo "susfs-main" || echo "main")"
                ;;
        esac

        info "Configuring KernelSU"
        config --enable CONFIG_KSU

        if [[ $KSU == "SUKI" ]]; then
            patch -s -p1 --fuzz=3 --no-backup-if-mismatch <"$KERNEL_PATCHES/suki/manual_hooks.patch"
            config --enable CONFIG_KPM
            config --enable CONFIG_KSU_TRACEPOINT_HOOK
            config --enable CONFIG_HAVE_SYSCALL_TRACEPOINTS
        elif [[ $KSU == "NEXT" ]]; then
            patch -s -p1 --fuzz=3 --no-backup-if-mismatch <"$KERNEL_PATCHES/next/manual_hooks.patch"
            config --disable CONFIG_KSU_KPROBES_HOOK
        fi

        success "KernelSU added"
    fi

    # SuSFS
    if is_true "$SUSFS"; then
        apply_susfs
    else
        config --disable CONFIG_KSU_SUSFS
    fi

    # LXC
    if is_true "$LXC"; then
        info "Apply LXC patch"
        patch -s -p1 --fuzz=3 --no-backup-if-mismatch <"$KERNEL_PATCHES/lxc_support.patch"
        success "LXC patch applied"
    fi

    # BBG
    if is_true "$BBG"; then
        info "Setup Baseband Guard (BBG) LSM for KernelSU variants"
        wget -qO- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash >/dev/null 2>&1
        sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/bpf/bpf,baseband_guard/ } }' security/Kconfig
        config --enable CONFIG_BBG
        success "Added BBG"
    fi

    # Core BPF Support
    config --enable CONFIG_BPF
    config --enable CONFIG_BPF_SYSCALL
    config --enable CONFIG_BPF_JIT
    # BTF / CO-RE Support (Requires 'dwarves' package installed above)
    config --enable CONFIG_DEBUG_INFO_BTF
    # BPF LTS/Tracing features
    config --enable CONFIG_BPF_EVENTS
    config --enable CONFIG_BPF_STREAM_PARSER
    config --enable CONFIG_CGROUP_BPF
    config --enable CONFIG_LWTUNNEL_BPF
}

build_kernel() {
    cd "$KERNEL"

    SECONDS=0

    info "Generate defconfig: $KERNEL_DEFCONFIG"
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LLVM=1 LLVM_IAS=1 LD="$CLANG_BIN/ld.lld" O=out gki_defconfig
    success "Defconfig generated"

    THREAD="-j$(nproc --all)"
    make CC=clang LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- O=out LD="$CLANG_BIN/ld.lld" $THREAD \
        LOCALVERSION=-android12-9-00019-g4ea09a298bb4-ab12292661 \
        CONFIG_LOCALVERSION_AUTO=n \
        CONFIG_MEDIATEK_CPUFREQ_DEBUG=m CONFIG_MTK_IPI=m CONFIG_MTK_TINYSYS_MCUPM_SUPPORT=m \
        CONFIG_MTK_MBOX=m CONFIG_RPMSG_MTK=m CONFIG_LTO_CLANG=y CONFIG_LTO_NONE=n \
        CONFIG_LTO_CLANG_THIN=y CONFIG_LTO_CLANG_FULL=n

    success "Kernel built successfully"

    KERNEL_VERSION=$(make -s kernelversion | cut -d- -f1)
}

################################################################################
# Main
################################################################################

main() {
    prepare_dirs
    fetch_sources
    setup_toolchain
    prebuild_kernel
    build_kernel

    # Build package name
    VARIANT="$KSU"
    is_true "$SUSFS" && VARIANT+="-SUSFS"
    is_true "$LXC" && VARIANT+="-LXC"
    is_true "$BBG" && VARIANT+="-BBG"
    PACKAGE_NAME="$KERNEL_NAME-$KERNEL_VERSION-$VARIANT"

    cp -p "$KERNEL_OUT/arch/arm64/boot/Image" "$OUT_DIR/$package_name.Image"
}

main "$@"
