#!/usr/bin/env bash
# PoC for the proposed system detector rule: omit host.id when the machine-id
# comes from a container. See README.md.
#
# Requirements: a Docker engine (Linux, Docker Desktop, colima, ...) that allows --privileged.
# Everything else (Go toolchain, containerd, systemd-nspawn, LXC) runs inside containers.
#
# Usage: ./run.sh            # run every scenario, exit 1 on any failure
#        KEEP=1 ./run.sh     # keep the built images afterwards
set -euo pipefail

cd "$(dirname "$0")"
POC_DIR=$PWD
OUT=$POC_DIR/out
FIX=$OUT/fixtures
mkdir -p "$OUT"

DIND_IMAGE=docker:27-dind
GO_IMAGE=golang:1.23
ALPINE=alpine:3.20
DIND=hostid-poc-dind
VOLUME=hostid-poc-machines
LXC_VOLUME=hostid-poc-lxc

PASS=0 FAIL=0 SKIP=0
RESULTS=$OUT/results.txt
: >"$RESULTS"

cleanup() {
	docker rm -f "$DIND" >/dev/null 2>&1 || true
	docker volume rm -f "$VOLUME" "$LXC_VOLUME" >/dev/null 2>&1 || true
	if [[ -z ${KEEP:-} ]]; then
		docker rmi -f hostid-poc/baked-alpine hostid-poc/debian-dbus hostid-poc/ubuntu-systemd \
			hostid-poc/fedora-systemd hostid-poc/nspawn hostid-poc/lxc >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

log() { printf '%s\n' "$*" | tee -a "$RESULTS"; }

# record NAME EXPECTED OUTPUT [MUST_HAVE_SIGNAL] [MUST_NOT_HAVE_SIGNAL]
# EXPECTED is a regex over the verdict word, e.g. "DISTRUST" or "TRUST|NO_ID".
record() {
	local name=$1 expected=$2 output=${3//$'\r'/} must=${4:-} mustnot=${5:-}
	local verdict signals ok=1
	verdict=$(sed -n 's/^VERDICT: \([A-Z_]*\).*/\1/p' <<<"$output")
	signals=$(sed -n 's/^SIGNALS: //p' <<<"$output")
	[[ $verdict =~ ^($expected)$ ]] || ok=0
	[[ -z $must || ",$signals," == *",$must,"* ]] || ok=0
	[[ -z $mustnot || ",$signals," != *",$mustnot,"* ]] || ok=0
	if ((ok)); then
		PASS=$((PASS + 1))
		log "PASS  $name"
	else
		FAIL=$((FAIL + 1))
		log "FAIL  $name   (expected verdict=$expected${must:+ with $must}${mustnot:+ without $mustnot})"
	fi
	sed 's/^/        /' <<<"$output" | tee -a "$RESULTS"
}

skip() {
	SKIP=$((SKIP + 1))
	log "SKIP  $1   ($2)"
}

# in_container IMAGE [docker run args...]: run the classifier as the container's PID 1.
in_container() {
	local image=$1
	shift
	docker run --rm "$@" -v "$OUT/classify:/classify:ro" --entrypoint /classify "$image" 2>&1
}

# on_host CMD: run CMD in the Docker host's namespaces (the VM for Docker Desktop/colima).
on_host() {
	docker run --rm --privileged --pid=host -v "$OUT:/out:ro" "$ALPINE" sh -c "
		cp /out/classify /proc/1/root/tmp/hostid-classify
		nsenter -t 1 -m -u -i -n -p -- $1
		rc=\$?; rm -f /proc/1/root/tmp/hostid-classify; exit \$rc" 2>&1
}

echo "==> building classifier with $GO_IMAGE"
docker run --rm -v "$POC_DIR/classify:/src:ro" -v "$OUT:/out" -w /src -e CGO_ENABLED=0 -e GOCACHE=/tmp/gocache \
	"$GO_IMAGE" go build -trimpath -o /out/classify . >/dev/null

echo "==> building scenario images"
for image in baked-alpine debian-dbus ubuntu-systemd fedora-systemd nspawn lxc; do
	docker build -q -t "hostid-poc/$image" -f "images/$image.Dockerfile" images >/dev/null
done

HOST_HAS_ID=0
if on_host "/bin/sh -c 'test -s /etc/machine-id'" >/dev/null; then HOST_HAS_ID=1; fi
HOST_HAS_SYSTEMD=0
if on_host "/bin/sh -c 'command -v systemd-run'" >/dev/null; then HOST_HAS_SYSTEMD=1; fi
host_service() { on_host "systemd-run --quiet --wait --pipe $1 -p BindReadOnlyPaths=/tmp/hostid-classify /tmp/hostid-classify"; }

log ""
log "## Host (the Docker host / VM itself)"
record "H1 host" "TRUST|NO_ID" "$(on_host /tmp/hostid-classify)"
if ((HOST_HAS_SYSTEMD)); then
	record "H2 host systemd service with ProtectSystem=strict, PrivateMounts, PrivateTmp, DynamicUser" "TRUST|NO_ID" \
		"$(host_service "-p ProtectSystem=strict -p PrivateMounts=yes -p PrivateTmp=yes -p DynamicUser=yes")"
	record "H3 host systemd service bind-mounting /etc/resolv.conf and /etc/hosts" "TRUST|NO_ID" \
		"$(host_service "-p BindReadOnlyPaths=/etc/resolv.conf -p BindReadOnlyPaths=/etc/hosts")"
else
	skip "H2/H3 host systemd services" "no systemd on the Docker host"
fi

log ""
log "## Docker"
record "C1 alpine (no machine-id)" "NO_ID" "$(in_container "$ALPINE")"
record "C2 ubuntu:24.04 (empty machine-id)" "NO_ID" "$(in_container ubuntu:24.04)"
record "C3 image with synthetic baked machine-id" "DISTRUST" "$(in_container hostid-poc/baked-alpine)" "etc-hostname-mount"
record "C4 debian:12 + dbus (baked /var/lib/dbus/machine-id)" "DISTRUST" "$(in_container hostid-poc/debian-dbus)"
record "C5 ubuntu:24.04 + systemd (baked /etc/machine-id)" "DISTRUST" "$(in_container hostid-poc/ubuntu-systemd)"
record "C6 fedora:41 + systemd (baked /etc/machine-id)" "DISTRUST" "$(in_container hostid-poc/fedora-systemd)"
record "C7 baked id, --privileged --pid=host --network=host --cgroupns=host" "DISTRUST" \
	"$(in_container hostid-poc/baked-alpine --privileged --pid=host --network=host --cgroupns=host)"
record "C8 baked id, non-root user 10001" "DISTRUST" "$(in_container hostid-poc/baked-alpine --user 10001)"
if ((HOST_HAS_ID)); then
	record "C9 host /etc/machine-id bind-mounted read-only" "TRUST" \
		"$(in_container "$ALPINE" -v /etc/machine-id:/etc/machine-id:ro)"
else
	skip "C9 host machine-id bind mount" "Docker host has no /etc/machine-id"
fi

log ""
log "## Kubernetes-like (CRI runtimes create no /.dockerenv; emulated by deleting it)"
record "K1 CRI-like hostPID container, baked id, no marker files" "DISTRUST" \
	"$(docker run --rm --pid=host -v "$OUT/classify:/classify:ro" --entrypoint sh hostid-poc/ubuntu-systemd \
		-c 'rm -f /.dockerenv /run/systemd/container; /classify' 2>&1)" "etc-hostname-mount" "dockerenv"
record "K2 KUBERNETES_SERVICE_HOST set" "DISTRUST" \
	"$(in_container hostid-poc/baked-alpine -e KUBERNETES_SERVICE_HOST=10.96.0.1)" "k8s-env"

log ""
log "## Nested containers (Docker-in-Docker) and plain containerd"
docker rm -f "$DIND" >/dev/null 2>&1 || true
dind_args=(-d --privileged --name "$DIND" -e DOCKER_TLS_CERTDIR= -v "$OUT:/out:ro")
((HOST_HAS_ID)) && dind_args+=(-v /etc/machine-id:/host-machine-id:ro)
docker run "${dind_args[@]}" "$DIND_IMAGE" >/dev/null
for _ in $(seq 1 60); do docker exec "$DIND" docker info >/dev/null 2>&1 && break; sleep 1; done
docker save hostid-poc/baked-alpine | docker exec -i "$DIND" docker load -q >/dev/null
docker exec "$DIND" sh -c "echo fedcba9876543210fedcba9876543210 > /etc/machine-id"
inner() { docker exec "$DIND" docker run --rm -v /out/classify:/classify:ro --entrypoint /classify "$@" 2>&1; }

record "N1 outer dind container with its own baked id" "DISTRUST" "$(docker exec "$DIND" /out/classify)"
record "N2 inner container, no machine-id" "NO_ID" "$(inner "$ALPINE")"
record "N3 inner container, outer container's /etc/machine-id bind-mounted" "DISTRUST" \
	"$(inner -v /etc/machine-id:/etc/machine-id:ro "$ALPINE")"
if ((HOST_HAS_ID)); then
	record "N4 inner container, host machine-id passed through both levels" "TRUST" \
		"$(inner -v /host-machine-id:/etc/machine-id:ro "$ALPINE")"
else
	skip "N4 host machine-id passed through dind" "Docker host has no /etc/machine-id"
fi
CTR="ctr -a /run/docker/containerd/containerd.sock -n poc"
docker save hostid-poc/baked-alpine | docker exec -i "$DIND" $CTR images import - >/dev/null
record "N5 KNOWN GAP: plain containerd (ctr/runc, no runtime /etc files, no marker files), baked id" "TRUST" \
	"$(docker exec "$DIND" $CTR run --rm --mount type=bind,src=/out/classify,dst=/classify,options=rbind:ro \
		docker.io/hostid-poc/baked-alpine:latest poc-n5 /classify 2>&1)"
docker rm -f "$DIND" >/dev/null

log ""
log "## systemd-nspawn (rootfs on an ext4 volume, Alpine payload without systemd)"
docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
docker create --name hostid-poc-export hostid-poc/baked-alpine >/dev/null
docker export hostid-poc-export >"$OUT/baked-rootfs.tar"
docker container rm -f hostid-poc-export >/dev/null
nspawn() {
	docker run --rm --privileged -e SYSTEMD_NSPAWN_UNIFIED_HIERARCHY=1 -v "$OUT:/out:ro" -v "$VOLUME:/var/lib/machines" \
		hostid-poc/nspawn sh -c "
		rm -rf /var/lib/machines/m && mkdir -p /var/lib/machines/m && tar -C /var/lib/machines/m -xf /out/baked-rootfs.tar
		rm -f /var/lib/machines/m/.dockerenv   # docker export leaks it into the rootfs
		$1
		systemd-nspawn --register=no --keep-unit -q -D /var/lib/machines/m --bind-ro=/out/classify:/classify /classify" 2>&1 |
		grep -v 'Attempted to remove disk file system'
}
record "S1 nspawn, baked machine-id, classifier as PID 1" "DISTRUST" "$(nspawn true)" "boot-id-mount" "dockerenv"
record "S2 nspawn, empty machine-id" "NO_ID" "$(nspawn ': > /var/lib/machines/m/etc/machine-id')" "container-env"

log ""
log "## LXC with a non-systemd init (busybox template, rootfs on an ext4 volume)"
lxc() { # lxc EXTRA_CONFIG ATTACH_ARGS
	local args=(--rm --privileged --cgroupns=host -v "$OUT:/out:ro" -v "$LXC_VOLUME:/var/lib/lxc")
	((HOST_HAS_ID)) && args+=(-v /etc/machine-id:/host-machine-id:ro)
	docker run "${args[@]}" hostid-poc/lxc bash -c "
		rm -rf /var/lib/lxc/bb && lxc-create -n bb -t busybox >/dev/null 2>&1
		R=/var/lib/lxc/bb/rootfs
		echo 0123456789abcdef0123456789abcdef > \$R/etc/machine-id
		cp /out/classify \$R/classify
		printf 'lxc.net.0.type = empty\nlxc.apparmor.profile = unconfined\n$1' >> /var/lib/lxc/bb/config
		lxc-start -n bb -d && sleep 2
		lxc-attach -n bb --clear-env $2 -- /classify
		lxc-stop -n bb -k >/dev/null" 2>&1
}
# lxc-attach sets $container, but the classifier is not PID 1, so only the boot_id mount counts.
record "L1 LXC busybox init, baked id, root, not PID 1" "DISTRUST" "$(lxc "" "")" "boot-id-mount" "container-env"
record "L2 LXC busybox init, baked id, uid 1000, not PID 1" "DISTRUST" "$(lxc "" "-u 1000 -g 1000")" "boot-id-mount"
if ((HOST_HAS_ID)); then
	record "L3 LXC busybox init, host machine-id bind-mounted (lxc.mount.entry)" "TRUST" \
		"$(lxc 'lxc.mount.entry = /host-machine-id etc/machine-id none bind,ro,create=file 0 0\n' "")"
else
	skip "L3 LXC host machine-id bind mount" "Docker host has no /etc/machine-id"
fi

log ""
log "## Fixtures (environments that cannot run here)"
rm -rf "$FIX"
fixture() { # fixture NAME: creates a minimal host-like tree with an ext4 root and a machine-id
	local d=$FIX/$1
	mkdir -p "$d/proc/self" "$d/proc/sys/kernel" "$d/etc" "$d/run/systemd"
	echo '26 1 253:1 / / rw,relatime shared:1 - ext4 /dev/root rw' >"$d/proc/self/mountinfo"
	echo 6.8.0-generic >"$d/proc/sys/kernel/osrelease"
	echo 3f880a9b355748508fb4b42163805ed1 >"$d/etc/machine-id"
	echo "$d"
}
fixture plain-host >/dev/null
d=$(fixture wsl2) && echo 5.15.167.4-microsoft-standard-WSL2 >"$d/proc/sys/kernel/osrelease"
d=$(fixture wsl1) && echo 4.4.0-19041-Microsoft >"$d/proc/sys/kernel/osrelease"
d=$(fixture openvz) && mkdir -p "$d/proc/vz"
d=$(fixture openvz-host-node) && mkdir -p "$d/proc/vz" "$d/proc/bc"
d=$(fixture lxc-systemd) && echo lxc >"$d/run/systemd/container"
d=$(fixture lxc-boot-id) && echo '40 26 0:50 /.lxc-boot-id /proc/sys/kernel/random/boot_id ro,nosuid - tmpfs none rw' >>"$d/proc/self/mountinfo"
d=$(fixture podman) && touch "$d/run/.containerenv"
d=$(fixture overlay-root-host) && echo '26 1 0:30 / / rw,relatime - overlay overlay rw' >"$d/proc/self/mountinfo"
d=$(fixture dockerenv-host) && touch "$d/.dockerenv"
fx() { local name=$1; shift; docker run --rm "$@" -v "$OUT:/out:ro" "$ALPINE" /out/classify -root "/out/fixtures/$name" 2>&1; }
record "F1 plain host (control)" "TRUST" "$(fx plain-host)"
record "F2 WSL2 osrelease" "DISTRUST" "$(fx wsl2)" "wsl-osrelease"
record "F3 WSL1 osrelease" "DISTRUST" "$(fx wsl1)" "wsl-osrelease"
record "F4 OpenVZ container (/proc/vz, no /proc/bc)" "DISTRUST" "$(fx openvz)" "openvz"
record "F5 OpenVZ host node (/proc/vz and /proc/bc)" "TRUST" "$(fx openvz-host-node)"
record "F6 container running systemd as init (/run/systemd/container)" "DISTRUST" "$(fx lxc-systemd)" "systemd-container"
record "F7 LXC/nspawn boot_id bind mount" "DISTRUST" "$(fx lxc-boot-id)" "boot-id-mount"
record "F8 Podman (/run/.containerenv)" "DISTRUST" "$(fx podman)" "containerenv"
record "F9 \$container set for PID 1 (Podman, LXC, nspawn)" "DISTRUST" "$(fx plain-host -e container=podman)" "container-env"
record "F10 host process with \$container set, not PID 1" "TRUST" \
	"$(docker run --rm -e container=oci -v "$OUT:/out:ro" "$ALPINE" sh -c '/out/classify -root /out/fixtures/plain-host; true' 2>&1)"
record "F11 host with an overlay root (live ISO, Raspberry Pi overlay file system)" "TRUST" "$(fx overlay-root-host)"

log ""
log "## Known false positives (asserting the current, documented behaviour)"
record "X1 host image built from docker export (leaked /.dockerenv)" "DISTRUST" "$(fx dockerenv-host)" "dockerenv"
if ((HOST_HAS_SYSTEMD)); then
	record "X2 host systemd service with BindReadOnlyPaths=/etc/hostname" "DISTRUST" \
		"$(host_service "-p BindReadOnlyPaths=/etc/hostname")" "etc-hostname-mount"
else
	skip "X2 host systemd service binding /etc/hostname" "no systemd on the Docker host"
fi

log ""
log "SUMMARY: $PASS passed, $FAIL failed, $SKIP skipped (full output in out/results.txt)"
((FAIL == 0))
