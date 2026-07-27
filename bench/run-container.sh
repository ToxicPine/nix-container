set -euo pipefail

usage() {
  echo "usage: run-container BUNDLE_DIR CONTAINER_ID" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage

bundle=$(realpath "$1")
container_id=$2
config="${bundle}/config.json"

[[ -r "${config}" && -d "${bundle}/rootfs" ]] || {
  echo "run-container: bundle must contain config.json and rootfs/" >&2
  exit 1
}
[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || {
  echo "run-container: runsc --platform=kvm requires read/write access to /dev/kvm" >&2
  exit 1
}

store_source=$(jq -er '
  .mounts[]
  | select(.destination == "/nix/store")
  | select(.type == "bind")
  | select(.options | index("rw"))
  | .source
' "${config}") || {
  echo "run-container: config.json needs a writable bind mount at /nix/store" >&2
  exit 1
}

lower_source=$(jq -er '
  .mounts[]
  | select(.destination == "/lower-store")
  | select(.type == "bind")
  | select(.options | index("ro"))
  | .source
' "${config}") || {
  echo "run-container: config.json needs a read-only bind mount at /lower-store" >&2
  exit 1
}

nix_source=$(jq -er '
  .mounts[]
  | select(.destination == "/nix")
  | select(.type == "bind")
  | .source
' "${config}") || {
  echo "run-container: config.json needs an instance-private bind mount at /nix" >&2
  exit 1
}

store_fs_type=$(findmnt -n -o FSTYPE --target "${store_source}") || {
  echo "run-container: unable to inspect /nix/store source: ${store_source}" >&2
  exit 1
}
[[ ${store_fs_type} == "overlay" ]] || {
  echo "run-container: /nix/store source is not a prepared OverlayFS mount: ${store_source}" >&2
  exit 1
}
[[ -S "${lower_source}/socket" ]] || {
  echo "run-container: lower-store daemon socket is missing: ${lower_source}/socket" >&2
  exit 1
}
[[ -d "${nix_source}" ]] || {
  echo "run-container: private /nix source is missing: ${nix_source}" >&2
  exit 1
}

exec runsc \
  --platform=kvm \
  --directfs=true \
  --overlay2=root:self \
  --file-access-mounts=exclusive \
  --network=sandbox \
  --host-uds=open \
  --ignore-cgroups=true \
  run \
  --bundle "${bundle}" \
  "${container_id}"
