#!/usr/bin/env bash
set -o pipefail
q=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$PLUGIN_QUERY")
curl -s "https://huggingface.co/api/models?search=${q}&filter=gguf&limit=12&sort=downloads&direction=-1" | jq -r '.[] | "\(.downloads)\t\(.id)"'
