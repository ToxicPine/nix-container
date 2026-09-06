# Read-only account validation and ownership planning. Shadow owns all account
# database mutations, password handling and locking.
def require($condition; $message):
  if $condition then . else error($message) end;
def lines: split("\n") | if last == "" then .[:-1] else . end | map(split(":"));
def accounts:
  lines
  | require((map(.[0]) | unique | length) == length; "duplicate account entry")
  | map({key: .[0], value: .}) | from_entries;
def without($names): with_entries(select(.key as $name | $names | index($name) | not));

(if $mode == "bootstrap" then . else .baseline end) as $baseline
| (if $mode == "bootstrap" then {users: {}, groups: {}} else . end) as $declared
| (if $mode == "bootstrap" then {} else $owned end) as $old
| require((($declared.users | keys) - ($baseline.users | keys)) == ($declared.users | keys);
          "built-in users belong to the container backend")
| require((($declared.groups | keys) - ($baseline.groups | keys)) == ($declared.groups | keys);
          "built-in groups belong to the container backend")
| ($baseline.users + $declared.users) as $users
| ($baseline.groups + $declared.groups) as $groups
| (($old.users // {}) + $users) as $all_users
| (($old.groups // {}) + $groups) as $all_groups
| (($old.users // {} | keys) - ($users | keys)) as $removed_users
| (($old.groups // {} | keys) - ($groups | keys)) as $removed_groups
| {passwd: ($passwd | accounts), group: ($group | accounts)} as $rows
| reduce ($all_users | to_entries[]) as $u (.;
    $rows.passwd[$u.key] as $row
    | require($row == null or (($row[2] | tonumber) == $u.value.uid and ($row[3] | tonumber) == $u.value.gid);
              "\($u.key): UID/GID migration requires explicit ownership migration first"))
| reduce ($all_groups | to_entries[]) as $g (.;
    $rows.group[$g.key] as $row
    | require($row == null or ($row[2] | tonumber) == $g.value.gid;
              "\($g.key): refusing a GID migration"))
| reduce ($users | to_entries[]) as $u (.;
    require(all($rows.passwd | to_entries[]; .key == $u.key or (.value[2] | tonumber) != $u.value.uid);
            "\($u.key): UID \($u.value.uid) already belongs to another user"))
| reduce ($groups | to_entries[]) as $g (.;
    require(all($rows.group | to_entries[]; .key == $g.key or (.value[2] | tonumber) != $g.value.gid);
            "\($g.key): GID \($g.value.gid) already belongs to another group"))
| require(($users | map(.uid) | unique | length) == ($users | length); "duplicate declared UIDs")
| require(($groups | map(.gid) | unique | length) == ($groups | length); "duplicate declared GIDs")
| [$removed_groups[] | $rows.group[.] // empty | .[2] | tonumber] as $removed_gids
| require(all($rows.passwd | without($all_users | keys)[];
              (.[3] | tonumber) as $gid | $removed_gids | index($gid) | not);
          "a removed group is still a primary group of an unmanaged user")
# Keep only the identities needed to recognize accounts withdrawn from Nix.
# Pending ownership includes both generations so a partial apply can be retried
# even when the next requested generation differs from the failed one.
| {users: (($old.users // {}) + $declared.users | map_values({uid, gid})),
   groups: (($old.groups // {}) + $declared.groups | map_values({gid}))} as $journal
| {removedUsers: $removed_users, removedGroups: $removed_groups, journal: $journal,
   completed: {users: ($declared.users | map_values({uid, gid})),
               groups: ($declared.groups | map_values({gid}))},
   users: ($users | with_entries(.key as $name | .value.baseline = ($baseline.users | has($name)))),
   groups: ($groups | with_entries(.key as $name | .value.baseline = ($baseline.groups | has($name))))}
