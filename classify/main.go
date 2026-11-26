// Command classify implements the proposed algorithm for the resourcedetection
// processor's system detector: decide whether the machine-id visible to this
// process can be reported as host.id, or whether it comes from a container and
// host.id must be omitted.
//
// Output (stable, grep-able):
//
//	MACHINE_ID_PATH: <path or ->
//	MACHINE_ID_MOUNT: point=<mount point> fstype=<fs type>
//	SIGNALS: <comma-separated signal names or ->
//	VERDICT: TRUST|DISTRUST|NO_ID (<reason>)
//
// The -root flag prefixes every file read with a directory, so fixture trees can
// emulate environments that cannot be reproduced locally (WSL, OpenVZ).
package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

var root string

func p(path string) string { return filepath.Join(root, path) }

func exists(path string) bool { _, err := os.Stat(p(path)); return err == nil }

func readTrim(path string) (string, error) {
	b, err := os.ReadFile(p(path))
	return strings.TrimSpace(string(b)), err
}

type mount struct{ point, fstype string }

func unescape(s string) string {
	return strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, `\`).Replace(s)
}

// readMounts parses /proc/self/mountinfo (proc(5)): field 5 is the mount point,
// the first field after the " - " separator is the file system type.
func readMounts() []mount {
	f, err := os.Open(p("/proc/self/mountinfo"))
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []mount
	s := bufio.NewScanner(f)
	for s.Scan() {
		fl := strings.Fields(s.Text())
		for i, x := range fl {
			if x == "-" && i >= 5 && len(fl) > i+1 {
				out = append(out, mount{point: unescape(fl[4]), fstype: fl[i+1]})
				break
			}
		}
	}
	return out
}

// containing returns the topmost mount whose mount point is the longest prefix of path.
func containing(ms []mount, path string) (mount, bool) {
	var best mount
	found := false
	for _, m := range ms {
		if m.point == path || m.point == "/" || strings.HasPrefix(path, strings.TrimSuffix(m.point, "/")+"/") {
			if !found || len(m.point) >= len(best.point) {
				best, found = m, true
			}
		}
	}
	return best, found
}

func isMountPoint(ms []mount, path string) bool {
	m, ok := containing(ms, path)
	return ok && m.point == path
}

// isContainerFS reports the file systems used by container image layers.
func isContainerFS(fstype string) bool {
	switch fstype {
	case "overlay", "aufs", "fuse.fuse-overlayfs":
		return true
	}
	return false
}

// signals evaluates the "in-container" signals, in the order of the proposal's table.
func signals(ms []mount) []string {
	var out []string
	add := func(name string, ok bool) {
		if ok {
			out = append(out, name)
		}
	}
	// Kubernetes (CRI-O, containerd), Docker, Podman: runtime-generated /etc/hostname.
	add("etc-hostname-mount", isMountPoint(ms, "/etc/hostname"))
	// Kubernetes: injected into every pod.
	add("k8s-env", os.Getenv("KUBERNETES_SERVICE_HOST") != "")
	// Docker.
	add("dockerenv", exists("/.dockerenv"))
	// Podman.
	add("containerenv", exists("/run/.containerenv"))
	// Podman, LXC, nspawn: $container is set for PID 1 only, so it is trusted only as PID 1 (as systemd does).
	add("container-env", os.Getpid() == 1 && os.Getenv("container") != "")
	// Containers running systemd as init (LXC, nspawn).
	add("systemd-container", exists("/run/systemd/container"))
	// nspawn, LXC (also Incus, Proxmox): a fake boot_id is bind-mounted, whatever the container's init.
	add("boot-id-mount", isMountPoint(ms, "/proc/sys/kernel/random/boot_id"))
	// OpenVZ.
	add("openvz", exists("/proc/vz") && !exists("/proc/bc"))
	// WSL.
	osrelease, _ := readTrim("/proc/sys/kernel/osrelease")
	add("wsl-osrelease", strings.Contains(osrelease, "Microsoft") || strings.Contains(osrelease, "WSL"))
	return out
}

func main() {
	flag.StringVar(&root, "root", "/", "prefix for all file reads (fixture testing)")
	flag.Parse()

	ms := readMounts()
	sig := signals(ms)
	sigOut := "-"
	if len(sig) > 0 {
		sigOut = strings.Join(sig, ",")
	}

	// Step 1: resolve the machine-id from the semantic conventions sources for Linux.
	path := ""
	for _, candidate := range []string{"/etc/machine-id", "/var/lib/dbus/machine-id"} {
		if v, err := readTrim(candidate); err == nil && v != "" && v != "uninitialized" {
			path = candidate
			break
		}
	}
	if path == "" {
		fmt.Println("MACHINE_ID_PATH: -")
	} else {
		fmt.Println("MACHINE_ID_PATH:", path)
	}
	fmt.Println("SIGNALS:", sigOut)
	if path == "" {
		fmt.Println("VERDICT: NO_ID (machine-id missing or empty)")
		return
	}

	real := path
	if r, err := filepath.EvalSymlinks(p(path)); err == nil {
		if rel, err := filepath.Rel(p("/"), r); err == nil {
			real = "/" + rel
		}
	}
	m, _ := containing(ms, real)
	fmt.Printf("MACHINE_ID_MOUNT: point=%s fstype=%s\n", m.point, m.fstype)

	switch {
	// Step 2: the machine-id file is itself a mount point.
	case m.point == real && isContainerFS(m.fstype):
		fmt.Println("VERDICT: DISTRUST (bind-mounted from another container's rootfs)")
	case m.point == real:
		fmt.Println("VERDICT: TRUST (explicitly mounted in, e.g. host bind mount)")
	// Step 3: not mounted; any in-container signal means the machine-id belongs to the container.
	case len(sig) > 0:
		fmt.Println("VERDICT: DISTRUST (in-container signals)")
	default:
		fmt.Println("VERDICT: TRUST (no in-container signals)")
	}
}
