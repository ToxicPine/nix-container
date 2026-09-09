#!/opt/bootstrap/bin/busybox sh
set -eu

DATA_DIR="/data"
ACCOUNT_DATA_DIR="${DATA_DIR}/etc"
BUSYBOX="/opt/bootstrap/bin/busybox"
BOOTSTRAP_CP="/opt/bootstrap/bin/cp"
NIX_STORE_BOOTSTRAP_DIFF="/opt/bootstrap/bin/nix-store-bootstrap-diff"
LOCAL_OVERLAY_STORE=@localOverlayStore@

# /nix may be an empty volume, so invoke the static BusyBox multicall binary
# directly until the image's store seed has been copied into place.

case "${HOSTNAME:-}" in
  "") HOSTNAME="$("${BUSYBOX}" hostname 2>/dev/null || true)" ;;
  *) ;;
esac
export HOSTNAME

seed_store_path() {
  source_store_path="${1:?missing source store path}"
  store_path_name="${source_store_path##*/}"
  destination_store_path="/nix/store/${store_path_name}"
  staging_store_path="/nix/store/.seed-${store_path_name}"

  if test -e "${destination_store_path}" || test -L "${destination_store_path}"; then
    return 0
  fi

  # GNU cp populates directories before restoring the seed's read-only modes.
  # Stage each path so an interrupted copy is never mistaken for a valid one.
  if test -e "${staging_store_path}" || test -L "${staging_store_path}"; then
    "${BUSYBOX}" chmod -R u+w "${staging_store_path}" 2>/dev/null || true
    "${BUSYBOX}" rm -rf "${staging_store_path}"
  fi
  "${BOOTSTRAP_CP}" -a "${source_store_path}" "${staging_store_path}"
  "${BUSYBOX}" mv "${staging_store_path}" "${destination_store_path}"
}

seed_nix_store() {
  "${BUSYBOX}" mkdir -p /nix/store /nix/var/nix

  if test -z "${LOCAL_OVERLAY_STORE}"; then
    for source_store_path in /nix-base/store/*; do
      seed_store_path "${source_store_path}"
    done
    return
  fi

  if test "${LOCAL_OVERLAY_STORE}" = filesystem; then
    lower_store_metadata="/lower-store/nix/var/nix/db/db.sqlite"
  else
    lower_store_metadata="/lower-store/socket"
  fi

  bootstrap_diff_path="/run/nix-store-bootstrap-diff"
  "${NIX_STORE_BOOTSTRAP_DIFF}" \
    "${LOCAL_OVERLAY_STORE}" \
    /nix-base/var/nix/store-paths \
    /nix/var/nix/db/db.sqlite \
    "${lower_store_metadata}" >"${bootstrap_diff_path}"

  while IFS= read -r store_path; do
    seed_store_path "/nix-base${store_path#/nix}"
  done <"${bootstrap_diff_path}"
  "${BUSYBOX}" rm -f "${bootstrap_diff_path}"
}

validate_local_overlay_store_mounts() {
  if test "${LOCAL_OVERLAY_STORE}" = socket; then
    lower_store_socket="/lower-store/socket"

    if ! test -S "${lower_store_socket}"; then
      echo "entrypoint: local overlay store requires a lower-store daemon socket at ${lower_store_socket}" >&2
      exit 1
    fi
  else
    lower_store_path="/lower-store/nix/store"
    lower_store_db="/lower-store/nix/var/nix/db/db.sqlite"

    if ! test -d "${lower_store_path}" || ! test -f "${lower_store_db}"; then
      echo "entrypoint: local overlay store requires the host's /nix mounted read-only below /lower-store" >&2
      exit 1
    fi

    lower_mount_point=""
    lower_mount_options=""
    while IFS=' ' read -r \
      _mount_id _parent_id _device _root mount_point mount_options _rest; do
      case "${lower_store_path}/" in
        "${mount_point%/}/"*)
          if test "${#mount_point}" -gt "${#lower_mount_point}"; then
            lower_mount_point="${mount_point}"
            lower_mount_options="${mount_options}"
          fi
          ;;
        *) ;;
      esac
    done </proc/self/mountinfo

    case ",${lower_mount_options}," in
      *,ro,*) ;;
      *)
        echo "entrypoint: the mount providing /lower-store/nix must be read-only" >&2
        exit 1
        ;;
    esac
  fi

  merged_store_is_overlay=false
  while IFS=' ' read -r _source mount_point filesystem_type _options _rest; do
    if test "${mount_point}" = /nix/store && test "${filesystem_type}" = overlay; then
      merged_store_is_overlay=true
      break
    fi
  done </proc/mounts

  if test "${merged_store_is_overlay}" != true; then
    echo "entrypoint: local overlay store requires a host-mounted OverlayFS at /nix/store" >&2
    exit 1
  fi
}

# Reconstruct the writable Nix store from the image seed before S6 starts the
# daemon that will own it for the rest of the container lifetime.
if test -n "${LOCAL_OVERLAY_STORE}"; then
  validate_local_overlay_store_mounts
fi
seed_nix_store

seed_account_file() {
  account_path="${1:?missing account path}"
  account_mode="${2:?missing account mode}"
  source_path="/etc/${account_path}"
  destination_path="${ACCOUNT_DATA_DIR}/${account_path}"
  staging_path="${destination_path}.seed.$$"

  if test -e "${destination_path}" || test -L "${destination_path}"; then
    return 0
  fi

  "${BUSYBOX}" mkdir -p "${destination_path%/*}"
  "${BUSYBOX}" rm -f "${staging_path}"
  "${BOOTSTRAP_CP}" -aL "${source_path}" "${staging_path}"
  "${BUSYBOX}" chmod "${account_mode}" "${staging_path}"
  "${BUSYBOX}" mv "${staging_path}" "${destination_path}"
}

create_account_file() {
  account_path="${1:?missing account path}"
  account_mode="${2:?missing account mode}"
  destination_path="${ACCOUNT_DATA_DIR}/${account_path}"
  staging_path="${destination_path}.seed.$$"

  if test -e "${destination_path}" || test -L "${destination_path}"; then
    return 0
  fi

  "${BUSYBOX}" rm -f "${staging_path}"
  : >"${staging_path}"
  "${BUSYBOX}" chmod "${account_mode}" "${staging_path}"
  "${BUSYBOX}" mv "${staging_path}" "${destination_path}"
}

# A new data volume starts from empty account databases and the image's
# account-tool defaults. The databases are created rather than copied from
# /etc: some runtimes, podman among them, write an entry for the container
# user into the image's /etc files, and those must not become persistent
# accounts. Existing databases are retained; bootstrap creates what is missing.
"${BUSYBOX}" mkdir -p "${ACCOUNT_DATA_DIR}/default"
"${BUSYBOX}" chmod 0755 "${ACCOUNT_DATA_DIR}" "${ACCOUNT_DATA_DIR}/default"
create_account_file passwd 0644
create_account_file group 0644
create_account_file shadow 0600
create_account_file gshadow 0600
create_account_file subuid 0644
create_account_file subgid 0644
seed_account_file login.defs 0644
seed_account_file default/useradd 0644
"${BUSYBOX}" mkdir -p "${DATA_DIR}/homes"

# Prefer the regular image toolchain once its store paths are reachable.
PATH="/run/current-system/sw/bin:/bin:/sbin:/usr/bin:/usr/sbin"
LD_LIBRARY_PATH="/lib"
export PATH LD_LIBRARY_PATH

# This executable is already in the restored store. It requires neither Nix
# evaluation nor a daemon, and runs before any name-based supervision or build.
@reconcileAccounts@ --bootstrap <<'BASELINE_ACCOUNTS'
@baselineAccounts@
BASELINE_ACCOUNTS

nix-store --load-db </nix-base/var/nix/db-base

# Some OCI runtimes preserve the writable container overlay across a stop/start.
# Recreate only the image's boot-scoped supervision state before starting S6.
rm -rf \
  /run/s6-linux-init-container-results \
  /run/s6-linux-init-env \
  /run/nix-supervise \
  /run/service

# Root's supervision configuration persists beside the user homes. Seed it
# from the factory copy on first boot and anchor the shared tree link to it.
# It is the input of the generation that provisions everything else, so it is
# the one piece of configuration the entrypoint still seeds itself. The
# generation reconciles user accounts; their creation hooks initialize homes.
system_config_dir="${DATA_DIR}/system/nixcfg"
mkdir -p "${system_config_dir}"
chmod 0700 "${DATA_DIR}/system"
first_system_config_entry="$("${BUSYBOX}" find "${system_config_dir}" -mindepth 1 -maxdepth 1 -print -quit)"
if test -z "${first_system_config_entry}"; then
  cp -R /opt/defaults/nix/. "${system_config_dir}/"
fi
chmod -R u+rwX "${system_config_dir}"
rm -rf /opt/app/nix
ln -snf "${system_config_dir}" /opt/app/nix

# Restore the image's HM links to configurations in surviving user homes.
if test -d /opt/app/hm-user; then
  while IFS=: read -r user_name _password _uid _gid _gecos home_dir _shell; do
    if test "${home_dir}" = "/home/${user_name}" && test -f "${home_dir}/.nixcfg/home.nix"; then
      ln -sfnT "${home_dir}/.nixcfg" "/opt/app/hm-user/${user_name}"
    fi
  done <"${ACCOUNT_DATA_DIR}/passwd"
fi

# exec preserves PID 1. S6 continues boot in rc.init after its root scan is
# running, so user activation never has to race supervision startup.
exec /etc/s6-linux-init/current/bin/init "$@"
