# Core identities shared by image bootstrap and runtime reconciliation.
{ lib }:
let
  buildUsers = lib.genList (index: "nixbld${toString (index + 1)}") 10;
  user = uid: gid: description: home: shell: {
    inherit
      uid
      gid
      description
      home
      shell
      ;
    extraGroups = [ ];
  };
in
{
  users = {
    root = user 0 0 "root" "/root" "/bin/bash";
    sshd = user 65533 65533 "sshd" "/var/empty" "/bin/false";
    nobody = user 65534 65534 "nobody" "/nonexistent" "/bin/false";
  }
  // lib.listToAttrs (
    lib.imap0 (index: name: {
      inherit name;
      value = user (
        30001 + index
      ) 30000 "Nix build user ${toString (index + 1)}" "/var/empty" "/bin/false";
    }) buildUsers
  );
  groups = {
    root = {
      gid = 0;
      members = [ ];
    };
    sshd = {
      gid = 65533;
      members = [ ];
    };
    nobody = {
      gid = 65534;
      members = [ ];
    };
    nixbld = {
      gid = 30000;
      members = buildUsers;
    };
  };
}
