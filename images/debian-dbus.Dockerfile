# Real-world: dbus postinst runs dbus-uuidgen and bakes /var/lib/dbus/machine-id.
FROM debian:12
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends dbus >/dev/null && rm -rf /var/lib/apt/lists/*
