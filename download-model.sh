#!/usr/bin/env bash
set -o pipefail
repo="${PLUGIN_REPO}"
dir="${PLUGIN_DIR}"
file=$(curl -s "https://huggingface.co/api/models/${repo}/tree/main" | jq -r '[.[] | select(.path|test("\\.gguf$")) | .path] | (map(select(test("Q4_K_M"))) | .[0]) // (map(select(test("Q4_0"))) | .[0]) // .[0]')
if [ -z "$file" ] || [ "$file" = "null" ]; then
  echo "NO_GGUF"
  exit 1
fi
echo "FILE:${file}"
if curl -fL -s -o "${dir}/${file}" "https://huggingface.co/${repo}/resolve/main/${file}"; then
  echo "DONE"
else
  echo "FAIL"
  exit 1
fi
