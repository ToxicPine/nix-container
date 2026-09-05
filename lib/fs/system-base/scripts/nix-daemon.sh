#!/usr/bin/env bash
set -euo pipefail

# The daemon serves the container, so it sees the container's initial
# environment: proxies, the selected daemon store, and any operator overrides.
if [[ -z "${SYSTEM_IMAGE_ENVIRONMENT_LOADED:-}" ]]; then
  exec s6-envdir -I -f /run/s6-linux-init-env \
    env SYSTEM_IMAGE_ENVIRONMENT_LOADED=1 "$0" "$@"
fi

if [[ -n "${SYSTEM_IMAGE_NIX_DAEMON_STORE:-}" ]]; then
  set -- --store "${SYSTEM_IMAGE_NIX_DAEMON_STORE}" "$@"
fi

# nix-daemon does not implement s6 readiness. A helper polls it through the
# socket and reports on the notification descriptor s6 passes as fd 3, so
# dependents start once the daemon answers, not once the socket file exists.
# The helper gives up when the daemon it was started for is gone.
(
  daemon_pid=$$
  for _ in $(seq 1 240); do
    if nix store info --store daemon >/dev/null 2>&1; then
      printf '\n' >&3
      exit 0
    fi
    kill -0 "${daemon_pid}" 2>/dev/null || exit 1
    sleep 0.25
  done
  exit 1
) &

exec nix-daemon "$@" 3>&-
