set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: summarize-benchmark-storage [--envelope-gib N] \
  DENSITY.jsonl ASSET_ROOT CONTAINER_POOL VM_POOL OUTPUT.json

Measure physically allocated runtime storage from prepared, exercised density
instances. Fixed storage includes the shared container root/store or VM image
artifacts. Marginal storage includes each container's private writable state
and OCI configuration or each VM's private qcow2 overlay.
EOF
  exit 2
}

die() {
  echo "summarize-benchmark-storage: $*" >&2
  exit 1
}

allocated_bytes() {
  du -B1 --summarize -- "$@" |
    awk '{ total += $1 } END { printf "%.0f\n", total }'
}

pool_field() {
  local pool_root=$1
  local expression=$2
  jq -er "${expression}" "${pool_root}/pool.json"
}

measure_container_instance() {
  local instance_root=$1
  allocated_bytes \
    "${instance_root}/bundle/config.json" \
    "${instance_root}/data" \
    "${instance_root}/nix" \
    "${instance_root}/store-upper" \
    "${instance_root}/store-work"
}

measure_vm_instance() {
  local instance_root=$1
  allocated_bytes "${instance_root}/disk.qcow2"
}

envelope_gib=16
while [[ $# -gt 0 ]]; do
  case "$1" in
    --envelope-gib)
      [[ $# -ge 2 ]] || usage
      envelope_gib=$2
      shift 2
      ;;
    -*)
      usage
      ;;
    *)
      break
      ;;
  esac
done

[[ ${envelope_gib} =~ ^[1-9][0-9]*$ ]] || usage
[[ $# -eq 5 ]] || usage
[[ ${EUID} -eq 0 ]] ||
  die "must run as root to read ownership-preserving prepared state"

density_raw=$(realpath "$1")
asset_root=$(realpath "$2")
container_pool=$(realpath "$3")
vm_pool=$(realpath "$4")
output=$(realpath -m "$5")

[[ -r ${density_raw} ]] || die "density JSONL is unreadable: ${density_raw}"
[[ -r ${asset_root}/assets.json ]] ||
  die "asset root is incomplete: ${asset_root}"
[[ -d ${output%/*} && -w ${output%/*} ]] ||
  die "output parent must be an existing writable directory"
[[ ! -e ${output} ]] || die "refusing to replace output: ${output}"

for pool_root in "${container_pool}" "${vm_pool}"; do
  [[ -r ${pool_root}/pool.json ]] ||
    die "prepared pool is incomplete: ${pool_root}"
  pool_schema=$(pool_field "${pool_root}" '.schema')
  [[ ${pool_schema} == fast-vms-prepared-pool-v1 ]] ||
    die "unsupported pool metadata: ${pool_root}/pool.json"
  pool_asset_root=$(pool_field "${pool_root}" '.asset_root')
  pool_asset_root=$(realpath "${pool_asset_root}")
  [[ ${pool_asset_root} == "${asset_root}" ]] ||
    die "pool does not use the supplied asset root: ${pool_root}"
done
container_arm=$(pool_field "${container_pool}" '.arm')
[[ ${container_arm} == container ]] ||
  die "container pool metadata has the wrong arm"
vm_arm=$(pool_field "${vm_pool}" '.arm')
[[ ${vm_arm} == vm-no-ksm ]] ||
  die "VM pool metadata has the wrong arm"

for path in \
  "${asset_root}/container-bundle/rootfs" \
  "${asset_root}/snix/castore" \
  "${asset_root}/snix/store" \
  "${asset_root}/vm-artifacts"; do
  [[ -e ${path} ]] || die "required shared runtime asset is absent: ${path}"
done

temporary_root=$(mktemp -d "${output%/*}/.storage-summary.XXXXXX")
cleanup() {
  rm -rf -- "${temporary_root}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

container_observations="${temporary_root}/container.jsonl"
vm_observations="${temporary_root}/vm.jsonl"
container_ids="${temporary_root}/container-ids"
vm_ids="${temporary_root}/vm-ids"
container_instances="${temporary_root}/container-instances"
vm_instances="${temporary_root}/vm-instances"
: >"${container_observations}"
: >"${vm_observations}"

jq -r --arg arm container '
  select(
    .schema == "fast-vms-benchmark-v1"
    and .record_type == "density_point"
    and .benchmark_arm == $arm
    and .within_envelope
    and .service_slo_met
    and .memory_stable
    and (.load_generator_failures == 0)
    and ((.client_saturated // false) | not)
  )
  | (.added_instance_ids // [.added_instance_id])[]
' "${density_raw}" |
  sort -u >"${container_ids}"
jq -Rr '
  try capture("r(?<ramp>[0-9]+)-i(?<index>[0-9]+)$") catch empty
  | "ramp-\(.ramp | tonumber)/instances/i-\(.index)"
' "${container_ids}" >"${container_instances}"
container_id_count=$(wc -l <"${container_ids}")
container_instance_count=$(wc -l <"${container_instances}")
[[ ${container_id_count} -eq ${container_instance_count} ]] ||
  die "a container density record has an unsupported instance ID"

while IFS= read -r relative_instance; do
  instance_root="${container_pool}/${relative_instance}"
  for path in \
    "${instance_root}/bundle/config.json" \
    "${instance_root}/data" \
    "${instance_root}/nix" \
    "${instance_root}/store-upper" \
    "${instance_root}/store-work"; do
    [[ -e ${path} ]] ||
      die "container private state is incomplete: ${instance_root}"
  done
  instance_allocated_bytes=$(measure_container_instance "${instance_root}")
  jq -cn \
    --arg instance "${instance_root}" \
    --argjson allocated_bytes "${instance_allocated_bytes}" \
    '{instance: $instance, allocated_bytes: $allocated_bytes}' \
    >>"${container_observations}"
done <"${container_instances}"

jq -r --arg arm vm-no-ksm '
  select(
    .schema == "fast-vms-benchmark-v1"
    and .record_type == "density_point"
    and .benchmark_arm == $arm
    and .within_envelope
    and .service_slo_met
    and .memory_stable
    and (.load_generator_failures == 0)
    and ((.client_saturated // false) | not)
  )
  | (.added_instance_ids // [.added_instance_id])[]
' "${density_raw}" |
  sort -u >"${vm_ids}"
jq -Rr '
  try capture("r(?<ramp>[0-9]+)-i(?<index>[0-9]+)$") catch empty
  | "ramp-\(.ramp | tonumber)/instances/i-\(.index)"
' "${vm_ids}" >"${vm_instances}"
vm_id_count=$(wc -l <"${vm_ids}")
vm_instance_count=$(wc -l <"${vm_instances}")
[[ ${vm_id_count} -eq ${vm_instance_count} ]] ||
  die "a VM density record has an unsupported instance ID"

while IFS= read -r relative_instance; do
  instance_root="${vm_pool}/${relative_instance}"
  [[ -f ${instance_root}/disk.qcow2 ]] ||
    die "VM private state is incomplete: ${instance_root}"
  instance_allocated_bytes=$(measure_vm_instance "${instance_root}")
  jq -cn \
    --arg instance "${instance_root}" \
    --argjson allocated_bytes "${instance_allocated_bytes}" \
    '{instance: $instance, allocated_bytes: $allocated_bytes}' \
    >>"${vm_observations}"
done <"${vm_instances}"

[[ -s ${container_observations} ]] ||
  die "container pool contains no measured instances"
[[ -s ${vm_observations} ]] || die "VM pool contains no measured instances"

container_fixed_bytes=$(allocated_bytes \
  "${asset_root}/container-bundle/rootfs" \
  "${asset_root}/snix/castore" \
  "${asset_root}/snix/store")
vm_fixed_bytes=$(du -B1 --dereference --summarize \
  "${asset_root}/vm-artifacts" | awk '{ print $1 }')
envelope_bytes=$((envelope_gib * 1024 * 1024 * 1024))

jq -n \
  --arg schema fast-vms-benchmark-storage-v1 \
  --arg source_density_records "${density_raw}" \
  --argjson envelope_bytes "${envelope_bytes}" \
  --argjson container_fixed_bytes "${container_fixed_bytes}" \
  --argjson vm_fixed_bytes "${vm_fixed_bytes}" \
  --slurpfile container_observations "${container_observations}" \
  --slurpfile vm_observations "${vm_observations}" \
  '
    def median:
      sort as $values
      | length as $count
      | if $count % 2 == 1 then
          $values[($count / 2 | floor)]
        else
          (($values[$count / 2 - 1] + $values[$count / 2]) / 2)
        end;
    def result($target; $arm; $fixed; $observations):
      ($observations | map(.allocated_bytes)) as $allocated
      | ($allocated | median) as $marginal
      | {
          target: $target,
          benchmark_arm: $arm,
          fixed_shared_bytes: $fixed,
          marginal_private_bytes_median: $marginal,
          marginal_private_bytes_min: ($allocated | min),
          marginal_private_bytes_max: ($allocated | max),
          observations: $observations,
          maximum_instances:
            (if $fixed >= $envelope_bytes then 0
             elif $marginal <= 0 then null
             else (($envelope_bytes - $fixed) / $marginal | floor)
             end)
        };
    {
      schema: $schema,
      source_density_records: $source_density_records,
      envelope_bytes: $envelope_bytes,
      method: {
        allocation: "filesystem allocated bytes reported by GNU du",
        population:
          "instances added at a healthy, settled density checkpoint",
        capacity:
          "floor((storage envelope - fixed shared bytes) / median private bytes)",
        container_fixed:
          "shared root filesystem plus Snix castore and path-info store",
        container_private:
          "OCI config plus private data, Nix state, store upper, and store work",
        vm_fixed:
          "raw base image, direct-boot kernel/initrd, and kernel parameters",
        vm_private: "private qcow2 overlay"
      },
      storage: [
        result(
          "gVisor shared store";
          "container";
          $container_fixed_bytes;
          $container_observations
        ),
        result(
          "NixOS VM";
          "vm-no-ksm";
          $vm_fixed_bytes;
          $vm_observations
        )
      ]
    }
  ' >"${output}"

echo "wrote allocated-storage summary to ${output}"
