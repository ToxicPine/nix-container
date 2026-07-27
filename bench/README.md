# Benchmark workflow

The two targets run the same pinned nginx package, the same
[`nginx.conf`](../fs/nginx.conf), one worker process, no access log, the same
small response, and the same generated 1 MiB store object on port 8080:

- the container's `user` Home Manager profile declares nginx to
  `nix-supervise`;
- the VM's NixOS module declares nginx directly as a systemd service.

Home Manager generations are built into the container image. The configuration
is not evaluated or rebuilt at launch. Normal first-use activation may still
initialize mutable user profile state, so that belongs to per-instance
preparation and is preserved outside measured launches.
Both images retain internal package management: the container has its
persistent private Nix database/store upper, and the VM runs the Nix daemon
against its writable instance disk.

## Build and prepare VMs

Build the upstream NixOS repart image and create all independent instances
before taking measurements:

```sh
nix build .#vm-image
nix run .#prepare-vm -- ./instances/vm-{01..08}
```

Each directory contains a small writable qcow2 layer referring to the immutable
raw image in the Nix store. Treat the resulting set as benchmark input. Do not
run `prepare-vm`, copy disks, reset overlays, or build Nix derivations inside a
measured interval.

Resolve the launcher before a timed block. User networking is a diagnostic
convenience path:

```sh
nix build .#run-vm -o result-run-vm
result-run-vm/bin/run-vm --host-port 18081 ./instances/vm-01
```

Do not put `nix run` evaluation in a measured interval. The headline path uses
one TAP/vhost interface per instance on the prepared benchmark bridge, plus a
unique private IPv4 address and locally administered unicast MAC:

```sh
result-run-vm/bin/run-vm \
  --tap tap-vm01 \
  --guest-ip 192.0.2.11/24 \
  --mac 02:00:00:00:00:11 \
  ./instances/vm-01
```

Free-page reporting is enabled by default while the guest-visible RAM remains
fixed. Run the non-KSM headline arm with the command above. Run the separately
reported KSM arm with the same prepared inputs and add `--ksm`; that marks the
QEMU RAM backend mergeable but does not mutate the host's global KSM policy.
Enable and tune host KSM before timing, keep transparent huge pages off, wait
until `pages_sharing` changes by less than 1% over 30 seconds, and charge
`ksmd` CPU to the VM arm. Afterward request unmerge, wait for sharing to reach
zero, and verify KSM is off before another arm.

For mechanism-attribution runs, `--free-page-reporting off` provides the
otherwise-identical control. Keep the primary production-like non-KSM and KSM
comparisons on the default `on` setting.

Active virtio-balloon inflation is a further, separately labelled arm. Create
a unique QMP socket for the instance and have the external benchmark harness
issue QMP's standard `balloon` command with a pinned byte target after
readiness:

```sh
result-run-vm/bin/run-vm \
  --qmp ./instances/vm-01/qmp.sock \
  --tap tap-vm01 \
  --guest-ip 192.0.2.11/24 \
  --mac 02:00:00:00:00:11 \
  ./instances/vm-01
```

For example, 192 MiB is QMP target value `201326592`. The target is usable
guest RAM; it does not change the configured 256 MiB maximum. Do not poll for
convergence in the benchmark. Wait the same fixed 30-second settling interval
after issuing the command, then record memory, pressure, and service health.
Restore the QMP target to `268435456` and allow the same settling interval
before reusing that prepared instance in a non-balloon arm. Do not fold active
inflation into launch-to-ready or the default VM result.

Choose and record `PAGES_TO_SCAN` and `SLEEP_MILLISECONDS` once for the KSM
suite. When operating the launchers manually, immediately before that suite
verify no non-VM workload has registered mergeable memory, then configure and
start KSM outside the measured launch:

```sh
ksm=/sys/kernel/mm/ksm
printf '%s\n' "$PAGES_TO_SCAN" |
  sudo tee "$ksm/pages_to_scan" >/dev/null
printf '%s\n' "$SLEEP_MILLISECONDS" |
  sudo tee "$ksm/sleep_millisecs" >/dev/null
printf '1\n' | sudo tee "$ksm/run" >/dev/null
```

At every density point, sample `pages_shared`, `pages_sharing`,
`pages_unshared`, `pages_volatile`, `full_scans`, and the `ksmd` task's CPU.
Do not record settled memory until `pages_sharing` changes by less than 1% over
30 seconds. After the KSM arm, unmerge synchronously and leave KSM stopped:

```sh
ksm=/sys/kernel/mm/ksm
printf '2\n' | sudo tee "$ksm/run" >/dev/null
while [[ $(<"$ksm/pages_sharing") -ne 0 ]]; do
  sleep 0.1
done
printf '0\n' | sudo tee "$ksm/run" >/dev/null
[[ $(<"$ksm/run") -eq 0 && $(<"$ksm/pages_sharing") -eq 0 ]]
```

KSM's cross-guest anonymous-page merging has a different side-channel risk
from deliberate sharing of immutable store files; report it as a separate
security/performance tradeoff, never as an unlabelled VM result.

When using the automated `run-benchmark --ksm` path below, leave KSM stopped
with zero shared pages. The runner performs the same enablement before the
first baseline, waits for stability, accounts `ksmd` CPU, unmerges at cleanup,
and restores the original scan tunables.

Create and attach the bridge, external client endpoint, TAPs, routes, and
addresses before timing. Bring every link up with the same MTU and transmit
queue length, and give each instance a unique address and MAC. The VM path uses
vhost-net; the container path uses its native veth/network-namespace path.
Do not claim identical offload implementations—the two stacks expose different
features. Record that as part of the mechanism rather than disabling supported
production acceleration without evidence. The launcher refuses TAP mode
without explicit address and MAC values. Probe the guest directly at
`http://GUEST_IP:8080/`; no NAT or host forwarding belongs in a headline run.

Before the timed block, also validate each overlay with `qemu-img check`, place
the launcher process in its already-created cpuset cgroup, and establish the
required cache condition. The vCPU and vhost workers then inherit that cgroup.
Do not pre-open KVM/vhost, preboot the guest, or prestart nginx.

## Run containers

Build the container image and launcher using the existing project targets,
create one OCI bundle and one private storage set per instance as described in
[`RUNNING-CONTAINER.md`](../RUNNING-CONTAINER.md), then launch:

```sh
nix build .#run-container -o result-run-container
result-run-container/bin/run-container \
  ./instances/container-01/bundle container-01
```

The launcher refuses bundles that do not expose a prepared writable OverlayFS
at `/nix/store`, a private `/nix`, and the read-only Snix socket directory at
`/lower-store`.

## Measurement rules

Use the same instance count, nginx readiness probe, CPU placement, cache state,
and repetition order for all three benchmark arms: container, VM without KSM,
and VM with KSM. Prepare every target before starting a run. Record wall-clock
time from runner invocation to the first successful HTTP response. For density
measurements, use the same fixed stabilization window after all instances are
ready so guest free-page reporting and container page reclamation can settle
before memory is sampled.

For VMs, include the QEMU processes, vhost kernel threads, and `ksmd` CPU where
applicable. For gVisor, include runsc Sentry/Gofer processes and instance
private tmpfs/overlay memory. Use whole-host memory deltas as the primary
density measure because shared page cache cannot be attributed reliably.
Report PSS, RSS, cgroup `memory.current`, and `memory.stat` as explanatory
breakdowns.
Run warm-cache and explicitly cold-cache experiments separately; do not drop
host caches between individual instances in the same sample.

The checked-in `BENCHMARKING.md` and draft `BLOG.md` predate several explicit
run decisions. The executable core protocol uses the later decisions:

- a fixed container, VM-without-KSM, VM-with-KSM order with a return-to-idle
  thermal gate, rather than randomized order;
- the same six-core target-deployment cpuset for launch, density, and nginx,
  rather than changing the deployment CPU envelope between tests;
- an exact 16 GiB observed deployment-memory envelope, plus a separate host
  safety reserve, rather than deriving the headline envelope from all host RAM;
- 256 MiB as fixed maximum guest-visible VM RAM with free-page reporting on,
  so unused backing can be reclaimed; active balloon inflation remains a
  separate optional mechanism experiment.

Those choices must be described when publishing results. The current automated
core suite does not implement the draft's minimal-readiness-daemon control or
secondary I/O/CPU/SQLite workloads. Do not imply that it does, and do not fill
claims depending on those controls from core-suite output.

## Automated core suites

Build the runner and summarizer before a measured session:

```sh
nix build .#run-benchmark -o result-run-benchmark
nix build .#run-paired-benchmark -o result-run-paired-benchmark
nix build .#summarize-benchmark -o result-summarize-benchmark
nix build .#summarize-benchmark-storage -o result-summarize-benchmark-storage
nix build .#evict-private-cache -o result-evict-private-cache
nix build .#benchmark-helpers -o result-benchmark-helpers
nix build .#prepare-benchmark-cgroups -o result-prepare-benchmark-cgroups
nix build .#prepare-benchmark-host -o result-prepare-benchmark-host
nix build .#prepare-density-pilot -o result-prepare-density-pilot
nix build .#size-benchmark-pools -o result-size-benchmark-pools
nix build .#prepare-benchmark -o result-prepare-benchmark
nix build .#run-core-benchmark -o result-run-core-benchmark
```

The runner consumes a JSON manifest shaped like
[`benchmark-manifest.example.json`](benchmark-manifest.example.json). Commands
are argv arrays and are never evaluated by a shell. Every entry describes a
fully prepared instance, its direct HTTP URL, and its cleanup command when the
foreground launcher cannot clean the runtime up by itself. Density manifests
label two disjoint prepared instance pools with `ramp` values 1 and 2.
Reusing the same writable VM disk or container state across ramps is invalid.
Optional per-instance `prepare` and `cleanup` command lists attach and detach
already-defined host resources outside the launch timer. Use them for the
instance's TAP or veth endpoint and, on the container path, its prepared
OverlayFS mount. This keeps setup out of launch latency while charging the
resources to density only while that instance is active. Each instance names
the resulting host-side `network_interface`; the runner verifies it before
launch and the performance suite reads its byte counters around every measured
interval.
Generated cleanup commands also sync and evict each stopped instance's private
qcow2 or container-state cache. They do not evict the shared VM base image,
container root filesystem, or Snix data.

`residency_files` names the fixed working-set manifest sampled with `fincore`:
the VM base image for the conventional arm and the corresponding Snix blob
files for the shared-store arm. Keep that list fixed across both targets and
all repetitions.

On this host, disable SMT and use this physical-core allocation:

- target deployment: CPUs `4-9`, all six Zen 5c cores;
- external benchmark client: CPU `3`, a Zen 5 core;
- host housekeeping: CPUs `0-2`, three Zen 5 cores;
- offline SMT siblings: CPUs `10-19`.

Create two exclusive cgroup v2 partition roots under a common empty benchmark
partition. Put the runner itself in the client partition. The runner moves all
target processes—including QEMU/vhost or runsc/Snix/FUSE—into the one target
cgroup before exec. A single target cgroup avoids scheduler-weight artifacts
from a hierarchy of per-instance CPU cgroups.

The preflight requires the configured and effective CPU sets to match, the
target and client sets to be disjoint exclusive partition roots, and both
`cpu.max` and `memory.max`/`memory.high` to be unlimited. CPU capacity comes
from exclusive physical cores, not quota-period throttling. Fix frequency,
disable boost, keep SMT/swap/THP off, keep KSM off except in its labelled arm,
move unrelated work and IRQs to housekeeping CPUs, and keep the host quiet.
The runner also requires irqbalance to be stopped and the global unbound
workqueue mask to equal the declared housekeeping CPUs. It refuses a measured
suite when the controls it can verify disagree.

Apply the recorded, reversible host controls first. The state directory must
not already exist; it is retained until restoration:

```sh
sudo result-prepare-benchmark-host/bin/prepare-benchmark-host \
  apply /var/lib/fast-vms/benchmark-host-state 4-9 3 0-2

sudo result-prepare-benchmark-cgroups/bin/prepare-benchmark-cgroups \
  create /sys/fs/cgroup/fast-vms 4-9 3
```

The host tool disables SMT, swap, THP and THP defrag, boost, and irqbalance;
fixes CPUs `3-9` to the lowest common ACPI CPPC nominal frequency; moves
configurable IRQs and unbound workqueues to CPUs `0-2`; verifies the three CPU
sets partition the resulting online CPUs; and rolls back automatically if
preparation fails. The environment record captures requested and current
frequency values for every target and client CPU.
Per-CPU or managed IRQs that reject runtime affinity changes remain a recorded
host limitation. For the lowest possible noise, boot once with matching
`irqaffinity`, `nohz_full`, and `rcu_nocbs` CPU isolation rather than pretending
runtime affinity can eliminate those kernel interruptions.

Enter the client partition before starting either the single-target or paired
runner:

```sh
sudo result-benchmark-helpers/bin/cgroup-exec \
  /sys/fs/cgroup/fast-vms/client \
  result-run-paired-benchmark/bin/run-paired-benchmark ...
```

Remove the empty hierarchy and restore the saved host controls after the
complete session:

```sh
sudo result-prepare-benchmark-cgroups/bin/prepare-benchmark-cgroups \
  remove /sys/fs/cgroup/fast-vms

sudo result-prepare-benchmark-host/bin/prepare-benchmark-host \
  restore /var/lib/fast-vms/benchmark-host-state
```

Use separate manifests for host-cold and cross-instance-warm conditions because
their cache hooks differ. A host-cold manifest must provide a
`before_sample` hook which both establishes and verifies the declared cache
state. A cross-instance-warm manifest must provide a `before_suite` hook that
starts, exercises, and stops a disposable prepared instance and verifies the
second fixed-working-set read is stable. Hooks run outside measured launch
intervals. The launch runner independently rejects cold residency at or above
one percent and records the full `fincore` snapshot for every cold or warm
sample. Density is intentionally warm-only; dropping caches between additions
would invalidate the live ramp.

For a standalone arm, capture the environment with:

```sh
result-run-benchmark/bin/run-benchmark \
  environment \
  --output ./bench/results/vm-warm/environment \
  ./manifests/vm-warm.json
```

The three-arm coordinator performs this capture automatically for container,
VM without KSM, and VM with KSM before establishing the thermal baseline.

Run fixed three-arm blocks in this order: container, VM without KSM, then VM
with KSM. Before each block, the coordinator records a stable idle
CPU-temperature baseline, then waits for the selected sensor to remain at or
below that block's declared baseline ceiling before every arm. For a
cross-instance-warm launch, this wait occurs after the warm-up and immediately
before the timed launch. A per-block baseline follows slow ambient drift
without giving any arm a different thermal starting rule. A cooler host is
accepted because boost is disabled and the benchmark CPUs run at a fixed
frequency; rejecting it can deadlock a long low-CPU density ramp as the host
cools below its initial idle temperature. The KSM scan policy is fixed once and
supplied to the same coordinator:

```sh
result-run-paired-benchmark/bin/run-paired-benchmark \
  launch \
  --container ./manifests/container-warm.json \
  --vm-no-ksm ./manifests/vm-warm.json \
  --vm-ksm ./manifests/vm-ksm.json \
  --output ./bench/results/launch-warm \
  --blocks 30 \
  --ksm-pages-to-scan "$PAGES_TO_SCAN" \
  --ksm-sleep-ms "$SLEEP_MILLISECONDS" \
  --temperature-sensor /sys/class/hwmon/hwmon4/temp1_input \
  --temperature-tolerance-millicelsius 1000 \
  --temperature-stable-seconds 30 \
  --temperature-timeout-seconds 900

result-run-paired-benchmark/bin/run-paired-benchmark \
  density \
  --container ./manifests/container-warm.json \
  --vm-no-ksm ./manifests/vm-warm.json \
  --vm-ksm ./manifests/vm-ksm.json \
  --output ./bench/results/density-warm \
  --blocks 2 \
  --ksm-pages-to-scan "$PAGES_TO_SCAN" \
  --ksm-sleep-ms "$SLEEP_MILLISECONDS" \
  --temperature-sensor /sys/class/hwmon/hwmon4/temp1_input \
  --temperature-tolerance-millicelsius 1000 \
  --temperature-stable-seconds 30 \
  --temperature-timeout-seconds 900 \
  -- \
  --memory-envelope-gib 16

result-run-paired-benchmark/bin/run-paired-benchmark \
  nginx \
  --container ./manifests/container-warm.json \
  --vm-no-ksm ./manifests/vm-warm.json \
  --vm-ksm ./manifests/vm-ksm.json \
  --output ./bench/results/nginx-warm \
  --blocks 5 \
  --ksm-pages-to-scan "$PAGES_TO_SCAN" \
  --ksm-sleep-ms "$SLEEP_MILLISECONDS" \
  --temperature-sensor /sys/class/hwmon/hwmon4/temp1_input \
  --temperature-tolerance-millicelsius 1000 \
  --temperature-stable-seconds 30 \
  --temperature-timeout-seconds 900
```

The hwmon number can change after boot. Resolve the `k10temp` `Tctl` input on
the benchmark host immediately before the run and record the resolved path.

### Observe capacity before preparing the full pools

Pool capacity is not inferred from the VM's 256 MiB maximum. First prepare one
independent 16-instance pilot ramp for each arm:

```sh
sudo result-prepare-density-pilot/bin/prepare-density-pilot \
  --instances 16 \
  /var/lib/fast-vms/density-pilot
```

Run only that pilot ramp through the same host controls, cgroups, fixed arm
order, KSM policy, load, settling rules, and exact 16 GiB envelope:

```sh
sudo result-run-core-benchmark/bin/run-core-benchmark \
  --work-root /var/lib/fast-vms/density-pilot \
  --output ./bench/results/density-pilot \
  --suite density \
  --density-blocks 1 \
  --ksm-pages-to-scan "$PAGES_TO_SCAN" \
  --ksm-sleep-ms "$SLEEP_MILLISECONDS"
```

Turn the three observed post-load regression slopes into pool sizes. The
projection includes 25% whole-instance headroom plus eight instances and uses
the larger VM projection for both VM arms:

```sh
result-size-benchmark-pools/bin/size-benchmark-pools \
  ./bench/results/density-pilot/density/summary.json \
  ./bench/results/density-pilot/pool-sizes.json

sudo result-prepare-benchmark/bin/prepare-benchmark \
  --pool-sizes ./bench/results/density-pilot/pool-sizes.json \
  --preparation-jobs 8 \
  --asset-root /var/lib/fast-vms/density-pilot/assets \
  /var/lib/fast-vms/core-benchmark
```

The pilot's private instances are never reused for measured results. Only its
immutable image/Snix assets are reused. A full density ramp that nevertheless
ends with `manifest_exhausted` remains censored; prepare a larger fresh pool
and repeat it rather than converting the projection into a result.
The preparation job count only parallelizes untimed first-use initialization
of independent container state. Each ramp waits for all of its jobs before
reusing endpoint indices in the next ramp.

`run-core-benchmark --suite ...` can run the four suites separately into one
output root. Each invocation uses a distinct saved host-state directory and
refuses to replace that suite's existing result directory. This is the
practical recovery boundary; an individual three-arm block is still
append-free and must finish as one unit.

The density envelope is exactly 16 GiB (`17179869184` bytes) of observed
whole-deployment physical residency relative to the quiet pre-platform
baseline. Residency is `MemTotal - MemFree`, so shared file cache is counted
once rather than incorrectly discounted as merely reclaimable. `MemAvailable`
is separately used to preserve the host safety reserve. No VM count is derived
from 256 MiB configured RAM, and no per-instance memory limit is imposed.

Density traffic comes from one bounded Go process with lightweight per-target
workers, not one `oha` process per instance. It schedules the same fixed rate
for every URL, validates the exact response body, applies coordinated-omission
correction by measuring from the scheduled request time, and retains
per-instance errors and p99 latency. This prevents the load generator itself
from consuming memory proportional to the instance count in heavyweight client
processes.

The runner first measures a four-instance checkpoint, then estimates marginal
post-load memory from settled checkpoints. The estimate is the larger of the
whole-run average and a median of recent pairwise slopes, plus the declared
prediction margin. It adds half of the predicted remaining capacity at a time,
with a default cap of 64 instances per batch. When no more than eight instances
are predicted to fit, it switches to single additions. Every checkpoint still
loads and validates every active instance.

If a batch crosses the envelope or service SLO, the runner records that failed
upper bound, removes and discards the whole batch, and retries halfway between
the last healthy and failed counts with fresh prepared instances. The stopped
instances' private file cache is evicted before refinement. The last few
additions are tested individually, so batching does not turn the maximum into a
projection. Each raw point records its batch size and all instances added at
that checkpoint. An adjacent failing count first found as part of a larger
batch is confirmed with a fresh single-instance addition. If that confirmation
passes, the failed bound is discarded and the ramp continues.

Before every launch within a batch, the runner rechecks `MemAvailable` and
requires the host reserve plus 512 MiB of transient headroom. It checks the
reserve again after readiness. This protects the KSM arm from using its smaller
settled, post-merge marginal cost as though all of that sharing existed while a
new batch was still starting.

Manifest exhaustion or the host safety reserve censors the capacity result
instead of presenting it as a measured maximum. The density client is also
measured around every load interval; reaching 90% utilization of its dedicated
core censors the ramp as client-limited rather than misreporting a target
capacity. Readiness failures are retained as `density_failure` records and
censor the affected ramp for investigation.

The summary reports the exact maximum healthy post-load count and the greatest
idle-ready count observed along the same trajectory. The latter is descriptive,
not a separately searched idle-only capacity boundary.

The KSM manifest must contain `--ksm` in every VM launch array; the non-KSM
manifest must not. The coordinator passes the KSM controls only to the KSM
arm. Each invocation starts with KSM stopped and zero shared pages, then
unmerges and restores the host KSM controls before the next thermal gate.
While enabled, `ksmd` is affinitized to the same six target CPUs as QEMU, so
the scanner cannot borrow capacity from housekeeping; its CPU time is also
reported separately.

The runner emits append-free JSONL streams, refuses to overwrite an existing
run, preserves per-arm logs, records thermal gating and the explicit
three-element arm order, and produces `summary.json` without editing the blog.
Every combined raw record and summary group has a `benchmark_arm` value of
`container`, `vm-no-ksm`, or `vm-ksm`. The summary contains the launch
median/p95/failures, regression-based marginal idle and post-load bytes,
uncensored maximum healthy counts, and nginx throughput/latency/error/CPU
figures needed by the result tables. Every nginx block includes the 10-second
warm-up and 60-second matrix; only the first block per arm adds the single
600-second, concurrency-32 sustained sample required by the agenda. Its raw
records also include whole-host CPU utilization, sampled peak and steady
resident memory, host-interface network bytes, and `ksmd` CPU. Summary medians
include deterministic 2,000-resample 95% bootstrap intervals for the headline
launch, marginal-memory, capacity, throughput, and p99 metrics.

The storage table is a separate post-workload calculation over a density pool
whose instances have all served the benchmark workload. It measures filesystem
allocated bytes, not apparent file size. Fixed container storage is the shared
root filesystem plus the Snix castore and path-info store; private container
storage is its OCI configuration, mutable data and Nix state, and store
upper/work directories. Fixed VM storage is the raw base image and direct-boot
artifacts; private VM storage is its qcow2 overlay. Calculate both capacities
inside the same explicit 16 GiB storage envelope:

```sh
sudo result-summarize-benchmark-storage/bin/summarize-benchmark-storage \
  /var/lib/fast-vms/density-pilot-results/density/paired-density.jsonl \
  /var/lib/fast-vms/density-pilot/assets \
  /var/lib/fast-vms/density-pilot/pools/container-density \
  /var/lib/fast-vms/density-pilot/pools/vm-no-ksm-density \
  ./bench/results/density-pilot/storage.json
```

The maximum in that JSON is an analytic storage-density result,
`floor((envelope - fixed) / median private allocation)`, rather than a claim
that thousands of otherwise idle instances were launched. Retain all raw
per-instance allocation observations with the result.
