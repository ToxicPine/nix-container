set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  prepare-benchmark-host apply STATE_DIR TARGET_CPUS CLIENT_CPUS HOUSEKEEPING_CPUS
  prepare-benchmark-host restore STATE_DIR

STATE_DIR is a new, persistent directory used to restore host settings after
the benchmark. Run as root. Apply disables SMT, swap, THP, boost, and
irqbalance; fixes target/client frequency; and moves configurable IRQs and
unbound workqueues to the housekeeping CPUs.
EOF
  exit 2
}

die() {
  echo "prepare-benchmark-host: $*" >&2
  exit 1
}

[[ ${EUID} -eq 0 ]] || die "must run as root"
[[ $# -ge 2 ]] || usage
action=$1
state_dir=$2
shift 2

expand_cpu_list() {
  local cpu_list=$1
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
  ' | sort -n -u
}

selected_value() {
  sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$1"
}

cpu_list_mask() {
  local cpu_list=$1
  local cpu
  local mask=0
  local expanded_cpus
  expanded_cpus=$(expand_cpu_list "${cpu_list}")
  while IFS= read -r cpu; do
    ((cpu < 63)) ||
      die "runtime workqueue mask helper supports CPU IDs below 63"
    mask=$((mask | (1 << cpu)))
  done <<<"${expanded_cpus}"
  printf '%x\n' "${mask}"
}

restore_state() {
  local state=$1
  local cpu
  local minimum
  local maximum
  local governor
  local irq
  local affinity
  local swap_name
  local swap_priority
  local frequency_path

  if [[ -r ${state}/irq-affinity.tsv ]]; then
    while IFS=$'\t' read -r irq affinity; do
      [[ -w /proc/irq/${irq}/smp_affinity_list ]] || continue
      printf '%s\n' "${affinity}" \
        >"/proc/irq/${irq}/smp_affinity_list" 2>/dev/null || true
    done <"${state}/irq-affinity.tsv"
  fi
  if [[ -r ${state}/workqueue-cpumask &&
    -w /sys/devices/virtual/workqueue/cpumask ]]; then
    <"${state}/workqueue-cpumask" \
      tee /sys/devices/virtual/workqueue/cpumask >/dev/null
  fi
  if [[ -r ${state}/frequency.tsv ]]; then
    while IFS=$'\t' read -r cpu minimum maximum governor; do
      frequency_path=/sys/devices/system/cpu/cpu"${cpu}"/cpufreq
      [[ -d ${frequency_path} ]] || continue
      printf '%s\n' "${minimum}" >"${frequency_path}/scaling_min_freq"
      printf '%s\n' "${maximum}" >"${frequency_path}/scaling_max_freq"
      printf '%s\n' "${governor}" >"${frequency_path}/scaling_governor"
    done <"${state}/frequency.tsv"
  fi
  if [[ -r ${state}/boost &&
    -w /sys/devices/system/cpu/cpufreq/boost ]]; then
    <"${state}/boost" tee /sys/devices/system/cpu/cpufreq/boost >/dev/null
  fi
  if [[ -r ${state}/thp-enabled ]]; then
    <"${state}/thp-enabled" \
      tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null
  fi
  if [[ -r ${state}/thp-defrag ]]; then
    <"${state}/thp-defrag" \
      tee /sys/kernel/mm/transparent_hugepage/defrag >/dev/null
  fi
  if [[ -r ${state}/smt-control &&
    $(<"${state}/smt-control") == on ]]; then
    printf 'on\n' > /sys/devices/system/cpu/smt/control
  fi
  if [[ -r ${state}/swaps.tsv ]]; then
    while read -r swap_name swap_priority; do
      [[ -n ${swap_name} ]] || continue
      swapon --priority "${swap_priority}" -- "${swap_name}"
    done <"${state}/swaps.tsv"
  fi
  if [[ -r ${state}/irqbalance-active &&
    $(<"${state}/irqbalance-active") == active ]]; then
    systemctl start irqbalance
  fi
}

case "${action}" in
  apply)
    [[ $# -eq 3 ]] || usage
    target_cpus=$1
    client_cpus=$2
    housekeeping_cpus=$3
    state_dir=$(realpath -m "${state_dir}")
    [[ ${state_dir} != / && ! -e ${state_dir} ]] ||
      die "STATE_DIR must be a new, non-root path"
    mkdir -p "${state_dir}"
    chmod 0700 "${state_dir}"
    apply_complete=false
    cleanup_apply() {
      if [[ ${apply_complete} == false ]]; then
        restore_state "${state_dir}"
      fi
    }
    trap cleanup_apply EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    expand_cpu_list "${target_cpus}" >"${state_dir}/target-cpus"
    expand_cpu_list "${client_cpus}" >"${state_dir}/client-cpus"
    expand_cpu_list "${housekeeping_cpus}" >"${state_dir}/housekeeping-cpus"
    cat \
      "${state_dir}/target-cpus" \
      "${state_dir}/client-cpus" \
      "${state_dir}/housekeeping-cpus" |
      sort -n -u >"${state_dir}/allocated-cpus"
    expand_cpu_list "$(< /sys/devices/system/cpu/online)" \
      >"${state_dir}/online-cpus-before"
    comm -12 "${state_dir}/target-cpus" "${state_dir}/client-cpus" \
      >"${state_dir}/overlap"
    [[ ! -s ${state_dir}/overlap ]] ||
      die "target and client CPUs overlap"

    cat /sys/devices/system/cpu/smt/control >"${state_dir}/smt-control"
    [[ $(<"${state_dir}/smt-control") == on ]] ||
      die "SMT must initially be on so the saved state is restorable"
    swapon --show=NAME,PRIO --noheadings --raw \
      >"${state_dir}/swaps.tsv"
    selected_value /sys/kernel/mm/transparent_hugepage/enabled \
      >"${state_dir}/thp-enabled"
    selected_value /sys/kernel/mm/transparent_hugepage/defrag \
      >"${state_dir}/thp-defrag"
    cat /sys/devices/system/cpu/cpufreq/boost >"${state_dir}/boost"
    cat /sys/devices/virtual/workqueue/cpumask \
      >"${state_dir}/workqueue-cpumask"
    systemctl is-active irqbalance >"${state_dir}/irqbalance-active" || true
    : >"${state_dir}/frequency.tsv"
    : >"${state_dir}/irq-affinity.tsv"

    if [[ $(<"${state_dir}/irqbalance-active") == active ]]; then
      systemctl stop irqbalance
    fi
    swapoff --all
    printf 'never\n' > /sys/kernel/mm/transparent_hugepage/enabled
    printf 'never\n' > /sys/kernel/mm/transparent_hugepage/defrag
    printf '0\n' > /sys/devices/system/cpu/cpufreq/boost
    printf 'off\n' > /sys/devices/system/cpu/smt/control

    cat \
      "${state_dir}/target-cpus" \
      "${state_dir}/client-cpus" |
      sort -n -u >"${state_dir}/frequency-cpus"
    fixed_frequency=
    while IFS= read -r cpu; do
      frequency_path=/sys/devices/system/cpu/cpu"${cpu}"/cpufreq
      [[ -d ${frequency_path} ]] ||
        die "CPU ${cpu} does not expose cpufreq controls"
      printf '%s\t%s\t%s\t%s\n' \
        "${cpu}" \
        "$(<"${frequency_path}/scaling_min_freq")" \
        "$(<"${frequency_path}/scaling_max_freq")" \
        "$(<"${frequency_path}/scaling_governor")" \
        >>"${state_dir}/frequency.tsv"
      nominal_frequency_path=/sys/devices/system/cpu/cpu"${cpu}"/acpi_cppc/nominal_freq
      [[ -r ${nominal_frequency_path} ]] ||
        die "CPU ${cpu} does not expose ACPI CPPC nominal frequency"
      cpu_nominal_frequency=$(<"${nominal_frequency_path}")
      cpu_nominal_frequency=$((cpu_nominal_frequency * 1000))
      if [[ -z ${fixed_frequency} ||
        ${cpu_nominal_frequency} -lt ${fixed_frequency} ]]; then
        fixed_frequency=${cpu_nominal_frequency}
      fi
    done <"${state_dir}/frequency-cpus"
    printf '%s\n' "${fixed_frequency}" >"${state_dir}/fixed-frequency"
    while IFS= read -r cpu; do
      frequency_path=/sys/devices/system/cpu/cpu"${cpu}"/cpufreq
      if [[ -w ${frequency_path}/scaling_governor ]]; then
        printf 'performance\n' >"${frequency_path}/scaling_governor"
      fi
      printf '%s\n' "${fixed_frequency}" \
        >"${frequency_path}/scaling_max_freq"
      printf '%s\n' "${fixed_frequency}" \
        >"${frequency_path}/scaling_min_freq"
    done <"${state_dir}/frequency-cpus"

    workqueue_mask=$(cpu_list_mask "${housekeeping_cpus}")
    printf '%s\n' "${workqueue_mask}" \
      > /sys/devices/virtual/workqueue/cpumask
    for affinity_path in /proc/irq/[0-9]*/smp_affinity_list; do
      [[ -r ${affinity_path} && -w ${affinity_path} ]] || continue
      irq=${affinity_path#/proc/irq/}
      irq=${irq%/smp_affinity_list}
      affinity=$(<"${affinity_path}")
      printf '%s\t%s\n' "${irq}" "${affinity}" \
        >>"${state_dir}/irq-affinity.tsv"
      printf '%s\n' "${housekeeping_cpus}" \
        >"${affinity_path}" 2>/dev/null || true
    done

    expand_cpu_list "$(< /sys/devices/system/cpu/online)" \
      >"${state_dir}/online-cpus-after"
    cmp --silent \
      "${state_dir}/allocated-cpus" \
      "${state_dir}/online-cpus-after" ||
      die "target, client, and housekeeping CPUs do not partition SMT-off CPUs"
    swap_line_count=$(wc -l </proc/swaps)
    ((swap_line_count == 1)) ||
      die "swap remains active"
    [[ $(</sys/kernel/mm/ksm/run) -eq 0 &&
      $(</sys/kernel/mm/ksm/pages_sharing) -eq 0 ]] ||
      die "KSM must be stopped and fully unmerged before host preparation"

    apply_complete=true
    trap - EXIT INT TERM
    echo "benchmark host controls applied; restore with:"
    echo "  prepare-benchmark-host restore ${state_dir}"
    ;;
  restore)
    [[ $# -eq 0 ]] || usage
    state_dir=$(realpath "${state_dir}")
    [[ -r ${state_dir}/smt-control &&
      -r ${state_dir}/swaps.tsv &&
      -r ${state_dir}/frequency.tsv ]] ||
      die "STATE_DIR is not a complete saved host state"
    restore_state "${state_dir}"
    echo "benchmark host controls restored from ${state_dir}"
    ;;
  *) usage ;;
esac
