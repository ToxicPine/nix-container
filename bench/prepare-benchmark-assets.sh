set -euo pipefail

usage() {
  echo "usage: prepare-benchmark-assets ASSET_ROOT" >&2
  exit 2
}

die() {
  echo "prepare-benchmark-assets: $*" >&2
  exit 1
}

[[ ${EUID} -eq 0 ]] || die "must run as root for ownership-preserving OCI unpack"
[[ $# -eq 1 ]] || usage

requested_root=$(realpath -m "$1")
[[ ! -e ${requested_root} ]] ||
  die "refusing to replace existing asset root: ${requested_root}"

parent=$(dirname "${requested_root}")
name=$(basename "${requested_root}")
mkdir -p "${parent}"
parent=$(realpath "${parent}")
asset_root="${parent}/${name}"
staging=$(mktemp -d "${parent}/.prepare-${name}.XXXXXX")
preparation_complete=false

container_copy=@CONTAINER_COPY@
snix_bin=@SNIX_BIN@
vm_artifacts=@VM_ARTIFACTS@

cleanup() {
  if [[ ${preparation_complete} == false && -d ${staging} ]]; then
    rm -rf -- "${staging}"
  fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p \
  "${staging}/container-oci" \
  "${staging}/snix/castore/blobs" \
  "${staging}/snix/store" \
  "${staging}/snix/run" \
  "${staging}/snix/lower" \
  "${staging}/snix/mount"

"${container_copy}/bin/copy-to" \
  "oci:${staging}/container-oci:latest"
umoci unpack \
  --image "${staging}/container-oci:latest" \
  "${staging}/container-bundle"

store_path_list="${staging}/container-bundle/rootfs/nix-base/var/nix/store-paths"
[[ -s ${store_path_list} ]] ||
  die "container image does not contain its runtime store-path list"
sort -u "${store_path_list}" >"${staging}/store-paths"
mapfile -t store_paths <"${staging}/store-paths"
for store_path in "${store_paths[@]}"; do
  [[ ${store_path} == /nix/store/* && -e ${store_path} ]] ||
    die "container runtime path is absent from the host store: ${store_path}"
done

nix path-info \
  --json \
  --closure-size \
  "${store_paths[@]}" |
  jq '
    [
      to_entries[]
      | .value + { path: .key }
    ]
  ' >"${staging}/store-path-info.json"

export BLOB_SERVICE_ADDR="objectstore+file:${staging}/snix/castore/blobs"
export DIRECTORY_SERVICE_ADDR="redb:${staging}/snix/castore/directories.redb"
export PATH_INFO_SERVICE_ADDR="redb:${staging}/snix/store/pathinfo.redb"
"${snix_bin}" store copy "${staging}/store-path-info.json"

find "${staging}/snix/castore/blobs" -type f -print |
  sed "s#^${staging}#${asset_root}#" |
  sort >"${staging}/container-residency-files"
[[ -s ${staging}/container-residency-files ]] ||
  die "Snix population produced no blob files"

ln -s "${vm_artifacts}" "${staging}/vm-artifacts"
realpath "${vm_artifacts}/disk.raw" >"${staging}/vm-residency-files"

container_manifest_digest=$(jq -r \
  '.manifests[0].digest' \
  "${staging}/container-oci/index.json")
snix_revision=$(jq -r '.pins.snix.revision' @NPINS_SOURCES@)
vm_artifacts_path=$(realpath "${vm_artifacts}")
jq -n \
  --arg schema fast-vms-assets-v1 \
  --arg container_manifest_digest "${container_manifest_digest}" \
  --arg snix_revision "${snix_revision}" \
  --arg snix_executable "${snix_bin}" \
  --arg vm_artifacts "${vm_artifacts_path}" \
  --argjson container_store_paths "${#store_paths[@]}" \
  '{
    schema: $schema,
    container_manifest_digest: $container_manifest_digest,
    container_store_paths: $container_store_paths,
    snix_revision: $snix_revision,
    snix_executable: $snix_executable,
    vm_artifacts: $vm_artifacts
  }' >"${staging}/assets.json"

mv "${staging}" "${asset_root}"
staging=
preparation_complete=true
echo "prepared immutable benchmark assets at ${asset_root}"
