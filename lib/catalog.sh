#!/bin/bash
# ---------------------------------------------------------------------------
# catalog.sh — built-in knowledge of common apps, used by ./inventory.sh add-app.
#
# catalog_lookup NAME prints a KEY=VALUE template (or nothing if the app is
# unknown). Keys match the fields of an `apps:` entry in inventory.yaml:
#   description, install_type, install_command, check_cmd, depends_apt, config_paths,
#   package (override for apt/snap/snap-classic/flatpak),
#   extensions (space-delimited extension/model IDs to re-install post-restore),
#   exclude (space-delimited rsync patterns to keep caches/binaries out of backups)
# ---------------------------------------------------------------------------
set -euo pipefail

catalog_lookup() {
  case "$1" in
    opencode)
      cat <<'EOF'
description=AI coding agent (opencode.ai)
install_type=script
install_command=curl -fsSL https://opencode.ai/install | bash
check_cmd=opencode
depends_apt=curl
config_paths=~/.config/opencode
exclude=node_modules
EOF
      ;;
    code|vscode)
      cat <<'EOF'
description=Visual Studio Code
install_type=snap-classic
package=code
check_cmd=code
config_paths=~/.config/Code
extensions=ms-vscode.cpptools ms-python.python ms-vscode.vscode-typescript-next
exclude=CachedExtensionVSIXs CachedData Cache WebStorage logs
EOF
      ;;
    docker)
      cat <<'EOF'
description=Docker Engine + CLI (official Docker apt repo)
install_type=custom
install_command=sudo apt-get update && sudo apt-get install -y ca-certificates curl && sudo install -m 0755 -d /etc/apt/keyrings && sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && sudo chmod a+r /etc/apt/keyrings/docker.asc && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(grep VERSION_CODENAME /etc/os-release | cut -d= -f2) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null && sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
check_cmd=docker
depends_apt=curl
groups=docker
config_paths=~/.docker
exclude=cli-plugins
EOF
      ;;
    gh)
      cat <<'EOF'
description=GitHub CLI (official apt repo)
install_type=custom
install_command=(type -p wget >/dev/null || (sudo apt-get update && sudo apt-get install -y wget)) && sudo mkdir -p -m 755 /etc/apt/keyrings && out=$(mktemp) && wget -nv -O $out https://cli.github.com/packages/githubcli-archive-keyring.gpg && cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null && sudo apt-get update && sudo apt-get install -y gh
check_cmd=gh
depends_apt=wget
config_paths=~/.config/gh
EOF
      ;;
    git)
      cat <<'EOF'
description=Git version control (official apt)
install_type=apt
check_cmd=git
config_paths=~/.gitconfig
config_paths=~/.config/git
EOF
      ;;
    gcloud)
      cat <<'EOF'
description=Google Cloud CLI (classic snap)
install_type=snap-classic
package=google-cloud-cli
check_cmd=gcloud
config_paths=~/.config/gcloud
exclude=logs
EOF
      ;;
    go)
      cat <<'EOF'
description=Go toolchain (official go.dev tarball)
install_type=custom
install_command=VER=$(curl -fsSL https://go.dev/VERSION?m=text | head -1) && curl -fsSL -o /tmp/go.tar.gz https://go.dev/dl/${VER}.linux-$(dpkg --print-architecture).tar.gz && sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tar.gz && sudo ln -sf /usr/local/go/bin/go /usr/local/bin/go
check_cmd=go
depends_apt=curl
config_paths=~/.config/go
exclude=telemetry
EOF
      ;;
    uv)
      cat <<'EOF'
description=Python package manager (official installer)
install_type=custom
install_command=curl -LsSf https://astral.sh/uv/install.sh | sh
check_cmd=uv
depends_apt=curl
config_paths=~/.config/uv
EOF
      ;;
    tmux)
      cat <<'EOF'
description=Terminal multiplexer (apt)
install_type=apt
check_cmd=tmux
config_paths=~/.tmux.conf
EOF
      ;;
    terraform)
      cat <<'EOF'
description=HashiCorp Terraform IaC CLI
install_type=snap-classic
check_cmd=terraform
config_paths=~/.terraform.d
exclude=checkpoint_cache checkpoint_signature
EOF
      ;;
    ollama)
      cat <<'EOF'
description=Local LLM runner (snap) — models NOT backed up
install_type=snap
check_cmd=ollama
extensions=llama3.2
EOF
      ;;
    az)
      cat <<'EOF'
description=Microsoft Azure CLI (official MS apt repo)
install_type=custom
install_command=curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
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
install_type=npm-global
check_cmd=azurite
depends_apt=nodejs npm
EOF
      ;;
    slack)
      cat <<'EOF'
description=Slack desktop (snap)
install_type=snap
check_cmd=slack
EOF
      ;;
    onlyoffice)
      cat <<'EOF'
description=OnlyOffice desktop editors (snap)
install_type=snap
package=onlyoffice-desktopeditors
check_cmd=onlyoffice-desktopeditors
EOF
      ;;
    storage-explorer)
      cat <<'EOF'
description=Azure Storage Explorer (snap)
install_type=snap
check_cmd=storage-explorer
EOF
      ;;
    google-chrome|chrome)
      cat <<'EOF'
description=Google Chrome web browser
install_type=custom
install_command=wget -q -O /tmp/google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && sudo apt-get install -y /tmp/google-chrome.deb
check_cmd=google-chrome
depends_apt=wget
config_paths=~/.config/google-chrome
exclude=optimization_guide_model_store component_crx_cache WasmTtsEngine Safe*Browsing OnDeviceHeadSuggestModel GPUPersistentCache Crashpad GPUCache
EOF
      ;;
    fish)
      cat <<'EOF'
description=Friendly interactive shell (official apt)
install_type=apt
check_cmd=fish
config_paths=~/.config/fish
EOF
      ;;
    sqlitebrowser)
      cat <<'EOF'
description=DB Browser for SQLite (official apt)
install_type=apt
check_cmd=sqlitebrowser
config_paths=~/.config/sqlitebrowser
EOF
      ;;
    stacer)
      cat <<'EOF'
description=System optimizer & monitor (official apt)
install_type=apt
check_cmd=stacer
config_paths=~/.config/stacer
EOF
      ;;
    sublime-text)
      cat <<'EOF'
description=Sublime Text editor (official apt repo)
install_type=custom
install_command=sudo mkdir -p /etc/apt/keyrings && wget -qO - https://download.sublimetext.com/sublimehq-pub.gpg | sudo tee /etc/apt/keyrings/sublimehq-pub.asc > /dev/null && echo -e 'Types: deb\nURIs: https://download.sublimetext.com/\nSuites: apt/stable/\nSigned-By: /etc/apt/keyrings/sublimehq-pub.asc' | sudo tee /etc/apt/sources.list.d/sublime-text.sources && sudo apt-get update && sudo apt-get install -y sublime-text
check_cmd=sublime_text
depends_apt=wget
config_paths=~/.config/sublime-text
exclude=Log
EOF
      ;;
    freebuff)
      cat <<'EOF'
description=Freebuff AI coding assistant CLI (npm)
install_type=npm-global
check_cmd=freebuff
depends_apt=nodejs npm
config_paths=~/.config/manicode
exclude=projects freebuff rg tree-sitter.wasm
EOF
      ;;
    cloudflared)
      cat <<'EOF'
description=Cloudflare Tunnel client (official apt repo)
install_type=custom
install_command=sudo mkdir -p --mode=0755 /usr/share/keyrings && curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null && echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | sudo tee /etc/apt/sources.list.d/cloudflared.list && sudo apt-get update && sudo apt-get install -y cloudflared
check_cmd=cloudflared
depends_apt=curl
EOF
      ;;
    mongodb-compass)
      cat <<'EOF'
description=MongoDB GUI (official .deb, latest stable)
install_type=custom
install_command=DEB=$(curl -fsSL https://info-mongodb-com.s3.amazonaws.com/com-download-center/compass.json | grep -oE 'https://downloads.mongodb.com/compass/mongodb-compass_[0-9.]+_amd64.deb' | head -1) && [ -n "$DEB" ] && curl -fsSL -o /tmp/mongodb-compass.deb "$DEB" && sudo apt-get install -y /tmp/mongodb-compass.deb
check_cmd=mongodb-compass
depends_apt=curl
config_paths=~/.config/MongoDB Compass
exclude=Cache GPUCache DawnWebGPUCache DawnGraphiteCache
EOF
      ;;
  esac
}
