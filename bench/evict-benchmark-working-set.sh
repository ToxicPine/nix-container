set -euo pipefail

usage() {
  echo "usage: evict-benchmark-working-set RESIDENCY_LIST" >&2
  exit 2
}

die() {
  echo "evict-benchmark-working-set: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
[[ ${EUID} -eq 0 ]] ||
  die "host-cold cache eviction must run as root"
residency_list=$(realpath "$1")
[[ -s ${residency_list} ]] ||
  die "residency list is empty: ${residency_list}"

mapfile -t files <"${residency_list}"
for file in "${files[@]}"; do
  [[ -r ${file} ]] || die "working-set file is unreadable: ${file}"
done

sync
printf '3\n' > /proc/sys/vm/drop_caches
batch_size=256
size=0
resident=0
for ((offset = 0; offset < ${#files[@]}; offset += batch_size)); do
  batch=("${files[@]:offset:batch_size}")
  vmtouch -e -q "${batch[@]}"
done
for ((offset = 0; offset < ${#files[@]}; offset += batch_size)); do
  batch=("${files[@]:offset:batch_size}")
  snapshot=$(fincore -J -b -o FILE,SIZE,RES "${batch[@]}")
  batch_size_bytes=$(jq '[.fincore[].size] | add // 0' <<<"${snapshot}")
  batch_resident_bytes=$(jq '[.fincore[].res] | add // 0' <<<"${snapshot}")
  size=$((size + batch_size_bytes))
  resident=$((resident + batch_resident_bytes))
done
((size > 0)) || die "working set has zero size"
((resident * 100 < size)) ||
  die "working-set residency remains at or above one percent"

jq -n \
  --argjson total_size_bytes "${size}" \
  --argjson total_resident_bytes "${resident}" \
  '{
    cache_state: "host-cold",
    total_size_bytes: $total_size_bytes,
    total_resident_bytes: $total_resident_bytes
  }'
