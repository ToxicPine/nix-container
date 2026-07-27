set -euo pipefail

usage() {
  echo "usage: run-snix-platform daemon|mount|nix-daemon|ready|unmount ROOT" >&2
  exit 2
}

die() {
  echo "run-snix-platform: $*" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage
mode=$1
root=$(realpath -m "$2")

snix_bin=${SNIX_BIN:-@SNIX_BIN@}
store_socket="${root}/run/store.sock"
lower_socket="${root}/lower/socket"
mount_path="${root}/mount"

[[ -x ${snix_bin} ]] || die "Snix executable is missing: ${snix_bin}"
[[ -d ${root}/castore/blobs &&
  -d ${root}/store &&
  -d ${root}/run &&
  -d ${root}/lower &&
  -d ${mount_path} ]] ||
  die "Snix root is not prepared: ${root}"

use_local_services() {
  export BLOB_SERVICE_ADDR="objectstore+file:${root}/castore/blobs"
  export DIRECTORY_SERVICE_ADDR="redb:${root}/castore/directories.redb"
  export PATH_INFO_SERVICE_ADDR="redb:${root}/store/pathinfo.redb"
}

use_grpc_services() {
  export BLOB_SERVICE_ADDR="grpc+unix:${store_socket}"
  export DIRECTORY_SERVICE_ADDR="grpc+unix:${store_socket}"
  export PATH_INFO_SERVICE_ADDR="grpc+unix:${store_socket}"
}

wait_for_path() {
  local path=$1
  local deadline=$((SECONDS + 30))
  while [[ ! -S ${path} && ${SECONDS} -lt ${deadline} ]]; do
    sleep 0.05
  done
  [[ -S ${path} ]] || die "timed out waiting for socket: ${path}"
}

case "${mode}" in
  daemon)
    use_local_services
    exec "${snix_bin}" store daemon \
      -l "${store_socket}" \
      --unix-listen-unlink
    ;;
  mount)
    wait_for_path "${store_socket}"
    mountpoint -q "${mount_path}" &&
      die "Snix mountpoint is already active: ${mount_path}"
    use_grpc_services
    exec "${snix_bin}" store mount \
      --allow-other \
      --threads 6 \
      "${mount_path}"
    ;;
  nix-daemon)
    wait_for_path "${store_socket}"
    use_grpc_services
    exec "${snix_bin}" nix-daemon \
      -l "${lower_socket}" \
      --unix-listen-unlink \
      --unix-listen-chmod everybody
    ;;
  ready)
    wait_for_path "${store_socket}"
    wait_for_path "${lower_socket}"
    deadline=$((SECONDS + 30))
    while ! mountpoint -q "${mount_path}" && ((SECONDS < deadline)); do
      sleep 0.05
    done
    mountpoint -q "${mount_path}" ||
      die "timed out waiting for Snix FUSE mount: ${mount_path}"
    ;;
  unmount)
    if mountpoint -q "${mount_path}"; then
      fusermount3 -u "${mount_path}"
    fi
    ;;
  *)
    usage
    ;;
esac
