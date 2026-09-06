# Ask n2c to serialize only the store paths actually shipped in the image.
# Its closure metadata also covers filesystem wrappers copied to /, which
# must not become registered store objects unless separately shipped there.
{
  pkgs,
  image,
  nixStorePrefix,
}:
let
  storePaths = pkgs.runCommand "image-store-paths" { nativeBuildInputs = [ pkgs.jq ]; } ''
    jq -r --arg prefix ${pkgs.lib.escapeShellArg "${nixStorePrefix}/"} \
      "[.layers[].paths[] | select(.options.rewrite.repl == \$prefix) | .path] | unique[]" \
      ${image} > "''${out}"
  '';
  registration = image.exportNixRegistration { inherit storePaths; };
in
pkgs.runCommand "system-image-registration" { } ''
  mkdir -p "''${out}"
  cp ${storePaths} "''${out}/store-paths"
  cp ${registration} "''${out}/registration"
''
