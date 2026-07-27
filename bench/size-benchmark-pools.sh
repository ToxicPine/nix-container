set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: size-benchmark-pools [--headroom-percent N] \
  PAIRED_DENSITY_SUMMARY.json OUTPUT.json

Project full density-pool sizes from an untimed pilot. The default adds 25%
whole-instance headroom plus eight instances. VM sizing uses the larger of the
KSM and non-KSM projections. A full ramp that still exhausts its manifest is
censored and must be repeated with a larger prepared pool.
EOF
  exit 2
}

die() {
  echo "size-benchmark-pools: $*" >&2
  exit 1
}

headroom_percent=25
summary=
output=

while [[ $# -gt 0 ]]; do
  case "$1" in
    --headroom-percent)
      [[ $# -ge 2 ]] || usage
      headroom_percent=$2
      shift 2
      ;;
    -*)
      usage
      ;;
    *)
      if [[ -z ${summary} ]]; then
        summary=$1
      elif [[ -z ${output} ]]; then
        output=$1
      else
        usage
      fi
      shift
      ;;
  esac
done

[[ ${headroom_percent} =~ ^[1-9][0-9]*$ &&
  -n ${summary} && -n ${output} ]] || usage
summary=$(realpath "${summary}")
output=$(realpath -m "${output}")
[[ -r ${summary} ]] || die "summary is unreadable: ${summary}"
[[ -d ${output%/*} && -w ${output%/*} ]] ||
  die "output parent must be an existing writable directory"
[[ ! -e ${output} ]] || die "refusing to replace output: ${output}"

jq -e '
  .schema == "fast-vms-benchmark-summary-v1"
  and (.density | type == "array")
  and ([.density[].benchmark_arm] | sort
       == ["container", "vm-ksm", "vm-no-ksm"])
  and (all(.density[];
    (.envelope_bytes | type == "number" and . > 0)
    and (.fixed_platform_bytes_median | type == "number" and . >= 0)
    and (.marginal_post_load_bytes_median | type == "number" and . > 0)))
' "${summary}" >/dev/null ||
  die "summary lacks positive pilot slopes for all three benchmark arms"

jq \
  --argjson headroom_percent "${headroom_percent}" \
  '
    def ceil_div($numerator; $denominator):
      ($numerator / $denominator | ceil);
    def projected_count:
      (.envelope_bytes - .fixed_platform_bytes_median) as $usable
      | if $usable <= 0 then error("fixed platform exceeds envelope")
        else
          ceil_div($usable; .marginal_post_load_bytes_median)
        end;
    def prepared_count:
      projected_count as $projected
      | ceil_div(
          ($projected * (100 + $headroom_percent));
          100
        ) + 8;

    .density as $density
    | ($density | map(select(.benchmark_arm == "container")) | .[0])
      as $container
    | ($density | map(select(.benchmark_arm == "vm-no-ksm")) | .[0])
      as $vm_no_ksm
    | ($density | map(select(.benchmark_arm == "vm-ksm")) | .[0])
      as $vm_ksm
    | {
        schema: "fast-vms-benchmark-pool-sizes-v1",
        method: {
          source: "single independent pilot ramp per arm",
          projection: "ceil((envelope - fixed) / post-load regression slope)",
          headroom_percent: $headroom_percent,
          additional_instances: 8,
          vm_rule: "maximum of KSM and non-KSM prepared counts"
        },
        container_density: ($container | prepared_count),
        vm_density:
          ([($vm_no_ksm | prepared_count), ($vm_ksm | prepared_count)] | max),
        projections: {
          container: {
            fixed_platform_bytes: $container.fixed_platform_bytes_median,
            marginal_post_load_bytes: $container.marginal_post_load_bytes_median,
            projected_instances: ($container | projected_count),
            prepared_instances: ($container | prepared_count)
          },
          vm_no_ksm: {
            fixed_platform_bytes: $vm_no_ksm.fixed_platform_bytes_median,
            marginal_post_load_bytes:
              $vm_no_ksm.marginal_post_load_bytes_median,
            projected_instances: ($vm_no_ksm | projected_count),
            prepared_instances: ($vm_no_ksm | prepared_count)
          },
          vm_ksm: {
            fixed_platform_bytes: $vm_ksm.fixed_platform_bytes_median,
            marginal_post_load_bytes: $vm_ksm.marginal_post_load_bytes_median,
            projected_instances: ($vm_ksm | projected_count),
            prepared_instances: ($vm_ksm | prepared_count)
          }
        }
      }
  ' "${summary}" >"${output}"

echo "wrote observed density pool sizes to ${output}"
