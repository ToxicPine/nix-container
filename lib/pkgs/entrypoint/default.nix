{
  lib,
  localOverlayStoreEnabled,
  writeTextFile,
}:

writeTextFile {
  name = "system-image-entrypoint";
  destination = "/bin/entrypoint";
  executable = true;
  text =
    builtins.replaceStrings
      [
        "@localOverlayStoreEnabled@"
      ]
      [
        (lib.boolToString localOverlayStoreEnabled)
      ]
      (builtins.readFile ./entrypoint.sh);
}
