#!/usr/bin/env bash
set -uo pipefail

ACCOUNT_DATA_DIR="/data/etc"
requested_user="${1:-}"

if (($# > 1)); then
  echo "usage: system-image-stop-user-trees [USER]" >&2
  exit 100
fi

shutdown_status=0
configured_users="$(awk -F: '$6 == "/home/" $1 { print $1 }' "${ACCOUNT_DATA_DIR}/passwd")"
while IFS= read -r user_name; do
  [[ -n "${user_name}" ]] || continue
  [[ -z "${requested_user}" || "${user_name}" == "${requested_user}" ]] || continue
  user_id="$(id -u -- "${user_name}" 2>/dev/null || true)"
  [[ -n "${user_id}" ]] || continue
  user_tree_service_dir="/run/service/nix-supervise-user-tree-${user_id}"
  if [[ -d "${user_tree_service_dir}" ]]; then
    touch "${user_tree_service_dir}/down"
    s6-svc -T 40000 -wd -d "${user_tree_service_dir}" || shutdown_status=$?
  fi

  if [[ -n "${requested_user}" ]] && ((shutdown_status == 0)); then
    rm -rf "${user_tree_service_dir}" "/run/nix-supervise/users/${user_id}"
    s6-svscanctl -a /run/service || shutdown_status=$?
  fi
done <<<"${configured_users}"

if [[ -n "${requested_user}" ]] \
  && ! grep -Fxq "${requested_user}" <<<"${configured_users}"
then
  echo "system-image-stop-user-trees: unknown configured user: ${requested_user}" >&2
  exit 100
fi

exit "${shutdown_status}"
