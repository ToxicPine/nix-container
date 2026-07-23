{
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
      ]
      [
        (if localOverlayStore == null then "" else localOverlayStore)
      ]
      (builtins.readFile ./entrypoint.sh);
}
