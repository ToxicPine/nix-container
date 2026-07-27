{ pkgs }:

pkgs.runCommand "fast-vms-benchmark-1m.bin" { } ''
  dd if=/dev/zero of="$out" bs=1M count=1 status=none
''
