#!/bin/sh
set -eu

bin=$(realpath "${1:-zig-out/bin/zoro}")
root=$(mktemp -d /tmp/zoro-e2e.XXXXXX)
trap 'rm -rf "$root"' EXIT
mkdir "$root/run"
cd "$root/run"

env -i ZORO_HOME="$root/home" ZORO_ENV_FILE="$root/missing.env" "$bin" status >status.txt
grep -q '^usable pending=0 failed=0 uncertain=0$' status.txt
env -i "$bin" --version | grep -q '^zoro '
test -d "$root/home/data"
test -d "$root/home/workspace"
test -d "$root/home/skills"
test ! -e data
test ! -e workspace
test ! -e skills
