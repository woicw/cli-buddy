#!/usr/bin/env bash
# Refreshes Sources/CliBuddy/Resources/litellm-pricing.json from the
# upstream LiteLLM model_prices_and_context_window.json. Filtered down to
# bare Claude / GPT model ids (no bedrock/vertex_ai/regional variants),
# keeping only the cost-relevant fields. Run this manually whenever
# Anthropic or OpenAI ship new models or change rates.

set -euo pipefail
cd "$(dirname "$0")/.."

URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
DEST="Sources/CliBuddy/Resources/litellm-pricing.json"
TMP="$(mktemp -t litellm-pricing.XXXXXX.json)"
trap 'rm -f "$TMP"' EXIT

echo "fetching $URL..."
curl -fsSL "$URL" -o "$TMP"

python3 - "$TMP" "$DEST" <<'PY'
import json, sys, datetime
src, dst = sys.argv[1], sys.argv[2]
data = json.load(open(src))
relevant = ('claude', 'gpt-4', 'gpt-5', 'o1-', 'o3-', 'o4-')

def is_bare_id(k: str) -> bool:
    """Match only bare model ids that appear verbatim in Claude Code /
    Codex JSONL `message.model`. Drops vendored variants like
    `bedrock/...`, `vertex_ai/...`, regional prefixes like `eu.anthropic.`,
    `us-gov.anthropic.`, and BedRock-style suffixes like `...-v1:0`."""
    if '/' in k or ':' in k:
        return False
    # Vendor / region prefixes (eu, us, us-gov, anthropic, …) lack digits
    # before the first dot. Real model ids put a digit in the first dot
    # segment (gpt-4, claude-3-opus, gpt-5.1, …).
    head = k.split('.', 1)[0]
    return any(c.isdigit() for c in head)

keep = {}
for k, v in data.items():
    if not isinstance(v, dict): continue
    if not is_bare_id(k): continue
    kl = k.lower()
    if not any(s in kl for s in relevant): continue
    slim = {fk: fv for fk, fv in v.items()
            if 'cost' in fk or fk in ('provider_specific_entry', 'max_input_tokens')}
    if slim:
        keep[k] = slim

out = {
    '_source': 'https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json',
    '_fetched': datetime.date.today().isoformat(),
    'models': keep,
}
with open(dst, 'w') as f:
    json.dump(out, f, indent=2, sort_keys=True)
print(f"wrote {dst} with {len(keep)} models")
PY
