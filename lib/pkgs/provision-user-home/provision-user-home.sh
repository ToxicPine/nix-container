# shellcheck shell=bash
set -euo pipefail

# Reconstruct a conventional user's persistent home and Home Manager link.
# With a seed source, populate ~/.nixcfg from it while the directory is
# empty; a missing source falls back to the skeleton. The useradd hook runs
# this without a source; the root tree's home-<name> oneshot runs it with one.

DATA="${KELLINGRAD_DATA:-/data}"
APP="${KELLINGRAD_APP:-/opt/app}"
DEFAULTS="${KELLINGRAD_DEFAULTS:-/opt/defaults}"
ACCOUNT_DATA_DIR="${DATA}/etc"
command_name="provision-user-home"
user_name="${1:-${SUBJECT:-}}"
seed_source_dir="${2:-}"

current_user_id="$(id -u)"
if [[ "${current_user_id}" != "0" ]]; then
  echo "${command_name}: must run as root" >&2
  exit 100
fi
if [[ -z "${user_name}" ]]; then
  echo "usage: ${command_name} USER [SEED_SOURCE]" >&2
  exit 2
fi

passwd_entry="$(awk -F: -v user="${user_name}" '$1 == user { print; exit }' "${ACCOUNT_DATA_DIR}/passwd")"
if [[ -z "${passwd_entry}" ]]; then
  echo "${command_name}: unknown user: ${user_name}" >&2
  exit 1
fi

IFS=: read -r _name _password user_id group_id _gecos home_dir _shell <<<"${passwd_entry}"
if [[ "${home_dir}" != "/home/${user_name}" ]]; then
  # System and explicitly nonstandard accounts are outside this image's
  # persistent-home convention.
  exit 0
fi

persistent_home_dir="${DATA}/homes/${user_name}"
persistent_nix_config_dir="${persistent_home_dir}/.nixcfg"
shared_user_config_link="${APP}/hm-user/${user_name}"
mkdir -p "${DATA}/homes" "${persistent_home_dir}" "${APP}/hm-user"

resolved_home_dir="$(readlink -f -- "${home_dir}")"
resolved_persistent_home_dir="$(readlink -f -- "${persistent_home_dir}")"
if [[ "${resolved_home_dir}" != "${resolved_persistent_home_dir}" ]]; then
  echo "${command_name}: ${home_dir} is not backed by ${persistent_home_dir}" >&2
  exit 1
fi

chown "${user_id}:${group_id}" "${persistent_home_dir}"
chmod 0700 "${persistent_home_dir}"

rm -rf "${shared_user_config_link}"
if [[ -L "${persistent_nix_config_dir}" ]]; then
  echo "${command_name}: refusing symlinked ${persistent_nix_config_dir}" >&2
  exit 1
fi

if [[ -n "${seed_source_dir}" ]] && {
  [[ ! -d "${persistent_nix_config_dir}" ]] \
    || [[ -z "$(find "${persistent_nix_config_dir}" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}; then
  [[ -d "${seed_source_dir}" ]] || seed_source_dir="${DEFAULTS}/skel/.nixcfg"
  echo "Seeding ${persistent_nix_config_dir} from ${seed_source_dir}" >&2
  mkdir -p "${persistent_nix_config_dir}"
  cp -R "${seed_source_dir}/." "${persistent_nix_config_dir}/"
fi

if [[ -f "${persistent_nix_config_dir}/home.nix" ]]; then
  chown -R "${user_id}:${group_id}" "${persistent_nix_config_dir}"
  chmod -R u+rwX "${persistent_nix_config_dir}"
  ln -snf "${persistent_nix_config_dir}" "${shared_user_config_link}"
fi
