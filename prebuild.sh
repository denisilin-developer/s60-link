#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p build/icon
mifconv build/icon/s60link_aif.mif /c32,8 data/s60link-icon.svg >/dev/null
