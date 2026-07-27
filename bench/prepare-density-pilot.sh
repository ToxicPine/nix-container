set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: prepare-density-pilot [--instances N] PILOT_ROOT

Prepare one independent density ramp for each benchmark arm. The default is
16 instances per arm. Run it through run-core-benchmark with
--suite density --density-blocks 1, then feed that result to
size-benchmark-pools.
EOF
  exit 2
}

die() {
  echo "prepare-density-pilot: $*" >&2
  exit 1
}

instances=16
pilot_root=

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instances)
      [[ $# -ge 2 ]] || usage
      instances=$2
      shift 2
      ;;
    -*)
      usage
      ;;
    *)
      [[ -z ${pilot_root} ]] || usage
      pilot_root=$1
      shift
      ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "must run as root"
[[ ${instances} =~ ^[1-9][0-9]*$ && -n ${pilot_root} ]] ||
  die "--instances must be an integer of at least 3"
((instances >= 3)) ||
  die "--instances must be an integer of at least 3"

pilot_root=$(realpath -m "${pilot_root}")
[[ ! -e ${pilot_root} ]] ||
  die "refusing to replace existing pilot root: ${pilot_root}"
mkdir -p \
  "${pilot_root}/manifests" \
  "${pilot_root}/network" \
  "${pilot_root}/pools"
preparation_complete=false

prepare_assets=@PREPARE_ASSETS@
make_network=@MAKE_NETWORK@
prepare_pool=@PREPARE_POOL@
make_manifest=@MAKE_MANIFEST@

cleanup() {
  if [[ ${preparation_complete} == false ]]; then
    echo "prepare-density-pilot: partial work retained at ${pilot_root}" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"${prepare_assets}" "${pilot_root}/assets"
"${make_network}" \
  netns \
  "$((instances + 1))" \
  "${pilot_root}/network/container.json"
"${make_network}" \
  tap \
  "$((instances + 1))" \
  "${pilot_root}/network/vm.json"

for arm in container vm-no-ksm vm-ksm; do
  if [[ ${arm} == container ]]; then
    network_spec="${pilot_root}/network/container.json"
  else
    network_spec="${pilot_root}/network/vm.json"
  fi
  pool="${pilot_root}/pools/${arm}-density"
  "${prepare_pool}" \
    "${arm}" \
    "${pilot_root}/assets" \
    "${network_spec}" \
    1 \
    "${instances}" \
    "${pool}"
  "${make_manifest}" \
    density \
    "${pool}" \
    "${pilot_root}/manifests/${arm}-density.json"
done

jq -n \
  --arg schema fast-vms-prepared-density-pilot-v1 \
  --argjson instances_per_arm "${instances}" \
  '{
    schema: $schema,
    density_ramps: 1,
    instances_per_arm: $instances_per_arm
  }' >"${pilot_root}/preparation.json"

preparation_complete=true
echo "prepared density pilot at ${pilot_root}"
