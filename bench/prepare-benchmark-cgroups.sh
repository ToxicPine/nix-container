set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  prepare-benchmark-cgroups create PARENT TARGET_CPUS CLIENT_CPUS
  prepare-benchmark-cgroups remove PARENT

PARENT must be a new direct child of the cgroup v2 mount. The tool creates
PARENT/target and PARENT/client as exclusive, load-balanced partition roots.
SMT must already be disabled. Removal refuses non-empty cgroups.
EOF
  exit 2
}

die() {
  echo "prepare-benchmark-cgroups: $*" >&2
  exit 1
}

expand_cpu_list() {
  local cpu_list=$1
  local output=$2
  awk -v cpu_list="${cpu_list}" '
    BEGIN {
      item_count = split(cpu_list, items, ",")
      for (item = 1; item <= item_count; item++) {
        range_count = split(items[item], range, "-")
        first = range[1] + 0
        last = range_count == 2 ? range[2] + 0 : first
        for (cpu = first; cpu <= last; cpu++) print cpu
      }
    }
  ' | sort -n -u >"${output}"
}

[[ ${EUID} -eq 0 ]] || die "must run as root"
[[ $# -ge 2 ]] || usage
mode=$1
requested_parent=$2
shift 2

cgroup_root=$(findmnt -n -o TARGET -t cgroup2)
[[ -n ${cgroup_root} ]] || die "cgroup v2 is not mounted"
parent=$(realpath -m "${requested_parent}")
[[ $(dirname "${parent}") == "${cgroup_root}" ]] ||
  die "PARENT must be a direct child of ${cgroup_root}"
[[ ${parent} != "${cgroup_root}" ]] || die "refusing cgroup v2 mount as PARENT"
target="${parent}/target"
client="${parent}/client"

work_dir=$(mktemp -d)
create_in_progress=false
create_complete=false

set_cgroup_empty() {
  local path=$1
  cgroup_empty=false
  if [[ -r ${path}/cgroup.procs &&
    -z $(<"${path}/cgroup.procs") ]]; then
    cgroup_empty=true
  fi
  return 0
}

rollback_partial_create() {
  if [[ ${create_in_progress} == true && ${create_complete} == false ]]; then
    if [[ -d ${target} ]]; then
      set_cgroup_empty "${target}"
      if [[ ${cgroup_empty} == true ]]; then
        printf 'member\n' >"${target}/cpuset.cpus.partition" 2>/dev/null || true
        rmdir "${target}" 2>/dev/null || true
      fi
    fi
    if [[ -d ${client} ]]; then
      set_cgroup_empty "${client}"
      if [[ ${cgroup_empty} == true ]]; then
        printf 'member\n' >"${client}/cpuset.cpus.partition" 2>/dev/null || true
        rmdir "${client}" 2>/dev/null || true
      fi
    fi
    if [[ -d ${parent} ]]; then
      set_cgroup_empty "${parent}"
      if [[ ${cgroup_empty} == true ]]; then
        printf 'member\n' >"${parent}/cpuset.cpus.partition" 2>/dev/null || true
        rmdir "${parent}" 2>/dev/null || true
      fi
    fi
  fi
  rm -rf -- "${work_dir}"
}

trap rollback_partial_create EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

enable_controller() {
  local subtree=$1
  local controller=$2
  if [[ " $(<"${subtree}/cgroup.subtree_control") " != *" ${controller} "* ]]; then
    printf '+%s\n' "${controller}" >"${subtree}/cgroup.subtree_control"
  fi
}

configure_partition() {
  local path=$1
  local cpus=$2
  local mems=$3
  printf '%s\n' "${mems}" >"${path}/cpuset.mems"
  printf '%s\n' "${cpus}" >"${path}/cpuset.cpus"
  printf '%s\n' "${cpus}" >"${path}/cpuset.cpus.exclusive"
  printf 'max 100000\n' >"${path}/cpu.max"
  printf 'max\n' >"${path}/memory.max"
  printf 'max\n' >"${path}/memory.high"
  printf 'root\n' >"${path}/cpuset.cpus.partition"
}

case "${mode}" in
  create)
    [[ $# -eq 2 ]] || usage
    target_cpus=$1
    client_cpus=$2
    [[ ! -e ${parent} ]] ||
      die "refusing existing benchmark cgroup: ${parent}"
    [[ $(</sys/devices/system/cpu/smt/control) == off ]] ||
      die "SMT must be disabled before creating benchmark partitions"

    expand_cpu_list "${target_cpus}" "${work_dir}/target"
    expand_cpu_list "${client_cpus}" "${work_dir}/client"
    online_cpus=$(</sys/devices/system/cpu/online)
    expand_cpu_list "${online_cpus}" "${work_dir}/online"
    comm -12 "${work_dir}/target" "${work_dir}/client" \
      >"${work_dir}/overlap"
    [[ ! -s ${work_dir}/overlap ]] ||
      die "target and client CPU sets overlap"
    cat "${work_dir}/target" "${work_dir}/client" |
      sort -n -u >"${work_dir}/benchmark"
    comm -23 "${work_dir}/benchmark" "${work_dir}/online" \
      >"${work_dir}/offline-requested"
    [[ ! -s ${work_dir}/offline-requested ]] ||
      die "a requested benchmark CPU is offline"
    comm -23 "${work_dir}/online" "${work_dir}/benchmark" \
      >"${work_dir}/housekeeping"
    [[ -s ${work_dir}/housekeeping ]] ||
      die "at least one online physical core must remain for housekeeping"

    create_in_progress=true
    for controller in cpuset cpu memory; do
      enable_controller "${cgroup_root}" "${controller}"
    done
    mkdir "${parent}"
    root_mems=$(<"${cgroup_root}/cpuset.mems.effective")
    benchmark_cpus=$(paste -sd, "${work_dir}/benchmark")
    configure_partition "${parent}" "${benchmark_cpus}" "${root_mems}"
    for controller in cpuset cpu memory; do
      enable_controller "${parent}" "${controller}"
    done

    mkdir "${target}" "${client}"
    configure_partition "${target}" "${target_cpus}" "${root_mems}"
    configure_partition "${client}" "${client_cpus}" "${root_mems}"

    [[ $(<"${parent}/cpuset.cpus.partition") == root &&
      $(<"${target}/cpuset.cpus.partition") == root &&
      $(<"${client}/cpuset.cpus.partition") == root ]] ||
      die "kernel rejected one or more benchmark partition roots"
    create_complete=true
    housekeeping_cpus=$(paste -sd, "${work_dir}/housekeeping")
    echo "created target partition ${target} on CPUs ${target_cpus}"
    echo "created client partition ${client} on CPUs ${client_cpus}"
    echo "housekeeping CPUs: ${housekeeping_cpus}"
    ;;
  remove)
    [[ $# -eq 0 ]] || usage
    [[ -d ${parent} && -d ${target} && -d ${client} ]] ||
      die "benchmark cgroup hierarchy is incomplete: ${parent}"
    set_cgroup_empty "${target}"
    target_empty=${cgroup_empty}
    set_cgroup_empty "${client}"
    client_empty=${cgroup_empty}
    set_cgroup_empty "${parent}"
    parent_empty=${cgroup_empty}
    if [[ ${target_empty} == false ||
      ${client_empty} == false ||
      ${parent_empty} == false ]]; then
      die "refusing to remove non-empty benchmark cgroups"
    fi
    printf 'member\n' >"${target}/cpuset.cpus.partition"
    printf 'member\n' >"${client}/cpuset.cpus.partition"
    rmdir "${target}" "${client}"
    printf 'member\n' >"${parent}/cpuset.cpus.partition"
    rmdir "${parent}"
    echo "removed ${parent}"
    ;;
  *)
    usage
    ;;
esac
