# Real-world: systemd postinst runs systemd-machine-id-setup and bakes /etc/machine-id.
FROM ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends systemd >/dev/null && rm -rf /var/lib/apt/lists/*
