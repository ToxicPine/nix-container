#!/usr/bin/env bash
# Ensure baseline accounts at bootstrap, or make the account database match a
# declared generation. Individual replacements are atomic; the complete
# application is not, but it is idempotent: rerunning converges.
set -euo pipefail
umask 077

account_lib=${account_lib:-$(dirname -- "${BASH_SOURCE[0]}")}
mode=runtime
resources=""
if [[ "${1:?usage: reconcile-accounts GENERATION | --bootstrap}" == --bootstrap ]]; then
    mode=bootstrap
else
    resources=$(realpath -e -- "$1")
fi
temporary_paths=()

fail() { printf 'system-reconcile-accounts: %s\n' "$*" >&2; exit 1; }
mkdir_public() { (umask 022; mkdir -p -- "$@"); }
cleanup() {
    local path
    for path in "${temporary_paths[@]}"; do rm -rf -- "${path}"; done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Return the checked path in REPLY, without resolving symlinks in its parents.
safe_path() {
    local destination=$1 parent
    [[ ${destination} == /* && ${destination} != / && ${destination} != */ &&
       ${destination} != *//* && ${destination}/ != */./* && ${destination}/ != */../* ]] ||
        fail "invalid destination: ${destination}"
    REPLY=${destination}
    parent=${REPLY%/*}
    while [[ -n ${parent} ]]; do
        [[ ! -L ${parent} ]] || fail "refusing symlinked parent: ${parent}"
        [[ ! -e ${parent} || -d ${parent} ]] || fail "parent is not a directory: ${parent}"
        parent=${parent%/*}
    done
}

replace_link() {
    local destination=$1 target=$2 staging
    staging=$(mktemp -d -- "${destination%/*}/.system-XXXXXXXX")
    temporary_paths+=("${staging}")
    ln -s -- "${target}" "${staging}/link"
    mv -fT -- "${staging}/link" "${destination}"
    rmdir -- "${staging}"
}

load_state() {
    # Shadow locks each database write; this lock serializes whole applies.
    mkdir_public /run/lock
    exec {apply_lock}> /run/lock/system-accounts
    flock -x "${apply_lock}"
    if [[ ${mode} == bootstrap ]]; then
        manifest=$(cat)
    else
        manifest=$(cat -- "${resources}/manifest.json")
        safe_path /run/current-system
        current=${REPLY}
        [[ ! -e ${current} || -L ${current} ]] || fail 'current-system must be a symlink'
    fi
}

validate_accounts() {
    if [[ ${mode} == runtime ]]; then
        jq -j '.users | keys[] | ., "\u0000"' <<< "${manifest}" |
            while IFS= read -r -d '' name; do
                safe_path "/data/homes/${name}"
                [[ ! -L ${REPLY} ]] || fail "invalid home: ${REPLY}"
                [[ ! -e ${REPLY} || -d ${REPLY} ]] || fail "invalid home: ${REPLY}"
            done
    fi

    safe_path /data/etc
    account_dir=${REPLY}
    [[ ! -L ${account_dir} ]] || fail 'account directory must not be symlinked'
    for name in passwd group shadow gshadow subuid subgid; do
        [[ ! -L ${account_dir}/${name} ]] || fail "account database is symlinked: ${account_dir}/${name}"
    done
    plan=$(jq --arg mode "${mode}" \
        --rawfile passwd "${account_dir}/passwd" --rawfile group "${account_dir}/group" \
        -f "${account_lib}/plan-accounts.jq" <<< "${manifest}")
}

lookup_account() { REPLY=$(awk -F: -v name="$2" '$1 == name { print; exit }' "${account_dir}/$1"); }

# Stop services using identities that are about to disappear. Home Manager's
# userdel hook separately stops the user's supervised tree. At first boot
# there is no live service manifest and nothing to stop.
stop_removed_account_services() {
    local live=/run/nix-supervise/system/live
    local service_manifest=/run/nix-supervise/system/current-service-manifest.json
    local selected
    local -a services
    [[ ${mode} == runtime && -f ${service_manifest} && -L ${live} ]] || return 0
    selected=$(jq -r --argjson plan "${plan}" '
        .services | to_entries[] |
        select((.value.execution.user as $user | $plan.removedUsers | index($user)) != null
            or (.value.execution.group as $group | $plan.removedGroups | index($group)) != null) |
        .key' "${service_manifest}")
    if [[ -n ${selected} ]]; then
        mapfile -t services <<< "${selected}"
        s6-rc -l "${live}" -d change "${services[@]}"
    fi
}

reconcile_accounts() {
    # Pipefail propagates failures from both jq and Shadow; no process
    # substitutions or scratch files are needed to feed these loops.
    jq -r '.removedUsers[]' <<< "${plan}" |
        while IFS= read -r name; do
            lookup_account passwd "${name}"
            if [[ -n ${REPLY} ]]; then /bin/userdel -- "${name}"; fi
        done
    jq -r '.removedGroups[]' <<< "${plan}" |
        while IFS= read -r name; do
            lookup_account group "${name}"
            if [[ -n ${REPLY} ]]; then /bin/groupdel -- "${name}"; fi
        done
    jq -r '.groups | to_entries[] | [.key, .value.gid] | @tsv' <<< "${plan}" |
        while IFS=$'\t' read -r name gid; do
            lookup_account group "${name}"
            if [[ -z ${REPLY} ]]; then /bin/groupadd --gid "${gid}" -- "${name}"; fi
        done
    jq -j '.users | to_entries[] | [.key, .value.uid, .value.gid,
        .value.home, .value.shell, .value.description, (.value.extraGroups | join(",")),
        .value.baseline] | .[] | tostring, "\u0000"' <<< "${plan}" |
        while mapfile -d '' -t -n 8 fields && ((${#fields[@]})); do
            name=${fields[0]}
            options=(--gid "${fields[2]}" --home "${fields[3]}" --shell "${fields[4]}" --comment "${fields[5]}" --groups "${fields[6]}")
            lookup_account passwd "${name}"
            if [[ -n ${REPLY} && ${fields[7]} == false ]]; then
                /bin/usermod "${options[@]}" -- "${name}"
            elif [[ -z ${REPLY} ]]; then
                if [[ ${fields[7]} == true ]]; then
                    # System accounts get no home or subordinate ID ranges. The
                    # per-invocation SYS_UID_MAX override only silences useradd's
                    # warning about fixed baseline UIDs above the login.defs range.
                    creation=(--system --no-create-home -K "SYS_UID_MAX=${fields[1]}")
                else
                    creation=(--create-home --skel /var/empty)
                fi
                /bin/useradd --uid "${fields[1]}" --no-user-group "${creation[@]}" "${options[@]}" -- "${name}"
            fi
            # Also repairs homes for adopted accounts or an interrupted hook.
            if [[ ${fields[7]} == false ]]; then /bin/provision-user-home "${name}"; fi
        done
    # Memberships are declared exactly. Bootstrap never removes one: it only
    # ensures the required baseline memberships before a generation applies.
    jq -j --arg mode "${mode}" --rawfile existing "${account_dir}/group" '
        . as $data | .groups | to_entries[] | .key as $name |
        [.key, ((.value.members + [$data.users | to_entries[] |
          select(.value.extraGroups | index($name)) | .key] +
          (if $mode == "bootstrap" then
            [$existing | split("\n")[] | split(":") | select(.[0] == $name) |
              .[3] | split(",")[] | select(. != "")]
           else [] end)) | unique | join(","))] | .[] | ., "\u0000"' <<< "${plan}" |
        while mapfile -d '' -t -n 2 fields && ((${#fields[@]})); do
            /bin/groupmod --users "${fields[1]}" -- "${fields[0]}"
        done
}

publish_generation() {
    if [[ ${mode} == runtime ]]; then
        mkdir_public "${current%/*}"
        replace_link "${current}" "${resources}"
    fi
}

load_state
validate_accounts
stop_removed_account_services
reconcile_accounts
publish_generation
