#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

# shellcheck source=./packaging/installer/functions.sh
. "$(dirname "$0")"/../installer/functions.sh || exit 1

BUILDARCH="${1}"

set -e

platform="$("$(dirname "${0}")/uname2platform.sh" "${BUILDARCH}")"

if [ -z "${platform}" ]; then
    exit 1
fi

if command -v docker > /dev/null 2>&1; then
    docker="docker"
elif command -v podman > /dev/null 2>&1; then
    docker="podman"
else
    echo "Could not find a usable OCI runtime, need either Docker or Podman."
    exit 1
fi

DOCKER_IMAGE_NAME="ubuntu"
DOCKER_IMAGE_VERSION="${2}"

if [ "${BUILDARCH}" != "$(uname -m)" ] && [ "$(uname -m)" = 'x86_64' ] && [ -z "${SKIP_EMULATION}" ]; then
    ${docker} run --rm --privileged multiarch/qemu-user-static --reset -p yes || exit 1
fi

if ${docker} inspect "${DOCKER_IMAGE_NAME}":"${DOCKER_IMAGE_VERSION}" > /dev/null 2>&1; then
    if ${docker} image inspect "${DOCKER_IMAGE_NAME}":"${DOCKER_IMAGE_VERSION}" | grep -q 'Variant'; then
        img_platform="$(${docker} image inspect "${DOCKER_IMAGE_NAME}":"${DOCKER_IMAGE_VERSION}" --format '{{.Os}}/{{.Architecture}}/{{.Variant}}')"
    else
        img_platform="$(${docker} image inspect "${DOCKER_IMAGE_NAME}":"${DOCKER_IMAGE_VERSION}" --format '{{.Os}}/{{.Architecture}}')"
    fi

    if [ "${img_platform}" != "${platform}" ]; then
        ${docker} image rm "${DOCKER_IMAGE_NAME}" || exit 1
    fi
fi

if ! ${docker} inspect "${DOCKER_IMAGE_NAME}":"${DOCKER_IMAGE_VERSION}" > /dev/null 2>&1; then
    ${docker} pull --platform "${platform}" "${DOCKER_IMAGE_NAME}":"${DOCKER_IMAGE_VERSION}"
fi

# Run the build script inside the container
if [ -t 1 ]; then
  run ${docker} run --rm -e BUILDARCH="${BUILDARCH}" -a stdin -a stdout -a stderr -i -t -v "$(pwd)":/netdata:rw \
    "${DOCKER_IMAGE_NAME}":"${DOCKER_IMAGE_VERSION}" \
    /netdata/packaging/makeself/build-freeipmi-in-container.sh "${@}"
else
  run ${docker} run --rm -e BUILDARCH="${BUILDARCH}" -v "$(pwd)":/netdata:rw \
    -e GITHUB_ACTIONS="${GITHUB_ACTIONS}" "${DOCKER_IMAGE_NAME}":"${DOCKER_IMAGE_VERSION}" \
    /netdata/packaging/makeself/build-freeipmi-in-container.sh "${@}"
fi
