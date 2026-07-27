set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  prepare-benchmark-pool [--jobs N] container|vm-no-ksm|vm-ksm ASSET_ROOT \
    NETWORK_SPEC RAMPS INSTANCES_PER_RAMP POOL_ROOT
EOF
  exit 2
}

die() {
  echo "prepare-benchmark-pool: $*" >&2
  exit 1
}

[[ ${EUID} -eq 0 ]] || die "must run as root"
preparation_jobs=1
if [[ ${1:-} == --jobs ]]; then
  [[ $# -ge 3 ]] || usage
  preparation_jobs=$2
  shift 2
fi
[[ $# -eq 6 ]] || usage

arm=$1
asset_root=$(realpath "$2")
network_spec=$(realpath "$3")
ramps=$4
instances_per_ramp=$5
pool_root=$(realpath -m "$6")

case "${arm}" in
  container|vm-no-ksm|vm-ksm) ;;
  *) usage ;;
esac
for value in "${ramps}" "${instances_per_ramp}"; do
  [[ ${value} =~ ^[1-9][0-9]*$ ]] ||
    die "ramps and instances per ramp must be positive integers"
done
[[ ${preparation_jobs} =~ ^[1-9][0-9]*$ ]] ||
  die "preparation jobs must be a positive integer"
[[ -r ${asset_root}/assets.json && -d ${asset_root}/vm-artifacts ]] ||
  die "asset root is incomplete: ${asset_root}"
[[ ! -e ${pool_root} ]] ||
  die "refusing to replace existing pool: ${pool_root}"

endpoint_count=$(jq '.endpoints | length' "${network_spec}")
((endpoint_count >= instances_per_ramp + 1)) ||
  die "network spec needs a warm endpoint plus every measured endpoint"
if [[ ${arm} == container ]]; then
  jq -e 'all(.endpoints[]; .kind == "netns")' "${network_spec}" >/dev/null ||
    die "container pool requires network-namespace endpoints"
else
  jq -e 'all(.endpoints[]; .kind == "tap")' "${network_spec}" >/dev/null ||
    die "VM pool requires TAP endpoints"
fi

prepare_vm=@PREPARE_VM@
prepare_container=@PREPARE_CONTAINER@
run_snix=@RUN_SNIX@
manage_network=@MANAGE_NETWORK@

mkdir -p "${pool_root}"
preparation_complete=false
network_active=false
service_pids=()
preparation_pids=()
declare -a vm_instances=()

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

cleanup() {
  local position
  for ((position = ${#preparation_pids[@]} - 1; position >= 0; position--)); do
    kill -TERM "${preparation_pids[position]}" 2>/dev/null || true
  done
  for ((position = ${#preparation_pids[@]} - 1; position >= 0; position--)); do
    wait "${preparation_pids[position]}" 2>/dev/null || true
  done
  if [[ ${arm} == container ]] &&
    mountpoint -q "${asset_root}/snix/mount"; then
    "${run_snix}" unmount "${asset_root}/snix" || true
  fi
  for ((position = ${#service_pids[@]} - 1; position >= 0; position--)); do
    stop_process_group "${service_pids[position]}"
  done
  if [[ ${network_active} == true ]]; then
    "${manage_network}" remove-bridge "${network_spec}" >/dev/null || true
  fi
  if [[ ${preparation_complete} == false ]]; then
    echo "prepare-benchmark-pool: partial pool retained at ${pool_root}" >&2
  fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_preparation_job() {
  local completed_pid
  local completed_status
  local position
  if wait -n -p completed_pid "${preparation_pids[@]}"; then
    completed_status=0
  else
    completed_status=$?
  fi
  for ((position = 0; position < ${#preparation_pids[@]}; position++)); do
    if [[ ${preparation_pids[position]} == "${completed_pid}" ]]; then
      unset 'preparation_pids[position]'
      break
    fi
  done
  preparation_pids=("${preparation_pids[@]}")
  ((completed_status == 0)) ||
    die "parallel instance preparation failed"
}

start_container_preparation() {
  local instance_path=$1
  local endpoint_index=$2
  local container_id=$3
  "${prepare_container}" \
    "${asset_root}" \
    "${instance_path}" \
    "${network_spec}" \
    "${endpoint_index}" \
    "${container_id}" &
  preparation_pids+=("$!")
  if ((${#preparation_pids[@]} >= preparation_jobs)); then
    wait_for_preparation_job
  fi
}

wait_for_all_preparation_jobs() {
  while ((${#preparation_pids[@]} > 0)); do
    wait_for_preparation_job
  done
}

if [[ ${arm} == container ]]; then
  mkdir -p "${pool_root}/logs"
  setsid -- "${run_snix}" daemon "${asset_root}/snix" \
    >"${pool_root}/logs/snix-daemon.log" 2>&1 &
  service_pids+=("$!")
  setsid -- "${run_snix}" mount "${asset_root}/snix" \
    >"${pool_root}/logs/snix-mount.log" 2>&1 &
  service_pids+=("$!")
  setsid -- "${run_snix}" nix-daemon "${asset_root}/snix" \
    >"${pool_root}/logs/snix-nix-daemon.log" 2>&1 &
  service_pids+=("$!")
  "${run_snix}" ready "${asset_root}/snix"
fi

"${manage_network}" create-bridge "${network_spec}"
network_active=true

for ((ramp = 1; ramp <= ramps; ramp++)); do
  ramp_root="${pool_root}/ramp-${ramp}"
  mkdir -p "${ramp_root}/instances"
  if [[ ${arm} == container ]]; then
    printf -v container_id 'prep-r%02d-warm' "${ramp}"
    start_container_preparation \
      "${ramp_root}/warm" \
      0 \
      "${container_id}"
    for ((index = 1; index <= instances_per_ramp; index++)); do
      printf -v instance_path \
        '%s/instances/i-%04d' "${ramp_root}" "${index}"
      printf -v container_id 'prep-r%02d-i%04d' "${ramp}" "${index}"
      start_container_preparation \
        "${instance_path}" \
        "${index}" \
        "${container_id}"
    done
    wait_for_all_preparation_jobs
  else
    vm_instances=("${ramp_root}/warm")
    for ((index = 1; index <= instances_per_ramp; index++)); do
      printf -v instance_path \
        '%s/instances/i-%04d' "${ramp_root}" "${index}"
      vm_instances+=("${instance_path}")
    done
    "${prepare_vm}" \
      --base "${asset_root}/vm-artifacts" \
      "${vm_instances[@]}"
  fi
done

jq -n \
  --arg schema fast-vms-prepared-pool-v1 \
  --arg arm "${arm}" \
  --arg asset_root "${asset_root}" \
  --arg network_spec "${network_spec}" \
  --argjson ramps "${ramps}" \
  --argjson instances_per_ramp "${instances_per_ramp}" \
  --argjson preparation_jobs "${preparation_jobs}" \
  '{
    schema: $schema,
    arm: $arm,
    asset_root: $asset_root,
    network_spec: $network_spec,
    ramps: $ramps,
    instances_per_ramp: $instances_per_ramp,
    preparation_jobs: $preparation_jobs
  }' >"${pool_root}/pool.json"

preparation_complete=true
echo "prepared ${arm} pool at ${pool_root}"
