{
  provision-user-home,
  runCommand,
  runtimeShell,
}:

runCommand "shadow-maint-hooks" { } ''
  mkdir -p "$out/etc/shadow-maint/useradd-post.d"

  substitute ${./useradd-post} "$out/etc/shadow-maint/useradd-post.d/50-kellingrad-home" \
    --replace-fail '@runtimeShell@' '${runtimeShell}' \
    --replace-fail '@provisionUserHome@' '${provision-user-home}/bin/provision-user-home'

  chmod 0755 "$out/etc/shadow-maint"/*/50-kellingrad-*
''
