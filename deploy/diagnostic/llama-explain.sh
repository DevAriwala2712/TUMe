#!/bin/sh
# Install a reviewed copy with the paths and CPU/context budget for the pilot.
set -eu

[ "$#" -eq 4 ] && [ "$1" = --max-tokens ] && [ "$3" = --request-json ] || exit 2
case "$2" in
    ''|*[!0-9]*) exit 2 ;;
esac
[ "${#2}" -le 3 ] && [ "$2" -ge 1 ] && [ "$2" -le 512 ] || exit 2
[ "${#4}" -le 2048 ] || exit 2

llama=/usr/local/bin/llama-completion
model=/var/lib/tume-diagnostic/model.gguf
[ -x "$llama" ] && [ -f "$model" ] && [ -r "$model" ] || exit 3

schema='{"type":"object","properties":{"schema_version":{"const":1},"cause":{"enum":["disk_near_capacity","memory_headroom_low","memory_stalls","unit_failed","unit_inactive"]},"citation":{"type":"string","minLength":64,"maxLength":64}},"required":["schema_version","cause","citation"],"additionalProperties":false}'
prompt='Return a single JSON object with schema_version 1, cause, and citation. Copy evidence.id exactly into citation. Choose cause from disk_near_capacity, memory_headroom_low, memory_stalls, unit_failed, unit_inactive. Use the given rule and measurement only. For service_unavailable, use active_state to distinguish failed from inactive. Do not emit commentary or actions.'
exec "$llama" -m "$model" -c 1024 -t 1 -ngl 0 -n "$2" -no-cnv \
    --offline --log-disable --no-display-prompt --simple-io --temp 0 -s 1 --json-schema "$schema" \
    -p "$prompt
Request:
$4
Response:"
