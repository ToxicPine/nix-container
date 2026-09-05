# Container supervision bootstrap

This directory owns only the container boundary around `nix-supervise`. The
goal is that as little as possible is fixed by the image:

1. The image entrypoint reconstructs the writable Nix store, account files,
   persistent homes, and the root configuration link, then `exec`s
   `s6-linux-init` as PID 1. s6 can assume a complete environment.
2. The PID 1 scan supervises exactly one image-defined service: a root-owned
   `nix-supervise-tree-run` in fixed mode at `/run/nix-supervise/system`.
3. `rc.init` runs `system-image-boot`, which waits for that tree, then applies
   a generation to it: the root profile at `/nix/var/nix/profiles/system` if
   present, otherwise the factory generation at
   `/opt/defaults/system-generation`. Boot never evaluates Nix for the root
   tree. A failed apply is reported without switching to another generation:
   a failed service must not replace the selected system with factory defaults.
4. `rc.shutdown` brings the root tree service down. Its runner performs the
   dependency-ordered `s6-rc` shutdown of everything it supervises, user trees
   included, before s6-linux-init's final teardown.

The generation is produced by `lib/fs/system-base`, a standalone system-scope
producer built from nix-supervise's library pieces (the service submodule, the
system-scope renderer, and the fixed tree contract). The base is only what
every image needs: `tree.nix` fixes the root tree's paths on top of
upstream's portable system-scope module and exposes the generation plus a
build-time `factory` interface for defaults the image must carry; `services.nix` contributes `nix-daemon`, with readiness
polled through the daemon socket; `users.nix` gives each
`users.<name>` an `account-<name>` oneshot that runs `useradd`
when the account is absent.

Home Manager is a module the system configuration imports,
`fs/system/home-manager.nix`. It extends users with `homeManager.*` and,
for each enabled user, adds:

- `home-<name>`, a oneshot that reconstructs the persistent home, seeds
  `~/.nixcfg` from `/opt/defaults/hm-user/<name>` or the skeleton while it is
  empty, and links `/opt/app/hm-user/<name>`;
- `tree-<name>` and `apply-<name>`, rendered by upstream's
  `lib.hostAdapter.renderS6Services`: a longrun for the user tree runner,
  ready through its notification descriptor, and a oneshot that runs the
  activation script as the user once the tree and the daemon are up. Home
  Manager's own activation step applies the user's services into the
  already-running tree, so `refresh-system` for users is unchanged.

It also publishes prebuilt generations for declared users through the factory
interface, so the image installs them without knowing what they are.

Users come from `fs/system/system.nix` and nowhere else. The image build
evaluates the repository copy into the factory generation; `refresh-system`
as root evaluates the persistent copy in `/data/system/nixcfg`, so adding a
user at runtime is the same declaration followed by a refresh, and the change
goes live through `s6-rc-update` like everything else. The `userdel` hook
only stops the user's tree; the account database is not consulted to decide
what runs.

## What is immutable

| Scope | Content | Changes with |
| --- | --- | --- |
| Per boot | PID 1 `s6-svscan`, its scandir, and the root tree runner | container restart |
| Per image | the factory generation, used only as a fallback | image rebuild |
| Runtime | everything the root tree supervises, including the s6 and nix-supervise versions in use | `refresh-system` as root |

## Upstream dependencies

The image relies on three `nix-supervise` changes that live on its
`codex/system-composition` branch, which extends `portable-system-tree` and
which the pin under `fs/hm-base/npins` tracks until the changes land on `main`:
the portable system-scope module and
`lib.evalSystemServices`, readiness notification from the tree runner
(`nix-supervise-tree-run -n`), and the s6-rc host adapter renderer. Nothing
here reimplements them.

## Verification

Run the boot-selection regression tests from the repository root:

```sh
nix shell nixpkgs/nixpkgs-unstable#python3 -c python3 -m unittest discover -s tests -v
```

The pinned nix-supervise branch also checks standalone generation assertions
and verifies that changed child apply commands and triggers change the apply
service definition without changing the child scan service.
