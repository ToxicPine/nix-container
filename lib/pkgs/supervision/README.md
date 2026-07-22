# Container supervision bootstrap

This directory owns only the container boundary around `nix-supervise`:

1. The image entrypoint reconstructs the writable Nix store and persistent
   home links, then `exec`s `s6-linux-init` as PID 1.
2. The root `s6-svscan` tree supervises the Nix daemon and one outer
   `nix-supervise-tree-run` process for each configured Home Manager user.
3. `rc.init` starts every user tree before activating the users' Home Manager
   generations. The upstream Home Manager module renders and applies each
   user's services to its already-running tree.
4. `rc.shutdown` stops the outer tree processes. Their upstream runner performs
   the dependency-aware `s6-rc` shutdown before exiting.

`s6-linux-init/default.nix` constructs the PID-1/root scan tree and keeps
reconstruction of its shutdown FIFO inside the generated init wrapper. The
other package directories contain the image-specific account discovery and
dynamic root-tree adapters. Service schema, rendering, application, online
updates, observation policy, and the user-tree runtime contract come from the
pinned `nix-supervise` source.

The generated root tree is disposable image state. Its scan is copied to
`/run/service`; `nix-supervise` user trees live below
`/run/nix-supervise/users`. `system-image-register-user-tree` only publishes an
upstream runner into that root tree; it does not implement a second user tree
runtime.
