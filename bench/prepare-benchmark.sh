set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  prepare-benchmark \
    (--pool-sizes FILE | --container-density N --vm-density N) \
    [--asset-root DIR] [--preparation-jobs N] WORK_ROOT

Use --pool-sizes with size-benchmark-pools output for a measured run.
Explicit counts are retained for diagnostics and deliberate reruns.
EOF
  exit 2
}

die() {
  echo "prepare-benchmark: $*" >&2
  exit 1
}

container_density=
vm_density=
pool_sizes=
asset_root=
work_root=
preparation_jobs=8
density_ramps=2
nginx_blocks=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container-density)
      [[ $# -ge 2 ]] || usage
      container_density=$2
      shift 2
      ;;
    --vm-density)
      [[ $# -ge 2 ]] || usage
      vm_density=$2
      shift 2
      ;;
    --pool-sizes)
      [[ $# -ge 2 ]] || usage
      pool_sizes=$2
      shift 2
      ;;
    --asset-root)
      [[ $# -ge 2 ]] || usage
      asset_root=$2
      shift 2
      ;;
    --preparation-jobs)
      [[ $# -ge 2 ]] || usage
      preparation_jobs=$2
      shift 2
      ;;
    -*)
      usage
      ;;
    *)
      [[ -z ${work_root} ]] || usage
      work_root=$1
      shift
      ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "must run as root"
if [[ -n ${pool_sizes} ]]; then
  [[ -z ${container_density} && -z ${vm_density} ]] || usage
  pool_sizes=$(realpath "${pool_sizes}")
  jq -e '.schema == "fast-vms-benchmark-pool-sizes-v1"' \
    "${pool_sizes}" >/dev/null ||
    die "invalid pool-size record: ${pool_sizes}"
  container_density=$(jq -r '.container_density' "${pool_sizes}")
  vm_density=$(jq -r '.vm_density' "${pool_sizes}")
else
  [[ -n ${container_density} && -n ${vm_density} ]] || usage
fi
[[ ${container_density} =~ ^[1-9][0-9]*$ &&
  ${vm_density} =~ ^[1-9][0-9]*$ &&
  ${preparation_jobs} =~ ^[1-9][0-9]*$ &&
  -n ${work_root} ]] || usage

work_root=$(realpath -m "${work_root}")
[[ ! -e ${work_root} ]] ||
  die "refusing to replace existing work root: ${work_root}"
mkdir -p \
  "${work_root}/manifests" \
  "${work_root}/network" \
  "${work_root}/pools"
preparation_complete=false

prepare_assets=@PREPARE_ASSETS@
make_network=@MAKE_NETWORK@
prepare_pool=@PREPARE_POOL@
make_manifest=@MAKE_MANIFEST@

cleanup() {
  if [[ ${preparation_complete} == false ]]; then
    echo "prepare-benchmark: partial work retained at ${work_root}" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -n ${asset_root} ]]; then
  asset_root=$(realpath "${asset_root}")
  [[ -r ${asset_root}/assets.json ]] ||
    die "asset root is incomplete: ${asset_root}"
else
  asset_root="${work_root}/assets"
  "${prepare_assets}" "${asset_root}"
fi
"${make_network}" \
  netns \
  "$((container_density + 1))" \
  "${work_root}/network/container.json"
"${make_network}" \
  tap \
  "$((vm_density + 1))" \
  "${work_root}/network/vm.json"

prepare_suite() {
  local arm=$1
  local suite=$2
  local ramps=$3
  local count=$4
  local network_spec=$5
  local pool="${work_root}/pools/${arm}-${suite}"
  local manifest="${work_root}/manifests/${arm}-${suite}.json"

  "${prepare_pool}" \
    --jobs "${preparation_jobs}" \
    "${arm}" \
    "${asset_root}" \
    "${network_spec}" \
    "${ramps}" \
    "${count}" \
    "${pool}"
  "${make_manifest}" "${suite}" "${pool}" "${manifest}"
}

for arm in container vm-no-ksm vm-ksm; do
  if [[ ${arm} == container ]]; then
    density_count=${container_density}
    network_spec="${work_root}/network/container.json"
  else
    density_count=${vm_density}
    network_spec="${work_root}/network/vm.json"
  fi
  prepare_suite "${arm}" launch-cold 30 1 "${network_spec}"
  prepare_suite "${arm}" launch-warm 30 1 "${network_spec}"
  prepare_suite \
    "${arm}" density "${density_ramps}" "${density_count}" "${network_spec}"
  prepare_suite "${arm}" nginx "${nginx_blocks}" 1 "${network_spec}"
done

jq -n \
  --arg schema fast-vms-prepared-benchmark-v1 \
  --arg asset_root "${asset_root}" \
  --arg pool_sizes "${pool_sizes}" \
  --argjson container_density "${container_density}" \
  --argjson vm_density "${vm_density}" \
  --argjson preparation_jobs "${preparation_jobs}" \
  --argjson density_ramps "${density_ramps}" \
  --argjson nginx_blocks "${nginx_blocks}" \
  '{
    schema: $schema,
    asset_root: $asset_root,
    pool_sizes_record: (if $pool_sizes == "" then null else $pool_sizes end),
    container_density_instances_per_ramp: $container_density,
    vm_density_instances_per_ramp: $vm_density,
    preparation_jobs: $preparation_jobs,
    launch_samples_per_condition: 30,
    density_ramps: $density_ramps,
    nginx_blocks: $nginx_blocks
  }' >"${work_root}/preparation.json"

preparation_complete=true
echo "prepared benchmark at ${work_root}"
