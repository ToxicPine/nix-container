set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  warm-benchmark-instance TARGET_CGROUP URL RESIDENCY_LIST STOP.json \
    PREPARE.json CLEANUP.json -- LAUNCH_COMMAND [ARG...]
EOF
  exit 2
}

die() {
  echo "warm-benchmark-instance: $*" >&2
  exit 1
}

[[ $# -ge 8 ]] || usage
repetition=${FAST_VMS_BENCHMARK_REPETITION:-1}
[[ ${repetition} =~ ^[1-9][0-9]*$ ]] ||
  die "FAST_VMS_BENCHMARK_REPETITION must be a positive integer"
target_cgroup=$(realpath "${1//@RAMP@/${repetition}}")
url=${2//@RAMP@/${repetition}}
url=${url%/}
residency_list=$(realpath "${3//@RAMP@/${repetition}}")
stop_commands=$(realpath "${4//@RAMP@/${repetition}}")
prepare_commands=$(realpath "${5//@RAMP@/${repetition}}")
cleanup_commands=$(realpath "${6//@RAMP@/${repetition}}")
shift 6
[[ $1 == -- ]] || usage
shift
[[ $# -gt 0 ]] || usage
launch_command=()
for argument in "$@"; do
  launch_command+=("${argument//@RAMP@/${repetition}}")
done

[[ -r ${target_cgroup}/cgroup.procs ]] ||
  die "target cgroup is unavailable: ${target_cgroup}"
[[ -s ${residency_list} ]] ||
  die "residency list is empty: ${residency_list}"
for command_file in \
  "${stop_commands}" \
  "${prepare_commands}" \
  "${cleanup_commands}"; do
  jq -e '
    type == "array"
    and all(.[];
      type == "array"
      and length > 0
      and all(.[]; type == "string"))
  ' "${command_file}" >/dev/null ||
    die "invalid command list: ${command_file}"
done

work_dir=$(mktemp -d)
launcher_pid=
cleanup_started=false
instance_prepared=false

run_command_list() {
  local command_file=$1
  local failure_mode=$2
  local command_json
  local command_status
  local -a command=()
  jq -c '.[]' "${command_file}" >"${work_dir}/commands"
  while IFS= read -r command_json; do
    jq -r '.[]' <<<"${command_json}" >"${work_dir}/command"
    mapfile -t command <"${work_dir}/command"
    set +e
    "${command[@]}" >/dev/null 2>&1
    command_status=$?
    set -e
    if ((command_status != 0)) && [[ ${failure_mode} == fatal ]]; then
      die "warm-up resource command failed: ${command[*]}"
    fi
  done <"${work_dir}/commands"
}

cleanup() {
  if [[ ${cleanup_started} == true ]]; then
    return
  fi
  cleanup_started=true
  run_command_list "${stop_commands}" best-effort
  if [[ -n ${launcher_pid} ]]; then
    kill -TERM -- "-${launcher_pid}" 2>/dev/null || true
    deadline=$((SECONDS + 10))
    while kill -0 "${launcher_pid}" 2>/dev/null &&
      ((SECONDS < deadline)); do
      sleep 0.1
    done
    if kill -0 "${launcher_pid}" 2>/dev/null; then
      kill -KILL -- "-${launcher_pid}" 2>/dev/null || true
    fi
    wait "${launcher_pid}" 2>/dev/null || true
  fi
  if [[ ${instance_prepared} == true ]]; then
    run_command_list "${cleanup_commands}" best-effort
  fi
  rm -rf -- "${work_dir}"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cgroup_read_bytes() {
  local pid
  local value
  local total=0
  while IFS= read -r pid; do
    [[ -r /proc/${pid}/io ]] || continue
    value=$(awk '$1 == "read_bytes:" { print $2 }' "/proc/${pid}/io")
    total=$((total + ${value:-0}))
  done <"${target_cgroup}/cgroup.procs"
  printf '%s\n' "${total}"
}

residency_bytes() {
  local batch_size=256
  local batch_resident_bytes
  local offset
  local snapshot
  local total_resident_bytes=0
  local -a batch=()
  local -a files=()
  mapfile -t files <"${residency_list}"
  for ((offset = 0; offset < ${#files[@]}; offset += batch_size)); do
    batch=("${files[@]:offset:batch_size}")
    snapshot=$(fincore -J -b -o FILE,SIZE,RES "${batch[@]}")
    batch_resident_bytes=$(jq '[.fincore[].res] | add // 0' <<<"${snapshot}")
    total_resident_bytes=$((total_resident_bytes + batch_resident_bytes))
  done
  printf '%s\n' "${total_resident_bytes}"
}

verify_object() {
  local path=$1
  local expected_size=$2
  local expected_sha256=$3
  local output="${work_dir}/response"
  local status
  local actual_size
  local actual_sha256
  status=$(curl \
    --silent \
    --noproxy '*' \
    --output "${output}" \
    --write-out '%{http_code}' \
    --connect-timeout 1 \
    --max-time 10 \
    "${url}${path}")
  [[ ${status} == 200 ]] || return 1
  actual_size=$(stat -c %s "${output}")
  actual_sha256=$(sha256sum "${output}")
  actual_sha256=${actual_sha256%% *}
  [[ ${actual_size} -eq ${expected_size} &&
    ${actual_sha256} == "${expected_sha256}" ]]
}

check_object() {
  set +e
  verify_object "$@"
  object_status=$?
  set -e
}

instance_prepared=true
run_command_list "${prepare_commands}" fatal
setsid -- cgroup-exec "${target_cgroup}" "${launch_command[@]}" \
  >"${work_dir}/launcher.log" 2>&1 &
launcher_pid=$!

deadline=$((SECONDS + 30))
while true; do
  check_object \
    / \
    25 \
    edf03332c6ca9e23cc6b21849fd76e032c59634312e1c787290816f8e8a5fa00
  ((object_status == 0)) && break
  kill -0 "${launcher_pid}" 2>/dev/null ||
    die "warm-up instance exited before readiness"
  ((SECONDS < deadline)) ||
    die "warm-up instance did not become ready within 30 seconds"
  sleep 0.05
done
check_object \
  /1m \
  1048576 \
  30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58
((object_status == 0)) ||
  die "warm-up instance returned the wrong 1 MiB object"

first_resident=$(residency_bytes)
read_bytes_before=$(cgroup_read_bytes)
check_object \
  / \
  25 \
  edf03332c6ca9e23cc6b21849fd76e032c59634312e1c787290816f8e8a5fa00
((object_status == 0)) ||
  die "second small-object read failed"
check_object \
  /1m \
  1048576 \
  30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58
((object_status == 0)) ||
  die "second 1 MiB read failed"
read_bytes_after=$(cgroup_read_bytes)
second_resident=$(residency_bytes)

resident_growth=$((second_resident - first_resident))
((resident_growth < 0)) && resident_growth=$((-resident_growth))
resident_tolerance=$((first_resident / 100))
((resident_tolerance < 4096)) && resident_tolerance=4096
((resident_growth <= resident_tolerance)) ||
  die "second working-set read changed residency by more than one percent"
backing_reads=$((read_bytes_after - read_bytes_before))
((backing_reads < 0)) && backing_reads=0
((backing_reads <= 1048576)) ||
  die "second working-set read caused more than 1 MiB of backing-device reads"

jq -n \
  --argjson first_resident_bytes "${first_resident}" \
  --argjson second_resident_bytes "${second_resident}" \
  --argjson second_read_backing_bytes "${backing_reads}" \
  '{
    cache_warmup: "verified",
    first_resident_bytes: $first_resident_bytes,
    second_resident_bytes: $second_resident_bytes,
    second_read_backing_bytes: $second_read_backing_bytes
  }'
