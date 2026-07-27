set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  make-benchmark-manifest launch-cold|launch-warm|density|nginx \
    POOL_ROOT OUTPUT.json
EOF
  exit 2
}

die() {
  echo "make-benchmark-manifest: $*" >&2
  exit 1
}

[[ $# -eq 3 ]] || usage
suite=$1
pool_root=$(realpath "$2")
output=$(realpath -m "$3")

case "${suite}" in
  launch-cold|launch-warm|density|nginx) ;;
  *) usage ;;
esac
[[ -r ${pool_root}/pool.json ]] ||
  die "pool metadata is missing: ${pool_root}/pool.json"
[[ -d ${output%/*} && -w ${output%/*} ]] ||
  die "output parent must be an existing writable directory"
[[ ! -e ${output} ]] || die "refusing to replace output: ${output}"

arm=$(jq -r '.arm' "${pool_root}/pool.json")
asset_root=$(jq -r '.asset_root' "${pool_root}/pool.json")
network_spec=$(jq -r '.network_spec' "${pool_root}/pool.json")
ramps=$(jq -r '.ramps' "${pool_root}/pool.json")
instances_per_ramp=$(jq -r '.instances_per_ramp' "${pool_root}/pool.json")
[[ -r ${asset_root}/assets.json && -r ${network_spec} ]] ||
  die "pool metadata refers to missing assets"

case "${arm}" in
  container|vm-no-ksm|vm-ksm) ;;
  *) die "pool metadata has an invalid arm: ${arm}" ;;
esac
if [[ ${suite} == density ]]; then
  ((ramps >= 1)) || die "density needs at least one independent ramp"
else
  ((instances_per_ramp == 1)) ||
    die "${suite} pools must contain exactly one measured instance per ramp"
fi

run_vm=@RUN_VM@
run_container=@RUN_CONTAINER@
run_snix=@RUN_SNIX@
runsc=@RUNSC@
manage_network=@MANAGE_NETWORK@
manage_store=@MANAGE_STORE@
warm_instance=@WARM_INSTANCE@
evict_working_set=@EVICT_WORKING_SET@
evict_private_cache=@EVICT_PRIVATE_CACHE@

work_dir=$(mktemp -d)
cleanup() {
  rm -rf -- "${work_dir}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ip_from_endpoint() {
  local index=$1
  jq -r --argjson index "${index}" \
    '.endpoints[$index].address' \
    "${network_spec}" >"${work_dir}/address"
  endpoint_address=$(<"${work_dir}/address")
  endpoint_address=${endpoint_address%/*}
}

interface_from_endpoint() {
  local index=$1
  jq -r --argjson index "${index}" \
    '.endpoints[$index].host_interface' \
    "${network_spec}" >"${work_dir}/interface"
  endpoint_interface=$(<"${work_dir}/interface")
}

mac_for_slot() {
  local slot=$1
  printf '02:fc:00:%02x:%02x:%02x\n' \
    "$(((slot >> 16) & 255))" \
    "$(((slot >> 8) & 255))" \
    "$((slot & 255))"
}

make_vm_launch() {
  local instance=$1
  local interface=$2
  local address=$3
  local slot=$4
  local destination=$5
  local mac
  local -a command=()
  mac=$(mac_for_slot "${slot}")
  command=(
    "${run_vm}"
    --tap "${interface}"
    --guest-ip "${address}/16"
    --mac "${mac}"
  )
  [[ ${arm} == vm-ksm ]] && command+=(--ksm)
  command+=("${instance}")
  printf '%s\n' "${command[@]}" |
    jq -Rsc 'split("\n") | map(select(length > 0))' >"${destination}"
}

make_container_control() {
  local instance=$1
  local endpoint=$2
  local id=$3
  local destination=$4
  jq -n \
    --arg manage_network "${manage_network}" \
    --arg network_spec "${network_spec}" \
    --arg endpoint "${endpoint}" \
    --arg manage_store "${manage_store}" \
    --arg instance "${instance}" \
    --arg snix_mount "${asset_root}/snix/mount" \
    --arg runsc "${runsc}" \
    --arg id "${id}" \
    --arg evict_private_cache "${evict_private_cache}" \
    '{
      prepare: [
        [$manage_network, "create-endpoint", $network_spec, $endpoint],
        [$manage_store, "mount", $instance, $snix_mount]
      ],
      stop: [[$runsc, "delete", "--force", $id]],
      cleanup: [
        [$manage_store, "unmount", $instance, $snix_mount],
        [$manage_network, "remove-endpoint", $network_spec, $endpoint],
        [
          $evict_private_cache,
          "\($instance)/data",
          "\($instance)/nix",
          "\($instance)/store-upper",
          "\($instance)/store-work"
        ]
      ]
    }' >"${destination}"
}

make_vm_control() {
  local instance=$1
  local endpoint=$2
  local destination=$3
  jq -n \
    --arg manage_network "${manage_network}" \
    --arg network_spec "${network_spec}" \
    --arg endpoint "${endpoint}" \
    --arg evict_private_cache "${evict_private_cache}" \
    --arg disk "${instance}/disk.qcow2" \
    '{
      prepare: [
        [$manage_network, "create-endpoint", $network_spec, $endpoint]
      ],
      stop: [],
      cleanup: [
        [$manage_network, "remove-endpoint", $network_spec, $endpoint],
        [$evict_private_cache, $disk]
      ]
    }' >"${destination}"
}

case "${arm}" in
  container)
    target=container
    residency_list="${asset_root}/container-residency-files"
    ;;
  vm-no-ksm|vm-ksm)
    target=vm
    residency_list="${asset_root}/vm-residency-files"
    ;;
  *)
    die "unreachable arm: ${arm}"
    ;;
esac

: >"${work_dir}/instances.jsonl"
for ((ramp = 1; ramp <= ramps; ramp++)); do
  ramp_root="${pool_root}/ramp-${ramp}"
  [[ -d ${ramp_root}/warm && -d ${ramp_root}/instances ]] ||
    die "pool ramp is incomplete: ${ramp_root}"
  mkdir -p "${ramp_root}/control"

  ip_from_endpoint 0
  interface_from_endpoint 0
  printf -v warm_id '%s-%s-warm-r%d' "${arm}" "${suite}" "${ramp}"
  if [[ ${arm} == container ]]; then
    make_container_control \
      "${ramp_root}/warm" \
      0 \
      "${warm_id}" \
      "${ramp_root}/control/warm.json"
  else
    make_vm_control \
      "${ramp_root}/warm" \
      0 \
      "${ramp_root}/control/warm.json"
  fi
  jq '.stop' "${ramp_root}/control/warm.json" \
    >"${ramp_root}/control/warm-stop.json"
  jq '.prepare' "${ramp_root}/control/warm.json" \
    >"${ramp_root}/control/warm-prepare.json"
  jq '.cleanup' "${ramp_root}/control/warm.json" \
    >"${ramp_root}/control/warm-cleanup.json"

  for ((index = 1; index <= instances_per_ramp; index++)); do
    printf -v instance '%s/instances/i-%04d' "${ramp_root}" "${index}"
    [[ -d ${instance} ]] || die "prepared instance is missing: ${instance}"
    ip_from_endpoint "${index}"
    interface_from_endpoint "${index}"
    printf -v id '%s-%s-r%02d-i%04d' \
      "${arm}" "${suite}" "${ramp}" "${index}"
    if [[ ${arm} == container ]]; then
      make_container_control \
        "${instance}" \
        "${index}" \
        "${id}" \
        "${work_dir}/control.json"
      jq -n \
        --arg launcher "${run_container}" \
        --arg bundle "${instance}/bundle" \
        --arg id "${id}" \
        '[$launcher, $bundle, $id]' >"${work_dir}/launch.json"
    else
      make_vm_control \
        "${instance}" \
        "${index}" \
        "${work_dir}/control.json"
      make_vm_launch \
        "${instance}" \
        "${endpoint_interface}" \
        "${endpoint_address}" \
        "${index}" \
        "${work_dir}/launch.json"
    fi
    jq -cn \
      --arg id "${id}" \
      --arg url "http://${endpoint_address}:8080/" \
      --arg interface "${endpoint_interface}" \
      --argjson ramp "${ramp}" \
      --slurpfile control "${work_dir}/control.json" \
      --slurpfile launch "${work_dir}/launch.json" \
      '{
        id: $id,
        ramp: $ramp,
        url: $url,
        network_interface: $interface,
        prepare: $control[0].prepare,
        launch: $launch[0],
        stop: $control[0].stop,
        cleanup: $control[0].cleanup
      }' >>"${work_dir}/instances.jsonl"
  done
done

jq -s . "${work_dir}/instances.jsonl" >"${work_dir}/instances.json"
jq -Rsc \
  'split("\n") | map(select(length > 0))' \
  "${residency_list}" >"${work_dir}/residency.json"

warm_url=$(jq -r '.endpoints[0].address' "${network_spec}")
warm_url="http://${warm_url%/*}:8080/"
warm_command=$(jq -cn \
  --arg warm_instance "${warm_instance}" \
  --arg target_cgroup /sys/fs/cgroup/fast-vms/target \
  --arg warm_url "${warm_url}" \
  --arg residency_list "${residency_list}" \
  --arg pool "${pool_root}" \
  '[
    $warm_instance,
    $target_cgroup,
    $warm_url,
    ($residency_list),
    ($pool + "/ramp-@RAMP@/control/warm-stop.json"),
    ($pool + "/ramp-@RAMP@/control/warm-prepare.json"),
    ($pool + "/ramp-@RAMP@/control/warm-cleanup.json"),
    "--"
  ]')
ip_from_endpoint 0
interface_from_endpoint 0
if [[ ${arm} == container ]]; then
  warm_launch=$(jq -cn \
    --arg launcher "${run_container}" \
    --arg bundle "${pool_root}/ramp-@RAMP@/warm/bundle" \
    --arg id "${arm}-${suite}-warm-r@RAMP@" \
    '[$launcher, $bundle, $id]')
else
  make_vm_launch \
    "${pool_root}/ramp-@RAMP@/warm" \
    "${endpoint_interface}" \
    "${endpoint_address}" \
    0 \
    "${work_dir}/warm-launch-template.json"
  warm_launch=$(<"${work_dir}/warm-launch-template.json")
fi
warm_command=$(jq -cn \
  --argjson prefix "${warm_command}" \
  --argjson launch "${warm_launch}" \
  '$prefix + $launch')

if [[ ${arm} == container ]]; then
  platform_launch=$(jq -cn \
    --arg run_snix "${run_snix}" \
    --arg snix_root "${asset_root}/snix" \
    '[
      [$run_snix, "daemon", $snix_root],
      [$run_snix, "mount", $snix_root],
      [$run_snix, "nix-daemon", $snix_root]
    ]')
  platform_ready=$(jq -cn \
    --arg manage_network "${manage_network}" \
    --arg network_spec "${network_spec}" \
    --arg run_snix "${run_snix}" \
    --arg snix_root "${asset_root}/snix" \
    '[
      [$manage_network, "create-bridge", $network_spec],
      [$run_snix, "ready", $snix_root]
    ]')
else
  platform_launch='[]'
  platform_ready=$(jq -cn \
    --arg manage_network "${manage_network}" \
    --arg network_spec "${network_spec}" \
    '[[$manage_network, "create-bridge", $network_spec]]')
fi
if [[ ${arm} == container ]]; then
  platform_stop=$(jq -cn \
    --arg run_snix "${run_snix}" \
    --arg snix_root "${asset_root}/snix" \
    --arg manage_network "${manage_network}" \
    --arg network_spec "${network_spec}" \
    '[
      [$run_snix, "unmount", $snix_root],
      [$manage_network, "remove-bridge", $network_spec]
    ]')
else
  platform_stop=$(jq -cn \
    --arg manage_network "${manage_network}" \
    --arg network_spec "${network_spec}" \
    '[[$manage_network, "remove-bridge", $network_spec]]')
fi

cache_condition=cross-instance-warm
before_suite=$(jq -cn --argjson warm "${warm_command}" '[$warm]')
before_sample='[]'
before_baseline='[]'
if [[ ${suite} == launch-cold ]]; then
  cache_condition=host-cold
  before_suite='[]'
  before_sample=$(jq -cn \
    --arg evict "${evict_working_set}" \
    --arg residency "${residency_list}" \
    '[[$evict, $residency]]')
elif [[ ${suite} == density ]]; then
  before_baseline=$(jq -cn \
    --arg evict "${evict_working_set}" \
    --arg residency "${residency_list}" \
    '[[$evict, $residency]]')
fi

jq -n \
  --arg schema fast-vms-benchmark-v1 \
  --arg target "${target}" \
  --arg cache_condition "${cache_condition}" \
  --argjson platform_launch "${platform_launch}" \
  --argjson platform_ready "${platform_ready}" \
  --argjson platform_stop "${platform_stop}" \
  --argjson before_suite "${before_suite}" \
  --argjson before_sample "${before_sample}" \
  --argjson before_baseline "${before_baseline}" \
  --slurpfile residency "${work_dir}/residency.json" \
  --slurpfile instances "${work_dir}/instances.json" \
  '{
    schema: $schema,
    target: $target,
    cache_condition: $cache_condition,
    private_cache_eviction: true,
    expected: {
      bytes: 25,
      sha256: "edf03332c6ca9e23cc6b21849fd76e032c59634312e1c787290816f8e8a5fa00"
    },
    residency_files: $residency[0],
    platform: {
      launch: $platform_launch,
      ready: $platform_ready,
      stop: $platform_stop
    },
    resources: {
      target_cgroup: "/sys/fs/cgroup/fast-vms/target",
      client_cgroup: "/sys/fs/cgroup/fast-vms/client",
      target_cpus: "4-9",
      client_cpus: "3",
      housekeeping_cpus: "0-2"
    },
    host_requirements: {
      kvm: true,
      swap_off: true,
      thp_off: true,
      ksm_off: true,
      cgroups: true,
      partition_roots: true,
      smt_off: true,
      homogeneous_target_cpus: true,
      fixed_frequency: true,
      housekeeping_isolation: true,
      direct_network: true
    },
    hooks: {
      before_baseline: $before_baseline,
      before_suite: $before_suite,
      before_sample: $before_sample,
      after_suite: []
    },
    instances: $instances[0]
  }' >"${output}"

echo "wrote ${suite} manifest for ${arm}: ${output}"
