set -euo pipefail

usage() {
  echo "usage: prepare-vm [--base ARTIFACTS] INSTANCE_DIR..." >&2
  exit 2
}

base="@VM_ARTIFACTS@"

if [[ ${1-} == "--base" ]]; then
  [[ $# -ge 3 ]] || usage
  base=$2
  shift 2
fi

[[ $# -gt 0 ]] || usage
[[ -r "${base}/disk.raw" && -r "${base}/kernel" && -r "${base}/initrd" ]] || {
  echo "prepare-vm: invalid VM artifact directory: ${base}" >&2
  exit 1
}

base=$(realpath "${base}")
base_disk=$(realpath "${base}/disk.raw")

staging=
cleanup_staging() {
  if [[ -n ${staging:-} && -d ${staging} ]]; then
    rm -rf -- "${staging}"
  fi
}

interrupt_staging() {
  cleanup_staging
  exit 130
}

terminate_staging() {
  cleanup_staging
  exit 143
}

trap cleanup_staging EXIT
trap interrupt_staging INT
trap terminate_staging TERM

for requested_dir in "$@"; do
  if [[ -e "${requested_dir}" ]]; then
    echo "prepare-vm: refusing to replace existing path: ${requested_dir}" >&2
    exit 1
  fi

  parent=$(dirname "${requested_dir}")
  name=$(basename "${requested_dir}")
  mkdir -p "${parent}"
  parent=$(realpath "${parent}")
  instance="${parent}/${name}"
  staging=$(mktemp -d "${parent}/.prepare-${name}.XXXXXX")

  qemu-img create \
    -q \
    -f qcow2 \
    -F raw \
    -b "${base_disk}" \
    -o "compat=1.1,lazy_refcounts=on,cluster_size=64k,extended_l2=on,preallocation=metadata" \
    "${staging}/disk.qcow2"
  qemu-img check -q -f qcow2 "${staging}/disk.qcow2"

  ln -s "${base}" "${staging}/base"
  printf '%s\n' "${base_disk}" > "${staging}/base-disk"
  printf '%s\n' "prepared-v1" > "${staging}/format"
  mv "${staging}" "${instance}"
  staging=

  echo "prepared ${instance}"
done
