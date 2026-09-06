# Read-only account validation and planning. The configuration is the only
# source of account identities: users and groups it does not declare are
# removed. Shadow owns all database mutations, password handling and locking.
def require($condition; $message):
  if $condition then . else error($message) end;
def lines: split("\n") | if last == "" then .[:-1] else . end | map(split(":"));
def accounts:
  lines
  | require((map(.[0]) | unique | length) == length; "duplicate account entry")
  | map({key: .[0], value: .}) | from_entries;

(if $mode == "bootstrap" then . else .baseline end) as $baseline
| (if $mode == "bootstrap" then {users: {}, groups: {}} else . end) as $declared
| require((($declared.users | keys) - ($baseline.users | keys)) == ($declared.users | keys);
          "built-in users belong to the container backend")
| require((($declared.groups | keys) - ($baseline.groups | keys)) == ($declared.groups | keys);
          "built-in groups belong to the container backend")
| ($baseline.users + $declared.users) as $users
| ($baseline.groups + $declared.groups) as $groups
| {passwd: ($passwd | accounts), group: ($group | accounts)} as $rows
| require(($users | map(.uid) | unique | length) == ($users | length); "duplicate declared UIDs")
| require(($groups | map(.gid) | unique | length) == ($groups | length); "duplicate declared GIDs")
# An existing account keeps its identity. Changing a declared UID or GID
# needs an explicit migration of the files that identity owns.
| reduce ($users | to_entries[]) as $u (.;
    $rows.passwd[$u.key] as $row
    | require($row == null or (($row[2] | tonumber) == $u.value.uid and ($row[3] | tonumber) == $u.value.gid);
              "\($u.key): UID/GID migration requires explicit ownership migration first"))
| reduce ($groups | to_entries[]) as $g (.;
    $rows.group[$g.key] as $row
    | require($row == null or ($row[2] | tonumber) == $g.value.gid;
              "\($g.key): refusing a GID migration"))
# Bootstrap only creates what is missing. Applying a generation removes
# everything the configuration does not declare; homes are retained.
| (if $mode == "bootstrap" then [] else ($rows.passwd | keys) - ($users | keys) end) as $removed_users
| (if $mode == "bootstrap" then [] else ($rows.group | keys) - ($groups | keys) end) as $removed_groups
| {removedUsers: $removed_users, removedGroups: $removed_groups,
   users: ($users | with_entries(.key as $name | .value.baseline = ($baseline.users | has($name)))),
   groups: ($groups | with_entries(.key as $name | .value.baseline = ($baseline.groups | has($name))))}
