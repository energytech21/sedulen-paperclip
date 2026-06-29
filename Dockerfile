# syntax=docker/dockerfile:1.20
FROM node:lts-trixie-slim AS base
ARG USER_UID=1000
ARG USER_GID=1000
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates gosu curl gh git wget ripgrep python3 \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable

# --- .NET toolchain for agent workspaces ---------------------------------
# Modern, cross-platform .NET (net6.0 .. net9.0). The .NET 9 SDK builds older
# target frameworks; the 6.0/7.0 runtimes let older test suites execute.
# NOTE: classic .NET Framework (net4x) is Windows-only and cannot run here;
# Mono below is a best-effort build path for legacy net4x class libraries
# (WPF/WinForms/classic WCF will not work on Linux).
ENV DOTNET_ROOT=/usr/share/dotnet \
    PATH=/usr/share/dotnet:/usr/share/dotnet/tools:$PATH \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    NUGET_PACKAGES=/paperclip/.nuget/packages
RUN apt-get update \
  && apt-get install -y --no-install-recommends libicu-dev libssl3 \
  && rm -rf /var/lib/apt/lists/* \
  && curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
  && chmod +x /tmp/dotnet-install.sh \
  && /tmp/dotnet-install.sh --channel 9.0 --install-dir /usr/share/dotnet \
  && /tmp/dotnet-install.sh --channel 8.0 --install-dir /usr/share/dotnet \
  && /tmp/dotnet-install.sh --channel 7.0 --runtime dotnet --install-dir /usr/share/dotnet \
  && /tmp/dotnet-install.sh --channel 6.0 --runtime dotnet --install-dir /usr/share/dotnet \
  && rm /tmp/dotnet-install.sh \
  && dotnet --info

# Legacy .NET Framework (net4x) build support via Mono — best effort, Linux limits apply.
# NOTE: no standalone `nuget` apt package on Debian trixie; the .NET SDK provides
# `dotnet nuget`/`dotnet restore`, and the standalone classic nuget.exe (below) runs
# under Mono for legacy packages.config restores.
RUN apt-get update \
  && apt-get install -y --no-install-recommends mono-complete \
  && rm -rf /var/lib/apt/lists/*

# Standalone classic NuGet CLI (nuget.exe) run via Mono. nuget.exe is x86-only
# (there is no win-x64 build) and is officially supported on Linux under Mono with
# limits: `nuget restore` works for packages.config but NOT .sln/.slnx, and
# `nuget update` is unsupported — use `dotnet restore`/`msbuild -t:restore` there.
ARG NUGET_VERSION=6.14.0
RUN curl -fsSL "https://dist.nuget.org/win-x86-commandline/v${NUGET_VERSION}/nuget.exe" \
      -o /usr/local/lib/nuget.exe \
  && printf '#!/bin/sh\nexec mono /usr/local/lib/nuget.exe "$@"\n' > /usr/local/bin/nuget \
  && chmod +x /usr/local/bin/nuget \
  && nuget help | head -1

# Modify the existing node user/group to have the specified UID/GID to match host user
RUN usermod -u $USER_UID --non-unique node \
  && groupmod -g $USER_GID --non-unique node \
  && usermod -g $USER_GID -d /paperclip node

FROM base AS deps
WORKDIR /app
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml .npmrc ./
COPY cli/package.json cli/
COPY server/package.json server/
COPY ui/package.json ui/
COPY packages/shared/package.json packages/shared/
COPY packages/db/package.json packages/db/
COPY packages/adapter-utils/package.json packages/adapter-utils/
COPY packages/mcp-server/package.json packages/mcp-server/
COPY packages/adapters/acpx-local/package.json packages/adapters/acpx-local/
COPY packages/adapters/claude-local/package.json packages/adapters/claude-local/
COPY packages/adapters/codex-local/package.json packages/adapters/codex-local/
COPY packages/adapters/cursor-cloud/package.json packages/adapters/cursor-cloud/
COPY packages/adapters/cursor-local/package.json packages/adapters/cursor-local/
COPY packages/adapters/gemini-local/package.json packages/adapters/gemini-local/
COPY packages/adapters/grok-local/package.json packages/adapters/grok-local/
COPY packages/adapters/openclaw-gateway/package.json packages/adapters/openclaw-gateway/
COPY packages/adapters/opencode-local/package.json packages/adapters/opencode-local/
COPY packages/adapters/pi-local/package.json packages/adapters/pi-local/
COPY packages/plugins/sdk/package.json packages/plugins/sdk/
COPY --parents packages/plugins/sandbox-providers/./*/package.json packages/plugins/sandbox-providers/
COPY packages/plugins/paperclip-plugin-fake-sandbox/package.json packages/plugins/paperclip-plugin-fake-sandbox/
COPY packages/plugins/plugin-llm-wiki/package.json packages/plugins/plugin-llm-wiki/
COPY packages/plugins/plugin-workspace-diff/package.json packages/plugins/plugin-workspace-diff/
COPY patches/ patches/
COPY scripts/link-plugin-dev-sdk.mjs scripts/

RUN pnpm install --frozen-lockfile

FROM base AS build
WORKDIR /app
COPY --from=deps /app /app
COPY . .
RUN pnpm --filter @paperclipai/ui build
RUN pnpm --filter @paperclipai/plugin-sdk build
RUN pnpm --filter @paperclipai/server build
RUN test -f server/dist/index.js || (echo "ERROR: server build output missing" && exit 1)

FROM base AS production
ARG USER_UID=1000
ARG USER_GID=1000
WORKDIR /app
COPY --chown=node:node --from=build /app /app
RUN npm install --global --omit=dev @anthropic-ai/claude-code@latest @openai/codex@latest opencode-ai \
  && apt-get update \
  && apt-get install -y --no-install-recommends openssh-client jq \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /paperclip \
  && chown node:node /paperclip

COPY scripts/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENV NODE_ENV=production \
  HOME=/paperclip \
  HOST=0.0.0.0 \
  PORT=3100 \
  SERVE_UI=true \
  PAPERCLIP_HOME=/paperclip \
  PAPERCLIP_INSTANCE_ID=default \
  USER_UID=${USER_UID} \
  USER_GID=${USER_GID} \
  PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
  PAPERCLIP_DEPLOYMENT_MODE=authenticated \
  PAPERCLIP_DEPLOYMENT_EXPOSURE=private \
  OPENCODE_ALLOW_ALL_MODELS=true

VOLUME ["/paperclip"]
EXPOSE 3100

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["node", "--import", "./server/node_modules/tsx/dist/loader.mjs", "server/dist/index.js"]
