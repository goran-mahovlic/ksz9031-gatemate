#!/bin/bash
# Self-test for the lab configuration loader (scripts/lab_env.sh).
# Usage: ./scripts/test_lab_env.sh
set -u
PASS=0; FAIL=0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"

check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1";
    else FAIL=$((FAIL+1)); echo "  FAIL $1: expected [$2] got [$3]"; fi
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp "$here/lab_env.sh" "$tmp/lab_env.sh"
LOADER="$tmp/lab_env.sh"

triple() { printf '%s|%s|%s\n' "${RPI_HOST}" "${FPGA_IP}" "${LAB_ENV_SOURCE}"; }

echo "[1] placeholder defaults apply with no lab.env and nothing preset"
out=$(unset RPI_HOST TEST_RPI_HOST RPI_DIR FPGA_IP FPGA_MAC; . "$LOADER"; triple)
check "default host/ip/source" "fpga@raspberrypi.local|192.168.1.150|defaults" "$out"

echo "[2] defaults expose no lab-internal 192.168.10.x address"
out=$(unset RPI_HOST TEST_RPI_HOST FPGA_IP RPI_DIR; . "$LOADER"
      printf '%s %s %s %s' "${RPI_HOST}" "${TEST_RPI_HOST}" "${FPGA_IP}" "${RPI_DIR}" |
      grep -c '192\.168\.10\.')
check "no 10.x in defaults" "0" "$out"

echo "[3] a preset variable overrides the default"
out=$(unset FPGA_IP; RPI_HOST="me@box"; . "$LOADER"; printf '%s' "${RPI_HOST}")
check "preset override" "me@box" "$out"

echo "[4] lab.env supplies values when nothing is preset"
printf 'RPI_HOST="fromfile@host"\nFPGA_IP="10.0.0.9"\n' > "$tmp/lab.env"
out=$(unset RPI_HOST TEST_RPI_HOST FPGA_IP; . "$LOADER"; triple)
check "file values" "fromfile@host|10.0.0.9|scripts/lab.env" "$out"

echo "[5] a preset variable beats the lab.env file"
out=$(unset FPGA_IP; RPI_HOST="preset@wins"; . "$LOADER"; printf '%s' "${RPI_HOST}")
check "preset precedence" "preset@wins" "$out"

echo "[6] TEST_RPI_HOST falls back to RPI_HOST"
out=$(unset TEST_RPI_HOST; RPI_HOST="only@one"; . "$LOADER"; printf '%s' "${TEST_RPI_HOST}")
check "TEST_RPI_HOST fallback" "only@one" "$out"

echo "[7] TEST_RPI_HOST may differ from RPI_HOST"
out=$(RPI_HOST="a@x"; TEST_RPI_HOST="b@y"; . "$LOADER"; printf '%s' "${TEST_RPI_HOST}")
check "TEST_RPI_HOST distinct" "b@y" "$out"

echo "[8] scripts/lab.env is git-ignored"
if git -C "$repo" check-ignore -q scripts/lab.env; then
    PASS=$((PASS+1)); echo "  ok   lab.env ignored"
else FAIL=$((FAIL+1)); echo "  FAIL lab.env is NOT git-ignored"; fi

echo "[9] no bench topology left in any tracked source file"
hits=$(git -C "$repo" grep -lE '192\.168\.10\.(14|18|150)|fpga-klaudio' -- . ':!build*' 2>/dev/null | wc -l)
check "tracked files leaking bench topology" "0" "$hits"

echo "[10] flash.sh and test.sh parse"
if bash -n "$here/flash.sh" && bash -n "$here/test.sh"; then
    PASS=$((PASS+1)); echo "  ok   both scripts parse"
else FAIL=$((FAIL+1)); echo "  FAIL syntax error"; fi

echo
echo "$PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
