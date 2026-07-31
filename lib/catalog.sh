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
depends_apt=wget
config_paths=~/.config/google-chrome
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
EOF
      ;;
    freebuff)
      cat <<'EOF'
description=Freebuff AI coding assistant CLI (npm)
install_type=npm-global
check_cmd=freebuff
depends_apt=nodejs npm
config_paths=~/.config/manicode
EOF
      ;;
  esac
}
