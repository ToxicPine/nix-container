#!/usr/bin/env bash
set -euo pipefail

# Populate each user's already-running scan tree from its Home Manager generation.

ACCOUNT_DATA_DIR="/data/etc"

run_as_user() {
  local user_name="$1"
  shift
  local user_id user_group_id user_home_dir user_path
  user_id="$(id -u -- "${user_name}")"
  user_group_id="$(id -g -- "${user_name}")"
  user_home_dir="/home/${user_name}"
  user_path="${user_home_dir}/.nix-profile/bin:${user_home_dir}/.local/state/nix/profiles/home-manager/home-path/bin:/bin:/usr/bin"

  setpriv --reuid="${user_id}" --regid="${user_group_id}" --init-groups \
    env HOME="${user_home_dir}" USER="${user_name}" PATH="${user_path}:${PATH}" \
    "$@"
}

run_as_user_or_warn() {
  local warning_message="${1:?missing warning message}"
  shift

  set +e
  run_as_user "$@"
  local exit_status=$?
  set -e

  if ((exit_status != 0)); then
    echo "${warning_message}" >&2
  fi
}

wait_for_nix_daemon() {
  while [[ ! -S /nix/var/nix/daemon-socket/socket ]]; do
    sleep 0.05
  done
}

activate_home_manager_user() {
  local rebuild_on_boot activate_on_boot
  local user_name="$1"
  local user_home_dir home_manager_profiles_dir home_manager_profile
  local home_manager_gc_roots_dir

  [[ -f "/opt/app/hm-user/${user_name}/home.nix" ]] || return 0

  rebuild_on_boot="$(jq -r '.rebuildOnBoot == true' /etc/home-manager-policy.json)"
  activate_on_boot="$(jq -r '.activateOnBoot != false' /etc/home-manager-policy.json)"
  user_home_dir="/home/${user_name}"
  home_manager_profiles_dir="${user_home_dir}/.local/state/nix/profiles"
  home_manager_profile="${home_manager_profiles_dir}/home-manager"
  home_manager_gc_roots_dir="${user_home_dir}/.local/state/home-manager/gcroots"

  run_as_user "${user_name}" mkdir -p "${home_manager_profiles_dir}" "${home_manager_gc_roots_dir}"

  if [[ "${rebuild_on_boot}" = "true" ]]; then
    echo "Refreshing Home Manager from user config for ${user_name}..." >&2
    run_as_user_or_warn \
      "Warning: Home Manager refresh failed for ${user_name}; keeping the previous generation" \
      "${user_name}" /opt/app/bin/refresh-system
  elif [[ "${activate_on_boot}" = "true" ]]; then
    if [[ -x "${home_manager_profile}/activate" ]]; then
      run_as_user_or_warn \
        "Warning: Home Manager activation failed for ${user_name}" \
        "${user_name}" "${home_manager_profile}/activate"
    else
      echo "Building Home Manager for newly provisioned user ${user_name}..." >&2
      run_as_user_or_warn \
        "Warning: initial Home Manager build failed for ${user_name}" \
        "${user_name}" /opt/app/bin/refresh-system
    fi
  fi
}

activate_home_manager_users() {
  local configured_users user_name user_id index
  local -a activation_pids=()
  local -a activation_users=()

  configured_users="$(awk -F: '$6 == "/home/" $1 { print $1 }' "${ACCOUNT_DATA_DIR}/passwd")"

  # Every empty scan must exist before an activation can wait on another user.
  while IFS= read -r user_name; do
    [[ -n "${user_name}" ]] || continue
    [[ -f "/opt/app/hm-user/${user_name}/home.nix" ]] || continue
    user_id="$(id -u -- "${user_name}")"
    system-image-register-user-tree "${user_name}" "${user_id}"
  done <<<"${configured_users}"

  while IFS= read -r user_name; do
    [[ -n "${user_name}" ]] || continue
    [[ -f "/opt/app/hm-user/${user_name}/home.nix" ]] || continue
    activate_home_manager_user "${user_name}" &
    activation_pids+=("$!")
    activation_users+=("${user_name}")
  done <<<"${configured_users}"

  for index in "${!activation_pids[@]}"; do
    if ! wait "${activation_pids[$index]}"; then
      echo "Warning: Home Manager boot activation failed for ${activation_users[$index]}" >&2
    fi
  done
}

wait_for_nix_daemon
activate_home_manager_users
