#!/usr/bin/env bash
set -euo pipefail

# Activate this user's Home Manager generation into their already-running
# supervision tree. The root tree's apply oneshot runs this as the user with
# HOME, USER, and PATH set; a failure fails the oneshot, which s6-rc reports
# by name.

usage="usage: system-image-activate-user USER REBUILD_ON_BOOT ACTIVATE_ON_BOOT"
user_name="${1:?${usage}}"
rebuild_on_boot="${2:?${usage}}"
activate_on_boot="${3:?${usage}}"

# Home Manager builds and activation scripts expect the container's initial
# environment (proxies and the like), with this user's identity kept on top.
if [[ -z "${SYSTEM_IMAGE_ENVIRONMENT_LOADED:-}" ]]; then
  exec s6-envdir -I -f /run/s6-linux-init-env \
    env HOME="${HOME}" USER="${USER}" PATH="${PATH}" SYSTEM_IMAGE_ENVIRONMENT_LOADED=1 \
    "$0" "$@"
fi

if [[ ! -f "/opt/app/hm-user/${user_name}/home.nix" ]]; then
  echo "system-image-activate-user: ${user_name} has no Home Manager configuration; nothing to activate" >&2
  exit 0
fi

home_manager_profiles_dir="${HOME}/.local/state/nix/profiles"
home_manager_profile="${home_manager_profiles_dir}/home-manager"
home_manager_gc_roots_dir="${HOME}/.local/state/home-manager/gcroots"
factory_home_manager_generation="/opt/defaults/home-manager-generations/${user_name}"

mkdir -p "${home_manager_profiles_dir}" "${home_manager_gc_roots_dir}"

if [[ "${rebuild_on_boot}" = "true" ]]; then
  exec /opt/app/bin/refresh-system
elif [[ "${activate_on_boot}" = "true" ]]; then
  if [[ -x "${home_manager_profile}/activate" ]]; then
    exec "${home_manager_profile}/activate"
  elif [[ -x "${factory_home_manager_generation}/activate" ]]; then
    exec "${factory_home_manager_generation}/activate"
  else
    exec /opt/app/bin/refresh-system
  fi
fi
