#!/usr/bin/env bash

: "${ANSIBLE_VERSION:="{{ ansible_version.string }}"}"

set -eu -o pipefail; shopt -qs failglob

echo "$ANSIBLE_VERSION"
