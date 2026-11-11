# syntax=docker/dockerfile:1
# Hardened ARM64 Container for Google Antigravity Agents + Multi-Repo code-server IDE
FROM node:22-bookworm-slim

ARG REQUIRE_AGY_AT_BUILD=false
ENV DEBIAN_FRONTEND=noninteractive

# Install core developer dependencies, Python 3 + venv/pip, Git, and tini
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
    less \
    procps \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    rsync \
    tini \
    tmux \
    && rm -rf /var/lib/apt/lists/*

# Install code-server (open-source VS Code in the browser, telemetry-free) into /usr/lib/code-server
# Installed as root so binaries and built-in extensions remain immutable under the container's read_only: true rootfs.
RUN curl -fsSL --retry 5 --retry-delay 2 --retry-connrefused https://code-server.dev/install.sh | sh && \
    code-server --extensions-dir /usr/lib/code-server/lib/vscode/extensions --install-extension Continue.continue && \
    rm -rf /root/.cache /root/.local /tmp/*

# Ensure UID/GID 1000 uses 'agent' user cleanly (node image comes with 'node' at 1000)
RUN <<'EOF'
set -e
usermod -l agent -d /home/agent -m node
groupmod -n agent node
mkdir -p \
    /workspaces \
    /opt/agy-vendor \
    /home/agent/.local/bin \
    /home/agent/.local/state \
    /home/agent/.local/share/code-server/User \
    /home/agent/.config \
    /home/agent/.continue \
    /home/agent/.gemini/config \
    /home/agent/.gemini/empty-hooks \
    /home/agent/.gemini/antigravity \
    /home/agent/.gemini/antigravity-cli \
    /home/agent/.cache
EOF

# Setup Codeserver settings.json file.
COPY resources/settings.json /home/agent/.local/share/code-server/User/settings.json

# Create the agy-url script and git wrapper.
COPY resources/agy-url /usr/local/bin/agy-url
COPY resources/git-wrapper /usr/local/bin/git
RUN chmod 0755 /usr/local/bin/agy-url /usr/local/bin/git

# Create the fallback server for autocomplete model invocations.
COPY resources/fallback.py /usr/local/bin/agy-gemini-fallback
RUN chmod 0755 /usr/local/bin/agy-gemini-fallback
RUN chown -R 1000:1000 /workspaces /home/agent /opt/agy-vendor

# System-level Git hardening (defense-in-depth layer alongside proxy & hooks)
RUN git config --system user.name "Antigravity Sandbox Agent" && \
    git config --system user.email "agent-sandbox@localhost" && \
    git config --system --add safe.directory '*' && \
    git config --system core.hooksPath /home/agent/.gemini/empty-hooks && \
    git config --system core.fsmonitor false && \
    git config --system protocol.allow "never" && \
    git config --system protocol.file.allow "always" && \
    git config --system protocol.https.allow "always"

# Copy any pre-downloaded Linux ARM64 agy binary from ./vendor/ into /opt/agy-vendor/
COPY --chown=1000:1000 vendor/ /opt/agy-vendor/

USER 1000:1000
ENV HOME=/home/agent
ENV HISTFILE=/tmp/.bash_history
ENV GIT_CONFIG_GLOBAL=/dev/null
ENV PATH="/home/agent/.local/bin:/opt/agy-vendor:${PATH}"
WORKDIR /workspaces

# Install Antigravity CLI (agy): uses vendored binary if present, else runs official installer.
# Pass --build-arg AGY_CACHEBUST=$(date +%s) (used by 'agy-sandbox update') to invalidate only this layer.
ARG AGY_CACHEBUST=initial
RUN if [ -x /opt/agy-vendor/agy ]; then \
        echo "Using vendored agy binary at /opt/agy-vendor/agy"; \
    elif curl -fsSL --connect-timeout 10 https://antigravity.google/cli/install.sh | bash; then \
        echo "Installed agy via official installer (cachebust=${AGY_CACHEBUST})"; \
    elif [ "$REQUIRE_AGY_AT_BUILD" = "true" ]; then \
        echo "ERROR: Failed to install agy and no binary found in ./vendor/agy" >&2; \
        exit 1; \
    else \
        echo "WARN: agy not installed at build time; mount binary into /opt/agy-vendor/agy at runtime."; \
    fi

EXPOSE 8443

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sh", "-c", "agy-gemini-fallback >/tmp/agy-gemini-fallback.log 2>&1 & exec code-server --bind-addr 0.0.0.0:8443 --auth none --disable-telemetry --disable-update-check /workspaces"]
