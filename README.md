# host.id container detection PoC

Proof of concept for a proposal to the OpenTelemetry Collector
`resource_detection` processor: the `system` detector should not report a
container's own `/etc/machine-id` as `host.id`.

`classify/` implements the proposed algorithm as a standalone program, and
`run.sh` runs it in real hosts, containers, nested containers, systemd-nspawn
and LXC, plus file fixtures for environments that can't run locally. It asserts
the expected verdict for each scenario.

## Algorithm

1. Resolve the machine-id: `/etc/machine-id`, then `/var/lib/dbus/machine-id`.
   If none is found (missing, empty or `uninitialized`), emit no `host.id`
   (`NO_ID`).
2. If the machine-id file is itself a mount point in `/proc/self/mountinfo`:
   - fstype `overlay`, `aufs` or `fuse.fuse-overlayfs`: it was bind-mounted from
     another container's rootfs (container-in-container), so emit no `host.id`
     (`DISTRUST`);
   - otherwise it was explicitly mounted, e.g. from the host: use it (`TRUST`).
3. Otherwise, if any in-container signal applies, emit no `host.id`
   (`DISTRUST`); else use it (`TRUST`).

## In-container signals

| Name in the output | Signal | Container manager |
|---|---|---|
| `etc-hostname-mount` | `/etc/hostname` is a mount point | Kubernetes (CRI-O, containerd), Docker, Podman |
| `k8s-env` | `KUBERNETES_SERVICE_HOST` is set | Kubernetes |
| `dockerenv` | `/.dockerenv` exists | Docker |
| `containerenv` | `/run/.containerenv` exists | Podman |
| `container-env` | `$container` is non-empty, checked only when running as PID 1 | Podman, LXC, systemd-nspawn |
| `systemd-container` | `/run/systemd/container` exists | containers running systemd as init (LXC, nspawn) |
| `boot-id-mount` | `/proc/sys/kernel/random/boot_id` is a mount point | systemd-nspawn, LXC (also Incus, Proxmox) |
| `openvz` | `/proc/vz` exists and `/proc/bc` does not | OpenVZ |
| `wsl-osrelease` | `/proc/sys/kernel/osrelease` contains `Microsoft` or `WSL` | WSL |

No signal needs privileges or reads cgroups.

## Running

Requirements: a Docker engine that allows `--privileged` (Linux, Docker Desktop
or colima). The Go toolchain, containerd (`ctr`), systemd-nspawn and LXC all run
inside containers.

```sh
./run.sh           # builds everything, runs all scenarios, exits 1 on any failure
KEEP=1 ./run.sh    # keep the built images afterwards
```

Full output for every scenario is written to `out/results.txt`.

"Host" means the Docker host, which is the VM on Docker Desktop or colima. It is
reached with a privileged `--pid=host` container and `nsenter`. Scenarios that
need a host `/etc/machine-id` or host systemd are skipped when those are absent.

## Results

Verified on 2026-11-26 with colima (Ubuntu 24.04.4 VM, kernel 6.8.0-117,
cgroup v2, arm64) and Docker 29.5.2: **37 passed, 0 failed, 0 skipped**.

A mutation check (disabling the step-2 overlay rule and the PID 1 restriction of
`$container`) makes N3, L1 and F10 fail, so the assertions catch regressions.

| ID | Scenario | Verdict | Signals |
|---|---|---|---|
| H1 | Docker host | TRUST | – |
| H2 | Host systemd service with `ProtectSystem=strict`, `PrivateMounts`, `PrivateTmp`, `DynamicUser` | TRUST | – |
| H3 | Host systemd service bind-mounting `/etc/resolv.conf` and `/etc/hosts` | TRUST | – |
| C1 | alpine (no machine-id) | NO_ID | etc-hostname-mount, dockerenv |
| C2 | ubuntu:24.04 (empty machine-id) | NO_ID | etc-hostname-mount, dockerenv, systemd-container ¹ |
| C3 | Image with a synthetic baked machine-id | DISTRUST | etc-hostname-mount, dockerenv |
| C4 | debian:12 + dbus (baked `/var/lib/dbus/machine-id`) | DISTRUST | etc-hostname-mount, dockerenv |
| C5 | ubuntu:24.04 + systemd (baked `/etc/machine-id`) | DISTRUST | etc-hostname-mount, dockerenv, systemd-container ¹ |
| C6 | fedora:41 + systemd (baked `/etc/machine-id`) | DISTRUST | etc-hostname-mount, dockerenv |
| C7 | Baked id, `--privileged --pid=host --network=host --cgroupns=host` | DISTRUST | etc-hostname-mount, dockerenv |
| C8 | Baked id, non-root user | DISTRUST | etc-hostname-mount, dockerenv |
| C9 | Host `/etc/machine-id` bind-mounted | TRUST (own mount, ext4) | etc-hostname-mount, dockerenv |
| K1 | Kubernetes-like `hostPID` container: baked id, no `/.dockerenv` ² | DISTRUST | etc-hostname-mount |
| K2 | `KUBERNETES_SERVICE_HOST` set | DISTRUST | etc-hostname-mount, k8s-env, dockerenv |
| N1 | Docker-in-Docker: outer container with its own baked id | DISTRUST | etc-hostname-mount, dockerenv |
| N2 | Docker-in-Docker: inner container, no machine-id | NO_ID | etc-hostname-mount, dockerenv |
| N3 | Docker-in-Docker: inner container with the outer container's machine-id bind-mounted | DISTRUST (own mount, overlay) | etc-hostname-mount, dockerenv |
| N4 | Docker-in-Docker: inner container with the host's machine-id passed through both levels | TRUST (own mount, ext4) | etc-hostname-mount, dockerenv |
| N5 | **Known gap:** plain containerd (`ctr`/runc), baked id | TRUST | – |
| S1 | systemd-nspawn, Alpine payload, baked id, classifier as PID 1 | DISTRUST | container-env, boot-id-mount |
| S2 | systemd-nspawn, empty machine-id | NO_ID | container-env, boot-id-mount |
| L1 | LXC with busybox init, baked id, root, not PID 1 | DISTRUST | boot-id-mount |
| L2 | LXC with busybox init, baked id, uid 1000, not PID 1 | DISTRUST | boot-id-mount |
| L3 | LXC with busybox init, host machine-id bind-mounted (`lxc.mount.entry`) | TRUST (own mount, ext4) | boot-id-mount |
| F1 | Fixture: plain host | TRUST | – |
| F2/F3 | Fixture: WSL2 / WSL1 `osrelease` | DISTRUST | wsl-osrelease |
| F4 | Fixture: OpenVZ container | DISTRUST | openvz |
| F5 | Fixture: OpenVZ host node (`/proc/bc` present) | TRUST | – |
| F6 | Fixture: container running systemd as init | DISTRUST | systemd-container |
| F7 | Fixture: LXC/nspawn `boot_id` bind mount | DISTRUST | boot-id-mount |
| F8 | Fixture: Podman `/run/.containerenv` | DISTRUST | containerenv |
| F9 | Fixture: `$container` set for PID 1 | DISTRUST | container-env |
| F10 | Fixture: host process with `$container` set, not PID 1 | TRUST | – |
| F11 | Fixture: host with an overlay root (live ISO, Raspberry Pi overlay file system) | TRUST | – |
| X1 | **Known false positive:** host image built with `docker export` (leaked `/.dockerenv`) | DISTRUST | dockerenv |
| X2 | **Known false positive:** host systemd service with `BindReadOnlyPaths=/etc/hostname` | DISTRUST | etc-hostname-mount |

¹ The stock `ubuntu:24.04` image ships `/run/systemd/container`.
² Kubernetes runtimes create no `/.dockerenv`; the scenario emulates this by
deleting it, and the image's `/run/systemd/container`, inside a Docker container.

## Layout

```
run.sh               # builds everything, runs the scenarios, asserts verdicts
classify/main.go     # the algorithm (no dependencies; -root reads files from a fixture tree)
images/*.Dockerfile  # baked-id images, systemd-nspawn and LXC helpers
out/                 # generated: classifier binary, fixtures, results.txt
```
