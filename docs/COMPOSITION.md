# System composition

`fs/nix/system.nix` is the entry point for both the image and the running
system. It is a function receiving `{ pkgs, sources, lib, infuse, ... }` and
returning a `final: prev:` overlay. The wrapper supplies a base component with
the Nix daemon, applies an ordered list of these overlays, and finally
validates and renders the result.

This follows SixOS's use of ordinary Nix functions, constructor arguments and
an overlay fixed point. We vendor upstream Infuse 2.6 unchanged, including its
MIT notice; see `lib/fs/nix-base/vendor/README.md`. The container backend
is local code. The service compiler and Home Manager still use their existing
module evaluators internally.

Both `nix/default.nix` and `lib/fs/nix-base/default.nix` accept `overlays`.
Every entry has the same shape as `system.nix` and can be a file path or a
function. The evaluator supplies the requested arguments, including the final
`pkgs` and `sources`. Entries run from left to right; `prev` includes preceding
overlays and `final` sees the completed composition.

```nix
import ./nix {
  overlays = [
    ./fs/nix/system.nix
    ./site.nix
    ({ infuse, ... }: final: prev: infuse prev {
      image.name.__assign = "my-container";
    })
    (import ./lib/modules/home-manager { buildProfiles = false; })
  ];
}
```

The image entry point defaults to the `fs/nix/system.nix` overlay followed by
`import ../lib/modules/home-manager { }`; supplying a list replaces those
defaults. The bare `nix-base` evaluator defaults to `[]`,
which keeps only its base component. The old singular `configuration` argument
is replaced by an entry in this list; extra entries now use the same argument
function as the first entry, rather than bare `final: prev:` functions.

Runtime refresh passes `[ /opt/app/nix/system.nix ]`. Extra overlays passed
only to an image build are not automatically persisted for later refreshes;
shared runtime policy must also be included by the persistent configuration.
`lib/image.nix` imports n2c internally using the composed package set.

`lib/modules/home-manager/default.nix` is a build-only overlay constructor.
Its `buildProfiles` option defaults to `true`; `factoryConfigDir` defaults to
`fs/hm-user`. It adds the account hooks, per-user factory configurations and
optional prebuilt profiles to the existing `home-manager` component's image
contribution. Apply it after overlays that change the runtime constructor's
inputs. It contributes nothing when that component is absent or disabled.

The build-only Nix implementation and hook templates stay outside `fs/` and
are not copied into `/opt/app` or `/opt/defaults`. The rendered executable
hooks are installed in `/etc/shadow-maint`, and the factory files and profiles
are installed at their `/opt/defaults` destinations. Runtime refresh needs
only `fs/nix/home-manager.nix` and its activation script to reconstruct the
account and service declarations; it does not import the image integration.

## Evaluator layout

The files in `lib/fs/nix-base` follow the evaluation flow:

| File | Responsibility |
| --- | --- |
| `default.nix` | Apply defaults and overlays, then check the complete top-level field set. |
| `schema.nix` | Validate and normalize component, account and image declarations. |
| `base.nix` | Supply the default Nix daemon component. |
| `accounts.nix` | Add private groups and package the account manifest and reconciliation service. |
| `reconcile-accounts.nix` | Build the shared executable used by bootstrap and runtime reconciliation. |
| `finalize.nix` | Collect component contributions, build the package environment and compile the supervision generation. |
| `scripts/plan-accounts.jq` | Check declared identities against the live account databases and plan ownership changes. |
| `scripts/reconcile-accounts.sh` | Apply that plan through Shadow and select the package environment. |

The schema checks declaration values; collection rejects duplicate owners and
account preparation checks private-group compatibility. The upstream service
evaluator validates service options. Runtime account checks additionally need
the mutable databases, which are unavailable during Nix evaluation.

Unknown top-level fields are rejected before projection onto the public
composition result. Image fields remain lazy, and disabled components do not
force their declarations. `lib/image.nix` consumes the normalized components
to prepare store references and OCI layers; runtime finalization does not
prepare image-layer metadata.

## Declare and override components

A component is an ordinary attribute set, optionally returned by a constructor.
`final.callComponent` supplies `pkgs`, `sources`, `lib`, and `userRuntimeRoot`
to constructors and gives their results `.override` support. It uses the final
package set, so package overrides are visible to every component.

```nix
{ infuse, ... }:
final: prev:
infuse prev {
  components.local.__init = {
    image.order = 10;
    packages = [ final.pkgs.ripgrep final.pkgs.rsync ];
  };
  components.home-manager.__init = final.callComponent ./home-manager.nix {
    users.alice.uid = 1000;
    rebuildOnBoot = false;
  };
  components.example.__init = {
    packages = [ final.pkgs.hello ];
    services.example.process.argv = [ "${final.pkgs.hello}/bin/hello" ];
    image = {
      order = 20;
      files."/etc/example.conf" = final.pkgs.writeText "example.conf" "greeting = hello\n";
      files."/etc/example-image-version" = final.pkgs.writeText "version" "1\n";
    };
  };
  image.name.__assign = "my-environment";
  image.exposedPorts.__append = [ 8080 ];
}
```

The template keeps its default tools directly in `system.nix`, in
`components.local`. Ad-hoc services and resources can go in that same component
and share its layer. Separate components provide separate layer groups;
separate source files are only an organizational choice. `image.order` controls
the order of those groups, not where their definitions must live.

Use Infuse to update nested fields. A plain Nix overlay returning
`{ components.foo = ...; }` replaces the entire `components` attribute, as
normal shallow overlay composition does.

An additional overlay can change constructor inputs or the resulting fields:

```nix
{ infuse, ... }:
final: prev:
infuse prev {
  components.home-manager.__input.users.bob.__init = { uid = 1001; };
  components.local.packages.__append = [ final.pkgs.jq ];
  components.example.enable.__assign = false;
}
```

`__init` rejects an existing definition, `__assign` replaces it, `__append`
extends a list, and `__input` invokes the constructor's `.override`. Changing
inputs recomputes the constructor. A subsequent input override also replaces
any direct edits made to that constructor's result, so apply input changes
before editing the result. Disable a component with `enable = false`.

## Component contract

Every field is optional; collections default to empty and `enable` to true.
Unknown component, account and image fields are errors.

| Field | Meaning |
| --- | --- |
| `packages` | Packages in the selected generation's `sw` environment. Its `bin` directory is on the container's PATH. Conflicting package paths fail the environment build. |
| `users` | Named accounts: required `uid`; optional `gid` (defaults to UID), `shell`, `description`, `extraGroups`. Homes are `/home/<name>`, backed by `/data/homes/<name>`. |
| `groups` | Named groups: required `gid`, optional `members`. Every user also gets a same-named private group. Supplementary groups must be declared. |
| `services` | Named declarations using the nix-supervise system service schema. Executables should use store paths. |
| `image.storePaths` | Additional store sources carried by the image, without exposing their programs on PATH. |
| `image.files` | Absolute image destinations mapped to source files, copied into the component's layer. |
| `image.trees` | Absolute image destinations mapped to source directories, copied into the component's layer. |
| `image.order` | Integer layer ordering key; defaults to 100. Equal values sort by component name. |
| `image.maxLayers` | Positive layer budget; defaults to 1. |

Two components cannot own the same user, group or service.
Override the owning component to change its declaration. Within one component, `image.files` and `image.trees`
destination roots must not overlap: these are copied into a single filesystem
fragment, with no layer ordering between them. Separate components may
contribute overlapping image paths; their layers use OCI precedence.

Runtime components do not expose `files` or `seeds`. Use `image.files` and
`image.trees` for filesystem content; their destinations must be normalized
absolute paths. Existing runtime `files` declarations must move to `image.files`
and require an image rebuild. Application-specific mutable initialization belongs
to that application's startup or provisioning code.

Account hooks are an image-level choice. For example, a component in
`system.nix` can contribute an executable hook:

```nix
image.files."/etc/shadow-maint/useradd-post.d/70-example" =
  pkgs.writeShellScript "example-useradd-hook" ''
    : "''${SUBJECT:?useradd did not provide SUBJECT}"
    ${pkgs.coreutils}/bin/echo "Created $SUBJECT" >&2
  '';
```

Use an executable source (`writeShellScript`, or an executable in a package).
The image renderer preserves its executable mode. HM installs its three hooks
this way, alongside the backend's generic home hook. Installing, changing or
removing hooks requires rebuilding and replacing the container; `refresh-system`
changes accounts and services but leaves the installed hooks in place.

Account reconciliation exports `SYSTEM_RESOURCES_APPLY=1`. HM's userdel hook
skips the service stop in this context because s6 already stopped dependent
services. Its useradd hook initializes configuration for both declared and
manually created accounts, selecting `/opt/defaults/hm-user/<name>` before
falling back to `/opt/defaults/skel/.nixcfg`. It preserves initialized user
configuration and sets ownership and permissions only on newly copied files.
On container startup, the entrypoint restores `/opt/app/hm-user/<name>` links
to existing configurations. It does not seed or repair user configuration;
existing accounts without one can be initialized by root with
`KELLINGRAD_USER=<name> reset-system`.

## Generation and mutable state

Finalization creates a `system-resources` oneshot and makes every declared
service depend on it. This reconciles accounts through Shadow, then
switches `/run/current-system` to the generation's resource tree. The tree
contains the package environment and the account manifest. The
oneshot has `restartOnChange`, so changing resources causes dependent services
to stop before realization and restart afterwards. This is deliberately a
coarse dependency boundary: even package changes currently restart those
services. Unchanged generations preserve the existing service transition rules.

The root generation contains its service bundle, resource tree and package
environment. `refresh-system` builds it from the persistent configuration,
selects it in the root profile, and applies it. Runtime evaluation does not
force image-only profile builds or require n2c.

`refresh-system` contains the Nix build expression, using absolute `/opt/app`
imports for the system and Home Manager configurations. It builds and applies
the result explicitly. Boot selects the saved root profile, or the factory
generation when no usable profile exists, and applies it without evaluating Nix.
A failed apply is reported without trying another generation.

Automatic refresh can be implemented as a separate service if needed. Such a
service must coordinate a later transition without waiting on an apply that
needs its own startup or shutdown to finish; it is not a prerequisite oneshot
that recursively applies the tree currently starting it. No automatic refresh
service is supplied by the backend.

Accounts declared by components are authoritative for their names. Their
shells, descriptions and group memberships are reconciled; removing their
declarations removes the accounts and stops dependent services. Homes remain.
The Bash account reconciler delegates account changes to the image's patched
`useradd`, `usermod`, `userdel`, `groupadd`, `groupmod`, and `groupdel` commands.
Passwords survive updates. Deletion uses normal Shadow behavior: homes remain,
but password records are removed and a recreated account starts locked.
Unmanaged users and built-in accounts remain in the database. Shadow manages
subuid/subgid ranges according to the persistent account-tool configuration.

Baseline identities are defined once in `lib/fs/nix-base/baseline-accounts.nix` and embedded in
the entrypoint, which passes them through stdin. There is no installed baseline
JSON file. The image carries empty account databases.
After restoring the store, the entrypoint invokes the prebuilt account program
with `--bootstrap`, before calling Nix or starting supervision. No Nix
evaluation is needed to create `root`, `sshd`, `nobody` and the shared `nixbld`
build-user pool. This uses the same Shadow application code as declared users.

Bootstrap creates missing identities and ensures required group memberships.
It preserves existing passwords, account settings and extra memberships, and
rejects conflicting UIDs/GIDs. It does not delete accounts or publish a
generation or write an ownership record. Runtime Nix imports the same baseline
definition into each desired configuration, so refresh also restores missing
core accounts and ensures their required memberships. No baseline history or
second built-in name list is maintained. The image starts as
numeric `0:0`; an OCI `--user root` override
cannot resolve a name from its initially empty `/etc/passwd`.

The backend records ownership in `/data/system/resources/owned.json` with mode
0600. This contains only declared account names and numeric IDs, allowing
withdrawn declarations to be removed while preserving manually created accounts.
Inputs, planning results and loop data stay in memory or flow through pipes;
only atomic ownership replacement needs a temporary file. Unchanged ownership
is not rewritten. Shadow owns the account database writes and their locks; the wrapper
serializes resource applications with a separate lock. Do not edit declared accounts
concurrently or use account tools as a second source of their configuration.
Standard tools remain usable for unmanaged accounts and password changes.
UID/GID mismatches fail before writing account files: migrating identities and
existing file ownership requires an explicit migration. When adopting an old
volume, declare its existing GID if it differs from the UID.

The ownership journal and selected-generation link are replaced atomically,
but a complete apply across account-tool invocations and services is not a transaction. The journal
allows an interrupted apply to be retried; a failed apply can have made partial
progress and does not automatically select the factory generation. A process
killed while holding account locks can leave `.lock` files requiring stale-lock
recovery. Mutable data is not included in generation rollback.

## Image rendering

The image renderer consumes the same finalized components. It emits stable
supervision and core runtime layers, ordered component layers, and a final
layer containing the aggregate generation, environment/boot links and store
registration. Each component carries the closure of its packages, service
references and image-only roots. n2c excludes store paths
already carried by explicitly supplied preceding layers. `lib/build-oci-layers.nix`
uses the all-prior-layers fold described in the guide linked from upstream's
README; this requires no change to n2c's layering implementation. The default
template produces six layers.

An overlay is a transformation of a description, not an OCI filesystem diff.
Components are rendered only after all overlays have run. Layer boundaries
remain named and inspectable through `componentLayers` and
`componentFilesystems` on the image result. Total layer budgets are capped at
125. Shared dependencies and ordering can change several layers; this is a
cache boundary, not a guarantee of independent rebuilds.

Composition determines the final declarations of each component, including
its `image.order`. If two components still supply the same image file, the
later layer wins; directories merge according to OCI rules. The backend
filesystem is always emitted in the final layer, so its files take precedence
over component contributions at the same paths. To change a component's
declaration before rendering, override that component in an overlay. Runtime
mounts and account provisioning then determine the running container's mutable
paths; image contents alone do not override existing persistent data.

All layers retain the `/nix-base` relocation patch. Registration comes directly
from n2c's closure metadata. The `export-nix-registration.patch` factors out
n2c's existing registration serializer and exposes `image.exportNixRegistration`.
`lib/export-nix-store-registration.nix` supplies the exact inventory from the
content image, so filesystem wrappers copied to `/` are excluded unless also
shipped as store objects. Requested paths without metadata fail the build.
There is no database variant of the image, SQLite database, or `nix-store`
invocation in this export path. The final image uses the same content definitions
with `store-paths` and `db-base` added to the last filesystem fragment, without
an extra layer. n2c's existing `initializeNixDatabase` option remains available
and uses the same serializer, but this image does not need it.

The exports retain real `/nix/store` identities. At boot, static tools use the
inventory to seed missing store paths, including the filesystem and socket
lower-store modes. Once Nix is runnable, entrypoint merges the registration
into the persistent database. The patched account tools and nss-altfiles
still use `/data/etc`.

Changing `image.*` requires rebuilding and replacing the container. Changing
packages, accounts and services can be applied by runtime refresh. The entrypoint
and HM provisioning initialize their own persistent state without overwriting
existing user configuration.

## Verification

From the repository root:

```sh
nix shell nixpkgs/nixpkgs-unstable#python3 nixpkgs/nixpkgs-unstable#jq nixpkgs/nixpkgs-unstable#util-linux nixpkgs/nixpkgs-unstable#bubblewrap -c bash tests/resources.sh
nix-instantiate --eval --strict tests/composition.nix
nix-build tests/layers.nix --no-out-link
nix-build tests/image.nix --no-out-link
nix-build nix -A rootFilesystem --no-out-link
nix-build nix --no-out-link
```

The resource tests run the real patched Shadow tools and home hook in private
mount and PID namespaces with temporary account files. The runner needs Linux
user namespaces and subordinate UID/GID mappings (`/etc/subuid` and `/etc/subgid`).
