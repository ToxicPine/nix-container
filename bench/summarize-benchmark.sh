set -euo pipefail

usage() {
  echo "usage: summarize-benchmark --output FILE JSONL..." >&2
  exit 2
}

output=
declare -a inputs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || usage
      output=$2
      shift 2
      ;;
    --)
      shift
      inputs+=("$@")
      break
      ;;
    -*)
      usage
      ;;
    *)
      inputs+=("$1")
      shift
      ;;
  esac
done

[[ -n ${output} && ${#inputs[@]} -gt 0 ]] || usage
for input in "${inputs[@]}"; do
  [[ -r ${input} ]] || {
    echo "summarize-benchmark: unreadable input: ${input}" >&2
    exit 1
  }
done

output=$(realpath -m "${output}")
mkdir -p "$(dirname "${output}")"
[[ ! -e ${output} ]] || {
  echo "summarize-benchmark: refusing to replace: ${output}" >&2
  exit 1
}

jq -sc '
  def median:
    sort as $values
    | ($values | length) as $count
    | if $count == 0 then null
      elif $count % 2 == 1 then $values[($count / 2 | floor)]
      else
        ($values[$count / 2 - 1] + $values[$count / 2]) / 2
      end;

  def nearest_rank($quantile):
    sort as $values
    | ($values | length) as $count
    | if $count == 0 then null
      else $values[((($count * $quantile) | ceil) - 1)]
      end;

  def bootstrap_median:
    map(select(. != null)) as $values
    | ($values | length) as $count
    | if $count < 2 then null
      else
        (reduce range(0; 2000) as $replicate (
          {
            state: 1,
            sample: [],
            medians: []
          };
          reduce range(0; $count) as $draw (
            .;
            .state = ((.state * 16807) % 2147483647)
            | .sample += [$values[.state % $count]]
          )
          | .medians += [(.sample | median)]
          | .sample = []
        )
        | .medians) as $medians
        | {
            confidence_level: 0.95,
            resamples: 2000,
            lower: ($medians | nearest_rank(0.025)),
            upper: ($medians | nearest_rank(0.975))
          }
      end;

  def regression_slope:
    map(select(.x != null and .y != null)) as $points
    | ($points | length) as $count
    | if $count < 2 then null
      else
        ([$points[].x] | add) as $sum_x
        | ([$points[].y] | add) as $sum_y
        | ([$points[] | .x * .y] | add) as $sum_xy
        | ([$points[] | .x * .x] | add) as $sum_x_squared
        | ($count * $sum_x_squared - $sum_x * $sum_x) as $denominator
        | if $denominator == 0 then null
          else
            ($count * $sum_xy - $sum_x * $sum_y) / $denominator
          end
      end;

  def valid_density_point:
    .within_envelope
    and .service_slo_met
    and .memory_stable
    and (.load_generator_failures == 0)
    and ((.client_saturated // false) | not);

  . as $records
  | {
      schema: "fast-vms-benchmark-summary-v1",
      launch:
        ([
          $records[]
          | select(.record_type == "launch")
        ]
        | group_by([(.benchmark_arm // .target), .cache_condition])
        | map(
            . as $group
            | {
                target: $group[0].target,
                benchmark_arm: ($group[0].benchmark_arm // $group[0].target),
                cache_condition: $group[0].cache_condition,
                samples: ($group | length),
                failures: ([$group[] | select(.exit_status != 0)] | length),
                first_valid_seconds: {
                  median:
                    ([$group[].first_valid_seconds | select(. != null)] | median),
                  p95:
                    ([$group[].first_valid_seconds | select(. != null)]
                    | nearest_rank(0.95)),
                  median_bootstrap_ci:
                    ([$group[].first_valid_seconds | select(. != null)]
                    | bootstrap_median)
                },
                confirmed_seconds: {
                  median:
                    ([$group[].confirmed_seconds | select(. != null)] | median),
                  p95:
                    ([$group[].confirmed_seconds | select(. != null)]
                    | nearest_rank(0.95)),
                  median_bootstrap_ci:
                    ([$group[].confirmed_seconds | select(. != null)]
                    | bootstrap_median)
                },
                cpu_to_ready_usec_median:
                  ([
                    $group[]
                    | select(.exit_status == 0)
                    | .cpu_usage_usec
                    | select(. != null)
                  ] | median),
                ksmd_cpu_seconds_median:
                  ([$group[].ksmd_cpu_seconds | select(. != null)] | median)
              }
          )),
      density:
        ([
          $records[]
          | select(.record_type == "density_point")
        ]
        | group_by(.benchmark_arm // .target)
        | map(
            . as $target_points
            | ($target_points | group_by(.paired_block // .repetition)) as $ramps
            | {
                target: $target_points[0].target,
                benchmark_arm:
                  ($target_points[0].benchmark_arm // $target_points[0].target),
                envelope_bytes: $target_points[0].envelope_bytes,
                repetitions: ($ramps | length),
                fixed_platform_bytes_median:
                  ([$ramps[] | .[0].fixed_platform_bytes] | median),
                marginal_idle_bytes_median:
                  ([
                    $ramps[]
                    | [
                        .[]
                        | select(valid_density_point)
                        | {
                            x: .instance_count,
                            y: (.idle_used_bytes - .baseline_used_bytes)
                          }
                      ]
                    | regression_slope
                    | select(. != null)
                  ] | median),
                marginal_idle_bytes_bootstrap_ci:
                  ([
                    $ramps[]
                    | [
                        .[]
                        | select(valid_density_point)
                        | {
                            x: .instance_count,
                            y: (.idle_used_bytes - .baseline_used_bytes)
                          }
                      ]
                    | regression_slope
                    | select(. != null)
                  ] | bootstrap_median),
                marginal_post_load_bytes_median:
                  ([
                    $ramps[]
                    | [
                        .[]
                        | select(valid_density_point)
                        | {
                            x: .instance_count,
                            y: .deployment_post_load_bytes
                          }
                      ]
                    | regression_slope
                    | select(. != null)
                  ] | median),
                marginal_post_load_bytes_bootstrap_ci:
                  ([
                    $ramps[]
                    | [
                        .[]
                        | select(valid_density_point)
                        | {
                            x: .instance_count,
                            y: .deployment_post_load_bytes
                          }
                      ]
                    | regression_slope
                    | select(. != null)
                  ] | bootstrap_median)
              }
          )),
      density_capacity:
        ([
          $records[]
          | select(
              .record_type == "density_summary"
              and (.capacity_censored | not)
            )
        ]
        | group_by(.benchmark_arm // .target)
        | map(
            . as $group
            | {
                target: $group[0].target,
                benchmark_arm: ($group[0].benchmark_arm // $group[0].target),
                envelope_bytes: $group[0].envelope_bytes,
                repetitions: ($group | length),
                maximum_healthy_instances: {
                  median: ([$group[].maximum_healthy_instances] | median),
                  minimum: ([$group[].maximum_healthy_instances] | min),
                  maximum: ([$group[].maximum_healthy_instances] | max),
                  observations: [$group[].maximum_healthy_instances],
                  median_bootstrap_ci:
                    ([$group[].maximum_healthy_instances] | bootstrap_median)
                },
                maximum_observed_healthy_idle_instances: {
                  median:
                    ([
                      $group[].maximum_observed_healthy_idle_instances
                      | select(. != null)
                    ] | median),
                  observations:
                    ([
                      $group[].maximum_observed_healthy_idle_instances
                      | select(. != null)
                    ])
                },
                remaining_envelope_bytes_median:
                  ([$group[].remaining_envelope_bytes] | median),
                ksmd_cpu_seconds_median:
                  ([$group[].ksmd_cpu_seconds | select(. != null)] | median)
              }
          )),
      censored_density_ramps:
        ([
          $records[]
          | select(
              .record_type == "density_summary"
              and .capacity_censored
            )
          | {
              target,
              benchmark_arm: (.benchmark_arm // .target),
              repetition,
              paired_block: (.paired_block // null),
              stop_reason,
              maximum_healthy_instances
            }
        ]),
      density_failures:
        ([
          $records[]
          | select(.record_type == "density_failure")
          | {
              target,
              benchmark_arm: (.benchmark_arm // .target),
              repetition,
              paired_block: (.paired_block // null),
              failed_instance_id,
              attempted_instance_count,
              reason,
              log
            }
        ]),
      nginx:
        ([
          $records[]
          | select(.record_type == "nginx")
        ]
        | group_by([
            (.benchmark_arm // .target),
            (.run_kind // "matrix"),
            .path,
            .keepalive,
            .concurrency
          ])
        | map(
            . as $group
            | {
                target: $group[0].target,
                benchmark_arm: ($group[0].benchmark_arm // $group[0].target),
                run_kind: ($group[0].run_kind // "matrix"),
                path: $group[0].path,
                keepalive: $group[0].keepalive,
                concurrency: $group[0].concurrency,
                samples: ($group | length),
                client_saturated_samples:
                  ([
                    $group[]
                    | select((.client_saturated // false) == true)
                  ] | length),
                target_throughput_valid:
                  (all($group[]; ((.client_saturated // false) | not))),
                requests_per_second_median:
                  ([$group[].oha.summary.requestsPerSec] | median),
                requests_per_second_bootstrap_ci:
                  ([$group[].oha.summary.requestsPerSec] | bootstrap_median),
                latency_seconds: {
                  p50_median:
                    ([$group[].oha.latencyPercentiles.p50] | median),
                  p95_median:
                    ([$group[].oha.latencyPercentiles.p95] | median),
                  p99_median:
                    ([$group[].oha.latencyPercentiles.p99] | median),
                  p99_bootstrap_ci:
                    ([$group[].oha.latencyPercentiles.p99] | bootstrap_median)
                },
                error_rate_median: ([$group[].error_rate] | median),
                target_cpu_seconds_median:
                  ([$group[].target_cpu_usage_usec / 1000000] | median),
                client_cpu_seconds_median:
                  ([$group[].client_cpu_usage_usec / 1000000] | median),
                client_cpu_utilization_median:
                  ([
                    $group[]
                    | .client_cpu_usage_usec
                      / (1000000 * .sample_seconds * .client_cpu_count)
                  ] | median),
                host_cpu_utilization_median:
                  ([$group[].host_cpu_utilization] | median),
                host_resident_peak_bytes_median:
                  ([$group[].host_resident_peak_bytes] | median),
                host_resident_steady_bytes_median:
                  ([$group[].host_resident_steady_bytes] | median),
                client_cgroup_memory_peak_bytes_median:
                  ([$group[].client_cgroup_memory_peak_bytes] | median),
                client_cgroup_memory_steady_bytes_median:
                  ([$group[].client_cgroup_memory_steady_bytes] | median),
                network_bytes_median:
                  ([$group[].network.total_bytes] | median),
                ksmd_cpu_seconds_median:
                  ([$group[].ksmd_cpu_seconds | select(. != null)] | median)
              }
          ))
    }
' "${inputs[@]}" >"${output}"

echo "wrote ${output}"
