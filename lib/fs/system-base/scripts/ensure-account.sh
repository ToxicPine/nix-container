#!/usr/bin/env bash
set -euo pipefail

user_name="${1:?usage: system-image-ensure-account USER UID}"
user_id="${2:?usage: system-image-ensure-account USER UID}"

if existing_user_id="$(id -u -- "${user_name}" 2>/dev/null)"; then
  if [[ "${existing_user_id}" != "${user_id}" ]]; then
    echo "system-image-ensure-account: ${user_name} exists with uid ${existing_user_id}, declared ${user_id}; keeping the existing account" >&2
  fi
  exit 0
fi

exec env PATH=/bin:/sbin:/usr/bin:/usr/sbin \
  useradd --uid "${user_id}" --user-group --create-home --skel /var/empty \
  --shell /bin/bash -- "${user_name}"
