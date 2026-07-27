set -euo pipefail

@DENSITY_BATCHING@

die() {
  echo "density-batching-test: $*" >&2
  exit 1
}

assert_equal() {
  local expected=$1
  local actual=$2
  local label=$3
  [[ ${actual} == "${expected}" ]] ||
    die "${label}: expected ${expected}, got ${actual}"
}

work_dir=$(mktemp -d)
cleanup() {
  rm -rf -- "${work_dir}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ids_json=$(json_string_array \
  container-density-r01-i0001 \
  'instance with spaces' \
  'instance"with"quotes')
assert_equal \
  '["container-density-r01-i0001","instance with spaces","instance\"with\"quotes"]' \
  "${ids_json}" \
  "instance ID JSON serialization"

declare -a counts=(0)
declare -a bytes=(1000)
declare -p counts bytes >/dev/null
estimate=$(estimate_density_marginal_bytes counts bytes "${work_dir}" 5)
assert_equal 0 "${estimate}" "insufficient checkpoints"

counts=(0 10)
bytes=(1000 900)
declare -p counts bytes >/dev/null
estimate=$(estimate_density_marginal_bytes counts bytes "${work_dir}" 5)
assert_equal 1 "${estimate}" "non-positive measured slopes"

counts=(0 4 20)
bytes=(1000 1400 3000)
declare -p counts bytes >/dev/null
estimate=$(estimate_density_marginal_bytes counts bytes "${work_dir}" 5)
assert_equal 105 "${estimate}" "linear marginal estimate"

counts=(0 10 20 30)
bytes=(0 1000 1900 1850)
declare -p counts bytes >/dev/null
estimate=$(estimate_density_marginal_bytes counts bytes "${work_dir}" 5)
assert_equal 94 "${estimate}" "KSM catch-up marginal estimate"

batch=$(choose_density_batch_size 0 200 16000 0 0 4 64 8)
assert_equal 4 "${batch}" "bootstrap batch"

batch=$(choose_density_batch_size 4 200 1000 1 0 4 64 8)
assert_equal 64 "${batch}" "near-zero measured marginal"

batch=$(choose_density_batch_size 20 200 10000 100 0 4 64 8)
assert_equal 50 "${batch}" "half of predicted remaining capacity"

batch=$(choose_density_batch_size 20 200 100000 100 0 4 64 8)
assert_equal 64 "${batch}" "maximum batch cap"

batch=$(choose_density_batch_size 50 200 800 100 0 4 64 8)
assert_equal 1 "${batch}" "single-step threshold"

batch=$(choose_density_batch_size 40 200 10000 100 56 4 64 8)
assert_equal 8 "${batch}" "failed-bound bisection"

batch=$(choose_density_batch_size 0 200 10000 100 200 4 64 8)
assert_equal 64 "${batch}" "failed-bound maximum batch cap"

batch=$(choose_density_batch_size 54 200 10000 100 56 4 64 8)
assert_equal 1 "${batch}" "failed-bound final singleton"

batch=$(choose_density_batch_size 55 200 10000 100 56 4 64 8)
assert_equal 0 "${batch}" "resolved failed bound"

batch=$(choose_density_batch_size 0 3 16000 0 0 4 64 8)
assert_equal 3 "${batch}" "pool limit"

current_count=4
failed_upper_bound=0
while :; do
  batch=$(choose_density_batch_size \
    "${current_count}" 200 5100 50 "${failed_upper_bound}" 4 64 8)
  ((batch > 0)) || break
  attempted_count=$((current_count + batch))
  if ((attempted_count > 37)); then
    failed_upper_bound=${attempted_count}
  else
    current_count=${attempted_count}
  fi
done
assert_equal 37 "${current_count}" "refined observed maximum"
assert_equal 38 "${failed_upper_bound}" "adjacent measured failure"

echo "density batching tests passed"
