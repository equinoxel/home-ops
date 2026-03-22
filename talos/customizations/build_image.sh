#!/bin/bash
docker run --rm -t -v ./_out:/out -v /dev:/dev --privileged \
    ghcr.io/siderolabs/imager:v1.12.6 rpi_5 \
    --base-installer-image="ghcr.io/siderolabs/installer-base:v1.12.4" \
    --overlay-image="ghcr.io/siderolabs/sbc-raspberrypi:v0.2.0" \
    --overlay-name="rpi_5" \
    --arch arm64