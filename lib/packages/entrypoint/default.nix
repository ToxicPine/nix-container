{
  reconcileAccounts,
  baselineAccounts,
  localOverlayStore,
  writeTextFile,
}:

writeTextFile {
  name = "system-image-entrypoint";
  destination = "/bin/entrypoint";
  executable = true;
  text =
    builtins.replaceStrings
      [
        "@localOverlayStore@"
        "@reconcileAccounts@"
        "@baselineAccounts@"
      ]
      [
        (if localOverlayStore == null then "" else localOverlayStore)
        "${reconcileAccounts}/bin/system-reconcile-accounts"
        (builtins.toJSON baselineAccounts)
      ]
      (builtins.readFile ./entrypoint.sh);
}
