set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: run-vm [OPTIONS] INSTANCE_DIR

Options:
  --cpus N          vCPU count (default: 1)
  --memory MIB      guest RAM in MiB (default: 256)
  --ksm             mark guest RAM mergeable for the separate KSM test arm
  --free-page-reporting on|off
                    allow guest free-page reclamation (default: on)
  --qmp PATH        create a QMP Unix socket for balloon control
  --host-port PORT  loopback port forwarded to guest nginx (default: 18080)
  --tap NAME        use an already-prepared TAP interface instead of usernet
  --guest-ip CIDR   static guest IPv4 CIDR (default: 10.0.2.15/24)
  --mac ADDRESS     deterministic guest MAC (required with --tap)
  --console PATH    write the ISA console to PATH (default: discard output)
EOF
  exit 2
}

cpus=1
memory=256
ksm=false
free_page_reporting=on
qmp_path=
host_port=18080
tap_name=
guest_ip=10.0.2.15/24
guest_ip_set=false
mac_address=
console_path=

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpus)
      [[ $# -ge 2 ]] || usage
      cpus=$2
      shift 2
      ;;
    --memory)
      [[ $# -ge 2 ]] || usage
      memory=$2
      shift 2
      ;;
    --ksm)
      ksm=true
      shift
      ;;
    --free-page-reporting)
      [[ $# -ge 2 ]] || usage
      free_page_reporting=$2
      shift 2
      ;;
    --qmp)
      [[ $# -ge 2 ]] || usage
      qmp_path=$2
      shift 2
      ;;
    --host-port)
      [[ $# -ge 2 ]] || usage
      host_port=$2
      shift 2
      ;;
    --tap)
      [[ $# -ge 2 ]] || usage
      tap_name=$2
      shift 2
      ;;
    --guest-ip)
      [[ $# -ge 2 ]] || usage
      guest_ip=$2
      guest_ip_set=true
      shift 2
      ;;
    --mac)
      [[ $# -ge 2 ]] || usage
      mac_address=$2
      shift 2
      ;;
    --console)
      [[ $# -ge 2 ]] || usage
      console_path=$2
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "run-vm: unknown option: $1" >&2
      usage
      ;;
    *)
      break
      ;;
  esac
done

[[ $# -eq 1 ]] || usage
[[ ${cpus} =~ ^[1-9][0-9]*$ ]] || {
  echo "run-vm: --cpus must be a positive integer" >&2
  exit 2
}
[[ ${memory} =~ ^[1-9][0-9]*$ ]] || {
  echo "run-vm: --memory must be a positive integer" >&2
  exit 2
}
[[ ${free_page_reporting} == on || ${free_page_reporting} == off ]] || {
  echo "run-vm: --free-page-reporting must be on or off" >&2
  exit 2
}
[[ ${host_port} =~ ^[0-9]+$ && ${host_port} -le 65535 ]] || {
  echo "run-vm: --host-port must be between 0 and 65535" >&2
  exit 2
}

if [[ -n ${qmp_path} ]]; then
  qmp_path=$(realpath -m "${qmp_path}")
  [[ -d ${qmp_path%/*} && -w ${qmp_path%/*} ]] || {
    echo "run-vm: QMP socket parent must be an existing writable directory" >&2
    exit 2
  }
  [[ ! -e ${qmp_path} && ! -S ${qmp_path} ]] || {
    echo "run-vm: refusing to replace existing QMP path: ${qmp_path}" >&2
    exit 2
  }
fi
[[ ${guest_ip} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || {
  echo "run-vm: --guest-ip must be an IPv4 CIDR" >&2
  exit 2
}

guest_address=${guest_ip%/*}
IFS=. read -r -a guest_octets <<< "${guest_address}"
for octet in "${guest_octets[@]}"; do
  ((10#${octet} <= 255)) || {
    echo "run-vm: --guest-ip contains an invalid IPv4 octet" >&2
    exit 2
  }
done

if [[ -n ${mac_address} ]]; then
  [[ ${mac_address} =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || {
    echo "run-vm: --mac must be six colon-separated hexadecimal octets" >&2
    exit 2
  }
  first_mac_octet=${mac_address%%:*}
  (( (16#${first_mac_octet} & 1) == 0 )) || {
    echo "run-vm: --mac must be a unicast address" >&2
    exit 2
  }
fi

if [[ -n ${tap_name} ]]; then
  [[ ${guest_ip_set} == true && -n ${mac_address} ]] || {
    echo "run-vm: --tap requires explicit --guest-ip and --mac values" >&2
    exit 2
  }
fi

instance=$(realpath "$1")
disk="${instance}/disk.qcow2"
base="${instance}/base"

[[ $(<"${instance}/format") == "prepared-v1" ]] || {
  echo "run-vm: not a prepared VM instance: ${instance}" >&2
  exit 1
}
[[ -f "${disk}" && -r "${base}/kernel" && -r "${base}/initrd" && -r "${base}/kernel-params" ]] || {
  echo "run-vm: prepared instance is incomplete: ${instance}" >&2
  exit 1
}

name=${instance##*/}
name=${name//[^A-Za-z0-9_.-]/-}
kernel_params=$(<"${base}/kernel-params")

kernel_params+=" benchmark.ip=${guest_ip} console=ttyS0"

memory_merge=off
if [[ ${ksm} == true ]]; then
  memory_merge=on
fi

qemu_args=(
  -name "guest=${name}"
  -nodefaults
  -no-user-config
  -no-reboot
  -display none
  -monitor none
  -accel kvm
  -machine "microvm,pit=on,pic=on,rtc=on,isa-serial=on,x-option-roms=on,auto-kernel-cmdline=on,memory-backend=ram"
  -cpu "host,-x2apic"
  -smp "cpus=${cpus},sockets=1,cores=${cpus},threads=1"
  -object "memory-backend-ram,id=ram,size=${memory}M,prealloc=off,merge=${memory_merge},dump=off"
  -kernel "${base}/kernel"
  -initrd "${base}/initrd"
  -append "${kernel_params}"
  -device "virtio-balloon-device,free-page-reporting=${free_page_reporting},free-page-hint=off,deflate-on-oom=off"
  -blockdev "driver=file,node-name=root-file,filename=${disk},aio=io_uring,cache.direct=off,cache.no-flush=off"
  -blockdev "driver=qcow2,node-name=root,file=root-file,discard=unmap"
  -device "virtio-blk-device,drive=root"
)

if [[ -n ${qmp_path} ]]; then
  qemu_args+=( -qmp "unix:${qmp_path},server=on,wait=off" )
fi

if [[ -n ${tap_name} ]]; then
  qemu_args+=(
    -netdev "tap,id=net0,ifname=${tap_name},script=no,downscript=no,vhost=on"
    -device "virtio-net-device,netdev=net0,mac=${mac_address}"
  )
else
  qemu_args+=(
    -netdev "user,id=net0,ipv6=off,restrict=on,hostfwd=tcp:127.0.0.1:${host_port}-${guest_address}:8080"
  )
  if [[ -n ${mac_address} ]]; then
    qemu_args+=( -device "virtio-net-device,netdev=net0,mac=${mac_address}" )
  else
    qemu_args+=( -device "virtio-net-device,netdev=net0" )
  fi
fi

if [[ -n ${console_path} ]]; then
  console_path=$(realpath -m "${console_path}")
  qemu_args+=( -serial "file:${console_path}" )
else
  qemu_args+=( -serial null )
fi

exec qemu-system-x86_64 "${qemu_args[@]}"
