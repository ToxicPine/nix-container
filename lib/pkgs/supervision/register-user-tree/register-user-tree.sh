#!/usr/bin/env bash
set -euo pipefail

user_name="${1:?usage: system-image-register-user-tree USER UID}"
user_id="${2:?usage: system-image-register-user-tree USER UID}"

current_user_id="$(id -u)"
if [[ "${current_user_id}" != "0" ]]; then
  echo "system-image-register-user-tree: must run as root" >&2
  exit 100
fi

user_tree_runtime_root="/run/nix-supervise/users"
user_tree_runtime_dir="${user_tree_runtime_root}/${user_id}"
user_tree_service_dir="/run/service/nix-supervise-user-tree-${user_id}"

if [[ ! "${user_name}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
  echo "system-image-register-user-tree: invalid user name: ${user_name}" >&2
  exit 100
fi

resolved_user_id="$(id -u -- "${user_name}" 2>/dev/null || true)"
if [[ "${resolved_user_id}" != "${user_id}" ]]; then
  echo "system-image-register-user-tree: ${user_name} does not have uid ${user_id}" >&2
  exit 100
fi
if [[ ! -d "${user_tree_service_dir}" ]]; then
  staging_service_dir="${user_tree_service_dir}.new.$$"
  rm -rf "${staging_service_dir}"
  install -d -m 0755 -o 0 -g 0 "${staging_service_dir}"
  touch "${staging_service_dir}/down"
  tree_run="$(command -v nix-supervise-tree-run)"
  cat >"${staging_service_dir}/run" <<EOF
#!/bin/sh
LD_LIBRARY_PATH=/lib exec ${tree_run} user ${user_name} ${user_tree_runtime_root}
EOF
  chmod 0755 "${staging_service_dir}/run"
  mv "${staging_service_dir}" "${user_tree_service_dir}"
fi

s6-svscanctl -a /run/service

for _attempt in $(seq 1 300); do
  [[ -d "${user_tree_service_dir}/supervise" ]] && break
  sleep 0.1
done
if [[ ! -d "${user_tree_service_dir}/supervise" ]]; then
  echo "system-image-register-user-tree: root scan did not discover ${user_tree_service_dir}" >&2
  exit 111
fi

s6-svc -u "${user_tree_service_dir}"
nix-supervise-tree-wait "${user_tree_runtime_dir}" 30000
