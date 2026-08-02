#!/bin/bash
# ---------------------------------------------------------------------------
# catalog.sh — built-in knowledge of common apps, used by ./inventory.sh add-app.
#
# catalog_lookup NAME prints a KEY=VALUE template (or nothing if the app is
# unknown). Keys match the fields of an `apps:` entry in inventory.yaml
# (schema v2 — the structured `installer:` block):
#   description, check_cmd, depends_apt, config_paths, extensions, exclude,
#   installer_type, installer_package, installer_url, installer_suite,
#   installer_components (space-delimited; "_none_" = no components),
#   installer_key_url, installer_key_fingerprint, installer_packages
#   (space-delimited), installer_arch, installer_checksum, installer_checksum_url,
#   installer_unverified (true/false), installer_binary, installer_dest,
#   installer_version, installer_version_url, installer_version_query
# ---------------------------------------------------------------------------
set -euo pipefail

catalog_lookup() {
  case "$1" in
    opencode)
      cat <<'EOF'
description=AI coding agent (opencode.ai)
installer_type=script
installer_url=https://opencode.ai/install
installer_unverified=true
check_cmd=opencode
depends_apt=curl
config_paths=~/.config/opencode
exclude=node_modules
EOF
      ;;
    code|vscode)
      cat <<'EOF'
description=Visual Studio Code
installer_type=snap_classic
installer_package=code
check_cmd=code
config_paths=~/.config/Code
extensions=ms-vscode.cpptools ms-python.python ms-vscode.vscode-typescript-next
exclude=CachedExtensionVSIXs CachedData Cache WebStorage logs
EOF
      ;;
    docker)
      cat <<'EOF'
description=Docker Engine + CLI (official Docker apt repo)
installer_type=apt_repository
installer_url=https://download.docker.com/linux/ubuntu
installer_suite=codename
installer_components=stable
installer_key_url=https://download.docker.com/linux/ubuntu/gpg
installer_key_fingerprint=9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88
installer_packages=docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
check_cmd=docker
depends_apt=curl
config_paths=~/.docker
exclude=cli-plugins
EOF
      ;;
    gh)
      cat <<'EOF'
description=GitHub CLI (official apt repo)
installer_type=apt_repository
installer_url=https://cli.github.com/packages
installer_suite=stable
installer_components=main
installer_key_url=https://cli.github.com/packages/githubcli-archive-keyring.gpg
installer_packages=gh
check_cmd=gh
depends_apt=curl
config_paths=~/.config/gh
EOF
      ;;
    git)
      cat <<'EOF'
description=Git version control (official apt)
installer_type=apt
check_cmd=git
config_paths=~/.gitconfig
config_paths=~/.config/git
EOF
      ;;
    gcloud)
      cat <<'EOF'
description=Google Cloud CLI (classic snap)
installer_type=snap_classic
installer_package=google-cloud-cli
check_cmd=gcloud
config_paths=~/.config/gcloud
exclude=logs
EOF
      ;;
    go)
      cat <<'EOF'
description=Go toolchain (official go.dev tarball)
installer_type=tarball
installer_url=https://go.dev/dl/{version}.linux-{arch}.tar.gz
installer_version_url=https://go.dev/VERSION?m=text
installer_checksum_url=https://go.dev/dl/{version}.linux-{arch}.tar.gz.sha256
installer_binary=go/bin/go
installer_dest=/usr/local
check_cmd=go
depends_apt=curl
config_paths=~/.config/go
exclude=telemetry
EOF
      ;;
    uv)
      cat <<'EOF'
description=Python package manager (official installer)
installer_type=script
installer_url=https://astral.sh/uv/install.sh
installer_unverified=true
check_cmd=uv
depends_apt=curl
config_paths=~/.config/uv
EOF
      ;;
    tmux)
      cat <<'EOF'
description=Terminal multiplexer (apt)
installer_type=apt
check_cmd=tmux
config_paths=~/.tmux.conf
EOF
      ;;
    terraform)
      cat <<'EOF'
description=HashiCorp Terraform IaC CLI
installer_type=snap_classic
check_cmd=terraform
config_paths=~/.terraform.d
exclude=checkpoint_cache checkpoint_signature
EOF
      ;;
    ollama)
      cat <<'EOF'
description=Local LLM runner (snap) — models NOT backed up
installer_type=snap
check_cmd=ollama
extensions=llama3.2
EOF
      ;;
    az)
      cat <<'EOF'
description=Microsoft Azure CLI (official MS apt repo)
installer_type=apt_repository
installer_url=https://packages.microsoft.com/repos/azure-cli
installer_suite=codename
installer_components=main
installer_key_url=https://packages.microsoft.com/keys/microsoft.asc
installer_packages=azure-cli
check_cmd=az
depends_apt=curl
config_paths=~/.azure
exclude=cliextensions logs telemetry commands
extensions=azure-devops
EOF
      ;;
    azurite)
      cat <<'EOF'
description=Azure Storage emulator (npm)
installer_type=npm_global
check_cmd=azurite
depends_apt=nodejs npm
EOF
      ;;
    slack)
      cat <<'EOF'
description=Slack desktop (snap)
installer_type=snap
check_cmd=slack
EOF
      ;;
    onlyoffice)
      cat <<'EOF'
description=OnlyOffice desktop editors (snap)
installer_type=snap
installer_package=onlyoffice-desktopeditors
check_cmd=onlyoffice-desktopeditors
EOF
      ;;
    storage-explorer)
      cat <<'EOF'
description=Azure Storage Explorer (snap)
installer_type=snap
check_cmd=storage-explorer
EOF
      ;;
    google-chrome|chrome)
      cat <<'EOF'
description=Google Chrome web browser
installer_type=deb
installer_url=https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
installer_arch=amd64
installer_unverified=true
check_cmd=google-chrome
depends_apt=curl
config_paths=~/.config/google-chrome
exclude=optimization_guide_model_store component_crx_cache WasmTtsEngine Safe*Browsing OnDeviceHeadSuggestModel GPUPersistentCache Crashpad GPUCache
EOF
      ;;
    fish)
      cat <<'EOF'
description=Friendly interactive shell (official apt)
installer_type=apt
check_cmd=fish
config_paths=~/.config/fish
EOF
      ;;
    sqlitebrowser)
      cat <<'EOF'
description=DB Browser for SQLite (official apt)
installer_type=apt
check_cmd=sqlitebrowser
config_paths=~/.config/sqlitebrowser
EOF
      ;;
    stacer)
      cat <<'EOF'
description=System optimizer & monitor (official apt)
installer_type=apt
check_cmd=stacer
config_paths=~/.config/stacer
EOF
      ;;
    sublime-text)
      cat <<'EOF'
description=Sublime Text editor (official apt repo)
installer_type=apt_repository
installer_url=https://download.sublimetext.com/
installer_suite=apt/stable/
installer_components=_none_
installer_key_url=https://download.sublimetext.com/sublimehq-pub.gpg
installer_packages=sublime-text
check_cmd=sublime_text
depends_apt=curl
config_paths=~/.config/sublime-text
exclude=Log
EOF
      ;;
    freebuff)
      cat <<'EOF'
description=Freebuff AI coding assistant CLI (npm)
installer_type=npm_global
check_cmd=freebuff
depends_apt=nodejs npm
config_paths=~/.config/manicode
exclude=projects freebuff rg tree-sitter.wasm
EOF
      ;;
    cloudflared)
      cat <<'EOF'
description=Cloudflare Tunnel client (official apt repo)
installer_type=apt_repository
installer_url=https://pkg.cloudflare.com/cloudflared
installer_suite=any
installer_components=main
installer_key_url=https://pkg.cloudflare.com/cloudflare-main.gpg
installer_packages=cloudflared
check_cmd=cloudflared
depends_apt=curl
EOF
      ;;
    mongodb-compass)
      cat <<'EOF'
description=MongoDB GUI (official .deb, latest stable)
installer_type=deb
installer_url=https://downloads.mongodb.com/compass/mongodb-compass_{version}_amd64.deb
installer_version_url=https://info-mongodb-com.s3.amazonaws.com/com-download-center/compass.json
installer_version_query=.versions[0]._id
installer_arch=amd64
installer_unverified=true
check_cmd=mongodb-compass
depends_apt=curl
config_paths=~/.config/MongoDB Compass
exclude=Cache GPUCache DawnWebGPUCache DawnGraphiteCache
EOF
      ;;
    tailscale)
      cat <<'EOF'
description=Tailscale mesh VPN (official installer)
installer_type=script
installer_url=https://tailscale.com/install.sh
installer_unverified=true
check_cmd=tailscale
depends_apt=curl
EOF
      ;;
  esac
}
