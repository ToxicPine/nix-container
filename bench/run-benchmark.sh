set -euo pipefail

readonly schema="fast-vms-benchmark-v1"
readonly default_body_sha256="edf03332c6ca9e23cc6b21849fd76e032c59634312e1c787290816f8e8a5fa00"
readonly mib=$((1024 * 1024))
readonly gib=$((1024 * 1024 * 1024))
readonly benchmark_source="@BENCHMARK_SOURCE@"
readonly benchmark_revision="@BENCHMARK_REVISION@"

usage() {
  cat >&2 <<'EOF'
usage:
  run-benchmark validate MANIFEST
  run-benchmark environment --output DIR MANIFEST
  run-benchmark launch [OPTIONS] MANIFEST
  run-benchmark density [OPTIONS] MANIFEST
  run-benchmark nginx [OPTIONS] MANIFEST

Common options:
  --output DIR                 result directory (required except for validate)
  --repetitions N              complete repetitions (suite defaults apply)

Launch options:
  --samples N                  fresh-instance samples (default: 30)

Density options:
  --memory-envelope-gib N      whole-deployment budget (default: 16)
  --memory-envelope-bytes N    exact whole-deployment budget
  --idle-seconds N             settle before idle sample (default: 30)
  --platform-settle-seconds N  settle helpers before fixed sample (default: 30)
  --load-seconds N             light-load duration (default: 60)
  --load-rate N                requests/s per instance (default: 10)
  --prediction-margin-percent N
                               next-instance forecast margin (default: 5)
  --density-bootstrap-instances N
                               first checkpoint size (default: 4)
  --density-max-batch N        largest adaptive addition (default: 64)
  --density-single-step-at N   use single additions when at most N fit
                               (default: 8)
  --ksm                        run the separately labelled VM KSM arm
  --ksm-pages-to-scan N        KSM scan batch (required with --ksm)
  --ksm-sleep-ms N             KSM scan interval (required with --ksm)

Nginx options:
  --sample-seconds N           measured duration (default: 60)
  --warmup-seconds N           warm-up duration (default: 10)
  --sustained-seconds N        sustained duration; 0 disables (default: 600)
  --sustained-concurrency N    sustained sample concurrency (default: 32)

The manifest supplies already-prepared instances, direct URLs, argv arrays,
pre-created cgroups, and optional platform processes/hooks. See
bench/benchmark-manifest.example.json.
EOF
  exit 2
}

die() {
  echo "run-benchmark: $*" >&2
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

manifest=
output_dir=
repetitions=
samples=30
memory_envelope_bytes=$((16 * gib))
idle_seconds=30
platform_settle_seconds=30
load_seconds=60
load_rate=10
prediction_margin_percent=5
density_bootstrap_instances=4
density_max_batch=64
density_single_step_at=8
density_launch_headroom_bytes=$((512 * mib))
sample_seconds=60
warmup_seconds=10
sustained_seconds=600
sustained_concurrency=32
ksm_enabled=false
ksm_pages_to_scan=
ksm_sleep_ms=

[[ $# -ge 2 ]] || usage
mode=$1
shift

case "${mode}" in
  validate|environment|launch|density|nginx) ;;
  *) usage ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || usage
      output_dir=$2
      shift 2
      ;;
    --repetitions)
      [[ $# -ge 2 ]] || usage
      repetitions=$2
      shift 2
      ;;
    --samples)
      [[ $# -ge 2 ]] || usage
      samples=$2
      shift 2
      ;;
    --memory-envelope-gib)
      [[ $# -ge 2 ]] || usage
      [[ $2 =~ ^[1-9][0-9]*$ ]] ||
        die "--memory-envelope-gib must be a positive integer"
      memory_envelope_bytes=$(("$2" * gib))
      shift 2
      ;;
    --memory-envelope-bytes)
      [[ $# -ge 2 ]] || usage
      memory_envelope_bytes=$2
      shift 2
      ;;
    --idle-seconds)
      [[ $# -ge 2 ]] || usage
      idle_seconds=$2
      shift 2
      ;;
    --platform-settle-seconds)
      [[ $# -ge 2 ]] || usage
      platform_settle_seconds=$2
      shift 2
      ;;
    --load-seconds)
      [[ $# -ge 2 ]] || usage
      load_seconds=$2
      shift 2
      ;;
    --load-rate)
      [[ $# -ge 2 ]] || usage
      load_rate=$2
      shift 2
      ;;
    --prediction-margin-percent)
      [[ $# -ge 2 ]] || usage
      prediction_margin_percent=$2
      shift 2
      ;;
    --density-bootstrap-instances)
      [[ $# -ge 2 ]] || usage
      density_bootstrap_instances=$2
      shift 2
      ;;
    --density-max-batch)
      [[ $# -ge 2 ]] || usage
      density_max_batch=$2
      shift 2
      ;;
    --density-single-step-at)
      [[ $# -ge 2 ]] || usage
      density_single_step_at=$2
      shift 2
      ;;
    --sample-seconds)
      [[ $# -ge 2 ]] || usage
      sample_seconds=$2
      shift 2
      ;;
    --warmup-seconds)
      [[ $# -ge 2 ]] || usage
      warmup_seconds=$2
      shift 2
      ;;
    --sustained-seconds)
      [[ $# -ge 2 ]] || usage
      sustained_seconds=$2
      shift 2
      ;;
    --sustained-concurrency)
      [[ $# -ge 2 ]] || usage
      sustained_concurrency=$2
      shift 2
      ;;
    --ksm)
      ksm_enabled=true
      shift
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
    --)
      shift
      break
      ;;
    -*)
      echo "run-benchmark: unknown option: $1" >&2
      usage
      ;;
    *)
      [[ -z ${manifest} ]] || usage
      manifest=$1
      shift
      ;;
  esac
done

[[ $# -eq 0 && -n ${manifest} ]] || usage
manifest=$(realpath "${manifest}")
[[ -r ${manifest} ]] || die "manifest is not readable: ${manifest}"

for value in "${samples}" "${memory_envelope_bytes}" "${idle_seconds}" \
  "${platform_settle_seconds}" "${load_seconds}" "${load_rate}" \
  "${prediction_margin_percent}" \
  "${density_bootstrap_instances}" "${density_max_batch}" \
  "${density_single_step_at}" \
  "${sample_seconds}" "${warmup_seconds}" \
  "${sustained_concurrency}"; do
  [[ ${value} =~ ^[1-9][0-9]*$ ]] ||
    die "numeric options must be positive integers"
done
[[ ${sustained_seconds} =~ ^[0-9]+$ ]] ||
  die "--sustained-seconds must be a non-negative integer"

if [[ -z ${repetitions} ]]; then
  if [[ ${mode} == density ]]; then
    repetitions=2
  else
    repetitions=1
  fi
fi
[[ ${repetitions} =~ ^[1-9][0-9]*$ ]] ||
  die "--repetitions must be a positive integer"

validate_manifest() {
  jq -e --arg schema "${schema}" '
    def command:
      type == "array"
      and length > 0
      and all(.[]; type == "string" and (contains("\n") | not));
    .schema == $schema
    and (.target | type == "string" and length > 0)
    and (.cache_condition == "host-cold" or .cache_condition == "cross-instance-warm")
    and (.instances | type == "array" and length > 0)
    and ([
      .instances[] |
      (.id | type == "string" and length > 0),
      (.url | type == "string" and startswith("http://")),
      (.network_interface | type == "string" and length > 0),
      ((.prepare // []) | type == "array" and all(.[]; command)),
      (.launch | command),
      ((.stop // []) | type == "array" and all(.[]; command)),
      ((.cleanup // []) | type == "array" and all(.[]; command)),
      ((.ramp // 1) | type == "number" and floor == . and . > 0)
    ] | all)
    and ([.instances[].id] | length == (unique | length))
    and ((.platform.launch // []) | type == "array")
    and (all(.platform.launch[]?; command))
    and ((.platform.ready // []) | type == "array")
    and (all(.platform.ready[]?; command))
    and ((.platform.stop // []) | type == "array")
    and (all(.platform.stop[]?; command))
    and (.resources.target_cgroup | type == "string" and length > 0)
    and (.resources.client_cgroup | type == "string" and length > 0)
    and (.resources.target_cpus | type == "string" and length > 0)
    and (.resources.client_cpus | type == "string" and length > 0)
    and (.resources.housekeeping_cpus | type == "string" and length > 0)
    and (.residency_files | type == "array" and length > 0)
    and (all(.residency_files[]; type == "string" and length > 0))
    and ([
      .hooks.before_baseline[]?,
      .hooks.before_suite[]?,
      .hooks.before_sample[]?,
      .hooks.after_suite[]?
    ] | all(command))
    and (((.host_requirements // {}) | type) == "object")
    and (all((.host_requirements // {}) | to_entries[]?;
      .value | type == "boolean"))
  ' "${manifest}" >/dev/null || die "manifest does not satisfy ${schema}"

  local duplicate_url_count
  local duplicate_interface_count
  duplicate_url_count=$(jq '
    [
      .instances[]
      | { ramp: (.ramp // 1), value: .url }
    ]
    | group_by(.ramp)
    | map(([.[].value] | length) - ([.[].value] | unique | length))
    | add // 0
  ' "${manifest}")
  [[ ${duplicate_url_count} -eq 0 ]] ||
    die "instance URLs must be unique within each density ramp"
  duplicate_interface_count=$(jq '
    [
      .instances[]
      | { ramp: (.ramp // 1), value: .network_interface }
    ]
    | group_by(.ramp)
    | map(([.[].value] | length) - ([.[].value] | unique | length))
    | add // 0
  ' "${manifest}")
  [[ ${duplicate_interface_count} -eq 0 ]] ||
    die "instance network interfaces must be unique within each density ramp"
}

validate_manifest

if [[ ${mode} == density ]] &&
  ! jq -e '.private_cache_eviction == true' "${manifest}" >/dev/null; then
  die "adaptive density runs require private-cache eviction in instance cleanup"
fi

if [[ ${mode} == validate ]]; then
  echo "valid ${schema} manifest: ${manifest}"
  exit 0
fi

[[ -n ${output_dir} ]] || die "--output is required for ${mode}"
mkdir -p "${output_dir}"
output_dir=$(realpath "${output_dir}")
mkdir -p "${output_dir}/logs" "${output_dir}/raw"
raw_file="${output_dir}/raw/${mode}.jsonl"
[[ ! -s ${raw_file} ]] ||
  die "refusing to append to an existing result stream: ${raw_file}"
touch "${raw_file}"
manifest_copy="${output_dir}/${mode}-manifest.json"
if [[ -e ${manifest_copy} ]]; then
  cmp --silent "${manifest}" "${manifest_copy}" ||
    die "result directory contains a different ${mode} manifest"
else
  cp -- "${manifest}" "${manifest_copy}"
fi

target=$(jq -r '.target' "${manifest}")
cache_condition=$(jq -r '.cache_condition' "${manifest}")
target_cgroup=$(jq -r '.resources.target_cgroup' "${manifest}")
client_cgroup=$(jq -r '.resources.client_cgroup' "${manifest}")
target_cpus=$(jq -r '.resources.target_cpus' "${manifest}")
cgroups_enabled=$(jq -r '
  if .host_requirements.cgroups == null
  then true
  else .host_requirements.cgroups
  end
' "${manifest}")
expected_sha256=$(jq -r --arg default "${default_body_sha256}" \
  '.expected.sha256 // $default' "${manifest}")
expected_bytes=$(jq -r '.expected.bytes // 25' "${manifest}")
[[ ${expected_sha256} =~ ^[[:xdigit:]]{64}$ ]] || die "expected.sha256 is invalid"
[[ ${expected_bytes} =~ ^[1-9][0-9]*$ ]] ||
  die "expected.bytes must be a positive integer"
if [[ ${mode} == density ]] &&
  [[ ${expected_sha256} != "${default_body_sha256}" ||
    ${expected_bytes} -ne 25 ]]; then
  die "density-load requires the fixed 25-byte benchmark response"
fi
if [[ ${ksm_enabled} == false ]] &&
  jq -e '[.instances[].launch | index("--ksm")] | any' \
    "${manifest}" >/dev/null; then
  die "a non-KSM run must not mark VM memory mergeable"
fi

preflight_host() {
  local require_kvm
  local require_swap_off
  local require_thp_off
  local require_cgroups
  local require_direct_network
  local require_ksm_off
  local require_partition_roots
  local require_smt_off
  local require_homogeneous_target_cpus
  local require_fixed_frequency
  local require_housekeeping_isolation
  local thp_enabled
  local thp_defrag
  local swap_entries
  local client_cgroup
  local target_cgroup
  local expected_target_cpus
  local expected_client_cpus
  local expected_housekeeping_cpus
  local cgroup2_mount
  local current_cgroup_relative
  local current_cgroup
  local cold_hook_count
  local warm_hook_count
  local loopback_url_count
  local non_ip_url_count
  local target_cpu_max
  local target_memory_max
  local target_memory_high
  local client_cpu_max
  local client_memory_max
  local client_memory_high
  local target_partition
  local client_partition
  local cpu
  local minimum_frequency
  local maximum_frequency
  local frequency_path
  local boost_state
  local online_cpus
  local first_target_performance
  local target_performance
  local performance_path
  local target_parent
  local client_parent
  local parent_partition
  local residency_path
  local workqueue_mask
  local workqueue_mask_value
  local expected_workqueue_mask=0
  local -a reserved_cpus=()

  require_kvm=$(jq -r '
    if .host_requirements.kvm == null then true
    else .host_requirements.kvm end
  ' "${manifest}")
  require_swap_off=$(jq -r '
    if .host_requirements.swap_off == null then true
    else .host_requirements.swap_off end
  ' "${manifest}")
  require_thp_off=$(jq -r '
    if .host_requirements.thp_off == null then true
    else .host_requirements.thp_off end
  ' "${manifest}")
  require_cgroups=$(jq -r '
    if .host_requirements.cgroups == null then true
    else .host_requirements.cgroups end
  ' "${manifest}")
  require_direct_network=$(jq -r \
    'if .host_requirements.direct_network == null then true
     else .host_requirements.direct_network end' "${manifest}")
  require_ksm_off=$(jq -r '
    if .host_requirements.ksm_off == null then true
    else .host_requirements.ksm_off end
  ' "${manifest}")
  require_partition_roots=$(jq -r \
    'if .host_requirements.partition_roots == null then true
     else .host_requirements.partition_roots end' "${manifest}")
  require_smt_off=$(jq -r '
    if .host_requirements.smt_off == null then true
    else .host_requirements.smt_off end
  ' "${manifest}")
  require_homogeneous_target_cpus=$(jq -r '
    if .host_requirements.homogeneous_target_cpus == null then true
    else .host_requirements.homogeneous_target_cpus end
  ' "${manifest}")
  require_fixed_frequency=$(jq -r \
    'if .host_requirements.fixed_frequency == null then true
     else .host_requirements.fixed_frequency end' "${manifest}")
  require_housekeeping_isolation=$(jq -r \
    'if .host_requirements.housekeeping_isolation == null then true
     else .host_requirements.housekeeping_isolation end' "${manifest}")

  [[ -r /proc/pressure/cpu &&
    -r /proc/pressure/io &&
    -r /proc/pressure/memory ]] ||
    die "CPU, I/O, and memory PSI interfaces are required"
  if [[ ${require_kvm} == true ]]; then
    [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] ||
      die "read/write KVM access is required"
  fi
  if [[ ${require_swap_off} == true ]]; then
    swap_entries=$(awk 'NR > 1 { count++ } END { print count + 0 }' /proc/swaps)
    ((swap_entries == 0)) || die "swap must be off"
  fi
  if [[ ${require_thp_off} == true ]]; then
    thp_enabled=$(</sys/kernel/mm/transparent_hugepage/enabled)
    thp_defrag=$(</sys/kernel/mm/transparent_hugepage/defrag)
    [[ ${thp_enabled} == *"[never]"* && ${thp_defrag} == *"[never]"* ]] ||
      die "transparent huge pages and THP defrag must both be set to never"
  fi
  if [[ ${require_ksm_off} == true || ${ksm_enabled} == true ]]; then
    [[ -d /sys/kernel/mm/ksm ]] || die "host kernel does not expose KSM controls"
  fi
  if [[ ${require_ksm_off} == true && ${ksm_enabled} == false ]]; then
    [[ $(</sys/kernel/mm/ksm/run) -eq 0 &&
      $(</sys/kernel/mm/ksm/pages_sharing) -eq 0 ]] ||
      die "headline runs require KSM stopped with no shared pages"
  fi
  if [[ ${cache_condition} == host-cold ]]; then
    [[ ${mode} != density ]] ||
      die "density mode supports only cross-instance-warm cache state"
    cold_hook_count=$(jq '.hooks.before_sample | length' "${manifest}")
    ((cold_hook_count > 0)) ||
      die "host-cold runs require a cache reset/verification before_sample hook"
  else
    warm_hook_count=$(jq '.hooks.before_suite | length' "${manifest}")
    ((warm_hook_count > 0)) ||
      die "cross-instance-warm runs require a warm-up/verification before_suite hook"
  fi
  if [[ ${require_direct_network} == true ]]; then
    loopback_url_count=$(jq '
      [.instances[].url |
        select(test("^http://(localhost|127\\.|\\[::1\\])"))] | length
    ' "${manifest}")
    ((loopback_url_count == 0)) ||
      die "headline runs require direct non-loopback instance URLs"
    non_ip_url_count=$(jq '
      [.instances[].url |
        select(
          test(
            "^http://(([0-9]{1,3}\\.){3}[0-9]{1,3}|\\[[0-9A-Fa-f:]+\\])(:[0-9]+)?/"
          )
          | not
        )
      ] | length
    ' "${manifest}")
    ((non_ip_url_count == 0)) ||
      die "headline instance URLs must use IP literals, not DNS names"
  fi
  jq -r '.residency_files[]' "${manifest}" >"${work_dir}/preflight-residency"
  while IFS= read -r residency_path; do
    [[ -r ${residency_path} ]] ||
      die "residency working-set path is unreadable: ${residency_path}"
  done <"${work_dir}/preflight-residency"
  if [[ ${require_cgroups} == true ]]; then
    client_cgroup=$(jq -r '.resources.client_cgroup' "${manifest}")
    target_cgroup=$(jq -r '.resources.target_cgroup' "${manifest}")
    expected_client_cpus=$(jq -r '.resources.client_cpus' "${manifest}")
    expected_target_cpus=$(jq -r '.resources.target_cpus' "${manifest}")
    expected_housekeeping_cpus=$(jq -r \
      '.resources.housekeeping_cpus' "${manifest}")
    cgroup2_mount=$(findmnt -n -o TARGET -t cgroup2)
    current_cgroup_relative=$(awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup)
    current_cgroup="${cgroup2_mount}${current_cgroup_relative}"
    current_cgroup=${current_cgroup%/}
    current_cgroup=$(realpath "${current_cgroup}")
    client_cgroup=$(realpath "${client_cgroup}")
    target_cgroup=$(realpath "${target_cgroup}")
    [[ ${current_cgroup} == "${client_cgroup}" ]] ||
      die "invoke the runner from its client cgroup: ${client_cgroup}"
    [[ -w ${target_cgroup}/cgroup.procs &&
      -r ${target_cgroup}/cpu.stat &&
      -r ${target_cgroup}/memory.current &&
      -r ${target_cgroup}/memory.stat &&
      -r ${target_cgroup}/cpuset.cpus.effective &&
      -r ${target_cgroup}/cpu.max &&
      -r ${target_cgroup}/memory.max &&
      -r ${target_cgroup}/memory.high ]] ||
      die "target cgroup is incomplete or inaccessible: ${target_cgroup}"
    [[ -z $(<"${target_cgroup}/cgroup.procs") ]] ||
      die "target cgroup is not empty before the suite: ${target_cgroup}"
    [[ -r ${client_cgroup}/cpu.stat &&
      -r ${client_cgroup}/memory.current &&
      -r ${client_cgroup}/cpuset.cpus.effective &&
      -r ${client_cgroup}/cpu.max &&
      -r ${client_cgroup}/memory.max &&
      -r ${client_cgroup}/memory.high ]] ||
      die "client cgroup is incomplete or inaccessible: ${client_cgroup}"
    expand_cpu_list "$(<"${target_cgroup}/cpuset.cpus.effective")" \
      "${work_dir}/target-cpus"
    expand_cpu_list "$(<"${client_cgroup}/cpuset.cpus.effective")" \
      "${work_dir}/client-cpus"
    expand_cpu_list "${expected_target_cpus}" "${work_dir}/expected-target-cpus"
    expand_cpu_list "${expected_client_cpus}" "${work_dir}/expected-client-cpus"
    expand_cpu_list "${expected_housekeeping_cpus}" \
      "${work_dir}/expected-housekeeping-cpus"
    online_cpus=$(</sys/devices/system/cpu/online)
    expand_cpu_list "${online_cpus}" "${work_dir}/online-cpus"
    cat \
      "${work_dir}/expected-target-cpus" \
      "${work_dir}/expected-client-cpus" \
      "${work_dir}/expected-housekeeping-cpus" |
      sort -n -u >"${work_dir}/allocated-cpus"
    comm -12 "${work_dir}/target-cpus" "${work_dir}/client-cpus" \
      >"${work_dir}/target-client-overlap"
    cmp --silent "${work_dir}/target-cpus" "${work_dir}/expected-target-cpus" ||
      die "target cgroup effective CPUs do not match resources.target_cpus"
    cmp --silent "${work_dir}/client-cpus" "${work_dir}/expected-client-cpus" ||
      die "client cgroup effective CPUs do not match resources.client_cpus"
    cmp --silent "${work_dir}/allocated-cpus" "${work_dir}/online-cpus" ||
      die "target, client, and housekeeping CPUs must partition all online CPUs"
    comm -12 "${work_dir}/target-cpus" \
      "${work_dir}/expected-housekeeping-cpus" \
      >"${work_dir}/target-housekeeping-overlap"
    comm -12 "${work_dir}/client-cpus" \
      "${work_dir}/expected-housekeeping-cpus" \
      >"${work_dir}/client-housekeeping-overlap"
    [[ ! -s ${work_dir}/target-housekeeping-overlap &&
      ! -s ${work_dir}/client-housekeeping-overlap ]] ||
      die "housekeeping CPUs overlap a benchmark cpuset"
    [[ ! -s ${work_dir}/target-client-overlap ]] ||
      die "target and client cpusets overlap"
    if [[ ${require_housekeeping_isolation} == true ]]; then
      if pgrep -x irqbalance >/dev/null; then
        die "irqbalance must be stopped during the benchmark"
      fi
      while IFS= read -r cpu; do
        ((cpu < 63)) ||
          die "workqueue isolation validation supports CPU IDs below 63"
        expected_workqueue_mask=$((expected_workqueue_mask | (1 << cpu)))
      done <"${work_dir}/expected-housekeeping-cpus"
      workqueue_mask=$(</sys/devices/virtual/workqueue/cpumask)
      workqueue_mask=${workqueue_mask//,/}
      workqueue_mask_value=$((16#${workqueue_mask}))
      ((workqueue_mask_value == expected_workqueue_mask)) ||
        die "unbound workqueues are not restricted to housekeeping CPUs"
    fi
    target_cpu_max=$(<"${target_cgroup}/cpu.max")
    target_memory_max=$(<"${target_cgroup}/memory.max")
    target_memory_high=$(<"${target_cgroup}/memory.high")
    client_cpu_max=$(<"${client_cgroup}/cpu.max")
    client_memory_max=$(<"${client_cgroup}/memory.max")
    client_memory_high=$(<"${client_cgroup}/memory.high")
    [[ ${target_cpu_max} == "max "* ]] ||
      die "target cgroup must not have a CPU quota"
    [[ ${client_cpu_max} == "max "* ]] ||
      die "client cgroup must not have a CPU quota"
    [[ ${target_memory_max} == max && ${target_memory_high} == max ]] ||
      die "target cgroup must not impose a memory limit"
    [[ ${client_memory_max} == max && ${client_memory_high} == max ]] ||
      die "client cgroup must not impose a memory limit"
    if [[ ${require_partition_roots} == true ]]; then
      target_partition=$(<"${target_cgroup}/cpuset.cpus.partition")
      client_partition=$(<"${client_cgroup}/cpuset.cpus.partition")
      [[ ${target_partition} == root && ${client_partition} == root ]] ||
        die "target and client cgroups must be valid exclusive partition roots"
      target_parent=$(dirname "${target_cgroup}")
      client_parent=$(dirname "${client_cgroup}")
      [[ ${target_parent} == "${client_parent}" ]] ||
        die "target and client partition roots must be siblings"
      parent_partition=$(<"${target_parent}/cpuset.cpus.partition")
      [[ ${parent_partition} == root ]] ||
        die "benchmark cgroup parent must be a valid partition root"
    fi
    if [[ ${require_smt_off} == true ]]; then
      lscpu -p=CORE,SOCKET |
        awk -F, '!/^#/ { seen[$1 "," $2]++ }
          END { for (core in seen) if (seen[core] > 1) print core }' \
          >"${work_dir}/smt-siblings"
      [[ ! -s ${work_dir}/smt-siblings ]] ||
        die "SMT must be disabled so each benchmark CPU is a physical core"
    fi
    if [[ ${require_fixed_frequency} == true ]]; then
      mapfile -t reserved_cpus <"${work_dir}/target-cpus"
      while IFS= read -r cpu; do
        reserved_cpus+=("${cpu}")
      done <"${work_dir}/client-cpus"
      for cpu in "${reserved_cpus[@]}"; do
        [[ -r /sys/devices/system/cpu/cpu"${cpu}"/cpufreq/scaling_min_freq &&
          -r /sys/devices/system/cpu/cpu"${cpu}"/cpufreq/scaling_max_freq ]] ||
          die "CPU ${cpu} does not expose frequency controls"
        frequency_path=/sys/devices/system/cpu/cpu"${cpu}"/cpufreq
        minimum_frequency=$(<"${frequency_path}/scaling_min_freq")
        maximum_frequency=$(<"${frequency_path}/scaling_max_freq")
        [[ ${minimum_frequency} -eq ${maximum_frequency} ]] ||
          die "CPU ${cpu} frequency is not fixed"
      done
      if [[ -r /sys/devices/system/cpu/cpufreq/boost ]]; then
        boost_state=$(</sys/devices/system/cpu/cpufreq/boost)
        [[ ${boost_state} -eq 0 ]] || die "CPU boost must be disabled"
      fi
    fi
    if [[ ${require_homogeneous_target_cpus} == true ]]; then
      first_target_performance=
      while IFS= read -r cpu; do
        [[ -r /sys/devices/system/cpu/cpu"${cpu}"/acpi_cppc/highest_perf ]] ||
          die "CPU ${cpu} does not expose ACPI CPPC performance class"
        performance_path=/sys/devices/system/cpu/cpu"${cpu}"/acpi_cppc/highest_perf
        target_performance=$(<"${performance_path}")
        if [[ -z ${first_target_performance} ]]; then
          first_target_performance=${target_performance}
        fi
        [[ ${target_performance} -eq ${first_target_performance} ]] ||
          die "target cpuset mixes different CPU performance classes"
      done <"${work_dir}/target-cpus"
    fi
  fi
}

work_dir=$(mktemp -d "${output_dir}/.run-benchmark.XXXXXX")
declare -a service_pids=()
declare -a service_names=()
declare -a service_logs=()
declare -a active_instance_indexes=()
declare -a prepared_instance_indexes=()
declare -a auxiliary_pids=()
cleanup_started=false
ksm_was_enabled=false
ksm_original_pages_to_scan=
ksm_original_sleep_ms=
ksm_original_cpus=
ksm_original_cgroup_path=
ksm_pid=
ksm_cgroup_moved=false
platform_active=false
platform_service_count=0
platform_generation=0
suite_active=false
hook_repetition=1

json_argv() {
  local json=$1
  jq -r '.[]' <<<"${json}" >"${work_dir}/argv"
  mapfile -t command_argv <"${work_dir}/argv"
}

run_command_json() {
  local json=$1
  local -a command_argv=()
  json_argv "${json}"
  set +e
  "${command_argv[@]}"
  command_status=$?
  set -e
}

read_json_items() {
  local query=$1
  jq -c "${query}" "${manifest}" >"${work_dir}/json-items"
  mapfile -t json_items <"${work_dir}/json-items"
}

run_hook_list() {
  local hook_name=$1
  local command_json
  local -a json_items=()
  read_json_items ".hooks.${hook_name}[]?"
  for command_json in "${json_items[@]}"; do
    FAST_VMS_BENCHMARK_MODE=${mode} \
      FAST_VMS_BENCHMARK_REPETITION=${hook_repetition} \
      run_command_json "${command_json}"
    ((command_status == 0)) ||
      die "hook ${hook_name} failed"
  done
}

run_hook_list_best_effort() {
  local hook_name=$1
  local command_json
  local -a json_items=()
  read_json_items ".hooks.${hook_name}[]?"
  for command_json in "${json_items[@]}"; do
    FAST_VMS_BENCHMARK_MODE=${mode} \
      FAST_VMS_BENCHMARK_REPETITION=${hook_repetition} \
      run_command_json "${command_json}"
  done
}

start_service_json() {
  local name=$1
  local command_json=$2
  local log_path=$3
  local -a command_argv=()
  json_argv "${command_json}"
  start_service_argv "${name}" "${log_path}" "${command_argv[@]}"
}

start_service_argv() {
  local name=$1
  local log_path=$2
  shift 2
  local -a command_argv=("$@")
  local -a execution_argv=()
  if [[ ${cgroups_enabled} == true ]]; then
    [[ -w ${target_cgroup}/cgroup.procs && -r ${target_cgroup}/cpu.stat ]] ||
      die "target cgroup is not prepared and writable: ${target_cgroup}"
    execution_argv=(cgroup-exec "${target_cgroup}" "${command_argv[@]}")
  else
    execution_argv=("${command_argv[@]}")
  fi
  setsid -- "${execution_argv[@]}" >"${log_path}" 2>&1 &
  local pid=$!
  kill -0 "${pid}" 2>/dev/null || {
    wait "${pid}" || true
    die "service ${name} exited during launch; see ${log_path}"
  }
  service_pids+=("${pid}")
  service_names+=("${name}")
  service_logs+=("${log_path}")
}

stop_process_group() {
  local pid=$1
  local deadline
  kill -TERM -- "-${pid}" 2>/dev/null || true
  deadline=$((SECONDS + 10))
  while kill -0 "${pid}" 2>/dev/null && ((SECONDS < deadline)); do
    sleep 0.1
  done
  if kill -0 "${pid}" 2>/dev/null; then
    kill -KILL -- "-${pid}" 2>/dev/null || true
  fi
  wait "${pid}" 2>/dev/null || true
}

evict_service_log_cache() {
  local log_path
  for log_path in "${service_logs[@]}"; do
    [[ -e ${log_path} ]] || continue
    sync -f "${log_path}"
    vmtouch -e -q "${log_path}"
  done
}

wait_for_target_cgroup_empty() {
  local deadline=$((SECONDS + 10))
  local remaining_pids
  target_cgroup_empty=false
  if [[ ${cgroups_enabled} != true ]]; then
    target_cgroup_empty=true
    return
  fi
  while ((SECONDS < deadline)); do
    remaining_pids=$(awk \
      -v ksmd_pid="${ksm_pid}" \
      -v ksmd_moved="${ksm_cgroup_moved}" \
      'ksmd_moved != "true" || $1 != ksmd_pid { print }' \
      "${target_cgroup}/cgroup.procs")
    if [[ -z ${remaining_pids} ]]; then
      target_cgroup_empty=true
      return
    fi
    sleep 0.1
  done
}

capture_platform_cgroup_members() {
  if [[ ${cgroups_enabled} == true ]]; then
    sort -n "${target_cgroup}/cgroup.procs" \
      >"${work_dir}/platform-cgroup-procs"
  else
    : >"${work_dir}/platform-cgroup-procs"
  fi
}

wait_for_platform_cgroup_members() {
  local deadline=$((SECONDS + 10))
  platform_cgroup_members_restored=false
  if [[ ${cgroups_enabled} != true ]]; then
    platform_cgroup_members_restored=true
    return
  fi
  while ((SECONDS < deadline)); do
    sort -n "${target_cgroup}/cgroup.procs" \
      >"${work_dir}/current-cgroup-procs"
    if cmp --silent \
      "${work_dir}/platform-cgroup-procs" \
      "${work_dir}/current-cgroup-procs"; then
      platform_cgroup_members_restored=true
      return
    fi
    sleep 0.1
  done
}

stop_instance_index() {
  local index=$1
  local command_json
  local -a json_items=()
  read_json_items ".instances[${index}].stop[]?"
  for command_json in "${json_items[@]}"; do
    run_command_json "${command_json}"
  done
}

prepare_instance_index() {
  local index=$1
  local command_json
  local network_interface
  local -a json_items=()
  read_json_items ".instances[${index}].prepare[]?"
  for command_json in "${json_items[@]}"; do
    run_command_json "${command_json}"
    ((command_status == 0)) ||
      die "instance preparation failed at manifest index ${index}"
  done
  network_interface=$(jq -r \
    ".instances[${index}].network_interface" "${manifest}")
  [[ -d /sys/class/net/${network_interface} &&
    -r /sys/class/net/${network_interface}/statistics/rx_bytes &&
    -r /sys/class/net/${network_interface}/statistics/tx_bytes ]] ||
    die "prepared interface is missing or lacks counters: ${network_interface}"
  prepared_instance_indexes+=("${index}")
}

cleanup_instance_index() {
  local index=$1
  local command_json
  local -a json_items=()
  read_json_items ".instances[${index}].cleanup[]?"
  for command_json in "${json_items[@]}"; do
    run_command_json "${command_json}"
    ((command_status == 0)) ||
      die "instance cleanup failed at manifest index ${index}"
  done
}

cleanup_instance_index_best_effort() {
  local index=$1
  local command_json
  local -a json_items=()
  read_json_items ".instances[${index}].cleanup[]?"
  for command_json in "${json_items[@]}"; do
    run_command_json "${command_json}"
  done
}

cleanup() {
  local index
  local position
  local command_json
  local cgroup_restore_failed=false
  local ksm_cleanup_deadline
  local cleanup_failed=false
  local -a json_items=()
  if [[ ${cleanup_started} == true ]]; then
    return
  fi
  cleanup_started=true

  for ((position = ${#active_instance_indexes[@]} - 1; position >= 0; position--)); do
    index=${active_instance_indexes[position]}
    stop_instance_index "${index}"
  done
  for ((
    position = ${#service_pids[@]} - 1;
    position >= platform_service_count;
    position--
  )); do
    stop_process_group "${service_pids[position]}"
  done
  service_pids=("${service_pids[@]:0:platform_service_count}")
  service_names=("${service_names[@]:0:platform_service_count}")
  service_logs=("${service_logs[@]:0:platform_service_count}")
  for ((
    position = ${#prepared_instance_indexes[@]} - 1;
    position >= 0;
    position--
  )); do
    cleanup_instance_index_best_effort \
      "${prepared_instance_indexes[position]}"
  done
  prepared_instance_indexes=()
  for ((position = ${#auxiliary_pids[@]} - 1; position >= 0; position--)); do
    kill -TERM "${auxiliary_pids[position]}" 2>/dev/null || true
    wait "${auxiliary_pids[position]}" 2>/dev/null || true
  done
  if [[ ${suite_active} == true ]]; then
    run_hook_list_best_effort after_suite
    suite_active=false
  fi
  if [[ ${platform_active} == true ]]; then
    read_json_items '.platform.stop[]?'
    for ((position = ${#json_items[@]} - 1; position >= 0; position--)); do
      run_command_json "${json_items[position]}"
    done
  fi
  for ((position = ${#service_pids[@]} - 1; position >= 0; position--)); do
    stop_process_group "${service_pids[position]}"
  done

  if [[ ${ksm_was_enabled} == true ]]; then
    if ! printf '2\n' > /sys/kernel/mm/ksm/run; then
      echo "run-benchmark: failed to request KSM unmerge during cleanup" >&2
      cleanup_failed=true
    else
      ksm_cleanup_deadline=$((SECONDS + 600))
      while [[ $(</sys/kernel/mm/ksm/pages_sharing) -ne 0 ]] &&
        ((SECONDS < ksm_cleanup_deadline)); do
        sleep 0.1
      done
      if [[ $(</sys/kernel/mm/ksm/pages_sharing) -ne 0 ]]; then
        echo "run-benchmark: KSM unmerge timed out; leaving unmerge active" >&2
        cleanup_failed=true
      elif ! printf '0\n' > /sys/kernel/mm/ksm/run; then
        echo "run-benchmark: failed to stop KSM after unmerge" >&2
        cleanup_failed=true
      fi
    fi
    if ! printf '%s\n' "${ksm_original_pages_to_scan}" \
      > /sys/kernel/mm/ksm/pages_to_scan; then
      echo "run-benchmark: failed to restore KSM pages_to_scan" >&2
      cleanup_failed=true
    fi
    if ! printf '%s\n' "${ksm_original_sleep_ms}" \
      > /sys/kernel/mm/ksm/sleep_millisecs; then
      echo "run-benchmark: failed to restore KSM sleep_millisecs" >&2
      cleanup_failed=true
    fi
  fi
  if [[ ${ksm_cgroup_moved} == true &&
    -n ${ksm_pid} &&
    -n ${ksm_original_cgroup_path} &&
    -d /proc/${ksm_pid} ]]; then
    if ! printf '%s\n' "${ksm_pid}" \
      >"${ksm_original_cgroup_path}/cgroup.procs"; then
      echo "run-benchmark: failed to restore ksmd cgroup" >&2
      cleanup_failed=true
      cgroup_restore_failed=true
    fi
  fi
  if [[ ${cgroup_restore_failed} == false &&
    -n ${ksm_pid} &&
    -n ${ksm_original_cpus} &&
    -d /proc/${ksm_pid} ]]; then
    if ! taskset --cpu-list --pid "${ksm_original_cpus}" "${ksm_pid}" \
      >/dev/null; then
      echo "run-benchmark: failed to restore ksmd CPU affinity" >&2
      cleanup_failed=true
    fi
  fi

  rm -rf -- "${work_dir}"
  [[ ${cleanup_failed} == false ]]
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

append_record() {
  local json=$1
  jq -ce . <<<"${json}" >>"${raw_file}"
  sync -f "${raw_file}"
  vmtouch -e -q "${raw_file}"
}

monotonic_ns() {
  monotonic-ns
}

memory_used_bytes() {
  awk '
    $1 == "MemTotal:" { total = $2 * 1024 }
    $1 == "MemFree:" { free = $2 * 1024 }
    END { printf "%.0f\n", total - free }
  ' /proc/meminfo
}

memory_available_bytes() {
  awk '$1 == "MemAvailable:" { printf "%.0f\n", $2 * 1024 }' /proc/meminfo
}

memory_total_bytes() {
  awk '$1 == "MemTotal:" { printf "%.0f\n", $2 * 1024 }' /proc/meminfo
}

median_memory_used_bytes() {
  local count=${1:-5}
  local delay=${2:-1}
  local -a readings=()
  local reading
  local position
  for ((position = 0; position < count; position++)); do
    readings+=("$(memory_used_bytes)")
    if ((position + 1 < count)); then
      sleep "${delay}"
    fi
  done
  printf '%s\n' "${readings[@]}" >"${work_dir}/memory-readings"
  sort -n "${work_dir}/memory-readings" >"${work_dir}/memory-readings-sorted"
  mapfile -t readings <"${work_dir}/memory-readings-sorted"
  reading=${readings[$((count / 2))]}
  printf '%s\n' "${reading}"
}

memory_snapshot_json() {
  awk '
    BEGIN { printf "{" }
    /^[A-Za-z_()]+:/ {
      key = $1
      sub(/:$/, "", key)
      if (seen++) printf ","
      printf "\"%s\":%.0f", key, $2 * 1024
    }
    END { printf "}\n" }
  ' /proc/meminfo
}

pressure_json() {
  local resource=$1
  awk '
    BEGIN { printf "{" }
    {
      if (line++) printf ","
      printf "\"%s\":{", $1
      for (field = 2; field <= NF; field++) {
        split($field, pair, "=")
        if (field > 2) printf ","
        printf "\"%s\":%s", pair[1], pair[2]
      }
      printf "}"
    }
    END { printf "}\n" }
  ' "/proc/pressure/${resource}"
}

read_memory_full_avg10() {
  memory_full_avg10=$(awk '
    $1 == "full" {
      split($2, pair, "=")
      print pair[2]
      exit
    }
  ' /proc/pressure/memory
  )
}

cgroup_cpu_usage_usec() {
  local cgroup_path=$1
  if [[ -n ${cgroup_path} && -r ${cgroup_path}/cpu.stat ]]; then
    awk '$1 == "usage_usec" { print $2 }' "${cgroup_path}/cpu.stat"
  else
    printf '0\n'
  fi
}

deployment_cpu_usage_usec() {
  if [[ ${cgroups_enabled} == true ]]; then
    cgroup_cpu_usage_usec "${target_cgroup}"
  else
    printf '0\n'
  fi
}

client_cpu_usage_usec() {
  if [[ ${cgroups_enabled} == true ]]; then
    cgroup_cpu_usage_usec "${client_cgroup}"
  else
    printf '0\n'
  fi
}

client_memory_current_bytes() {
  if [[ ${cgroups_enabled} == true &&
    -r ${client_cgroup}/memory.current ]]; then
    cat "${client_cgroup}/memory.current"
  else
    printf '0\n'
  fi
}

ksm_snapshot_json() {
  local ksm_path=/sys/kernel/mm/ksm
  local allowed_cpus=
  local current_ksm_pid
  if [[ ! -d ${ksm_path} ]]; then
    printf '{}\n'
    return
  fi
  current_ksm_pid=$(pgrep -xo ksmd || true)
  if [[ -n ${current_ksm_pid} && -r /proc/${current_ksm_pid}/status ]]; then
    allowed_cpus=$(awk \
      '$1 == "Cpus_allowed_list:" { print $2 }' \
      "/proc/${current_ksm_pid}/status")
  fi
  jq -n \
    --arg allowed_cpus "${allowed_cpus}" \
    --argjson run "$(<"${ksm_path}/run")" \
    --argjson pages_shared "$(<"${ksm_path}/pages_shared")" \
    --argjson pages_sharing "$(<"${ksm_path}/pages_sharing")" \
    --argjson pages_unshared "$(<"${ksm_path}/pages_unshared")" \
    --argjson pages_volatile "$(<"${ksm_path}/pages_volatile")" \
    --argjson full_scans "$(<"${ksm_path}/full_scans")" \
    '{
      run: $run,
      pages_shared: $pages_shared,
      pages_sharing: $pages_sharing,
      pages_unshared: $pages_unshared,
      pages_volatile: $pages_volatile,
      full_scans: $full_scans,
      allowed_cpus: $allowed_cpus
    }'
}

cgroup_snapshot_json() {
  local cgroup_path=$1
  local cpu_stat
  local memory_stat
  if [[ ! -d ${cgroup_path} ]]; then
    printf '{}\n'
    return
  fi
  cpu_stat=$(awk '
    BEGIN { printf "{" }
    {
      if (line++) printf ","
      printf "\"%s\":%s", $1, $2
    }
    END { printf "}\n" }
  ' "${cgroup_path}/cpu.stat")
  memory_stat=$(awk '
    BEGIN { printf "{" }
    {
      if (line++) printf ","
      printf "\"%s\":%s", $1, $2
    }
    END { printf "}\n" }
  ' "${cgroup_path}/memory.stat")
  jq -n \
    --arg path "${cgroup_path}" \
    --arg cpus "$(<"${cgroup_path}/cpuset.cpus.effective")" \
    --arg cpu_max "$(<"${cgroup_path}/cpu.max")" \
    --arg memory_max "$(<"${cgroup_path}/memory.max")" \
    --arg memory_high "$(<"${cgroup_path}/memory.high")" \
    --arg partition "$(<"${cgroup_path}/cpuset.cpus.partition")" \
    --argjson cpu "${cpu_stat}" \
    --argjson memory_current "$(<"${cgroup_path}/memory.current")" \
    --argjson memory_stat "${memory_stat}" \
    '{
      path: $path,
      cpuset_cpus_effective: $cpus,
      cpuset_partition: $partition,
      cpu_max: $cpu_max,
      memory_max: $memory_max,
      memory_high: $memory_high,
      cpu_stat: $cpu,
      memory_current: $memory_current,
      memory_stat: $memory_stat
    }'
}

process_memory_snapshot_json() {
  local cgroup_path=$1
  local pid
  local smaps
  local rss_kib=0
  local pss_kib=0
  local anonymous_kib=0
  local value
  local process_count=0
  if [[ ! -r ${cgroup_path}/cgroup.procs ]]; then
    printf '{}\n'
    return
  fi
  while IFS= read -r pid; do
    if ! smaps=$(cat "/proc/${pid}/smaps_rollup" 2>/dev/null); then
      continue
    fi
    value=$(awk '$1 == "Rss:" { print $2 }' <<<"${smaps}")
    rss_kib=$((rss_kib + ${value:-0}))
    value=$(awk '$1 == "Pss:" { print $2 }' <<<"${smaps}")
    pss_kib=$((pss_kib + ${value:-0}))
    value=$(awk '$1 == "Anonymous:" { print $2 }' <<<"${smaps}")
    anonymous_kib=$((anonymous_kib + ${value:-0}))
    process_count=$((process_count + 1))
  done <"${cgroup_path}/cgroup.procs"
  jq -n \
    --argjson process_count "${process_count}" \
    --argjson rss_bytes "$((rss_kib * 1024))" \
    --argjson pss_bytes "$((pss_kib * 1024))" \
    --argjson anonymous_bytes "$((anonymous_kib * 1024))" \
    '{
      process_count: $process_count,
      rss_bytes: $rss_bytes,
      pss_bytes: $pss_bytes,
      anonymous_bytes: $anonymous_bytes
    }'
}

residency_snapshot_json() {
  local batch_size=256
  local batch_size_bytes
  local batch_resident_bytes
  local file_count
  local offset
  local path
  local snapshot
  local total_size_bytes=0
  local total_resident_bytes=0
  local -a batch=()
  local -a residency_files=()
  jq -r '.residency_files[]' "${manifest}" >"${work_dir}/residency-files"
  mapfile -t residency_files <"${work_dir}/residency-files"
  for path in "${residency_files[@]}"; do
    [[ -r ${path} ]] ||
      die "residency working-set path is unreadable: ${path}"
  done
  file_count=${#residency_files[@]}
  for ((offset = 0; offset < file_count; offset += batch_size)); do
    batch=("${residency_files[@]:offset:batch_size}")
    snapshot=$(fincore -J -b -o FILE,SIZE,RES "${batch[@]}")
    batch_size_bytes=$(jq '[.fincore[].size] | add // 0' <<<"${snapshot}")
    batch_resident_bytes=$(jq '[.fincore[].res] | add // 0' <<<"${snapshot}")
    total_size_bytes=$((total_size_bytes + batch_size_bytes))
    total_resident_bytes=$((total_resident_bytes + batch_resident_bytes))
  done
  jq -n \
    --argjson file_count "${file_count}" \
    --argjson total_size_bytes "${total_size_bytes}" \
    --argjson total_resident_bytes "${total_resident_bytes}" \
    '{
      file_count: $file_count,
      total_size_bytes: $total_size_bytes,
      total_resident_bytes: $total_resident_bytes
    }'
}

thermal_snapshot_json() {
  local zone
  local zone_name
  local temperature
  local first=true
  printf '['
  for zone in /sys/class/thermal/thermal_zone*; do
    [[ -r ${zone}/temp ]] || continue
    zone_name=$(<"${zone}/type")
    temperature=$(<"${zone}/temp")
    if [[ ${first} == false ]]; then
      printf ','
    fi
    first=false
    jq -cn \
      --arg zone "${zone##*/}" \
      --arg type "${zone_name}" \
      --argjson millidegrees_celsius "${temperature}" \
      '{zone: $zone, type: $type, millidegrees_celsius: $millidegrees_celsius}'
  done
  printf ']\n'
}

frequency_snapshot_json() {
  local role
  local cpu_spec
  local cpu
  local frequency_path
  local cppc_path
  : >"${work_dir}/frequency-snapshot.jsonl"
  for role in target client; do
    cpu_spec=$(jq -r ".resources.${role}_cpus" "${manifest}")
    expand_cpu_list "${cpu_spec}" "${work_dir}/frequency-${role}-cpus"
    while IFS= read -r cpu; do
      frequency_path=/sys/devices/system/cpu/cpu"${cpu}"/cpufreq
      cppc_path=/sys/devices/system/cpu/cpu"${cpu}"/acpi_cppc
      [[ -d ${frequency_path} ]] || continue
      jq -cn \
        --arg role "${role}" \
        --argjson cpu "${cpu}" \
        --arg driver "$(<"${frequency_path}/scaling_driver")" \
        --arg governor "$(<"${frequency_path}/scaling_governor")" \
        --argjson minimum_khz "$(<"${frequency_path}/scaling_min_freq")" \
        --argjson maximum_khz "$(<"${frequency_path}/scaling_max_freq")" \
        --argjson current_khz "$(<"${frequency_path}/scaling_cur_freq")" \
        --argjson nominal_mhz "$(<"${cppc_path}/nominal_freq")" \
        '{
          role: $role,
          cpu: $cpu,
          driver: $driver,
          governor: $governor,
          scaling_min_khz: $minimum_khz,
          scaling_max_khz: $maximum_khz,
          scaling_cur_khz: $current_khz,
          cppc_nominal_mhz: $nominal_mhz
        }' >>"${work_dir}/frequency-snapshot.jsonl"
    done <"${work_dir}/frequency-${role}-cpus"
  done
  jq -s . "${work_dir}/frequency-snapshot.jsonl"
}

ksmd_cpu_ticks() {
  local ksmd_pid
  ksmd_pid=$(pgrep -xo ksmd || true)
  if [[ -n ${ksmd_pid} && -r /proc/${ksmd_pid}/stat ]]; then
    awk '{ print $14 + $15 }' "/proc/${ksmd_pid}/stat"
  else
    printf '0\n'
  fi
}

configure_ksm() {
  local cgroup_mount
  local ksm_original_cgroup
  local nonmergeable_launches
  [[ ${target} == *vm* ]] || die "--ksm is only valid for a VM target"
  [[ ${ksm_pages_to_scan} =~ ^[1-9][0-9]*$ ]] ||
    die "--ksm-pages-to-scan is required and must be positive"
  [[ ${ksm_sleep_ms} =~ ^[1-9][0-9]*$ ]] ||
    die "--ksm-sleep-ms is required and must be positive"
  [[ -w /sys/kernel/mm/ksm/run ]] || die "KSM sysfs controls are not writable"
  [[ $(</sys/kernel/mm/ksm/run) -eq 0 ]] ||
    die "KSM must initially be stopped"
  [[ $(</sys/kernel/mm/ksm/pages_sharing) -eq 0 ]] ||
    die "KSM must initially have no shared pages"
  nonmergeable_launches=$(jq \
    '[.instances[] | select((.launch | index("--ksm")) == null)] | length' \
    "${manifest}")
  ((nonmergeable_launches == 0)) ||
    die "every VM launch command in a KSM arm must contain --ksm"
  ksm_original_pages_to_scan=$(</sys/kernel/mm/ksm/pages_to_scan)
  ksm_original_sleep_ms=$(</sys/kernel/mm/ksm/sleep_millisecs)
  ksm_pid=$(pgrep -xo ksmd || true)
  [[ -n ${ksm_pid} ]] || die "ksmd kernel thread is unavailable"
  ksm_original_cpus=$(awk \
    '$1 == "Cpus_allowed_list:" { print $2 }' \
    "/proc/${ksm_pid}/status")
  if [[ ${cgroups_enabled} == true ]]; then
    ksm_original_cgroup=$(awk -F: \
      '$1 == "0" { print $3 }' \
      "/proc/${ksm_pid}/cgroup")
    cgroup_mount=$(findmnt -n -o TARGET -t cgroup2)
    [[ -n ${ksm_original_cgroup} && -n ${cgroup_mount} ]] ||
      die "could not resolve the original ksmd cgroup"
    ksm_original_cgroup_path="${cgroup_mount}${ksm_original_cgroup}"
    [[ -w ${target_cgroup}/cgroup.procs &&
      -w ${ksm_original_cgroup_path}/cgroup.procs ]] ||
      die "ksmd cgroup controls are not writable"
    if ! printf '%s\n' "${ksm_pid}" >"${target_cgroup}/cgroup.procs"; then
      die "kernel refused to move ksmd into the target cgroup"
    fi
    ksm_cgroup_moved=true
  fi
  taskset --cpu-list --pid "${target_cpus}" "${ksm_pid}" >/dev/null
  printf '%s\n' "${ksm_pages_to_scan}" > /sys/kernel/mm/ksm/pages_to_scan
  printf '%s\n' "${ksm_sleep_ms}" > /sys/kernel/mm/ksm/sleep_millisecs
  printf '1\n' > /sys/kernel/mm/ksm/run
  ksm_was_enabled=true
}

wait_for_ksm_stability() {
  local previous
  local current
  local initial_full_scans
  local current_full_scans
  local difference
  local threshold
  local deadline=$((SECONDS + 600))
  ksm_stable=false
  previous=$(</sys/kernel/mm/ksm/pages_sharing)
  initial_full_scans=$(</sys/kernel/mm/ksm/full_scans)
  while ((SECONDS < deadline)); do
    sleep 30
    current=$(</sys/kernel/mm/ksm/pages_sharing)
    current_full_scans=$(</sys/kernel/mm/ksm/full_scans)
    difference=$((current > previous ? current - previous : previous - current))
    threshold=$((previous / 100))
    ((threshold < 1)) && threshold=1
    if ((current_full_scans > initial_full_scans && difference < threshold)); then
      ksm_stable=true
      return
    fi
    previous=${current}
  done
}

wait_for_memory_stability() {
  local baseline=$1
  local previous
  local current
  local previous_deployment
  local difference
  local threshold
  local start_seconds=${SECONDS}
  local deadline=$((SECONDS + 120))
  memory_stable=false
  previous=$(median_memory_used_bytes 3 1)
  while ((SECONDS < deadline)); do
    sleep 27
    current=$(median_memory_used_bytes 3 1)
    difference=$((current > previous ? current - previous : previous - current))
    previous_deployment=$((previous - baseline))
    ((previous_deployment < 0)) && previous_deployment=0
    threshold=$((previous_deployment / 100))
    ((threshold < 1024 * 1024)) && threshold=$((1024 * 1024))
    read_memory_full_avg10
    if ((difference < threshold)) &&
      [[ ${memory_full_avg10} == 0.00 || ${memory_full_avg10} == 0 ]]; then
      stabilized_used_bytes=${current}
      stabilization_seconds=$((SECONDS - start_seconds))
      memory_stable=true
      return
    fi
    previous=${current}
  done
  stabilized_used_bytes=${previous}
  stabilization_seconds=$((SECONDS - start_seconds))
}

probe_instance() {
  local url=$1
  local timeout_seconds=${2:-30}
  local response_file="${work_dir}/probe-response"
  local start_ns
  local now_ns
  local deadline_ns
  local status
  local response_size
  local response_sha256
  local response_ns
  local consecutive=0
  probe_succeeded=false
  readiness_first_ns=0
  readiness_confirmed_ns=0
  start_ns=$(monotonic_ns)
  deadline_ns=$((start_ns + timeout_seconds * 1000000000))

  while :; do
    now_ns=$(monotonic_ns)
    if ((now_ns >= deadline_ns)); then
      return
    fi
    status=
    if status=$(curl \
      --silent \
      --show-error \
      --noproxy '*' \
      --output "${response_file}" \
      --write-out '%{http_code}' \
      --connect-timeout 1 \
      --max-time 2 \
      "${url}" 2>/dev/null); then
      response_ns=$(monotonic_ns)
      response_size=$(stat -c %s "${response_file}")
      response_sha256=$(sha256sum "${response_file}")
      response_sha256=${response_sha256%% *}
      if [[ ${status} == 200 &&
        ${response_size} -eq ${expected_bytes} &&
        ${response_sha256} == "${expected_sha256}" ]]; then
        ((consecutive++)) || true
        if ((consecutive == 1)); then
          readiness_first_ns=${response_ns}
        fi
        if ((consecutive == 3)); then
          readiness_confirmed_ns=${response_ns}
          probe_succeeded=true
          return
        fi
      else
        consecutive=0
        readiness_first_ns=0
      fi
    else
      consecutive=0
      readiness_first_ns=0
    fi
    sleep 0.01
  done
}

verify_http_object() {
  local url=$1
  local required_bytes=$2
  local required_sha256=$3
  local response_file="${work_dir}/verify-response"
  local status
  local actual_bytes
  local actual_sha256
  verification_succeeded=false
  status=
  set +e
  status=$(curl \
    --silent \
    --show-error \
    --noproxy '*' \
    --output "${response_file}" \
    --write-out '%{http_code}' \
    --connect-timeout 1 \
    --max-time 10 \
    "${url}")
  curl_status=$?
  set -e
  if ((curl_status != 0)); then
    return
  fi
  actual_bytes=$(stat -c %s "${response_file}")
  actual_sha256=$(sha256sum "${response_file}")
  actual_sha256=${actual_sha256%% *}
  if [[ ${status} == 200 &&
    ${actual_bytes} -eq ${required_bytes} &&
    ${actual_sha256} == "${required_sha256}" ]]; then
    verification_succeeded=true
  fi
}

start_platform() {
  local service_number=0
  local command_json
  local -a json_items=()
  platform_generation=$((platform_generation + 1))
  read_json_items '.platform.launch[]?'
  for command_json in "${json_items[@]}"; do
    service_number=$((service_number + 1))
    start_service_json \
      "platform-${service_number}" \
      "${command_json}" \
      "${output_dir}/logs/platform-${platform_generation}-${service_number}.log"
  done

  read_json_items '.platform.ready[]?'
  for command_json in "${json_items[@]}"; do
    run_command_json "${command_json}"
    ((command_status == 0)) ||
      die "a platform readiness command failed"
  done
  platform_active=true
  platform_service_count=${#service_pids[@]}
}

stop_platform() {
  local position
  local -a json_items=()
  if [[ ${suite_active} == true ]]; then
    run_hook_list after_suite
    suite_active=false
  fi
  read_json_items '.platform.stop[]?'
  for ((position = ${#json_items[@]} - 1; position >= 0; position--)); do
    run_command_json "${json_items[position]}"
    ((command_status == 0)) || die "a platform stop command failed"
  done
  for ((position = ${#service_pids[@]} - 1; position >= 0; position--)); do
    stop_process_group "${service_pids[position]}"
  done
  service_pids=()
  service_names=()
  service_logs=()
  platform_active=false
  platform_service_count=0
  wait_for_target_cgroup_empty
  [[ ${target_cgroup_empty} == true ]] ||
    die "target cgroup retained processes after platform teardown"
}

start_instance() {
  local index=$1
  local repetition=$2
  local id
  local command_json
  local log_path
  id=$(jq -r ".instances[${index}].id" "${manifest}")
  command_json=$(jq -c ".instances[${index}].launch" "${manifest}")
  log_path="${output_dir}/logs/${mode}-r${repetition}-${id}.log"
  start_service_json "${id}" "${command_json}" "${log_path}"
  active_instance_indexes+=("${index}")
  instance_log=${log_path}
}

stop_last_instance() {
  local last_position=$((${#active_instance_indexes[@]} - 1))
  local last_service_position=$((${#service_pids[@]} - 1))
  local index=${active_instance_indexes[last_position]}
  stop_instance_index "${index}"
  stop_process_group "${service_pids[last_service_position]}"
  cleanup_instance_index "${index}"
  unset 'active_instance_indexes[last_position]'
  unset 'prepared_instance_indexes[-1]'
  unset 'service_pids[last_service_position]'
  unset 'service_names[last_service_position]'
  unset 'service_logs[last_service_position]'
  active_instance_indexes=("${active_instance_indexes[@]}")
  prepared_instance_indexes=("${prepared_instance_indexes[@]}")
  service_pids=("${service_pids[@]}")
  service_names=("${service_names[@]}")
  service_logs=("${service_logs[@]}")
}

run_light_load() {
  local count=$1
  local repetition=$2
  local load_dir="${output_dir}/logs/density-r${repetition}-n${count}"
  local target_file="${load_dir}/targets.tsv"
  local output="${load_dir}/load.json"
  local stderr="${load_dir}/load.stderr"
  local index
  local id
  local url
  local pid
  local jq_status
  local load_status
  local client_cpu_before
  local client_cpu_after
  mkdir -p "${load_dir}"
  : >"${target_file}"
  for index in "${active_instance_indexes[@]}"; do
    id=$(jq -r ".instances[${index}].id" "${manifest}")
    url=$(jq -r ".instances[${index}].url" "${manifest}")
    printf '%s\t%s\n' "${id}" "${url}" >>"${target_file}"
  done

  client_cpu_before=$(client_cpu_usage_usec)
  GOMAXPROCS=${client_cpu_count} density-load \
    --targets "${target_file}" \
    --duration "${load_seconds}s" \
    --timeout 2s \
    --rate "${load_rate}" \
    >"${output}" 2>"${stderr}" &
  pid=$!
  auxiliary_pids+=("${pid}")
  load_generator_failures=0
  set +e
  wait "${pid}"
  load_status=$?
  set -e
  ((load_status == 0)) || load_generator_failures=1
  client_cpu_after=$(client_cpu_usage_usec)
  auxiliary_pids=()
  load_client_cpu_usage_usec=$((client_cpu_after - client_cpu_before))

  set +e
  jq -e \
    --argjson expected_count "${#active_instance_indexes[@]}" \
    '
      (.attempts | type == "number" and . >= 0)
      and (.errors | type == "number" and . >= 0)
      and (.max_error_rate | type == "number")
      and (.max_p99_seconds | type == "number")
      and (.all_instances_meet_slo | type == "boolean")
      and (.per_instance | type == "array" and length == $expected_count)
      and (all(.per_instance[];
        (.id | type == "string" and length > 0)
        and (.attempts | type == "number" and . > 0)
        and (.errors | type == "number" and . >= 0)
        and (.error_rate | type == "number")
        and (.p99_seconds | type == "number")))
    ' "${output}" >/dev/null 2>&1
  jq_status=$?
  set -e
  if ((jq_status == 0)); then
    load_summary_json=$(<"${output}")
  else
    load_summary_json='{
      "attempts": 0,
      "errors": 0,
      "max_error_rate": 1,
      "max_p99_seconds": null,
      "all_instances_meet_slo": false,
      "per_instance": []
    }'
    load_generator_failures=1
  fi

  load_slo_met=$(jq -r '.all_instances_meet_slo' <<<"${load_summary_json}")
  if ((load_generator_failures > 0)); then
    load_slo_met=false
  fi
  sync -f "${target_file}" "${output}" "${stderr}"
  vmtouch -e -q "${load_dir}"
}

@DENSITY_BATCHING@

write_environment_record() {
  local meminfo
  local cpuinfo
  local memory_psi
  local cpu_psi
  local io_psi
  local ksm
  local mounts
  local git_revision
  local git_root
  local git_dirty
  local git_diff_sha256
  local manifest_sha256
  local timestamp
  local kernel
  local kernel_cmdline
  local microcode
  local bios_version
  local target_resources
  local client_resources
  local thermals
  local host_controls
  local frequencies
  local swap_entries
  local thp_enabled
  local thp_defrag
  local smt_control
  local boost_control
  local workqueue_cpumask
  local irqbalance_active=false
  local tool_paths
  local bash_path
  local curl_path
  local fincore_path
  local jq_path
  local monotonic_ns_path
  local oha_path
  local density_load_path
  local vmtouch_path
  meminfo=$(memory_snapshot_json)
  cpuinfo=$(lscpu --json)
  memory_psi=$(pressure_json memory)
  cpu_psi=$(pressure_json cpu)
  io_psi=$(pressure_json io)
  ksm=$(ksm_snapshot_json)
  mounts=$(findmnt --json)
  git_root=$(git -C "$(dirname "${manifest}")" \
    rev-parse --show-toplevel 2>/dev/null || true)
  git_revision=
  git_dirty=false
  git_diff_sha256=
  if [[ -n ${git_root} ]]; then
    git_revision=$(git -C "${git_root}" rev-parse HEAD)
    git -C "${git_root}" status --porcelain --untracked-files=no \
      >"${work_dir}/git-status"
    if [[ -s ${work_dir}/git-status ]]; then
      git_dirty=true
    fi
    git -C "${git_root}" diff --binary HEAD >"${work_dir}/git-diff"
    git_diff_sha256=$(sha256sum "${work_dir}/git-diff")
    git_diff_sha256=${git_diff_sha256%% *}
  fi
  manifest_sha256=$(sha256sum "${manifest}")
  manifest_sha256=${manifest_sha256%% *}
  timestamp=$(date --iso-8601=ns)
  kernel=$(uname -srvmo)
  kernel_cmdline=$(</proc/cmdline)
  microcode=$(awk -F: '
    $1 ~ /^[[:space:]]*microcode[[:space:]]*$/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ' /proc/cpuinfo)
  bios_version=
  if [[ -r /sys/class/dmi/id/bios_version ]]; then
    bios_version=$(</sys/class/dmi/id/bios_version)
  fi
  target_resources=$(cgroup_snapshot_json "${target_cgroup}")
  client_resources=$(cgroup_snapshot_json "${client_cgroup}")
  thermals=$(thermal_snapshot_json)
  frequencies=$(frequency_snapshot_json)
  swap_entries=$(sed -n '2,$p' /proc/swaps)
  thp_enabled=$(</sys/kernel/mm/transparent_hugepage/enabled)
  thp_defrag=$(</sys/kernel/mm/transparent_hugepage/defrag)
  smt_control=$(</sys/devices/system/cpu/smt/control)
  boost_control=
  if [[ -r /sys/devices/system/cpu/cpufreq/boost ]]; then
    boost_control=$(</sys/devices/system/cpu/cpufreq/boost)
  fi
  workqueue_cpumask=$(</sys/devices/virtual/workqueue/cpumask)
  if pgrep -x irqbalance >/dev/null; then
    irqbalance_active=true
  fi
  bash_path=$(command -v bash)
  curl_path=$(command -v curl)
  fincore_path=$(command -v fincore)
  jq_path=$(command -v jq)
  monotonic_ns_path=$(command -v monotonic-ns)
  oha_path=$(command -v oha)
  density_load_path=$(command -v density-load)
  vmtouch_path=$(command -v vmtouch)
  tool_paths=$(jq -n \
    --arg bash "${bash_path}" \
    --arg curl "${curl_path}" \
    --arg fincore "${fincore_path}" \
    --arg jq "${jq_path}" \
    --arg monotonic_ns "${monotonic_ns_path}" \
    --arg oha "${oha_path}" \
    --arg density_load "${density_load_path}" \
    --arg vmtouch "${vmtouch_path}" \
    '{
      bash: $bash,
      curl: $curl,
      fincore: $fincore,
      jq: $jq,
      monotonic_ns: $monotonic_ns,
      oha: $oha,
      density_load: $density_load,
      vmtouch: $vmtouch
    }')
  host_controls=$(jq -n \
    --arg swap "${swap_entries}" \
    --arg thp_enabled "${thp_enabled}" \
    --arg thp_defrag "${thp_defrag}" \
    --arg smt "${smt_control}" \
    --arg boost "${boost_control}" \
    --arg workqueue_cpumask "${workqueue_cpumask}" \
    --argjson irqbalance_active "${irqbalance_active}" \
    '{
      swap_entries: ($swap | split("\n") | map(select(length > 0))),
      transparent_hugepage_enabled: $thp_enabled,
      transparent_hugepage_defrag: $thp_defrag,
      smt_control: $smt,
      boost: $boost,
      workqueue_cpumask: $workqueue_cpumask,
      irqbalance_active: $irqbalance_active
    }')
  jq -n \
    --arg schema "${schema}" \
    --arg record_type environment \
    --arg target "${target}" \
    --arg cache_condition "${cache_condition}" \
    --arg timestamp "${timestamp}" \
    --arg kernel "${kernel}" \
    --arg kernel_cmdline "${kernel_cmdline}" \
    --arg microcode "${microcode}" \
    --arg bios_version "${bios_version}" \
    --arg git_revision "${git_revision}" \
    --arg git_diff_sha256 "${git_diff_sha256}" \
    --arg manifest_sha256 "${manifest_sha256}" \
    --arg benchmark_source "${benchmark_source}" \
    --arg benchmark_revision "${benchmark_revision}" \
    --argjson git_dirty "${git_dirty}" \
    --argjson meminfo "${meminfo}" \
    --argjson cpuinfo "${cpuinfo}" \
    --argjson memory_psi "${memory_psi}" \
    --argjson cpu_psi "${cpu_psi}" \
    --argjson io_psi "${io_psi}" \
    --argjson ksm "${ksm}" \
    --argjson mounts "${mounts}" \
    --argjson target_resources "${target_resources}" \
    --argjson client_resources "${client_resources}" \
    --argjson thermals "${thermals}" \
    --argjson frequencies "${frequencies}" \
    --argjson host_controls "${host_controls}" \
    --argjson tool_paths "${tool_paths}" \
    '{
      schema: $schema,
      record_type: $record_type,
      target: $target,
      cache_condition: $cache_condition,
      timestamp: $timestamp,
      kernel: $kernel,
      kernel_cmdline: $kernel_cmdline,
      microcode: $microcode,
      bios_version: $bios_version,
      git_revision: $git_revision,
      git_dirty: $git_dirty,
      git_diff_sha256: $git_diff_sha256,
      manifest_sha256: $manifest_sha256,
      benchmark_source: $benchmark_source,
      benchmark_revision: $benchmark_revision,
      meminfo: $meminfo,
      cpuinfo: $cpuinfo,
      pressure: {memory: $memory_psi, cpu: $cpu_psi, io: $io_psi},
      resources: {
        target: $target_resources,
        client: $client_resources
      },
      host_controls: $host_controls,
      tool_paths: $tool_paths,
      thermals: $thermals,
      frequencies: $frequencies,
      ksm: $ksm,
      mounts: $mounts
    }'
}

run_environment() {
  local record
  record=$(write_environment_record)
  append_record "${record}"
  jq . <<<"${record}" >"${output_dir}/environment.json"
  echo "wrote ${output_dir}/environment.json"
}

run_launch() {
  local instance_count
  local sample
  local index
  local id
  local url
  local invocation_ns
  local cpu_before
  local cpu_after
  local ksm_cpu_before
  local ksm_cpu_after
  local clock_ticks
  local ksm_json
  local residency_json
  local resident_bytes
  local residency_size_bytes
  local exit_status
  local log_path
  local record
  local -a launch_argv=()
  instance_count=$(jq '.instances | length' "${manifest}")
  clock_ticks=$(getconf CLK_TCK)
  hook_repetition=$(jq -r '.instances[0].source_ramp // 1' "${manifest}")
  ((samples <= instance_count)) ||
    die "launch mode needs at least ${samples} fresh instances in the manifest"

  if [[ ${cache_condition} == cross-instance-warm ]]; then
    suite_active=true
    start_platform
    run_hook_list before_suite
    capture_platform_cgroup_members
  fi

  for ((sample = 1; sample <= samples; sample++)); do
    if [[ ${cache_condition} == host-cold ]]; then
      suite_active=true
      start_platform
      run_hook_list before_suite
      capture_platform_cgroup_members
    fi
    index=$((sample - 1))
    prepare_instance_index "${index}"
    run_hook_list before_sample
    residency_json=$(residency_snapshot_json)
    if [[ ${cache_condition} == host-cold ]]; then
      resident_bytes=$(jq -r '.total_resident_bytes' <<<"${residency_json}")
      residency_size_bytes=$(jq -r '.total_size_bytes' <<<"${residency_json}")
      ((residency_size_bytes > 0 &&
        resident_bytes * 100 < residency_size_bytes)) ||
        die "host-cold residency is not below one percent before launch"
    fi
    id=$(jq -r ".instances[${index}].id" "${manifest}")
    url=$(jq -r ".instances[${index}].url" "${manifest}")
    jq -r ".instances[${index}].launch[]" "${manifest}" \
      >"${work_dir}/launch-argv"
    mapfile -t launch_argv <"${work_dir}/launch-argv"
    log_path="${output_dir}/logs/${mode}-r1-${id}.log"
    cpu_before=$(deployment_cpu_usage_usec)
    ksm_cpu_before=$(ksmd_cpu_ticks)
    invocation_ns=$(monotonic_ns)
    start_service_argv "${id}" "${log_path}" "${launch_argv[@]}"
    active_instance_indexes+=("${index}")
    instance_log=${log_path}
    exit_status=0
    probe_instance "${url}" 30
    if [[ ${probe_succeeded} == false ]]; then
      exit_status=1
      readiness_first_ns=0
      readiness_confirmed_ns=0
    fi
    cpu_after=$(deployment_cpu_usage_usec)
    ksm_cpu_after=$(ksmd_cpu_ticks)
    ksm_json=$(ksm_snapshot_json)

    record=$(jq -n \
      --arg schema "${schema}" \
      --arg record_type launch \
      --arg target "${target}" \
      --arg cache_condition "${cache_condition}" \
      --arg id "${id}" \
      --arg log "${instance_log}" \
      --argjson sample "${sample}" \
      --argjson invocation_ns "${invocation_ns}" \
      --argjson first_valid_ns "${readiness_first_ns}" \
      --argjson confirmed_ns "${readiness_confirmed_ns}" \
      --argjson cpu_usage_usec "$((cpu_after - cpu_before))" \
      --argjson ksmd_cpu_ticks "$((ksm_cpu_after - ksm_cpu_before))" \
      --argjson clock_ticks "${clock_ticks}" \
      --argjson ksm "${ksm_json}" \
      --argjson residency "${residency_json}" \
      --argjson exit_status "${exit_status}" \
      '{
        schema: $schema,
        record_type: $record_type,
        target: $target,
        cache_condition: $cache_condition,
        instance_id: $id,
        sample: $sample,
        invocation_monotonic_ns: $invocation_ns,
        first_valid_monotonic_ns: $first_valid_ns,
        confirmed_monotonic_ns: $confirmed_ns,
        first_valid_seconds:
          (if $first_valid_ns == 0 then null
           else ($first_valid_ns - $invocation_ns) / 1000000000 end),
        confirmed_seconds:
          (if $confirmed_ns == 0 then null
           else ($confirmed_ns - $invocation_ns) / 1000000000 end),
        cpu_usage_usec: $cpu_usage_usec,
        ksmd_cpu_seconds: ($ksmd_cpu_ticks / $clock_ticks),
        ksm: $ksm,
        cache_evidence: {
          residency: $residency
        },
        exit_status: $exit_status,
        log: $log
      }')
    append_record "${record}"
    stop_last_instance
    wait_for_platform_cgroup_members
    [[ ${platform_cgroup_members_restored} == true ]] ||
      die "target cgroup retained non-platform processes after launch sample teardown"
    if [[ ${cache_condition} == host-cold ]]; then
      stop_platform
    fi
  done
}

run_density() {
  local repetition
  local index
  local pool_position
  local batch_position
  local batch_size
  local batch_start_count
  local batch_started
  local pool_remaining
  local pool_count
  local count
  local id
  local url
  local added_ids_json
  local baseline_used
  local platform_used
  local fixed_platform_bytes
  local idle_used
  local idle_deployment_used
  local idle_within_envelope
  local post_used
  local previous_post
  local deployment_used
  local remaining
  local predicted_marginal
  local host_available
  local launch_headroom
  local host_total
  local host_reserve
  local cpu_before
  local cpu_after
  local ksm_cpu_before
  local ksm_cpu_after
  local within_envelope
  local memory_stable
  local healthy_point
  local stop_reason
  local batch_abort_reason
  local capacity_stop_reason
  local failed_upper_bound
  local adjacent_failure_confirmed
  local measurement_points
  local max_healthy
  local max_healthy_idle
  local record
  local summary
  local meminfo
  local memory_psi
  local cpu_psi
  local ksm_json
  local clock_ticks
  local ksmd_cpu_repetition_before
  local ksmd_cpu_total_ticks
  local ksmd_cpu_delta_ticks
  local target_cgroup_json
  local process_memory_json
  local residency_json
  local client_cpu_spec
  local client_cpu_count
  local client_saturated
  local checkpoint_count
  local rollback_memory_stable
  local -a batch_added_ids=()
  local -a density_checkpoint_counts=()
  local -a density_checkpoint_bytes=()
  local -a pool_indexes=()

  for ((repetition = 1; repetition <= repetitions; repetition++)); do
    pool_count=$(jq --argjson ramp "${repetition}" \
      '[.instances[] | select((.ramp // 1) == $ramp)] | length' \
      "${manifest}")
    ((pool_count > 0)) ||
      die "density repetition ${repetition} has no fresh instance pool"
  done
  host_total=$(memory_total_bytes)
  clock_ticks=$(getconf CLK_TCK)
  client_cpu_spec=$(jq -r '.resources.client_cpus' "${manifest}")
  expand_cpu_list "${client_cpu_spec}" "${work_dir}/density-client-cpus"
  client_cpu_count=$(wc -l <"${work_dir}/density-client-cpus")
  host_reserve=$((host_total / 5))
  ((host_reserve < 4 * gib)) && host_reserve=$((4 * gib))
  ((host_total > memory_envelope_bytes + host_reserve)) ||
    die "host needs more RAM than the envelope plus safety reserve"

  for ((repetition = 1; repetition <= repetitions; repetition++)); do
    hook_repetition=$(jq -r \
      ".instances[0].source_ramp // ${repetition}" \
      "${manifest}")
    active_instance_indexes=()
    service_pids=()
    service_names=()
    service_logs=()
    batch_added_ids=()
    density_checkpoint_counts=()
    density_checkpoint_bytes=()
    ksmd_cpu_total_ticks=0
    ksmd_cpu_repetition_before=$(ksmd_cpu_ticks)
    jq -r --argjson ramp "${repetition}" '
      .instances
      | to_entries[]
      | select((.value.ramp // 1) == $ramp)
      | .key
    ' "${manifest}" >"${work_dir}/pool-indexes"
    mapfile -t pool_indexes <"${work_dir}/pool-indexes"
    suite_active=true
    run_hook_list before_baseline
    baseline_used=$(median_memory_used_bytes)
    start_platform
    run_hook_list before_suite
    capture_platform_cgroup_members
    sleep "${platform_settle_seconds}"
    evict_service_log_cache
    platform_used=$(median_memory_used_bytes)
    fixed_platform_bytes=$((platform_used - baseline_used))
    ((fixed_platform_bytes < 0)) && fixed_platform_bytes=0
    previous_post=${platform_used}
    density_checkpoint_counts+=(0)
    density_checkpoint_bytes+=("${platform_used}")
    max_healthy=0
    max_healthy_idle=0
    failed_upper_bound=0
    adjacent_failure_confirmed=false
    capacity_stop_reason=
    measurement_points=0
    stop_reason=manifest_exhausted

    pool_position=0
    while ((pool_position < ${#pool_indexes[@]})); do
      count=${#active_instance_indexes[@]}
      predicted_marginal=$(estimate_density_marginal_bytes \
        density_checkpoint_counts density_checkpoint_bytes \
        "${work_dir}" "${prediction_margin_percent}")
      deployment_used=$((previous_post - baseline_used))
      ((deployment_used < 0)) && deployment_used=0
      remaining=$((memory_envelope_bytes - deployment_used))
      host_available=$(memory_available_bytes)
      pool_remaining=$((${#pool_indexes[@]} - pool_position))
      if ((failed_upper_bound > 0 &&
        failed_upper_bound - count <= 1)); then
        batch_size=1
      else
        batch_size=$(choose_density_batch_size \
          "${count}" \
          "${pool_remaining}" \
          "${remaining}" \
          "${predicted_marginal}" \
          "${failed_upper_bound}" \
          "${density_bootstrap_instances}" \
          "${density_max_batch}" \
          "${density_single_step_at}")
      fi

      if ((batch_size == 0)); then
        stop_reason=${capacity_stop_reason}
        break
      fi

      while ((batch_size > 1 &&
        predicted_marginal > 1 &&
        host_available <
          host_reserve + predicted_marginal * batch_size)); do
        batch_size=$((batch_size / 2))
      done
      if ((predicted_marginal > 1 &&
        host_available <
          host_reserve + predicted_marginal * batch_size)); then
        stop_reason=host_safety_reserve
        break
      fi

      batch_start_count=${count}
      batch_started=0
      batch_added_ids=()
      batch_abort_reason=
      cpu_before=$(deployment_cpu_usage_usec)
      ksm_cpu_before=$(ksmd_cpu_ticks)
      launch_headroom=${predicted_marginal}
      if ((launch_headroom < density_launch_headroom_bytes)); then
        launch_headroom=${density_launch_headroom_bytes}
      fi

      for ((batch_position = 0; batch_position < batch_size; batch_position++)); do
        host_available=$(memory_available_bytes)
        if ((host_available < host_reserve + launch_headroom)); then
          batch_abort_reason=host_safety_reserve
          break
        fi
        index=${pool_indexes[pool_position + batch_position]}
        prepare_instance_index "${index}"
        run_hook_list before_sample
        id=$(jq -r ".instances[${index}].id" "${manifest}")
        url=$(jq -r ".instances[${index}].url" "${manifest}")
        start_instance "${index}" "${repetition}"
        ((batch_started++)) || true
        batch_added_ids+=("${id}")
        probe_instance "${url}" 30
        if [[ ${probe_succeeded} == true ]]; then
          host_available=$(memory_available_bytes)
          if ((host_available < host_reserve)); then
            batch_abort_reason=host_safety_reserve
            break
          fi
          continue
        fi

        stop_reason=readiness_failure
        batch_abort_reason=${stop_reason}
        cpu_after=$(deployment_cpu_usage_usec)
        ksm_cpu_after=$(ksmd_cpu_ticks)
        meminfo=$(memory_snapshot_json)
        memory_psi=$(pressure_json memory)
        cpu_psi=$(pressure_json cpu)
        ksm_json=$(ksm_snapshot_json)
        target_cgroup_json=$(cgroup_snapshot_json "${target_cgroup}")
        record=$(jq -n \
          --arg schema "${schema}" \
          --arg record_type density_failure \
          --arg target "${target}" \
          --arg cache_condition "${cache_condition}" \
          --arg id "${id}" \
          --arg reason "${stop_reason}" \
          --arg log "${instance_log}" \
          --argjson repetition "${repetition}" \
          --argjson previous_instance_count "${batch_start_count}" \
          --argjson batch_size "${batch_size}" \
          --argjson launched_in_batch "${batch_started}" \
          --argjson instance_count \
          "$((batch_start_count + batch_started))" \
          --argjson cpu_usage_usec "$((cpu_after - cpu_before))" \
          --argjson ksmd_cpu_ticks "$((ksm_cpu_after - ksm_cpu_before))" \
          --argjson clock_ticks "${clock_ticks}" \
          --argjson meminfo "${meminfo}" \
          --argjson memory_psi "${memory_psi}" \
          --argjson cpu_psi "${cpu_psi}" \
          --argjson ksm "${ksm_json}" \
          --argjson target_cgroup "${target_cgroup_json}" \
          '{
            schema: $schema,
            record_type: $record_type,
            target: $target,
            cache_condition: $cache_condition,
            repetition: $repetition,
            failed_instance_id: $id,
            previous_instance_count: $previous_instance_count,
            batch_size: $batch_size,
            launched_in_batch: $launched_in_batch,
            attempted_instance_count: $instance_count,
            reason: $reason,
            readiness_timeout_seconds: 30,
            deployment_cpu_usage_usec: $cpu_usage_usec,
            ksmd_cpu_seconds: ($ksmd_cpu_ticks / $clock_ticks),
            host: {
              meminfo: $meminfo,
              pressure: {memory: $memory_psi, cpu: $cpu_psi},
              target_cgroup: $target_cgroup
            },
            ksm: $ksm,
            log: $log
          }')
        append_record "${record}"
        break
      done

      if [[ -n ${batch_abort_reason} ]]; then
        while ((batch_started > 0)); do
          stop_last_instance
          ((batch_started--)) || true
        done
        if [[ ${batch_abort_reason} == host_safety_reserve ]]; then
          stop_reason=${batch_abort_reason}
        fi
        break
      fi

      for batch_position in "${service_logs[@]: -batch_size}"; do
        sync -f "${batch_position}"
        vmtouch -e -q "${batch_position}"
      done
      sleep "${idle_seconds}"
      if [[ ${ksm_enabled} == true ]]; then
        wait_for_ksm_stability
        if [[ ${ksm_stable} == false ]]; then
          stop_reason=ksm_stability_timeout
          while ((batch_started > 0)); do
            stop_last_instance
            ((batch_started--)) || true
          done
          break
        fi
      fi
      evict_service_log_cache
      count=${#active_instance_indexes[@]}
      idle_used=$(median_memory_used_bytes)
      idle_deployment_used=$((idle_used - baseline_used))
      ((idle_deployment_used < 0)) && idle_deployment_used=0
      idle_within_envelope=true
      if ((idle_deployment_used > memory_envelope_bytes)); then
        idle_within_envelope=false
      elif ((count > max_healthy_idle)); then
        max_healthy_idle=${count}
      fi

      run_light_load "${count}" "${repetition}"
      client_saturated=false
      if ((load_client_cpu_usage_usec * 10 >=
        load_seconds * client_cpu_count * 1000000 * 9)); then
        client_saturated=true
      fi
      if [[ ${ksm_enabled} == true ]]; then
        wait_for_ksm_stability
        if [[ ${ksm_stable} == false ]]; then
          stop_reason=ksm_stability_timeout
          load_slo_met=false
        fi
      fi
      evict_service_log_cache
      wait_for_memory_stability "${baseline_used}"
      post_used=${stabilized_used_bytes}
      cpu_after=$(deployment_cpu_usage_usec)
      ksm_cpu_after=$(ksmd_cpu_ticks)
      ksmd_cpu_delta_ticks=$((ksm_cpu_after - ksm_cpu_before))
      deployment_used=$((post_used - baseline_used))
      ((deployment_used < 0)) && deployment_used=0
      within_envelope=true
      if ((deployment_used > memory_envelope_bytes)); then
        within_envelope=false
      fi

      healthy_point=false
      if [[ ${within_envelope} == true &&
        ${load_slo_met} == true &&
        ${load_generator_failures} -eq 0 &&
        ${memory_stable} == true &&
        ${client_saturated} == false ]]; then
        healthy_point=true
        density_checkpoint_counts+=("${count}")
        density_checkpoint_bytes+=("${post_used}")
      fi
      added_ids_json=$(json_string_array "${batch_added_ids[@]}")
      predicted_marginal=$(estimate_density_marginal_bytes \
        density_checkpoint_counts density_checkpoint_bytes \
        "${work_dir}" "${prediction_margin_percent}")
      meminfo=$(memory_snapshot_json)
      memory_psi=$(pressure_json memory)
      cpu_psi=$(pressure_json cpu)
      ksm_json=$(ksm_snapshot_json)
      target_cgroup_json=$(cgroup_snapshot_json "${target_cgroup}")
      process_memory_json=$(process_memory_snapshot_json "${target_cgroup}")
      residency_json=$(residency_snapshot_json)
      record=$(jq -n \
        --arg schema "${schema}" \
        --arg record_type density_point \
        --arg target "${target}" \
        --arg cache_condition "${cache_condition}" \
        --arg id "${id}" \
        --argjson added_ids "${added_ids_json}" \
        --argjson repetition "${repetition}" \
        --argjson previous_instance_count "${batch_start_count}" \
        --argjson batch_size "${batch_size}" \
        --argjson instance_count "${count}" \
        --argjson envelope_bytes "${memory_envelope_bytes}" \
        --argjson baseline_used_bytes "${baseline_used}" \
        --argjson fixed_platform_bytes "${fixed_platform_bytes}" \
        --argjson idle_used_bytes "${idle_used}" \
        --argjson idle_deployment_bytes "${idle_deployment_used}" \
        --argjson idle_within_envelope "${idle_within_envelope}" \
        --argjson post_load_used_bytes "${post_used}" \
        --argjson deployment_post_load_bytes "${deployment_used}" \
        --argjson marginal_prediction_bytes "${predicted_marginal}" \
        --argjson within_envelope "${within_envelope}" \
        --argjson memory_stable "${memory_stable}" \
        --argjson stabilization_seconds "${stabilization_seconds}" \
        --argjson slo_met "${load_slo_met}" \
        --argjson load_generator_failures "${load_generator_failures}" \
        --argjson load "${load_summary_json}" \
        --argjson client_cpu_usage_usec "${load_client_cpu_usage_usec}" \
        --argjson client_cpu_count "${client_cpu_count}" \
        --argjson load_seconds "${load_seconds}" \
        --argjson client_saturated "${client_saturated}" \
        --argjson meminfo "${meminfo}" \
        --argjson memory_psi "${memory_psi}" \
        --argjson cpu_psi "${cpu_psi}" \
        --argjson deployment_cpu_usage_usec "$((cpu_after - cpu_before))" \
        --argjson ksmd_cpu_ticks "${ksmd_cpu_delta_ticks}" \
        --argjson clock_ticks "${clock_ticks}" \
        --argjson ksm "${ksm_json}" \
        --argjson target_cgroup "${target_cgroup_json}" \
        --argjson process_memory "${process_memory_json}" \
        --argjson residency "${residency_json}" \
        '{
          schema: $schema,
          record_type: $record_type,
          target: $target,
          cache_condition: $cache_condition,
          repetition: $repetition,
          added_instance_id: $id,
          added_instance_ids: $added_ids,
          previous_instance_count: $previous_instance_count,
          batch_size: $batch_size,
          instance_count: $instance_count,
          envelope_bytes: $envelope_bytes,
          baseline_used_bytes: $baseline_used_bytes,
          fixed_platform_bytes: $fixed_platform_bytes,
          idle_used_bytes: $idle_used_bytes,
          idle_deployment_bytes: $idle_deployment_bytes,
          idle_within_envelope: $idle_within_envelope,
          post_load_used_bytes: $post_load_used_bytes,
          deployment_post_load_bytes: $deployment_post_load_bytes,
          marginal_prediction_bytes: $marginal_prediction_bytes,
          within_envelope: $within_envelope,
          memory_stable: $memory_stable,
          stabilization_seconds: $stabilization_seconds,
          service_slo_met: $slo_met,
          load_generator_failures: $load_generator_failures,
          load: $load,
          client_cpu_usage_usec: $client_cpu_usage_usec,
          client_cpu_count: $client_cpu_count,
          client_cpu_utilization:
            ($client_cpu_usage_usec
             / (1000000 * $load_seconds * $client_cpu_count)),
          client_saturated: $client_saturated,
          host: {
            meminfo: $meminfo,
            pressure: {memory: $memory_psi, cpu: $cpu_psi},
            target_cgroup: $target_cgroup,
            process_memory: $process_memory,
            residency: $residency
          },
          deployment_cpu_usage_usec: $deployment_cpu_usage_usec,
          ksm: ($ksm + {
            ksmd_cpu_ticks: $ksmd_cpu_ticks,
            ksmd_cpu_seconds: ($ksmd_cpu_ticks / $clock_ticks)
          })
        }')
      append_record "${record}"
      ((measurement_points++)) || true

      if [[ ${healthy_point} == true ]]; then
        max_healthy=${count}
        previous_post=${post_used}
        pool_position=$((pool_position + batch_size))
        if ((failed_upper_bound > 0 && count >= failed_upper_bound)); then
          failed_upper_bound=0
          adjacent_failure_confirmed=false
          capacity_stop_reason=
          stop_reason=manifest_exhausted
        fi
      else
        if ((load_generator_failures > 0)); then
          stop_reason=load_generator_failure
        elif [[ ${memory_stable} == false ]]; then
          stop_reason=memory_stability_timeout
        elif [[ ${within_envelope} == false ]]; then
          stop_reason=measured_envelope_exceeded
        elif [[ ${client_saturated} == true ]]; then
          stop_reason=client_saturation
        elif [[ ${stop_reason} != ksm_stability_timeout ]]; then
          stop_reason=service_slo_failure
        fi
        while ((batch_started > 0)); do
          stop_last_instance
          ((batch_started--)) || true
        done

        if [[ ${stop_reason} == measured_envelope_exceeded ||
          ${stop_reason} == service_slo_failure ]]; then
          if ((failed_upper_bound == 0 || count < failed_upper_bound)); then
            failed_upper_bound=${count}
            adjacent_failure_confirmed=false
            capacity_stop_reason=${stop_reason}
          fi
          pool_position=$((pool_position + batch_size))
          if ((batch_size == 1 &&
            batch_start_count == max_healthy &&
            count == max_healthy + 1)); then
            adjacent_failure_confirmed=true
            break
          fi

          sleep "${idle_seconds}"
          rollback_memory_stable=true
          if [[ ${ksm_enabled} == true ]]; then
            wait_for_ksm_stability
            if [[ ${ksm_stable} == false ]]; then
              rollback_memory_stable=false
            fi
          fi
          if [[ ${rollback_memory_stable} == true ]]; then
            wait_for_memory_stability "${baseline_used}"
            rollback_memory_stable=${memory_stable}
          fi
          if [[ ${rollback_memory_stable} == false ]]; then
            stop_reason=memory_stability_timeout
            break
          fi
          continue
        fi
        break
      fi
    done

    if ((pool_position >= ${#pool_indexes[@]} &&
      failed_upper_bound > 0)) &&
      [[ ${adjacent_failure_confirmed} == false ]]; then
      stop_reason=manifest_exhausted
    fi
    checkpoint_count=$((${#density_checkpoint_counts[@]} - 1))
    predicted_marginal=$(estimate_density_marginal_bytes \
      density_checkpoint_counts density_checkpoint_bytes \
      "${work_dir}" "${prediction_margin_percent}")
    ksmd_cpu_total_ticks=$(($(ksmd_cpu_ticks) - ksmd_cpu_repetition_before))
    deployment_used=$((previous_post - baseline_used))
    ((deployment_used < 0)) && deployment_used=0
    remaining=$((memory_envelope_bytes - deployment_used))
    ((remaining < 0)) && remaining=0
    summary=$(jq -n \
      --arg schema "${schema}" \
      --arg record_type density_summary \
      --arg target "${target}" \
      --arg cache_condition "${cache_condition}" \
      --arg stop_reason "${stop_reason}" \
      --argjson repetition "${repetition}" \
      --argjson envelope_bytes "${memory_envelope_bytes}" \
      --argjson fixed_platform_bytes "${fixed_platform_bytes}" \
      --argjson maximum_healthy_instances "${max_healthy}" \
      --argjson maximum_observed_healthy_idle_instances \
      "${max_healthy_idle}" \
      --argjson final_deployment_bytes "${deployment_used}" \
      --argjson remaining_envelope_bytes "${remaining}" \
      --argjson marginal_prediction_bytes "${predicted_marginal}" \
      --argjson prediction_margin_percent "${prediction_margin_percent}" \
      --argjson bootstrap_instances "${density_bootstrap_instances}" \
      --argjson maximum_batch_size "${density_max_batch}" \
      --argjson single_step_at "${density_single_step_at}" \
      --argjson launch_headroom_bytes "${density_launch_headroom_bytes}" \
      --argjson checkpoint_count "${checkpoint_count}" \
      --argjson measurement_points "${measurement_points}" \
      --argjson failed_upper_bound "${failed_upper_bound}" \
      --argjson adjacent_failure_confirmed \
      "${adjacent_failure_confirmed}" \
      --argjson ksmd_cpu_total_ticks "${ksmd_cpu_total_ticks}" \
      --argjson clock_ticks "${clock_ticks}" \
      '{
        schema: $schema,
        record_type: $record_type,
        target: $target,
        cache_condition: $cache_condition,
        repetition: $repetition,
        envelope_bytes: $envelope_bytes,
        fixed_platform_bytes: $fixed_platform_bytes,
        maximum_healthy_instances: $maximum_healthy_instances,
        maximum_observed_healthy_idle_instances:
          $maximum_observed_healthy_idle_instances,
        final_deployment_bytes: $final_deployment_bytes,
        remaining_envelope_bytes: $remaining_envelope_bytes,
        marginal_prediction_bytes: $marginal_prediction_bytes,
        prediction_margin_percent: $prediction_margin_percent,
        adaptive_batching: {
          bootstrap_instances: $bootstrap_instances,
          maximum_batch_size: $maximum_batch_size,
          per_launch_host_headroom_bytes: $launch_headroom_bytes,
          single_step_at_predicted_remaining_instances: $single_step_at,
          healthy_checkpoint_count: $checkpoint_count,
          measurement_points: $measurement_points,
          failed_upper_bound:
            (if $failed_upper_bound == 0
             then null
             else $failed_upper_bound
             end),
          adjacent_failure_confirmed: $adjacent_failure_confirmed
        },
        ksmd_cpu_seconds: ($ksmd_cpu_total_ticks / $clock_ticks),
        fractional_instance_headroom:
          (if $marginal_prediction_bytes > 0
           then $remaining_envelope_bytes / $marginal_prediction_bytes
           else null end),
        capacity_censored:
          ($stop_reason == "manifest_exhausted"
           or $stop_reason == "host_safety_reserve"
           or $stop_reason == "ksm_stability_timeout"
           or $stop_reason == "load_generator_failure"
           or $stop_reason == "memory_stability_timeout"
           or $stop_reason == "client_saturation"
           or $stop_reason == "readiness_failure"),
        stop_reason: $stop_reason
      }')
    append_record "${summary}"

    while ((${#active_instance_indexes[@]} > 0)); do
      stop_last_instance
    done
    stop_platform
    sleep 5
  done
}

host_cpu_counters() {
  awk '
    $1 == "cpu" {
      total = 0
      for (field = 2; field <= NF; field++) total += $field
      print total, $5 + $6
      exit
    }
  ' /proc/stat
}

monitor_host_memory() {
  local duration=$1
  local destination=$2
  local deadline=$((SECONDS + duration))
  local host_memory
  local client_memory
  while ((SECONDS < deadline)); do
    host_memory=$(memory_used_bytes)
    client_memory=$(client_memory_current_bytes)
    printf '%s %s\n' \
      "${host_memory}" \
      "${client_memory}" \
      >>"${destination}"
    sleep 1
  done
}

memory_sample_statistics() {
  local source=$1
  local duration=$2
  local steady_count=$((duration / 2))
  ((steady_count > 0)) || steady_count=1
  memory_peak_bytes=$(awk '
    NR == 1 || $1 > maximum { maximum = $1 }
    END { print maximum }
  ' "${source}")
  client_memory_peak_bytes=$(awk '
    NR == 1 || $2 > maximum { maximum = $2 }
    END { print maximum }
  ' "${source}")
  memory_steady_bytes=$(tail -n "${steady_count}" "${source}" |
    awk '{ print $1 }' |
    sort -n |
    awk '
      { values[NR] = $1 }
      END {
        if (NR % 2 == 1) print values[(NR + 1) / 2]
        else print (values[NR / 2] + values[NR / 2 + 1]) / 2
      }
    ')
  client_memory_steady_bytes=$(tail -n "${steady_count}" "${source}" |
    awk '{ print $2 }' |
    sort -n |
    awk '
      { values[NR] = $1 }
      END {
        if (NR % 2 == 1) print values[(NR + 1) / 2]
        else print (values[NR / 2] + values[NR / 2 + 1]) / 2
      }
    ')
}

run_nginx_sample() {
  local repetition=$1
  local run_kind=$2
  local path=$3
  local keepalive=$4
  local concurrency=$5
  local duration=$6
  local base_url=$7
  local id=$8
  local network_interface=$9
  local client_cpu_count=${10}
  local path_label=${path#/}
  local url="${base_url}${path}"
  local output
  local memory_samples
  local host_cpu_sample
  local load_json
  local status_responses
  local transport_errors
  local bad_statuses
  local errors
  local requests
  local memory_before
  local memory_after
  local cpu_before
  local cpu_after
  local client_cpu_before
  local client_cpu_after
  local client_cpu_delta
  local client_saturated
  local ksmd_cpu_before
  local ksmd_cpu_after
  local clock_ticks
  local host_total_before
  local host_idle_before
  local host_total_after
  local host_idle_after
  local host_total_delta
  local host_idle_delta
  local host_cpu_utilization
  local network_rx_before
  local network_tx_before
  local network_rx_after
  local network_tx_after
  local monitor_pid
  local oha_status
  local record
  local ksm_json
  local -a keepalive_arg=()

  [[ -n ${path_label} ]] || path_label=root
  if [[ ${keepalive} == false ]]; then
    keepalive_arg=(--disable-keepalive)
  fi

  NO_COLOR=true oha \
    --no-tui \
    --output-format quiet \
    --wait-ongoing-requests-after-deadline \
    --connect-timeout 1s \
    -t 2s \
    -c "${concurrency}" \
    -z "${warmup_seconds}s" \
    "${keepalive_arg[@]}" \
    "${url}" >/dev/null

  output="${output_dir}/logs/nginx-${run_kind}-r${repetition}-${path_label}-c${concurrency}-ka${keepalive}.json"
  memory_samples="${output%.json}-memory.txt"
  host_cpu_sample="${output%.json}-host-cpu.txt"
  cpu_before=$(deployment_cpu_usage_usec)
  client_cpu_before=$(client_cpu_usage_usec)
  ksmd_cpu_before=$(ksmd_cpu_ticks)
  memory_before=$(memory_used_bytes)
  host_cpu_counters >"${host_cpu_sample}"
  read -r host_total_before host_idle_before <"${host_cpu_sample}"
  network_rx_before=$(<"/sys/class/net/${network_interface}/statistics/rx_bytes")
  network_tx_before=$(<"/sys/class/net/${network_interface}/statistics/tx_bytes")

  monitor_host_memory "${duration}" "${memory_samples}" &
  monitor_pid=$!
  auxiliary_pids+=("${monitor_pid}")
  set +e
  NO_COLOR=true oha \
    --no-tui \
    --output-format json \
    --wait-ongoing-requests-after-deadline \
    --connect-timeout 1s \
    -t 2s \
    -c "${concurrency}" \
    -z "${duration}s" \
    "${keepalive_arg[@]}" \
    "${url}" >"${output}"
  oha_status=$?
  set -e
  if ((oha_status != 0)); then
    kill -TERM "${monitor_pid}" 2>/dev/null || true
  fi
  wait "${monitor_pid}" 2>/dev/null || true
  unset 'auxiliary_pids[-1]'
  auxiliary_pids=("${auxiliary_pids[@]}")
  ((oha_status == 0)) || die "oha failed for ${run_kind} nginx sample"

  network_rx_after=$(<"/sys/class/net/${network_interface}/statistics/rx_bytes")
  network_tx_after=$(<"/sys/class/net/${network_interface}/statistics/tx_bytes")
  host_cpu_counters >"${host_cpu_sample}"
  read -r host_total_after host_idle_after <"${host_cpu_sample}"
  memory_after=$(memory_used_bytes)
  ksmd_cpu_after=$(ksmd_cpu_ticks)
  client_cpu_after=$(client_cpu_usage_usec)
  cpu_after=$(deployment_cpu_usage_usec)
  client_cpu_delta=$((client_cpu_after - client_cpu_before))
  client_saturated=false
  if ((client_cpu_delta * 10 >=
    duration * client_cpu_count * 1000000 * 9)); then
    client_saturated=true
  fi
  memory_sample_statistics "${memory_samples}" "${duration}"
  host_total_delta=$((host_total_after - host_total_before))
  host_idle_delta=$((host_idle_after - host_idle_before))
  host_cpu_utilization=$(awk \
    -v total="${host_total_delta}" \
    -v idle="${host_idle_delta}" \
    'BEGIN {
      if (total > 0) print (total - idle) / total
      else print 0
    }')
  clock_ticks=$(getconf CLK_TCK)
  load_json=$(<"${output}")
  status_responses=$(jq \
    '[.statusCodeDistribution[]?] | add // 0' <<<"${load_json}")
  transport_errors=$(jq \
    '[.errorDistribution[]?] | add // 0' <<<"${load_json}")
  bad_statuses=$(jq '
    [.statusCodeDistribution | to_entries[]? |
      select(.key != "200") | .value] | add // 0
  ' <<<"${load_json}")
  requests=$((status_responses + transport_errors))
  errors=$((transport_errors + bad_statuses))
  ksm_json=$(ksm_snapshot_json)
  record=$(jq -n \
    --arg schema "${schema}" \
    --arg record_type nginx \
    --arg run_kind "${run_kind}" \
    --arg target "${target}" \
    --arg cache_condition "${cache_condition}" \
    --arg id "${id}" \
    --arg path "${path}" \
    --arg network_interface "${network_interface}" \
    --argjson repetition "${repetition}" \
    --argjson concurrency "${concurrency}" \
    --argjson keepalive "${keepalive}" \
    --argjson requests "${requests}" \
    --argjson errors "${errors}" \
    --argjson target_cpu_usage_usec "$((cpu_after - cpu_before))" \
    --argjson client_cpu_usage_usec "${client_cpu_delta}" \
    --argjson client_saturated "${client_saturated}" \
    --argjson ksmd_cpu_ticks "$((ksmd_cpu_after - ksmd_cpu_before))" \
    --argjson clock_ticks "${clock_ticks}" \
    --argjson sample_seconds "${duration}" \
    --argjson warmup_seconds "${warmup_seconds}" \
    --argjson client_cpu_count "${client_cpu_count}" \
    --argjson memory_before_bytes "${memory_before}" \
    --argjson memory_after_bytes "${memory_after}" \
    --argjson memory_peak_bytes "${memory_peak_bytes}" \
    --argjson memory_steady_bytes "${memory_steady_bytes}" \
    --argjson client_memory_peak_bytes "${client_memory_peak_bytes}" \
    --argjson client_memory_steady_bytes "${client_memory_steady_bytes}" \
    --argjson host_cpu_utilization "${host_cpu_utilization}" \
    --argjson network_rx_bytes "$((network_rx_after - network_rx_before))" \
    --argjson network_tx_bytes "$((network_tx_after - network_tx_before))" \
    --argjson ksm "${ksm_json}" \
    --argjson load "${load_json}" \
    '{
      schema: $schema,
      record_type: $record_type,
      run_kind: $run_kind,
      target: $target,
      cache_condition: $cache_condition,
      repetition: $repetition,
      instance_id: $id,
      path: $path,
      keepalive: $keepalive,
      concurrency: $concurrency,
      requests: $requests,
      errors: $errors,
      error_rate: (if $requests > 0 then $errors / $requests else null end),
      target_cpu_usage_usec: $target_cpu_usage_usec,
      client_cpu_usage_usec: $client_cpu_usage_usec,
      client_cpu_utilization:
        ($client_cpu_usage_usec
         / (1000000 * $sample_seconds * $client_cpu_count)),
      client_saturated: $client_saturated,
      ksmd_cpu_seconds: ($ksmd_cpu_ticks / $clock_ticks),
      sample_seconds: $sample_seconds,
      warmup_seconds: $warmup_seconds,
      client_cpu_count: $client_cpu_count,
      host_cpu_utilization: $host_cpu_utilization,
      host_resident_before_bytes: $memory_before_bytes,
      host_resident_after_bytes: $memory_after_bytes,
      host_resident_peak_bytes: $memory_peak_bytes,
      host_resident_steady_bytes: $memory_steady_bytes,
      client_cgroup_memory_peak_bytes: $client_memory_peak_bytes,
      client_cgroup_memory_steady_bytes: $client_memory_steady_bytes,
      network: {
        interface: $network_interface,
        rx_bytes: $network_rx_bytes,
        tx_bytes: $network_tx_bytes,
        total_bytes: ($network_rx_bytes + $network_tx_bytes)
      },
      ksm: $ksm,
      oha: $load
    }')
  append_record "${record}"
  sync -f "${output}" "${memory_samples}" "${host_cpu_sample}"
  vmtouch -e -q "${output}" "${memory_samples}" "${host_cpu_sample}"
}

run_nginx() {
  local repetition
  local concurrency
  local path
  local keepalive
  local index=0
  local id
  local base_url
  local network_interface
  local client_cpu_count
  local client_cpu_spec
  local -a concurrencies=(1 8 32 128)
  local -a paths=("/" "/1m")
  local -a keepalive_modes=(true false)

  hook_repetition=$(jq -r '.instances[0].source_ramp // 1' "${manifest}")
  suite_active=true
  start_platform
  run_hook_list before_suite
  capture_platform_cgroup_members
  id=$(jq -r ".instances[${index}].id" "${manifest}")
  base_url=$(jq -r ".instances[${index}].url" "${manifest}")
  base_url=${base_url%/}
  network_interface=$(jq -r \
    ".instances[${index}].network_interface" "${manifest}")
  prepare_instance_index "${index}"
  start_instance "${index}" 1
  probe_instance "${base_url}/" 30
  [[ ${probe_succeeded} == true ]] ||
    die "nginx instance failed readiness"
  verify_http_object \
    "${base_url}/1m" \
    1048576 \
    "30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58"
  [[ ${verification_succeeded} == true ]] ||
    die "nginx 1 MiB object failed exact content verification"
  if [[ ${ksm_enabled} == true ]]; then
    wait_for_ksm_stability
    [[ ${ksm_stable} == true ]] ||
      die "KSM did not converge before nginx measurement"
  else
    sleep 30
  fi
  client_cpu_spec=$(jq -r '.resources.client_cpus' "${manifest}")
  expand_cpu_list "${client_cpu_spec}" "${work_dir}/nginx-client-cpus"
  client_cpu_count=$(wc -l <"${work_dir}/nginx-client-cpus")

  for ((repetition = 1; repetition <= repetitions; repetition++)); do
    for path in "${paths[@]}"; do
      for keepalive in "${keepalive_modes[@]}"; do
        for concurrency in "${concurrencies[@]}"; do
          run_nginx_sample \
            "${repetition}" matrix "${path}" "${keepalive}" \
            "${concurrency}" "${sample_seconds}" "${base_url}" \
            "${id}" "${network_interface}" "${client_cpu_count}"
        done
      done
    done
    if ((sustained_seconds > 0)); then
      run_nginx_sample \
        "${repetition}" sustained / true \
        "${sustained_concurrency}" "${sustained_seconds}" "${base_url}" \
        "${id}" "${network_interface}" "${client_cpu_count}"
    fi
  done
}

case "${mode}" in
  environment)
    preflight_host
    run_environment
    ;;
  launch)
    preflight_host
    if [[ ${ksm_enabled} == true ]]; then
      configure_ksm
    fi
    run_launch
    ;;
  density)
    preflight_host
    if [[ ${ksm_enabled} == true ]]; then
      configure_ksm
    fi
    run_density
    ;;
  nginx)
    preflight_host
    if [[ ${ksm_enabled} == true ]]; then
      configure_ksm
    fi
    run_nginx
    ;;
  *) die "unreachable mode: ${mode}" ;;
esac

cleanup
trap - EXIT INT TERM
