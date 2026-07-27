set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: run-paired-benchmark MODE OPTIONS [-- RUN-BENCHMARK_OPTIONS...]

Modes: launch, density, nginx

Options:
  --container MANIFEST
  --vm-no-ksm MANIFEST
  --vm-ksm MANIFEST
  --output DIR
  --blocks N             three-arm blocks (default: 5)
  --ksm-pages-to-scan N  KSM scan batch for the VM KSM arm
  --ksm-sleep-ms N       KSM scan interval for the VM KSM arm
  --temperature-sensor FILE
                         CPU temperature input in millidegrees Celsius
  --temperature-tolerance-millicelsius N
                         allowed heat above idle baseline (default: 1000)
  --temperature-stable-seconds N
                         continuous time at or below the ceiling (default: 30)
  --temperature-timeout-seconds N
                         maximum wait before failing (default: 900)

Every block runs container, VM without KSM, then VM with KSM. Density manifests
must label fresh pools with ramp numbers 1..N. Launch and nginx modes consume
one fresh instance per block in manifest order.
EOF
  exit 2
}

die() {
  echo "run-paired-benchmark: $*" >&2
  exit 1
}

run_temperature_hook() {
  [[ $# -eq 7 ]] ||
    die "internal temperature hook received the wrong number of arguments"
  local sensor=$1
  local upper_bound=$2
  local stable_seconds=$3
  local timeout_seconds=$4
  local trace_file=$5
  local block=$6
  local arm=$7
  local temperature
  local timestamp
  local stable_samples=0
  local start_seconds=${SECONDS}

  for value in \
    "${upper_bound}" \
    "${stable_seconds}" \
    "${timeout_seconds}" \
    "${block}"; do
    [[ ${value} =~ ^[1-9][0-9]*$ ]] ||
      die "internal temperature hook numeric arguments must be positive integers"
  done
  sensor=$(realpath "${sensor}")
  [[ -r ${sensor} ]] ||
    die "temperature sensor is not readable: ${sensor}"
  [[ -d $(dirname "${trace_file}") ]] ||
    die "temperature trace directory does not exist: ${trace_file}"

  while ((SECONDS - start_seconds < timeout_seconds)); do
    temperature=$(<"${sensor}")
    [[ ${temperature} =~ ^[0-9]+$ ]] ||
      die "temperature sensor returned a non-integer value"
    timestamp=$(date --iso-8601=ns)
    jq -cn \
      --arg phase post-warmup-waiting \
      --arg arm "${arm}" \
      --arg sensor "${sensor}" \
      --arg timestamp "${timestamp}" \
      --argjson block "${block}" \
      --argjson temperature_millicelsius "${temperature}" \
      --argjson maximum_temperature_millicelsius "${upper_bound}" \
      '{
        phase: $phase,
        block: $block,
        arm: $arm,
        timestamp: $timestamp,
        sensor: $sensor,
        temperature_millicelsius: $temperature_millicelsius,
        maximum_temperature_millicelsius:
          $maximum_temperature_millicelsius
      }' >>"${trace_file}"
    if ((temperature <= upper_bound)); then
      stable_samples=$((stable_samples + 1))
      if ((stable_samples >= stable_seconds)); then
        return
      fi
    else
      stable_samples=0
    fi
    sleep 1
  done
  die "CPU temperature did not return below the ceiling after ${arm} warm-up in block ${block}"
}

if [[ ${1:-} == temperature-hook ]]; then
  shift
  run_temperature_hook "$@"
  exit 0
fi

[[ $# -ge 1 ]] || usage
mode=$1
shift
case "${mode}" in
  launch|density|nginx) ;;
  *) usage ;;
esac

container_manifest=
vm_no_ksm_manifest=
vm_ksm_manifest=
output_dir=
blocks=5
ksm_pages_to_scan=
ksm_sleep_ms=
temperature_sensor=
temperature_tolerance=1000
temperature_stable_seconds=30
temperature_timeout_seconds=900
declare -a benchmark_options=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-no-ksm)
      [[ $# -ge 2 ]] || usage
      vm_no_ksm_manifest=$2
      shift 2
      ;;
    --vm-ksm)
      [[ $# -ge 2 ]] || usage
      vm_ksm_manifest=$2
      shift 2
      ;;
    --container)
      [[ $# -ge 2 ]] || usage
      container_manifest=$2
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || usage
      output_dir=$2
      shift 2
      ;;
    --blocks)
      [[ $# -ge 2 ]] || usage
      blocks=$2
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
    --temperature-tolerance-millicelsius)
      [[ $# -ge 2 ]] || usage
      temperature_tolerance=$2
      shift 2
      ;;
    --temperature-stable-seconds)
      [[ $# -ge 2 ]] || usage
      temperature_stable_seconds=$2
      shift 2
      ;;
    --temperature-timeout-seconds)
      [[ $# -ge 2 ]] || usage
      temperature_timeout_seconds=$2
      shift 2
      ;;
    --)
      shift
      benchmark_options=("$@")
      break
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n ${container_manifest} && -n ${vm_no_ksm_manifest} &&
  -n ${vm_ksm_manifest} && -n ${output_dir} &&
  -n ${ksm_pages_to_scan} && -n ${ksm_sleep_ms} &&
  -n ${temperature_sensor} ]] || usage
for value in "${blocks}" "${temperature_tolerance}" \
  "${temperature_stable_seconds}" "${temperature_timeout_seconds}" \
  "${ksm_pages_to_scan}" "${ksm_sleep_ms}"; do
  [[ ${value} =~ ^[1-9][0-9]*$ ]] ||
    die "block, temperature, and KSM options must be positive integers"
done
for option in "${benchmark_options[@]}"; do
  case "${option}" in
    --output|--repetitions|--samples|--ksm|--ksm-pages-to-scan|--ksm-sleep-ms)
      die "the coordinator owns ${option}; do not pass it after --"
      ;;
    *) ;;
  esac
done
temperature_sensor=$(realpath "${temperature_sensor}")
[[ -r ${temperature_sensor} ]] ||
  die "temperature sensor is not readable: ${temperature_sensor}"

container_manifest=$(realpath "${container_manifest}")
vm_no_ksm_manifest=$(realpath "${vm_no_ksm_manifest}")
vm_ksm_manifest=$(realpath "${vm_ksm_manifest}")
[[ -r ${container_manifest} && -r ${vm_no_ksm_manifest} &&
  -r ${vm_ksm_manifest} ]] ||
  die "all three manifests must be readable"
comparison_fields='{
  cache_condition,
  expected,
  resources,
  host_requirements
}'
container_comparison=$(jq -cS "${comparison_fields}" "${container_manifest}")
vm_no_ksm_comparison=$(jq -cS "${comparison_fields}" "${vm_no_ksm_manifest}")
vm_ksm_comparison=$(jq -cS "${comparison_fields}" "${vm_ksm_manifest}")
[[ ${container_comparison} == "${vm_no_ksm_comparison}" &&
  ${container_comparison} == "${vm_ksm_comparison}" ]] ||
  die "all three manifests must have identical expected responses, cache condition, resources, and host requirements"
paired_cache_condition=$(jq -r '.cache_condition' "${container_manifest}")
jq -e '
  [.instances[] | select(.launch | index("--ksm") != null)]
  | length == 0
' "${container_manifest}" >/dev/null ||
  die "the container manifest must not contain --ksm launch arguments"
jq -e '
  [.instances[] | select(.launch | index("--ksm") != null)]
  | length == 0
' "${vm_no_ksm_manifest}" >/dev/null ||
  die "the non-KSM VM manifest must not contain --ksm launch arguments"
jq -e '
  [.instances[] | select(.launch | index("--ksm") == null)]
  | length == 0
' "${vm_ksm_manifest}" >/dev/null ||
  die "every KSM VM launch command must contain --ksm"

for source_manifest in \
  "${container_manifest}" \
  "${vm_no_ksm_manifest}" \
  "${vm_ksm_manifest}"; do
  run-benchmark validate "${source_manifest}" >/dev/null
  case "${mode}" in
    launch|nginx)
      available_instances=$(jq '.instances | length' "${source_manifest}")
      ((available_instances >= blocks)) ||
        die "${source_manifest} needs at least ${blocks} fresh instances"
      ;;
    density)
      for ((required_ramp = 1; required_ramp <= blocks; required_ramp++)); do
        available_instances=$(jq --argjson ramp "${required_ramp}" '
          [.instances[] | select((.ramp // 1) == $ramp)] | length
        ' "${source_manifest}")
        ((available_instances > 0)) ||
          die "${source_manifest} has no instances for ramp ${required_ramp}"
      done
      ;;
    *)
      die "unreachable mode: ${mode}"
      ;;
  esac
done

mkdir -p "${output_dir}"
output_dir=$(realpath "${output_dir}")
order_file="${output_dir}/arm-order.jsonl"
thermal_file="${output_dir}/thermal-trace.jsonl"
paired_executable=$(realpath "$0")
existing_output=$(find "${output_dir}" -mindepth 1 -maxdepth 1 -print -quit)
[[ -z ${existing_output} ]] ||
  die "the coordinator output directory must be empty: ${output_dir}"

work_dir=$(mktemp -d "${output_dir}/.paired.XXXXXX")
cleanup() {
  rm -rf -- "${work_dir}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

read_temperature() {
  temperature=$(<"${temperature_sensor}")
  [[ ${temperature} =~ ^[0-9]+$ ]] ||
    die "temperature sensor returned a non-integer value"
}

record_temperature() {
  local phase=$1
  local block=$2
  local arm=$3
  local timestamp
  timestamp=$(date --iso-8601=ns)
  jq -cn \
    --arg phase "${phase}" \
    --arg arm "${arm}" \
    --arg sensor "${temperature_sensor}" \
    --arg timestamp "${timestamp}" \
    --argjson block "${block}" \
    --argjson temperature_millicelsius "${temperature}" \
    '{
      phase: $phase,
      block: $block,
      arm: $arm,
      timestamp: $timestamp,
      sensor: $sensor,
      temperature_millicelsius: $temperature_millicelsius
    }' >>"${thermal_file}"
}

capture_temperature_baseline() {
  local block=$1
  local range
  local median_index
  local start_seconds=${SECONDS}
  local -a temperatures=()
  local -a sorted_temperatures=()
  while ((SECONDS - start_seconds < temperature_timeout_seconds)); do
    read_temperature
    temperatures+=("${temperature}")
    record_temperature baseline "${block}" none
    if ((${#temperatures[@]} > temperature_stable_seconds)); then
      temperatures=("${temperatures[@]:1}")
    fi
    if ((${#temperatures[@]} == temperature_stable_seconds)); then
      printf '%s\n' "${temperatures[@]}" >"${work_dir}/baseline-temperatures"
      sort -n "${work_dir}/baseline-temperatures" \
        >"${work_dir}/baseline-temperatures-sorted"
      mapfile -t sorted_temperatures \
        <"${work_dir}/baseline-temperatures-sorted"
      range=$((
        sorted_temperatures[${#sorted_temperatures[@]} - 1] -
          sorted_temperatures[0]
      ))
      if ((range <= temperature_tolerance)); then
        median_index=$((${#sorted_temperatures[@]} / 2))
        baseline_temperature=${sorted_temperatures[median_index]}
        return
      fi
    fi
    sleep 1
  done
  die "CPU temperature did not reach a stable idle baseline"
}

wait_for_temperature_ceiling() {
  local block=$1
  local arm=$2
  local upper_bound=$((baseline_temperature + temperature_tolerance))
  local stable_samples=0
  local start_seconds=${SECONDS}
  while ((SECONDS - start_seconds < temperature_timeout_seconds)); do
    read_temperature
    record_temperature waiting "${block}" "${arm}"
    if ((temperature <= upper_bound)); then
      stable_samples=$((stable_samples + 1))
      if ((stable_samples >= temperature_stable_seconds)); then
        return
      fi
    else
      stable_samples=0
    fi
    sleep 1
  done
  die "CPU temperature did not return below the ceiling before ${arm} block ${block}"
}

filter_manifest() {
  local source=$1
  local block=$2
  local arm=$3
  local destination=$4
  local filtered_count
  local cache_condition
  local thermal_hook
  case "${mode}" in
    density)
      jq --argjson block "${block}" '
        .instances |= map(select((.ramp // 1) == $block))
        | .instances[].source_ramp = $block
        | .instances[].ramp = 1
      ' "${source}" >"${destination}"
      ;;
    launch|nginx)
      jq --argjson index "$((block - 1))" '
        .instances = [(.instances[$index] // empty)]
        | .instances[0].source_ramp = $index + 1
      ' "${source}" >"${destination}"
      ;;
    *)
      die "unreachable mode: ${mode}"
      ;;
  esac
  cache_condition=$(jq -r '.cache_condition' "${destination}")
  if [[ ${mode} == launch &&
    ${cache_condition} == cross-instance-warm ]]; then
    thermal_hook=$(jq -cn \
      --arg executable "${paired_executable}" \
      --arg sensor "${temperature_sensor}" \
      --arg upper_bound "$((baseline_temperature + temperature_tolerance))" \
      --arg stable_seconds "${temperature_stable_seconds}" \
      --arg timeout_seconds "${temperature_timeout_seconds}" \
      --arg trace_file "${thermal_file}" \
      --arg block "${block}" \
      --arg arm "${arm}" \
      '[
        $executable,
        "temperature-hook",
        $sensor,
        $upper_bound,
        $stable_seconds,
        $timeout_seconds,
        $trace_file,
        $block,
        $arm
      ]')
    jq --argjson thermal_hook "${thermal_hook}" '
      .hooks.before_sample =
        ((.hooks.before_sample // []) + [$thermal_hook])
    ' "${destination}" >"${destination}.thermal"
    mv "${destination}.thermal" "${destination}"
  fi
  filtered_count=$(jq '.instances | length' "${destination}")
  ((filtered_count > 0)) ||
    die "${source} has no fresh instances for block ${block}"
}

run_arm() {
  local label=$1
  local source_manifest=$2
  local block=$3
  local filtered_manifest="${work_dir}/${label}-${block}.json"
  local block_output="${output_dir}/block-${block}/${label}"
  local -a mode_options=()
  filter_manifest \
    "${source_manifest}" \
    "${block}" \
    "${label}" \
    "${filtered_manifest}"
  case "${mode}" in
    density)
      mode_options=(--repetitions 1)
      ;;
    launch)
      mode_options=(--samples 1)
      ;;
    nginx)
      mode_options=(--repetitions 1)
      if ((block > 1)); then
        mode_options+=(--sustained-seconds 0)
      fi
      ;;
    *)
      die "unreachable mode: ${mode}"
      ;;
  esac
  if [[ ${label} == vm-ksm ]]; then
    mode_options+=(
      --ksm
      --ksm-pages-to-scan "${ksm_pages_to_scan}"
      --ksm-sleep-ms "${ksm_sleep_ms}"
    )
  fi
  run-benchmark \
    "${mode}" \
    --output "${block_output}" \
    "${mode_options[@]}" \
    "${benchmark_options[@]}" \
    "${filtered_manifest}"
}

capture_arm_environment() {
  local label=$1
  local source_manifest=$2
  local -a mode_options=()
  if [[ ${label} == vm-ksm ]]; then
    mode_options=(
      --ksm
      --ksm-pages-to-scan "${ksm_pages_to_scan}"
      --ksm-sleep-ms "${ksm_sleep_ms}"
    )
  fi
  run-benchmark \
    environment \
    --output "${output_dir}/environment/${label}" \
    "${mode_options[@]}" \
    "${source_manifest}"
}

capture_arm_environment container "${container_manifest}"
capture_arm_environment vm-no-ksm "${vm_no_ksm_manifest}"
capture_arm_environment vm-ksm "${vm_ksm_manifest}"

for ((block = 1; block <= blocks; block++)); do
  capture_temperature_baseline "${block}"
  jq -cn \
    --arg mode "${mode}" \
    --arg sensor "${temperature_sensor}" \
    --argjson block "${block}" \
    --argjson baseline_temperature_millicelsius "${baseline_temperature}" \
    --argjson tolerance_millicelsius "${temperature_tolerance}" \
    --argjson ksm_pages_to_scan "${ksm_pages_to_scan}" \
    --argjson ksm_sleep_milliseconds "${ksm_sleep_ms}" \
    --argjson maximum_temperature_millicelsius \
      "$((baseline_temperature + temperature_tolerance))" \
    '{
      mode: $mode,
      block: $block,
      order: ["container", "vm-no-ksm", "vm-ksm"],
      temperature_sensor: $sensor,
      baseline_temperature_millicelsius: $baseline_temperature_millicelsius,
      tolerance_millicelsius: $tolerance_millicelsius,
      maximum_temperature_millicelsius: $maximum_temperature_millicelsius,
      ksm: {
        arm: "vm-ksm",
        pages_to_scan: $ksm_pages_to_scan,
        sleep_milliseconds: $ksm_sleep_milliseconds
      }
    }' \
    >>"${order_file}"

  if [[ ${mode} != launch ||
    ${paired_cache_condition} != cross-instance-warm ]]; then
    wait_for_temperature_ceiling "${block}" container
  fi
  run_arm container "${container_manifest}" "${block}"
  if [[ ${mode} != launch ||
    ${paired_cache_condition} != cross-instance-warm ]]; then
    wait_for_temperature_ceiling "${block}" vm-no-ksm
  fi
  run_arm vm-no-ksm "${vm_no_ksm_manifest}" "${block}"
  if [[ ${mode} != launch ||
    ${paired_cache_condition} != cross-instance-warm ]]; then
    wait_for_temperature_ceiling "${block}" vm-ksm
  fi
  run_arm vm-ksm "${vm_ksm_manifest}" "${block}"
done

combined_raw="${output_dir}/paired-${mode}.jsonl"
for ((block = 1; block <= blocks; block++)); do
  for label in container vm-no-ksm vm-ksm; do
    arm_raw="${output_dir}/block-${block}/${label}/raw/${mode}.jsonl"
    [[ -s ${arm_raw} ]] ||
      die "paired run is missing records: ${arm_raw}"
    jq -c \
      --arg benchmark_arm "${label}" \
      --argjson paired_block "${block}" \
      '. + {
        benchmark_arm: $benchmark_arm,
        paired_block: $paired_block
      }' "${arm_raw}" \
      >>"${combined_raw}"
  done
done
summarize-benchmark \
  --output "${output_dir}/summary.json" \
  "${combined_raw}"

echo "three-arm ${mode} benchmark complete: ${output_dir}"
