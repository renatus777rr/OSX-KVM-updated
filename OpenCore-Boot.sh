#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="${SCRIPT_DIR}/macos-kvm.conf"

load_config() {
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
}

detect_system() {
    local cpuinfo="/proc/cpuinfo"
    if [[ ! -r "$cpuinfo" ]]; then
        CPU_THREADS=4
        CPU_CORES=2
        CPU_SOCKETS=1
        return 1
    fi

    CPU_THREADS=$(grep -c '^processor' "$cpuinfo")
    CPU_CORES=$(grep -c 'cpu cores.*:' "$cpuinfo" 2>/dev/null || echo "$((CPU_THREADS / 2))")
    CPU_SOCKETS=$(grep -c 'physical id.*:' "$cpuinfo" 2>/dev/null || echo 1)

    CPU_CORES=$((CPU_CORES > 1 ? CPU_CORES : CPU_THREADS / 2))
    CPU_THREADS=$((CPU_THREADS > 2 ? CPU_THREADS : 4))
    CPU_CORES=$((CPU_CORES > CPU_THREADS ? CPU_THREADS / 2 : CPU_CORES))
}

detect_memory() {
    local meminfo="/proc/meminfo"
    if [[ ! -r "$meminfo" ]]; then
        ALLOCATED_RAM=4096
        return 1
    fi

    local total_mem_kb
    total_mem_kb=$(grep '^MemTotal:' "$meminfo" | awk '{print $2}')
    local total_mem_gb=$((total_mem_kb / 1024 / 1024))

    case $total_mem_gb in
        0..3) ALLOCATED_RAM=2048 ;;
        4..7) ALLOCATED_RAM=4096 ;;
        8..15) ALLOCATED_RAM=8192 ;;
        16..31) ALLOCATED_RAM=16384 ;;
        32..63) ALLOCATED_RAM=32768 ;;
        *) ALLOCATED_RAM=65536 ;;
    esac
}

auto_tune() {
    detect_system
    detect_memory

    CPU_GEN="${CPU_GEN:-skylake}"
    NET_MODE="${NET_MODE:-user}"
    SSH_PORT="${SSH_PORT:-2222}"
    VIDEO_MODE="${VIDEO_MODE:-vmware}"
    USB_PASSTHROUGH="${USB_PASSTHROUGH:-false}"

    CPU_THREADS=$((CPU_THREADS * 3 / 4))
    CPU_CORES=$((CPU_CORES * 3 / 4))
    CPU_SOCKETS=$((CPU_SOCKETS > 1 ? CPU_SOCKETS : 1))

    CPU_THREADS=$((CPU_THREADS < 2 ? 2 : CPU_THREADS))
    CPU_CORES=$((CPU_CORES < 1 ? 1 : CPU_CORES))
}

get_cpu_flags() {
    local gen="$1"
    case "$gen" in
        penryn) echo "+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check" ;;
        skylake|haswell) echo "-hle,-rtm,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check" ;;
        *) echo "-hle,-rtm,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check" ;;
    esac
}

build_cpu_string() {
    local gen="$1"
    local flags
    flags="$(get_cpu_flags "$gen")"
    if [[ "$gen" == "penryn" ]]; then
        echo "Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,$flags"
    else
        echo "${gen^}-Client,$flags,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on"
    fi
}

build_network() {
    case "${NET_MODE:-user}" in
        tap)
            echo "-netdev tap,id=net0,ifname=tap0,script=no,downscript=no -device virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:27"
            ;;
        none)
            ;;
        *)
            echo "-netdev user,id=net0,hostfwd=tcp::${SSH_PORT:-2222}-:22 -device virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:27"
            ;;
    esac
}

build_video() {
    case "${VIDEO_MODE:-vmware}" in
        virtio) echo "-device virtio-gpu-pci" ;;
        qxl)    echo "-device qxl" ;;
        *)      echo "-device vmware-svga" ;;
    esac
}

find_image() {
    local name="$1"
    local candidates=(
        "${SCRIPT_DIR}/${name}"
        "${SCRIPT_DIR}/OpenCore/${name}"
        "${SCRIPT_DIR}/OVMF/${name}"
        "./${name}"
    )
    
    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

validate_files() {
    local files=("$@")
    for file in "${files[@]}"; do
        [[ -f "$file" ]]
    done
}

main() {
    load_config
    auto_tune

    local mac_hdd opencore install_media ovmf_code ovmf_vars

    mac_hdd="$(find_image 'mac_hdd_ng.img' || find_image '*.img' || echo "${SCRIPT_DIR}/mac_hdd_ng.img")"
    opencore="$(find_image 'OpenCore.qcow2' || find_image '*.qcow2' || echo "${SCRIPT_DIR}/OpenCore/OpenCore.qcow2")"
    install_media="$(find_image 'BaseSystem.img' || echo "${SCRIPT_DIR}/BaseSystem.img")"
    ovmf_code="$(find_image 'OVMF_CODE_4M.fd' || find_image 'OVMF_CODE.fd' || echo "${SCRIPT_DIR}/OVMF_CODE_4M.fd")"
    ovmf_vars="$(find_image 'OVMF_VARS-*.fd' || find_image 'OVMF_VARS.fd' || echo "${SCRIPT_DIR}/OVMF_VARS-1920x1080.fd")"

    local required_files=(
        "$ovmf_code"
        "$ovmf_vars"
        "$opencore"
        "$install_media"
        "$mac_hdd"
    )

    if ! validate_files "${required_files[@]}"; then
        echo "hdd and installer not found, do you want still continue? (y/n): "
        read -r response
        [[ "$response" =~ ^[Yy]$ ]] || exit 1
    fi

    echo "Starting macOS KVM"
    echo "RAM: ${ALLOCATED_RAM}MiB CPU: ${CPU_THREADS}T/${CPU_CORES}C/${CPU_SOCKETS}S (${CPU_GEN})"

    local args=(
        -enable-kvm
        -m "$ALLOCATED_RAM"
        -cpu "$(build_cpu_string "$CPU_GEN")"
        -machine q35
        -smp "$CPU_THREADS",cores="$CPU_CORES",sockets="$CPU_SOCKETS"
        -device qemu-xhci,id=xhci
        -device usb-kbd,bus=xhci.0
        -device usb-tablet,bus=xhci.0
        -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
        -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code"
        -drive "if=pflash,format=raw,file=$ovmf_vars"
        -smbios type=2
        -device ich9-intel-hda
        -device hda-duplex
        -device ich9-ahci,id=sata
        -drive "id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,file=$opencore"
        -device "ide-hd,bus=sata.2,drive=OpenCoreBoot"
        -device "ide-hd,bus=sata.3,drive=InstallMedia"
        -drive "id=InstallMedia,if=none,file=$install_media,format=raw"
        -drive "id=MacHDD,if=none,file=$mac_hdd,format=qcow2"
        -device "ide-hd,bus=sata.4,drive=MacHDD"
        "$(build_network)"
        "$(build_video)"
        -monitor stdio
    )

    if [[ "${USB_PASSTHROUGH:-false}" == "true" ]]; then
        args+=(-device usb-ehci,id=ehci)
    fi

    exec qemu-system-x86_64 "${args[@]}"
}

main "$@"
