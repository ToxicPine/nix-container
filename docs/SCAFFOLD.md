# System scaffold

`fs/nix/system.nix` declares the packages, accounts, services and image settings
for both image builds and runtime refresh. Start with the [template usage](../README.md#configure-the-system).

## Overlays and components

A system overlay receives `{ pkgs, sources, lib, infuse, ... }` and returns a
`final: prev:` function. Overlays run in order: `prev` contains earlier results,
and `final` refers to the completed system. The scaffold supplies a base
component with the Nix daemon.

```nix
{ infuse, ... }:
final: prev:
infuse prev {
  components.local.__init = {
    packages = [ final.pkgs.ripgrep final.pkgs.rsync ];
    services.metrics = {
      process.argv = [ "${final.pkgs.python3}/bin/python" "-m" "http.server" "9100" ];
    };
    image.files."/etc/example.conf" = final.pkgs.writeText "example.conf" "hello\n";
  };
  components.home-manager.__init = final.callComponent ./home-manager.nix {
    users.alice.uid = 1000;
    rebuildOnBoot = false;
  };
  image.name.__assign = "my-environment";
  image.exposedPorts.__append = [ 9100 ];
}
```

`final.callComponent` supplies `pkgs`, `sources`, `lib` and `userRuntimeRoot`
to a constructor and gives its result `.override` support. All components use
the final package set. An additional overlay can modify inputs or results:

```nix
{ infuse, ... }:
final: prev:
infuse prev {
  components.home-manager.__input.users.bob.__init = { uid = 1001; };
  components.local.packages.__append = [ final.pkgs.jq ];
}
```

| Infuse operation | Effect |
| --- | --- |
| `__init` | Add a definition; fail if it already exists. |
| `__assign` | Replace a value. |
| `__append` | Extend a list. |
| `__input` | Override constructor arguments and recompute its result. |

Apply constructor input changes before direct result edits: a later input
override replaces those edits. Plain Nix overlays merge shallowly, so returning
`{ components.foo = ...; }` replaces the whole `components` attribute.

Both `nix/default.nix` and `lib/fs/scaffold/default.nix` accept `overlays`, a
list of paths or functions with the shape above. The image defaults to
`fs/nix/system.nix`, followed by `lib/overlays/home-manager`; supplying a list
replaces those defaults. The scaffold alone defaults to `[]`.

Runtime refresh uses only `/opt/app/nix/system.nix`. Include shared runtime
policy in that persistent configuration; extra image-build overlays do not
persist automatically.

## Component fields

Fields are optional; collections default to empty and `enable` to `true`.
Unknown top-level, component, account and image fields are rejected. Disabled
components do not evaluate their declarations; runtime evaluation leaves
image-only contributions lazy.

| Field | Contract |
| --- | --- |
| `enable` | Set to `false` to omit the component. |
| `packages` | Packages added to the generation's `sw` environment and PATH. Conflicting paths fail the build. |
| `users` | Named accounts with required `uid`; optional `gid` (defaults to UID), `shell`, `description`, `extraGroups`. Homes are `/home/<name>`, backed by `/data/homes/<name>`. |
| `groups` | Named groups with required `gid` and optional `members`. Each user also gets a same-named private group; supplementary groups must be declared. |
| `services` | Named nix-supervise system services. Use store paths for executables. |
| `image.storePaths` | Extra store sources carried by the image without adding programs to PATH. |
| `image.files` | Absolute destinations mapped to source files. Executable modes are preserved. |
| `image.trees` | Absolute destinations mapped to source directories. |
| `image.order` | Integer layer order, default 100; ties sort by component name. |
| `image.maxLayers` | Positive layer budget, default 1. |

A user, group or service can belong to only one component; override its owner
to change it. Within a component, `image.files` and `image.trees` destinations
must be normalized absolute paths with no overlapping roots. There are no
runtime `files` or `seeds` fields. Mutable initialization belongs in application
startup or provisioning code.

## Refresh and persistence

| Change | Apply with |
| --- | --- |
| System packages, accounts or services | Edit the persistent `system.nix`, then run `refresh-system` as root. |
| Home Manager packages, files or services | Edit `~/.nixcfg/home.nix`, then run `refresh-system` as that user. |
| Image files, trees, hooks or other `image.*` settings | Rebuild the image and replace the container. |

Root refresh builds, selects and applies a generation in
`/nix/var/nix/profiles/system`. Account reconciliation then selects its package
environment through `/run/current-system`. Boot applies the saved root generation,
or the factory generation if no usable profile exists, without evaluating Nix.
A failed apply never falls back to another generation.

System and Home Manager services default to **`s6.restartOnChange = true`**:
refresh restarts a service when its rendered definition or selected environment
changes. Set it to `false` per service to defer changes until the service next
starts. Unchanged services keep running. Package or account changes also restart
services depending on `system-resources`; the base Nix daemon stays up.

Keep `/nix` and `/data` across container replacement to retain generations,
configuration, accounts and homes. Image contents do not overwrite existing
persistent configuration. For store initialization details, see
[upper and lower stores](UPPER_LOWER.md).

### Accounts and Home Manager

The configuration is authoritative: refresh removes undeclared accounts and
groups, while retaining homes. Passwords survive updates, but deleting an
account removes its password record; recreating it starts locked. UID/GID
conflicts fail before account writes and require an explicit ownership migration.
When adopting existing volumes, declare every account to retain with its current
UID and GID. Shadow manages passwords, database locks and subuid/subgid ranges.

Boot creates missing baseline identities (`root`, `sshd`, `nobody`, `nixbld`)
without Nix evaluation, preserving existing settings and rejecting identity
conflicts. Refresh also restores missing baseline accounts. The image starts
as numeric `0:0`; named OCI `--user` overrides cannot resolve against its
initially empty account databases.

The build-only `lib/overlays/home-manager` overlay adds account hooks, factory
configurations and optional prebuilt profiles. Its options are `buildProfiles`
(default `true`) and `factoryConfigDir` (default `fs/hm-user`). Apply it after
runtime constructor overrides; it contributes nothing when HM is absent or disabled.

HM's useradd hook seeds configuration from `/opt/defaults/hm-user/<name>`, or
`/opt/defaults/skel/.nixcfg` as a fallback, preserving initialized configuration.
Startup restores links to existing configurations. Root can initialize an
existing account without one using `SYSTEM_IMAGE_USER=<name> reset-system`.
HM boot activation and rebuilding are controlled by `activateOnBoot` and
`rebuildOnBoot`; see the [template options](../README.md#configure-the-system).

Executable account hooks belong in `image.files` under `/etc/shadow-maint`.
Changing hooks requires container replacement; runtime refresh uses the installed
hooks. During reconciliation, `SYSTEM_RESOURCES_APPLY=1` tells HM's userdel hook
that supervision already handled stopping dependent services.

### Failures

Evaluation or build failure leaves the existing profile and live system alone.
After activation starts, accounts, files and services may be partially changed:
activation is not transactional and does not automatically roll back. A failed
root apply leaves the new profile selected; rerun after correcting the cause.
Old generations are available for recovery, but switching profiles does not
restore mutable data or apply services by itself. Stale Shadow locks may need
recovery after a killed process.

HM checks file collisions before its write boundary; failures after that point
may leave partial changes. With `rebuildOnBoot = true`, a failed build does not
activate the old HM profile, so user services may remain down on fresh boot.

## Image layers

Components render after all overlays run. The image contains core and supervision
layers, ordered component layers, and a final backend/generation layer. Each
component includes its package, service and image-source closures; store paths
already in preceding layers are deduplicated. Total layer budgets are capped at 125.
Inspect `componentLayers` and `componentFilesystems` on the image result.

Across components, later layers win overlapping file paths and directories merge
under OCI rules. Backend files in the final layer take precedence. Shared
dependencies can affect several layers, so components do not guarantee independent
rebuilds. Store content is relocated to `/nix-base`; registration retains its real
`/nix/store` identities and is merged into the persistent store at boot.

## Verification

Run `nix-build tests --no-out-link`, or select a check with `-A <name>`:

| Check | Coverage |
| --- | --- |
| `scaffold` | Overlays, overrides, laziness and schema rejection. |
| `boot` | Saved/factory generation selection and failure handling. |
| `home-manager` | Build-only hook integration. |
| `layers` | Deduplication, relocation and unchanged-layer reuse. |
| `image` | Registration, layer placement and installed files. |
| `vm` | Container lifecycle and live service updates under podman. |

The VM needs KVM. Its offline guest uses a prebuilt runtime closure in
`tests/vm.nix`; add dependencies there when extending runtime scenarios.
