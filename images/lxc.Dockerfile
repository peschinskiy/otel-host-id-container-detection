# Outer helper to run LXC with the busybox template: a container whose init is not systemd.
FROM debian:12
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends lxc busybox-static >/dev/null && rm -rf /var/lib/apt/lists/*
