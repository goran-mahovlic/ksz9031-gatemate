#!/bin/bash
# Shared lab-configuration loader for flash.sh / test.sh.
#
# Resolution order (first one that sets a value wins):
#   1. environment variable already exported by the caller
#   2. scripts/lab.env (git-ignored, holds your private network details)
#   3. the placeholder defaults below
#
# The defaults are deliberately generic. This repository is public, so the real
# addresses of the lab bench live only in scripts/lab.env, never in git.

_lab_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_lab_file="$_lab_dir/lab.env"

if [ -f "$_lab_file" ]; then
    # shellcheck disable=SC1090
    # Values already present in the environment keep precedence.
    _lab_saved_host="${RPI_HOST-}"; _lab_saved_dir="${RPI_DIR-}"
    _lab_saved_thost="${TEST_RPI_HOST-}"
    _lab_saved_ip="${FPGA_IP-}";    _lab_saved_mac="${FPGA_MAC-}"
    set -a; . "$_lab_file"; set +a
    [ -n "$_lab_saved_host" ] && RPI_HOST="$_lab_saved_host"
    [ -n "$_lab_saved_thost" ] && TEST_RPI_HOST="$_lab_saved_thost"
    [ -n "$_lab_saved_dir" ]  && RPI_DIR="$_lab_saved_dir"
    [ -n "$_lab_saved_ip" ]   && FPGA_IP="$_lab_saved_ip"
    [ -n "$_lab_saved_mac" ]  && FPGA_MAC="$_lab_saved_mac"
    unset _lab_saved_host _lab_saved_thost _lab_saved_dir _lab_saved_ip _lab_saved_mac
    LAB_ENV_SOURCE="scripts/lab.env"
else
    LAB_ENV_SOURCE="defaults"
fi

RPI_HOST="${RPI_HOST:-fpga@raspberrypi.local}"
# test.sh may run from a different host than the one holding the JTAG dongle.
TEST_RPI_HOST="${TEST_RPI_HOST:-$RPI_HOST}"
RPI_DIR="${RPI_DIR:-/home/fpga/FPGA}"
FPGA_IP="${FPGA_IP:-192.168.1.150}"
FPGA_MAC="${FPGA_MAC:-10:e2:d5:00:00:00}"

export RPI_HOST TEST_RPI_HOST RPI_DIR FPGA_IP FPGA_MAC LAB_ENV_SOURCE

lab_env_banner() {
    echo "=== Lab config ($LAB_ENV_SOURCE): RPI_HOST=$RPI_HOST FPGA_IP=$FPGA_IP ==="
    if [ "$LAB_ENV_SOURCE" = "defaults" ]; then
        echo "    Using placeholder values. Copy scripts/lab.env.example to"
        echo "    scripts/lab.env and enter your own bench addresses."
    fi
}
