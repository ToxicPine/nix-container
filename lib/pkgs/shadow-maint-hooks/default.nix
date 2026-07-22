{
  coreutils,
  provision-user-home,
  runCommand,
  runtimeShell,
  stopUserTrees,
}:

runCommand "shadow-maint-hooks" { } ''
  mkdir -p \
    "$out/etc/shadow-maint/useradd-post.d" \
    "$out/etc/shadow-maint/userdel-post.d" \
    "$out/etc/shadow-maint/userdel-pre.d"

  substitute ${./useradd-post} "$out/etc/shadow-maint/useradd-post.d/50-kellingrad-home" \
    --replace-fail '@runtimeShell@' '${runtimeShell}' \
    --replace-fail '@provisionUserHome@' '${provision-user-home}/bin/provision-user-home'
  substitute ${./userdel-post} "$out/etc/shadow-maint/userdel-post.d/50-kellingrad-home" \
    --replace-fail '@runtimeShell@' '${runtimeShell}' \
    --replace-fail '@rm@' '${coreutils}/bin/rm'
  substitute ${./userdel-pre} "$out/etc/shadow-maint/userdel-pre.d/50-kellingrad-services" \
    --replace-fail '@runtimeShell@' '${runtimeShell}' \
    --replace-fail '@stopUserTrees@' '${stopUserTrees}/bin/system-image-stop-user-trees'

  chmod 0755 "$out/etc/shadow-maint"/*/50-kellingrad-*
''
