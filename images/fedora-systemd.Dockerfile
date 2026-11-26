# Real-world: systemd rpm scriptlets bake /etc/machine-id.
FROM fedora:41
RUN dnf install -y -q systemd >/dev/null && dnf clean all
