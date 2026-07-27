set -euo pipefail

usage() {
  echo "usage: manage-container-store mount|unmount INSTANCE_ROOT SNIX_MOUNT" >&2
  exit 2
}

die() {
  echo "manage-container-store: $*" >&2
  exit 1
}

[[ ${EUID} -eq 0 ]] || die "must run as root"
[[ $# -eq 3 ]] || usage

mode=$1
instance_root=$(realpath "$2")
snix_mount=$(realpath "$3")
merged="${instance_root}/store-merged"
upper="${instance_root}/store-upper"
work="${instance_root}/store-work"
mount_complete=false

[[ -d ${merged} && -d ${upper} && -d ${work} ]] ||
  die "container store directories are incomplete: ${instance_root}"

rollback_mount() {
  if [[ ${mode} == mount && ${mount_complete} == false ]] &&
    mountpoint -q "${merged}"; then
    umount "${merged}" || true
  fi
}

trap rollback_mount EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "${mode}" in
  mount)
    mountpoint -q "${snix_mount}" ||
      die "Snix lower is not mounted: ${snix_mount}"
    mountpoint -q "${merged}" &&
      die "container store is already mounted: ${merged}"
    mount -t overlay overlay \
      -o "lowerdir=${snix_mount},upperdir=${upper},workdir=${work},index=off" \
      "${merged}"
    mount_complete=true
    ;;
  unmount)
    mountpoint -q "${merged}" ||
      die "container store is not mounted: ${merged}"
    umount "${merged}"
    mount_complete=true
    ;;
  *)
    usage
    ;;
esac
