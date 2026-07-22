# shellcheck shell=bash
set -euo pipefail

APP="${KELLINGRAD_APP:-/opt/app}"
DATA="${KELLINGRAD_DATA:-/data}"
DEFAULTS="${KELLINGRAD_DEFAULTS:-/opt/defaults}"
ACCOUNT_DATA_DIR="${DATA}/etc"
command_name="seed-user-hm"
user_name="${1:-}"

if [[ "$(id -u)" != "0" ]]; then
  echo "${command_name}: must run as root" >&2
  exit 100
fi
if [[ -z "${user_name}" || $# -ne 1 ]]; then
  echo "usage: ${command_name} USER" >&2
  exit 2
fi

source_config_dir="${DEFAULTS}/skel/.nixcfg"
if [[ ! -f "${source_config_dir}/home.nix" ]]; then
  echo "${command_name}: missing Home Manager skeleton at ${source_config_dir}" >&2
  exit 1
fi

passwd_entry="$(awk -F: -v user="${user_name}" '$1 == user { print; exit }' "${ACCOUNT_DATA_DIR}/passwd")"
if [[ -z "${passwd_entry}" ]]; then
  echo "${command_name}: unknown user: ${user_name}" >&2
  exit 1
fi
IFS=: read -r _name _password user_id group_id _gecos home_dir _shell <<<"${passwd_entry}"
if [[ "${home_dir}" != "/home/${user_name}" ]]; then
  echo "${command_name}: expected ${user_name}'s home to be /home/${user_name}, got ${home_dir}" >&2
  exit 1
fi

provision-user-home "${user_name}"
persistent_home_dir="${DATA}/homes/${user_name}"
config_dir="${persistent_home_dir}/.nixcfg"

if [[ -e "${config_dir}" || -L "${config_dir}" ]]; then
  echo "${command_name}: refusing to replace existing ${config_dir}" >&2
  exit 1
fi

staging_config_dir="$(mktemp -d "${persistent_home_dir}/.nixcfg-seed.XXXXXX")"
cleanup() {
  rm -rf "${staging_config_dir}"
}
trap cleanup EXIT
cp -R "${source_config_dir}/." "${staging_config_dir}/"
chown -R "${user_id}:${group_id}" "${staging_config_dir}"
chmod -R u+rwX "${staging_config_dir}"
mv "${staging_config_dir}" "${config_dir}"
trap - EXIT

mkdir -p "${APP}/hm-user"
rm -rf "${APP}/hm-user/${user_name}"
ln -snf "${config_dir}" "${APP}/hm-user/${user_name}"

echo "Seeded ${config_dir} from ${source_config_dir}"
echo "Home Manager will be activated automatically on the next boot."
