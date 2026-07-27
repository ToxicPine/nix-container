set -euo pipefail

usage() {
  echo "usage: evict-private-cache PATH..." >&2
  exit 2
}

[[ $# -gt 0 ]] || usage

declare -a paths=()
for path in "$@"; do
  path=$(realpath "${path}")
  [[ -e ${path} ]] || {
    echo "evict-private-cache: path does not exist: ${path}" >&2
    exit 1
  }
  paths+=("${path}")
done

sync -f "${paths[@]}"
vmtouch -e -q "${paths[@]}"
