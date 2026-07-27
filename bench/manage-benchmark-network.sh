set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  manage-benchmark-network create|remove SPEC.json
  manage-benchmark-network create-bridge|remove-bridge SPEC.json
  manage-benchmark-network create-endpoint|remove-endpoint SPEC.json INDEX
EOF
  exit 2
}

die() {
  echo "manage-benchmark-network: $*" >&2
  exit 1
}

[[ ${EUID} -eq 0 ]] || die "must run as root"
[[ $# -ge 2 && $# -le 3 ]] || usage

mode=$1
spec=$(realpath "$2")
endpoint_index=${3:-}
[[ -r ${spec} ]] || die "network spec is not readable: ${spec}"

jq -e '
  .schema == "fast-vms-network-v1"
  and (.bridge.name | type == "string" and length > 0 and length <= 15)
  and (.bridge.address | type == "string" and contains("/"))
  and (.endpoints | type == "array" and length > 0)
  and (all(.endpoints[];
    (.kind == "tap" or .kind == "netns")
    and (.host_interface | type == "string" and length > 0 and length <= 15)
    and (.address | type == "string" and contains("/"))
    and (if .kind == "netns"
         then (.namespace | type == "string" and length > 0)
         else true
         end)))
  and ([.endpoints[].host_interface] | length == (unique | length))
  and ([.endpoints[].address] | length == (unique | length))
  and ([.endpoints[] | select(.kind == "netns") | .namespace]
       | length == (unique | length))
' "${spec}" >/dev/null || die "invalid fast-vms-network-v1 spec"

case "${mode}" in
  create|remove|create-bridge|remove-bridge)
    [[ $# -eq 2 ]] || usage
    ;;
  create-endpoint|remove-endpoint)
    [[ $# -eq 3 && ${endpoint_index} =~ ^[0-9]+$ ]] || usage
    ;;
  *)
    usage
    ;;
esac

bridge=$(jq -r '.bridge.name' "${spec}")
bridge_address=$(jq -r '.bridge.address' "${spec}")
endpoint_count=$(jq '.endpoints | length' "${spec}")
work_dir=$(mktemp -d)
rollback_action=none
rollback_index=

read_endpoint() {
  local index=$1
  jq -ce --argjson index "${index}" \
    '.endpoints[$index] // empty' \
    "${spec}" >"${work_dir}/endpoint" ||
    die "endpoint index is out of range: ${index}"
  endpoint_json=$(<"${work_dir}/endpoint")
  endpoint_kind=$(jq -r '.kind' <<<"${endpoint_json}")
  endpoint_interface=$(jq -r '.host_interface' <<<"${endpoint_json}")
  endpoint_address=$(jq -r '.address' <<<"${endpoint_json}")
  endpoint_namespace=$(jq -r '.namespace // empty' <<<"${endpoint_json}")
}

bridge_create() {
  ip link show dev "${bridge}" >/dev/null 2>&1 &&
    die "bridge already exists: ${bridge}"
  ip link add name "${bridge}" type bridge \
    stp_state 0 \
    mcast_snooping 0
  ip address add "${bridge_address}" dev "${bridge}"
  ip link set dev "${bridge}" mtu 1500 txqueuelen 1000 up
}

bridge_remove() {
  if ip link show dev "${bridge}" >/dev/null 2>&1; then
    ip link delete dev "${bridge}"
  fi
}

endpoint_create() {
  local index=$1
  read_endpoint "${index}"
  ip link show dev "${bridge}" >/dev/null 2>&1 ||
    die "benchmark bridge is missing: ${bridge}"
  ip link show dev "${endpoint_interface}" >/dev/null 2>&1 &&
    die "interface already exists: ${endpoint_interface}"

  if [[ ${endpoint_kind} == tap ]]; then
    ip tuntap add dev "${endpoint_interface}" mode tap
    ip link set dev "${endpoint_interface}" \
      master "${bridge}" \
      mtu 1500 \
      txqueuelen 1000 \
      up
    return
  fi

  if [[ -e /run/netns/${endpoint_namespace} ]]; then
    die "network namespace already exists: ${endpoint_namespace}"
  fi
  ip netns add "${endpoint_namespace}"
  ip link add name "${endpoint_interface}" \
    type veth \
    peer name eth0 \
    netns "${endpoint_namespace}"
  ip link set dev "${endpoint_interface}" \
    master "${bridge}" \
    mtu 1500 \
    txqueuelen 1000 \
    up
  ip -n "${endpoint_namespace}" link set dev lo up
  ip -n "${endpoint_namespace}" link set dev eth0 \
    mtu 1500 \
    txqueuelen 1000 \
    up
  ip -n "${endpoint_namespace}" address add "${endpoint_address}" dev eth0
  ip -n "${endpoint_namespace}" route add default via "${bridge_address%/*}"
}

endpoint_remove() {
  local index=$1
  read_endpoint "${index}"
  if ip link show dev "${endpoint_interface}" >/dev/null 2>&1; then
    ip link delete dev "${endpoint_interface}"
  fi
  if [[ ${endpoint_kind} == netns &&
    -e /run/netns/${endpoint_namespace} ]]; then
    ip netns delete "${endpoint_namespace}"
  fi
}

network_remove() {
  local index
  for ((index = endpoint_count - 1; index >= 0; index--)); do
    endpoint_remove "${index}"
  done
  bridge_remove
}

cleanup() {
  case "${rollback_action}" in
    bridge)
      bridge_remove
      ;;
    endpoint)
      endpoint_remove "${rollback_index}"
      ;;
    network)
      network_remove
      ;;
    none) ;;
    *)
      die "invalid rollback action: ${rollback_action}"
      ;;
  esac
  rm -rf -- "${work_dir}"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "${mode}" in
  create)
    rollback_action=network
    bridge_create
    for ((endpoint_index = 0; endpoint_index < endpoint_count; endpoint_index++)); do
      endpoint_create "${endpoint_index}"
    done
    rollback_action=none
    echo "created benchmark network ${bridge} with ${endpoint_count} endpoints"
    ;;
  remove)
    network_remove
    echo "removed benchmark network ${bridge}"
    ;;
  create-bridge)
    rollback_action=bridge
    bridge_create
    rollback_action=none
    echo "created benchmark bridge ${bridge}"
    ;;
  remove-bridge)
    bridge_remove
    echo "removed benchmark bridge ${bridge}"
    ;;
  create-endpoint)
    rollback_index=${endpoint_index}
    rollback_action=endpoint
    endpoint_create "${endpoint_index}"
    rollback_action=none
    echo "created endpoint ${endpoint_index} on ${bridge}"
    ;;
  remove-endpoint)
    endpoint_remove "${endpoint_index}"
    echo "removed endpoint ${endpoint_index} from ${bridge}"
    ;;
  *)
    die "unreachable mode: ${mode}"
    ;;
esac
