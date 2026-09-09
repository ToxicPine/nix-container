# Container supervision bootstrap

This directory owns only the container boundary around `nix-supervise`. The
goal is that as little as possible is fixed by the image:

1. The image starts as numeric `0:0`. Its entrypoint reconstructs the writable
   Nix store, initializes missing account files, and runs the prebuilt account
   program with `--bootstrap` to ensure baseline identities exist. This happens
   before calling Nix or starting supervision. It then prepares persistent homes
   and the root configuration link and `exec`s `s6-linux-init` as PID 1.
2. The PID 1 scan supervises exactly one image-defined service: a root-owned
   `nix-supervise-tree-run` in fixed mode at `/run/nix-supervise/system`.
3. `rc.init` waits for that tree, then applies
   a generation to it: the root profile at `/nix/var/nix/profiles/system` if
   present, otherwise the factory generation at
   `/opt/defaults/system-generation`. Boot applies the saved generation without
   evaluating Nix. A failed apply is reported without switching to another
   generation: a failed service must not replace the selected system with
   factory defaults.
4. `rc.shutdown` brings the root tree service down. Its runner performs the
   dependency-ordered `s6-rc` shutdown of everything it supervises, user trees
   included, before s6-linux-init's final teardown.

The generation is produced by `lib/fs/scaffold`. It composes ordinary Nix
components through Infuse overlays, then renders their services with
nix-supervise's portable system-scope evaluator. `finalize.nix` fixes the root
tree's paths and assembles the generation; `base.nix` contributes `nix-daemon`
with socket readiness. `accounts.nix` prepares the `system-resources` oneshot
to reconcile declared accounts and select the package environment. Every
declared service outside the base component depends on it; `nix-daemon` stays
up across resource changes. Resource changes restart dependent services;
homes and other mutable state are retained.

Home Manager is a component constructor in `fs/nix/home-manager.nix`. For
each declared user it adds `tree-<name>` and `apply-<name>`, rendered by
upstream's `lib.hostAdapter.renderS6Services`: a longrun for the user tree
runner, ready through its notification descriptor, and a oneshot that runs
the activation script as the user once the tree and the daemon are up. Home
Manager's own activation step applies the user's services into the
already-running tree, so `refresh-system` for users is unchanged.

The build-only overlay in `lib/overlays/home-manager` adds factory
configurations, prebuilt profiles and account hooks to the same component's
image layer. `nix/default.nix` applies it after the runtime system overlay.
Its Nix implementation and hook templates are not copied into `/opt/app` or
`/opt/defaults`; runtime refresh does not import them.
The template's `fs/skel/.nixcfg` supplies the HM fallback at
`/opt/defaults/skel/.nixcfg`; HM defaults are intentionally part of `fs/`.
The build-only HM overlay bakes its Shadow account hooks into the image using
`image.files`. For both manual and declarative account creation, the useradd
hook initializes `~/.nixcfg` from `/opt/defaults/hm-user/<name>` or the skeleton
and creates `/opt/app/hm-user/<name>`. Initialized configuration is preserved.
The entrypoint restores these links for existing accounts at startup without
copying configuration or changing its ownership or permissions.
The account backend calls the patched Shadow tools, so declarative and manual
account creation share the image's generic home hook. It also calls the same
home helper for adopted accounts and retries after interrupted provisioning.
Changing or disabling HM hooks requires rebuilding and replacing the container.
Runtime refresh leaves installed hooks in place. The template skeleton remains
available independently of the component.

Users come from `fs/nix/system.nix` and nowhere else. The image build
evaluates the repository copy into the factory generation; `refresh-system`
as root evaluates the persistent copy in `/data/system/nixcfg`, so adding a
user at runtime is the same declaration followed by a refresh, and the change
goes live through `s6-rc-update` like everything else. The `userdel` hook
stops the user's tree and removes its runtime directory; the account database
is not consulted to decide
what runs. The account reconciler removes every account the configuration
does not declare, using `userdel`. The hook skips its service stop when
`SYSTEM_RESOURCES_APPLY=1`, avoiding a nested s6 transition.
See `docs/SCAFFOLD.md` for the full scaffold and ownership contract.

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
nix-build tests -A boot --no-out-link
```

The full container lifecycle, including boot from the factory generation and
from a saved profile, runs under `nix-build tests -A vm`.

The pinned nix-supervise branch also checks standalone generation assertions
and verifies that changed child apply commands and triggers change the apply
service definition without changing the child scan service.
