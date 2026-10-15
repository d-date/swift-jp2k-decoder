#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <destination>" >&2
    exit 2
fi

commit=39524bd3a601d90ed8e0177559400d23945f96a9
destination=$1
mkdir -p "$destination"
destination=$(cd "$destination" && pwd)

if [[ -d "$destination/.git" ]] &&
   [[ $(git -C "$destination" rev-parse HEAD 2>/dev/null || true) == "$commit" ]] &&
   [[ -f "$destination/input/conformance/COPYRIGHT" ]] &&
   [[ -f "$destination/baseline/conformance/COPYRIGHT" ]]; then
    exit 0
fi

if [[ -n $(find "$destination" -mindepth 1 -maxdepth 1 -print -quit) ]] &&
   [[ ! -d "$destination/.git" ]]; then
    echo "Destination is not an openjpeg-data checkout: $destination" >&2
    exit 1
fi

if [[ ! -d "$destination/.git" ]]; then
    git -C "$destination" init -q
    git -C "$destination" remote add origin https://github.com/uclouvain/openjpeg-data.git
fi
git -C "$destination" sparse-checkout init --cone
git -C "$destination" sparse-checkout set input/conformance baseline/conformance
git -C "$destination" fetch --depth 1 origin "$commit"
git -C "$destination" checkout --detach -f FETCH_HEAD
actual=$(git -C "$destination" rev-parse HEAD)
if [[ "$actual" != "$commit" ]]; then
    echo "Expected openjpeg-data $commit, got $actual" >&2
    exit 1
fi
for path in input/conformance/COPYRIGHT baseline/conformance/COPYRIGHT; do
    if [[ ! -f "$destination/$path" ]]; then
        echo "Missing conformance notice: $path" >&2
        exit 1
    fi
done
