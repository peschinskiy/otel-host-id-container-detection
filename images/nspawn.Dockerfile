# Outer helper to run systemd-nspawn (a systemd-detect-virt "systemd-nspawn" container).
FROM debian:12
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends systemd-container >/dev/null && rm -rf /var/lib/apt/lists/*
