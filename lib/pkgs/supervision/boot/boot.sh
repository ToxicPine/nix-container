#!/usr/bin/env bash
set -uo pipefail

# Stage 2 of container boot. PID 1 is s6-linux-init and the root supervision
# tree is running under it. Everything above that tree comes from a selected
# generation: the root profile when one exists, otherwise the image's factory
# generation. Neither this script nor the image names a service.

runtime_directory="/run/nix-supervise/system"
profile="/nix/var/nix/profiles/system"
factory_generation="/opt/defaults/system-generation"
environment_dump="/run/s6-linux-init-env"

log() {
  echo "system-image-boot: $*" >&2
}

if ! nix-supervise-tree-wait "${runtime_directory}" 30000; then
  log "root supervision tree did not become ready"
  exit 1
fi

# The container's initial environment (proxies and the like) is what Home
# Manager builds expect. Activation runs as each user, so the dump PID 1
# made of that environment has to be readable by them.
if [[ -d "${environment_dump}" ]]; then
  chmod 0755 "${environment_dump}"
fi

if [[ -x "${profile}/bin/apply" ]]; then
  selected_generation="$(readlink -f -- "${profile}")"
else
  selected_generation="${factory_generation}"
fi

if [[ ! -x "${selected_generation}/bin/apply" ]]; then
  log "no supervision generation is available"
  exit 1
fi

# A failed transition may already have installed the selected database and
# started some services. Applying the factory here would replace that service
# set, potentially removing unrelated services because one activation failed.
log "applying generation ${selected_generation}"
"${selected_generation}/bin/apply"
apply_status=$?
if ((apply_status != 0)); then
  log "generation failed to apply; retaining the selected service set"
fi
exit "${apply_status}"
