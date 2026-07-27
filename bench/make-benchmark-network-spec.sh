set -euo pipefail

usage() {
  echo "usage: make-benchmark-network-spec netns|tap ENDPOINT_COUNT OUTPUT.json" >&2
  exit 2
}

die() {
  echo "make-benchmark-network-spec: $*" >&2
  exit 1
}

[[ $# -eq 3 ]] || usage
kind=$1
endpoint_count=$2
output=$(realpath -m "$3")

[[ ${kind} == netns || ${kind} == tap ]] || usage
[[ ${endpoint_count} =~ ^[1-9][0-9]*$ ]] ||
  die "endpoint count must be a positive integer"
[[ -d ${output%/*} && -w ${output%/*} ]] ||
  die "output parent must be an existing writable directory"
[[ ! -e ${output} ]] || die "refusing to replace output: ${output}"

work_dir=$(mktemp -d)
cleanup() {
  rm -rf -- "${work_dir}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ip_for_slot() {
  local slot=$1
  local host=$((slot + 10))
  printf '198.18.%d.%d\n' "$((host / 256))" "$((host % 256))"
}

for ((index = 0; index < endpoint_count; index++)); do
  address=$(ip_for_slot "${index}")
  if [[ ${kind} == netns ]]; then
    host_interface=$(printf 'fvc%04d' "${index}")
    namespace=$(printf 'fvcn%04d' "${index}")
    jq -cn \
      --arg host_interface "${host_interface}" \
      --arg namespace "${namespace}" \
      --arg address "${address}/16" \
      '{
        kind: "netns",
        host_interface: $host_interface,
        namespace: $namespace,
        address: $address
      }' >>"${work_dir}/endpoints"
  else
    host_interface=$(printf 'fvt%04d' "${index}")
    jq -cn \
      --arg host_interface "${host_interface}" \
      --arg address "${address}/16" \
      '{
        kind: "tap",
        host_interface: $host_interface,
        address: $address
      }' >>"${work_dir}/endpoints"
  fi
done

jq -s '{
  schema: "fast-vms-network-v1",
  bridge: {
    name: "fvbenchbr",
    address: "198.18.0.1/16"
  },
  endpoints: .
}' "${work_dir}/endpoints" >"${output}"
