# Synthetic: a machine-id written at build time, shared by every container of this image.
FROM alpine:3.20
RUN echo 0123456789abcdef0123456789abcdef > /etc/machine-id
