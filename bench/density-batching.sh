# shellcheck shell=bash

json_string_array() {
  jq -cn --args '$ARGS.positional' "$@"
}

estimate_density_marginal_bytes() {
  local -n counts_ref=$1
  local -n bytes_ref=$2
  local work_dir=$3
  local prediction_margin_percent=$4
  local point_count=${#counts_ref[@]}
  local start=0
  local first_count
  local first_bytes
  local last_count
  local last_bytes
  local global_slope=0
  local recent_slope=0
  local estimate
  local left
  local right
  local delta_count
  local delta_bytes
  local slope_count

  ((point_count == ${#bytes_ref[@]})) ||
    die "density checkpoint count and memory arrays differ"
  if ((point_count < 2)); then
    printf '0\n'
    return
  fi

  if ((point_count > 7)); then
    start=$((point_count - 7))
  fi

  : >"${work_dir}/density-slopes"
  for ((left = start; left < point_count - 1; left++)); do
    for ((right = left + 1; right < point_count; right++)); do
      delta_count=$((counts_ref[right] - counts_ref[left]))
      delta_bytes=$((bytes_ref[right] - bytes_ref[left]))
      if ((delta_count > 0 && delta_bytes > 0)); then
        printf '%s\n' "$((delta_bytes / delta_count))" \
          >>"${work_dir}/density-slopes"
      fi
    done
  done

  if [[ -s ${work_dir}/density-slopes ]]; then
    sort -n "${work_dir}/density-slopes" \
      >"${work_dir}/density-slopes-sorted"
    slope_count=$(wc -l <"${work_dir}/density-slopes-sorted")
    recent_slope=$(sed -n "$((slope_count / 2 + 1))p" \
      "${work_dir}/density-slopes-sorted")
  fi

  first_count=${counts_ref[0]}
  first_bytes=${bytes_ref[0]}
  last_count=${counts_ref[point_count - 1]}
  last_bytes=${bytes_ref[point_count - 1]}
  delta_count=$((last_count - first_count))
  delta_bytes=$((last_bytes - first_bytes))
  if ((delta_count > 0 && delta_bytes > 0)); then
    global_slope=$((delta_bytes / delta_count))
  fi

  estimate=${recent_slope}
  ((global_slope > estimate)) && estimate=${global_slope}
  ((estimate < 1)) && estimate=1
  estimate=$((estimate * (100 + prediction_margin_percent) / 100))
  printf '%s\n' "${estimate}"
}

choose_density_batch_size() {
  local current_count=$1
  local pool_remaining=$2
  local remaining_bytes=$3
  local marginal_bytes=$4
  local failed_upper_bound=$5
  local density_bootstrap_instances=$6
  local density_max_batch=$7
  local density_single_step_at=$8
  local predicted_remaining_instances
  local gap
  local batch_size

  if ((failed_upper_bound > 0)); then
    gap=$((failed_upper_bound - current_count))
    if ((gap <= 1)); then
      printf '0\n'
      return
    fi
    batch_size=$((gap / 2))
  elif ((marginal_bytes == 0)); then
    batch_size=${density_bootstrap_instances}
  else
    predicted_remaining_instances=$((remaining_bytes / marginal_bytes))
    if ((predicted_remaining_instances <= density_single_step_at)); then
      batch_size=1
    else
      batch_size=$((predicted_remaining_instances / 2))
    fi
  fi

  ((batch_size < 1)) && batch_size=1
  ((batch_size > density_max_batch)) && batch_size=${density_max_batch}
  ((batch_size > pool_remaining)) && batch_size=${pool_remaining}
  printf '%s\n' "${batch_size}"
}
