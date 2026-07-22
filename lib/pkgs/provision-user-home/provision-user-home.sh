# shellcheck shell=bash
set -euo pipefail

DATA="${KELLINGRAD_DATA:-/data}"
APP="${KELLINGRAD_APP:-/opt/app}"
ACCOUNT_DATA_DIR="${DATA}/etc"
command_name="provision-user-home"
user_name="${1:-${SUBJECT:-}}"

if [[ "$(id -u)" != "0" ]]; then
  echo "${command_name}: must run as root" >&2
  exit 100
fi
if [[ -z "${user_name}" ]]; then
  echo "usage: ${command_name} USER" >&2
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
mkdir -p "${DATA}/homes" "${persistent_home_dir}" "${APP}/hm-user"

if [[ "$(readlink -f "${home_dir}")" != "$(readlink -f "${persistent_home_dir}")" ]]; then
  echo "${command_name}: ${home_dir} is not backed by ${persistent_home_dir}" >&2
  exit 1
fi

chown "${user_id}:${group_id}" "${persistent_home_dir}"
chmod 0700 "${persistent_home_dir}"

rm -rf "${APP}/hm-user/${user_name}"
if [[ -L "${persistent_home_dir}/.nixcfg" ]]; then
  echo "${command_name}: refusing symlinked ${persistent_home_dir}/.nixcfg" >&2
  exit 1
fi
if [[ -f "${persistent_home_dir}/.nixcfg/home.nix" ]]; then
  chown -R "${user_id}:${group_id}" "${persistent_home_dir}/.nixcfg"
  chmod -R u+rwX "${persistent_home_dir}/.nixcfg"
  ln -snf "${persistent_home_dir}/.nixcfg" "${APP}/hm-user/${user_name}"
fi
