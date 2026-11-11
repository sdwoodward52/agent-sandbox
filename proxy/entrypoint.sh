#!/bin/bash
#
# Entrypoint for agy-egress-proxy container.
# Forwards IDE port 8443 and launches Squid egress proxy.

set -euo pipefail

# Forward localhost-bound IDE port (8443) across the internal network to
# agent-sandbox:8443.
socat TCP-LISTEN:8443,fork,reuseaddr TCP:agent-sandbox:8443 &

# Hand off to the standard ubuntu/squid entrypoint.
exec /usr/sbin/squid -NYCd 1 -f /etc/squid/squid.conf
