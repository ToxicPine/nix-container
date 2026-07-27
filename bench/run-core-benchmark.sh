set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  run-core-benchmark --work-root DIR --output DIR \
    --ksm-pages-to-scan N --ksm-sleep-ms N \
    [--suite all|launch-cold|launch-warm|density|nginx] \
    [--density-blocks N] \
    [--temperature-sensor FILE]
EOF
  exit 2
}

die() {
  echo "run-core-benchmark: $*" >&2
  exit 1
}

work_root=
output_root=
ksm_pages_to_scan=
ksm_sleep_ms=
temperature_sensor=
suite=all
density_blocks=2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-root)
      [[ $# -ge 2 ]] || usage
      work_root=$2
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || usage
      output_root=$2
      shift 2
      ;;
    --ksm-pages-to-scan)
      [[ $# -ge 2 ]] || usage
      ksm_pages_to_scan=$2
      shift 2
      ;;
    --ksm-sleep-ms)
      [[ $# -ge 2 ]] || usage
      ksm_sleep_ms=$2
      shift 2
      ;;
    --temperature-sensor)
      [[ $# -ge 2 ]] || usage
      temperature_sensor=$2
      shift 2
      ;;
    --suite)
      [[ $# -ge 2 ]] || usage
      suite=$2
      shift 2
      ;;
    --density-blocks)
      [[ $# -ge 2 ]] || usage
      density_blocks=$2
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "must run as root"
case "${suite}" in
  all|launch-cold|launch-warm|density|nginx) ;;
  *) usage ;;
esac
[[ -n ${work_root} && -n ${output_root} &&
  ${ksm_pages_to_scan} =~ ^[1-9][0-9]*$ &&
  ${ksm_sleep_ms} =~ ^[1-9][0-9]*$ &&
  ${density_blocks} =~ ^[1-9][0-9]*$ ]] || usage

work_root=$(realpath "${work_root}")
output_root=$(realpath -m "${output_root}")
[[ -r ${work_root}/preparation.json &&
  -d ${work_root}/manifests ]] ||
  die "prepared benchmark root is incomplete: ${work_root}"
mkdir -p "${output_root}"
[[ -d ${output_root} ]] ||
  die "output root is not a directory: ${output_root}"

if [[ -z ${temperature_sensor} ]]; then
  for name_path in /sys/class/hwmon/hwmon*/name; do
    [[ -r ${name_path} && $(<"${name_path}") == k10temp ]] || continue
    hwmon_root=${name_path%/name}
    for label_path in "${hwmon_root}"/temp*_label; do
      [[ -r ${label_path} && $(<"${label_path}") == Tctl ]] || continue
      temperature_sensor=${label_path%_label}_input
      break 2
    done
  done
fi
[[ -n ${temperature_sensor} ]] ||
  die "could not resolve the k10temp Tctl sensor"
temperature_sensor=$(realpath "${temperature_sensor}")
[[ -r ${temperature_sensor} ]] ||
  die "temperature sensor is unreadable: ${temperature_sensor}"

prepare_host=@PREPARE_HOST@
prepare_cgroups=@PREPARE_CGROUPS@
cgroup_exec=@CGROUP_EXEC@
run_paired=@RUN_PAIRED@

host_state="${output_root}/host-state-${suite}"
[[ ! -e ${host_state} ]] ||
  die "host-state path already exists: ${host_state}"
cgroup_root=/sys/fs/cgroup/fast-vms
host_prepared=false
cgroups_prepared=false
cleanup_started=false

cleanup() {
  local cleanup_status=0
  if [[ ${cleanup_started} == true ]]; then
    return
  fi
  cleanup_started=true
  set +e
  if [[ ${cgroups_prepared} == true ]]; then
    "${prepare_cgroups}" remove "${cgroup_root}"
    ((cleanup_status |= $?))
  fi
  if [[ ${host_prepared} == true ]]; then
    "${prepare_host}" restore "${host_state}"
    ((cleanup_status |= $?))
  fi
  set -e
  ((cleanup_status == 0))
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"${prepare_host}" apply "${host_state}" 4-9 3 0-2
host_prepared=true
"${prepare_cgroups}" create "${cgroup_root}" 4-9 3
cgroups_prepared=true

run_suite() {
  local mode=$1
  local manifest_suffix=$2
  local blocks=$3
  local destination=$4
  shift 4
  "${cgroup_exec}" \
    "${cgroup_root}/client" \
    "${run_paired}" \
    "${mode}" \
    --container "${work_root}/manifests/container-${manifest_suffix}.json" \
    --vm-no-ksm "${work_root}/manifests/vm-no-ksm-${manifest_suffix}.json" \
    --vm-ksm "${work_root}/manifests/vm-ksm-${manifest_suffix}.json" \
    --output "${destination}" \
    --blocks "${blocks}" \
    --ksm-pages-to-scan "${ksm_pages_to_scan}" \
    --ksm-sleep-ms "${ksm_sleep_ms}" \
    --temperature-sensor "${temperature_sensor}" \
    --temperature-tolerance-millicelsius 1000 \
    --temperature-stable-seconds 30 \
    --temperature-timeout-seconds 900 \
    "$@"
}

if [[ ${suite} == all || ${suite} == launch-cold ]]; then
  run_suite \
    launch \
    launch-cold \
    30 \
    "${output_root}/launch-cold"
fi
if [[ ${suite} == all || ${suite} == launch-warm ]]; then
  run_suite \
    launch \
    launch-warm \
    30 \
    "${output_root}/launch-warm"
fi
if [[ ${suite} == all || ${suite} == density ]]; then
  run_suite \
    density \
    density \
    "${density_blocks}" \
    "${output_root}/density" \
    -- \
    --memory-envelope-bytes 17179869184
fi
if [[ ${suite} == all || ${suite} == nginx ]]; then
  run_suite \
    nginx \
    nginx \
    5 \
    "${output_root}/nginx"
fi

cleanup
trap - EXIT INT TERM
echo "core three-arm benchmark complete: ${output_root}"
