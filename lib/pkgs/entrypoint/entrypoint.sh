#!/opt/bootstrap/bin/busybox sh
set -eu

DATA_DIR="/data"
ACCOUNT_DATA_DIR="${DATA_DIR}/etc"
BUSYBOX="/opt/bootstrap/bin/busybox"
BOOTSTRAP_CP="/opt/bootstrap/bin/cp"
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
  for source_store_path in /nix-base/store/*; do
    seed_store_path "${source_store_path}"
  done
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

# The image keeps a conventional /etc for the OCI runtime. Account state alone
# is seeded onto the data volume and is canonical after its first boot.
"${BUSYBOX}" mkdir -p "${ACCOUNT_DATA_DIR}/default"
"${BUSYBOX}" chmod 0755 "${ACCOUNT_DATA_DIR}" "${ACCOUNT_DATA_DIR}/default"
seed_account_file passwd 0644
seed_account_file group 0644
seed_account_file shadow 0600
seed_account_file gshadow 0600
seed_account_file subuid 0644
seed_account_file subgid 0644
seed_account_file login.defs 0644
seed_account_file default/useradd 0644
"${BUSYBOX}" mkdir -p "${DATA_DIR}/homes"

# Prefer the regular image toolchain once its store paths are reachable.
PATH="/bin:/sbin:/usr/bin:/usr/sbin"
LD_LIBRARY_PATH="/lib"
export PATH LD_LIBRARY_PATH

nix-store --load-db </nix-base/var/nix/db-base

# Some OCI runtimes preserve the writable container overlay across a stop/start.
# Recreate only Kellingrad's boot-scoped supervision state before starting S6.
rm -rf \
  /run/s6-linux-init-container-results \
  /run/s6-linux-init-env \
  /run/nix-supervise \
  /run/service

# The mutable passwd database is canonical. Reconstruct persistent homes and
# optional Home Manager links for conventional /home/<name> users before any
# activation can run.
configured_users_file="/run/configured-users.tsv"
awk -F: '$6 == "/home/" $1 { print $1 "\t" $3 "\t" $4 }' \
  "${ACCOUNT_DATA_DIR}/passwd" >"${configured_users_file}"

while IFS="$(printf '\t')" read -r user_name user_id group_id; do
  persistent_home_dir="${DATA_DIR}/homes/${user_name}"
  factory_settings_dir="/opt/defaults/hm-user/${user_name}"
  shared_user_config_link="/opt/app/hm-user/${user_name}"
  persistent_nix_config_dir="${persistent_home_dir}/.nixcfg"

  mkdir -p "${persistent_home_dir}"
  chown "${user_id}:${group_id}" "${persistent_home_dir}"
  chmod 0700 "${persistent_home_dir}"

  if test -L "${persistent_nix_config_dir}" \
    || { test -e "${persistent_nix_config_dir}" && test ! -d "${persistent_nix_config_dir}"; }; then
    echo "entrypoint: ignoring invalid ${persistent_nix_config_dir}; expected a real directory" >&2
    rm -rf "${shared_user_config_link}"
    continue
  fi

  seed_persistent_nix_config=false
  if test -d "${factory_settings_dir}" && test ! -d "${persistent_nix_config_dir}"; then
    seed_persistent_nix_config=true
  elif test -d "${factory_settings_dir}"; then
    first_config_entry="$("${BUSYBOX}" find "${persistent_nix_config_dir}" -mindepth 1 -maxdepth 1 -print -quit)"
    if test -z "${first_config_entry}"; then
      seed_persistent_nix_config=true
    fi
  fi

  if test "${seed_persistent_nix_config}" = true; then
    mkdir -p "${persistent_nix_config_dir}"
    cp -R "${factory_settings_dir}/." "${persistent_nix_config_dir}/"
  fi
  rm -rf "${shared_user_config_link}"

  if test -d "${persistent_nix_config_dir}"; then
    chown -R "${user_id}:${group_id}" "${persistent_nix_config_dir}"
    chmod -R u+rwX "${persistent_nix_config_dir}"
  fi

  if test -f "${persistent_nix_config_dir}/home.nix"; then
    # Keep relative imports anchored in the shared image tree. ~/.nixcfg is
    # already the real persistent directory through the /home link.
    ln -snf "${persistent_nix_config_dir}" "${shared_user_config_link}"
  fi
done <"${configured_users_file}"
rm -f "${configured_users_file}"

# exec preserves PID 1. S6 continues boot in rc.init after its root scan is
# running, so user activation never has to race supervision startup.
exec /etc/s6-linux-init/current/bin/init "$@"
