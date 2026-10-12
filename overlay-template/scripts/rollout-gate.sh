#!/usr/bin/env bash
# rollout-gate.sh — fail-closed rollout gate, the last step of every deploy.
#
# What is gated (any failure => exit 1):
#   * every Deployment in the rendered overlay (RENDER). The render is the
#     source of truth: webhook-proxy, mcp-proxy, and cloudflared when
#     ../../base/ingress is enabled are all in it, so the list never goes stale;
#   * the runtime Deployments HCC creates from your instances (EXTRA, "ns/name");
#   * every other live Deployment in the platform namespaces (GATING_NAMESPACES):
#     per-Host agent pods in mcp-host, channel-reader-<host> in channels, ...
# What is reported but never fails the gate (NONGATING_NAMESPACES): Deployments
# there that the render does not own — third-party MCP servers in mcp-server,
# WRC per-recipe workloads in sandbox-recipes. mcp-server/mcp-proxy is in the
# render, so it stays gating.
#
# Exit 1 when: RENDER is unreadable or contains no Deployment, a namespace
# cannot be listed, an expected Deployment is missing, or a gating rollout does
# not complete within its timeout (HCC gets HCC_TIMEOUT: it serves 503 on
# /ready until its first full reconciliation, which can take 20+ minutes).
#
# Usage: CONTEXT=<kube-context> [RENDER=/tmp/rendered.yaml] bash rollout-gate.sh
set -euo pipefail

: "${CONTEXT:?set CONTEXT to the kube-context to gate}"
RENDER="${RENDER:-/tmp/rendered.yaml}"
EXTRA="${EXTRA:-gfs/gfsc-writer gfs/gfsc-reader}"
GATING_NAMESPACES="${GATING_NAMESPACES:-channels control-plane gfs mcp-host profiles rpc-proxy webhook-ingress ingress}"
NONGATING_NAMESPACES="${NONGATING_NAMESPACES:-mcp-server sandbox-recipes}"
TIMEOUT="${TIMEOUT:-300s}"
HCC_TIMEOUT="${HCC_TIMEOUT:-1500s}"
NONGATING_TIMEOUT="${NONGATING_TIMEOUT:-60s}"

kc() { kubectl --context "$CONTEXT" "$@"; }
in_list() { printf '%s\n' "$2" | grep -Fx -- "$1" >/dev/null; }   # no -q: a quiet grep can SIGPIPE printf under pipefail
ns_in() { local x; for x in $2; do [ "$x" = "$1" ] && return 0; done; return 1; }

# --- 1. expected inventory: Deployments in the render + EXTRA ---------------
if [ ! -r "$RENDER" ]; then
  echo "FAIL: render $RENDER is not readable (run kubectl kustomize first)" >&2
  exit 1
fi
if ! expected=$(python3 - "$RENDER" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
found = set()

def unquote(v):
    # a YAML-quoted scalar ("name" / 'name') must compare equal to the bare name
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    return v

for doc in re.split(r"^---$", src, flags=re.MULTILINE):
    kind = ns = name = None
    in_meta = False
    for line in doc.strip().splitlines():
        if line.startswith("kind:"):
            kind = line.split(":", 1)[1].strip()
        elif line == "metadata:":
            in_meta = True
        elif in_meta and line.startswith("  name:"):
            name = unquote(line.split(":", 1)[1])
        elif in_meta and line.startswith("  namespace:"):
            ns = unquote(line.split(":", 1)[1])
        elif in_meta and line and not line.startswith(" "):
            in_meta = False
    if kind == "Deployment" and ns and name:
        found.add(f"{ns}/{name}")
print("\n".join(sorted(found)))
PY
); then
  echo "FAIL: could not parse $RENDER" >&2
  exit 1
fi
if [ -z "$expected" ]; then
  echo "FAIL: no Deployment found in $RENDER — wrong file or empty render" >&2
  exit 1
fi
for e in $EXTRA; do expected="$expected"$'\n'"$e"; done
expected=$(printf '%s\n' "$expected" | sort -u)

# --- 2. live inventory: every listing must succeed ---------------------------
live=""
for ns in $GATING_NAMESPACES $NONGATING_NAMESPACES; do
  if ! names=$(kc -n "$ns" get deploy -o name); then
    echo "FAIL: cannot list Deployments in namespace $ns" >&2
    exit 1
  fi
  for n in $names; do live="$live"$'\n'"$ns/${n#deployment.apps/}"; done
done
live=$(printf '%s\n' "$live" | sed '/^$/d' | sort -u)

# --- 3. gating set = expected + live in gating namespaces --------------------
gating="$expected"
for d in $live; do
  ns_in "${d%%/*}" "$GATING_NAMESPACES" && gating="$gating"$'\n'"$d"
done
gating=$(printf '%s\n' "$gating" | sort -u)

failures=""
missing=""
for d in $expected; do
  in_list "$d" "$live" || missing="$missing"$'\n'"$d"
done
if [ -n "$missing" ]; then
  echo "MISSING (expected by the render/instances, not on the cluster):$missing" >&2
  failures="$failures$missing"
fi

# --- 4. rollout status, gating ----------------------------------------------
for d in $gating; do
  in_list "$d" "$live" || continue            # already recorded as missing
  ns="${d%%/*}"; name="${d#*/}"; t="$TIMEOUT"
  [ "$d" = control-plane/host-context-controller ] && t="$HCC_TIMEOUT"
  echo "── $d (gating, timeout $t)"
  if ! kc -n "$ns" rollout status "deployment/$name" --timeout="$t"; then
    echo "FAILED rollout: $d" >&2
    failures="$failures"$'\n'"$d"
  fi
done

# --- 5. rollout status, non-gating (report only) ----------------------------
for d in $live; do
  ns="${d%%/*}"; name="${d#*/}"
  ns_in "$ns" "$NONGATING_NAMESPACES" || continue
  in_list "$d" "$gating" && continue
  echo "── $d (non-gating, timeout $NONGATING_TIMEOUT)"
  kc -n "$ns" rollout status "deployment/$name" --timeout="$NONGATING_TIMEOUT" \
    || echo "WARN (non-gating, not failing the gate): $d"
done

# --- 6. summary --------------------------------------------------------------
n_gating=$(printf '%s\n' "$gating" | sed '/^$/d' | wc -l | tr -d ' ')
if [ -n "$failures" ]; then
  echo "ROLLOUT GATE FAILED — $(printf '%s\n' "$failures" | sed '/^$/d' | wc -l | tr -d ' ') of $n_gating gating Deployments:$failures" >&2
  exit 1
fi
echo "ROLLOUT GATE OK — $n_gating gating Deployments rolled out"
