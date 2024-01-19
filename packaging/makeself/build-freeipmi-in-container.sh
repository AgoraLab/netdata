#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

# -----------------------------------------------------------------------------
# parse command line arguments

set -e

export NETDATA_BUILD_WITH_DEBUG=0

while [ -n "${1}" ]; do
  case "${1}" in
    debug)
      export NETDATA_BUILD_WITH_DEBUG=1
      ;;

    *) ;;

  esac

  shift
done

# -----------------------------------------------------------------------------

get_os_release() {
  # Loads the /etc/os-release or /usr/lib/os-release file(s)
  # Only the required fields are loaded
  #
  # If it manages to load a valid os-release, it returns 0
  # otherwise it returns 1
  #
  # It searches the ID_LIKE field for a compatible distribution

  os_release_file=
  if [ -s "/etc/os-release" ]; then
    os_release_file="/etc/os-release"
  elif [ -s "/usr/lib/os-release" ]; then
    os_release_file="/usr/lib/os-release"
  else
    echo >&2 "Cannot find an os-release file ..."
    return 1
  fi

  local x
  echo >&2 "Loading ${os_release_file} ..."

  eval "$(grep -E "^(NAME|ID|ID_LIKE|VERSION|VERSION_ID)=" "${os_release_file}")"
  for x in "${ID}" ${ID_LIKE}; do
    case "${x,,}" in
      almalinux | alpine | arch | centos | clear-linux-os | debian | fedora | gentoo | manjaro | opensuse-leap | opensuse-tumbleweed | ol | rhel | rocky | sabayon | sles | suse | ubuntu)
        distribution="${x}"
        if [ "${ID}" = "opensuse-tumbleweed" ]; then
          version="tumbleweed"
          codename="tumbleweed"
        else
          version="${VERSION_ID}"
          codename="${VERSION}"
        fi
        detection="${os_release_file}"
        break
        ;;
      *)
        echo >&2 "Unknown distribution ID: ${x}"
        ;;
    esac
  done
  [ -z "${distribution}" ] echo >&2 "Cannot find valid distribution in: ${ID} ${ID_LIKE}" return 1

  [ -z "${distribution}" ] return 1
  return 0
}

get_lsb_release() {
  # Loads the /etc/lsb-release file
  # If it fails, it attempts to run the command: lsb_release -a
  # and parse its output
  #
  # If it manages to find the lsb-release, it returns 0
  # otherwise it returns 1

  if [ -f "/etc/lsb-release" ]; then
    echo >&2 "Loading /etc/lsb-release ..."
    local DISTRIB_ID="" DISTRIB_RELEASE="" DISTRIB_CODENAME=""
    eval "$(grep -E "^(DISTRIB_ID|DISTRIB_RELEASE|DISTRIB_CODENAME)=" /etc/lsb-release)"
    distribution="${DISTRIB_ID}"
    version="${DISTRIB_RELEASE}"
    codename="${DISTRIB_CODENAME}"
    detection="/etc/lsb-release"
  fi

  if [ -z "${distribution}" ] [ -n "${lsb_release}" ]; then
    echo >&2 "Cannot find distribution with /etc/lsb-release"
    echo >&2 "Running command: lsb_release ..."
    eval "declare -A release=( $(lsb_release -a 2> /dev/null | sed -e "s|^\(.*\):[[:space:]]*\(.*\)$|[\1]=\"\2\"|g") )"
    distribution="${release["Distributor ID"]}"
    version="${release[Release]}"
    codename="${release[Codename]}"
    detection="lsb_release"
  fi

  [ -z "${distribution}" ] echo >&2 "Cannot find valid distribution with lsb-release" return 1
  return 0
}

autodetect_distribution() {
  # autodetection of distribution/OS
  case "$(uname -s)" in
    "Linux")
      get_os_release || get_lsb_release
      ;;
    "FreeBSD")
      distribution="freebsd"
      version="$(uname -r)"
      detection="uname"
      ;;
    "Darwin")
      distribution="macos"
      version="$(uname -r)"
      detection="uname"

      if [ ${EUID} -eq 0 ]; then
        echo >&2 "This script does not support running as EUID 0 on macOS. Please run it as a regular user."
        exit 1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

if ! autodetect_distribution ; then
  echo >&2 "Cannot autodetect distribution/OS"
  exit 1
fi

mkdir -p /usr/src
cp -va /netdata /usr/src/netdata
chown -R root:root /usr/src/netdata

cd /usr/src/netdata || exit 1

[ -z "${NETDATA_INSTALL_PATH}" ] && export NETDATA_INSTALL_PATH="${1-/opt/netdata}"

# make sure the path does not end with /
if [ "${NETDATA_INSTALL_PATH:$((${#NETDATA_INSTALL_PATH} - 1)):1}" = "/" ]; then
  export NETDATA_INSTALL_PATH="${NETDATA_INSTALL_PATH:0:$((${#NETDATA_INSTALL_PATH} - 1))}"
fi

# find the parent directory
NETDATA_INSTALL_PARENT="$(dirname "${NETDATA_INSTALL_PATH}")"
export NETDATA_INSTALL_PARENT

export PACKAGES_NETDATA_FREEIPMI=1 
if ! packaging/installer/install-required-packages.sh --dont-wait --non-interactive all; then
  printf >&2 "Build failed."
  exit 1
fi

git clean -dxf
git submodule foreach --recursive git clean -dxf

cat >&2 << EOF
This program will create a self-extracting shell package containing
a statically linked netdata, able to run on any 64bit Linux system,
without any dependencies from the target system.

It can be used to have netdata running in no-time, or in cases the
target Linux system cannot compile netdata.
EOF

if [ ! -d tmp ]; then
  mkdir tmp || exit 1
else
  rm -rf tmp/*
fi

if [ -z "${GITHUB_ACTIONS}" ]; then
    export GITHUB_ACTIONS=false
fi

if [ "${NETDATA_BUILD_WITH_DEBUG}" -eq 0 ]; then
  export CFLAGS="-ffunction-sections -fdata-sections -O2 -funroll-loops -pipe"
else
  export CFLAGS="-O1 -pipe -ggdb3 -Wall -Wextra -Wformat-signedness -DNETDATA_INTERNAL_CHECKS=1"
fi

if ! ./netdata-installer.sh --install-prefix "${NETDATA_INSTALL_PARENT}" \
    --dont-wait \
    --dont-start-it \
    --use-system-protobuf \
    --dont-scrub-cflags-even-though-it-may-break-things \
    --one-time-build \
    --enable-lto \
    --disable-cloud \
    --disable-go \
    --disable-ebpf \
    --disable-telemetry \
    --disable-dbengine \
    --disable-plugin-xenstat \
    --disable-exporting-kinesis \
    --disable-exporting-mongodb \
    --disable-exporting-pubsub \
    --disable-ml \
    --disable-logsmanagement \
    --enable-plugin-freeipmi ; then
  printf >&2 "Build failed."
  exit 1
fi

NETDATA_VERSION="$(${NETDATA_INSTALL_PARENT}/netdata/usr/libexec/netdata/plugins.d/freeipmi.plugin -v | cut -f 2 -d ' ')"
if [ ${NETDATA_BUILD_WITH_DEBUG} -eq 1 ]; then
  NETDATA_VERSION="${NETDATA_VERSION}-debug"
fi

mkdir -p /netdata/artifacts/freeipmi
cp -r "${NETDATA_INSTALL_PARENT}"/netdata/usr/libexec/netdata/plugins.d/freeipmi.plugin /netdata/artifacts/freeipmi/freeipmi_$(uname -m)-${NETDATA_VERSION}_${distribution}_${version}.plugin
chown -R "$(stat -c '%u:%g' /netdata)" /netdata/artifacts/freeipmi
