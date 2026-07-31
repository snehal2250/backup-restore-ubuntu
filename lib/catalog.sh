#!/bin/bash
# ---------------------------------------------------------------------------
# catalog.sh — built-in knowledge of common apps, used by ./inventory.sh add-app.
#
# catalog_lookup NAME prints a KEY=VALUE template (or nothing if the app is
# unknown). Keys match the fields of an `apps:` entry in inventory.yaml:
#   description, install_type, install_command, check_cmd, depends_apt, config_paths
#
# The catalog is only a SUGGESTION source for the manual inventory tool. It is
# never consulted by backup.sh / restore.sh — those read ONLY inventory.yaml.
# Extend this list as the user adopts more apps.
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
EOF
      ;;
    code|vscode)
      cat <<'EOF'
description=Visual Studio Code
install_type=snap-classic
check_cmd=code
config_paths=~/.config/Code
EOF
      ;;
    docker)
      cat <<'EOF'
description=Docker container runtime
install_type=apt
check_cmd=docker
config_paths=~/.docker
EOF
      ;;
    google-chrome|chrome)
      cat <<'EOF'
description=Google Chrome web browser
install_type=custom
install_command=wget -q -O /tmp/google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && sudo apt-get install -y /tmp/google-chrome.deb
check_cmd=google-chrome
config_paths=~/.config/google-chrome
EOF
      ;;
  esac
}
