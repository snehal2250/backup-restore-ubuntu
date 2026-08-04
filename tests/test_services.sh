#!/bin/bash
# ---------------------------------------------------------------------------
# test_services.sh — unit tests for the service start-guard helpers in
# lib/common.sh, added after the VirtualBox rehearsal finding: a unit whose
# ExecStart binary is missing (e.g. its app install failed mid-restore) must
# NOT be started, because systemd would just sit in a restart loop
# (cloudflared hit counter 118 in the rehearsal).
#
#   service_start_binary UNIT_FILE  — first token of ExecStart= (prefix chars
#                                     -/@/: and quotes stripped), empty for
#                                     units without ExecStart (timers...).
#   service_can_start UNIT_NAME UNIT_FILE — 1 when the ExecStart binary is
#                                     missing (skip start), 0 otherwise.
# ---------------------------------------------------------------------------
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"

sandbox_new

_write_unit() {  # NAME CONTENT
  printf '%s\n' "$2" > "$SANDBOX/$1"
}

# --- service_start_binary: ExecStart parsing ---------------------------------
t_begin "service_start_binary: plain ExecStart"
_write_unit plain.service "ExecStart=/usr/bin/cloudflared tunnel run"
assert_eq "/usr/bin/cloudflared" "$(service_start_binary "$SANDBOX/plain.service")" "first token"

t_begin "service_start_binary: systemd prefix chars stripped (- @ :)"
_write_unit dash.service "ExecStart=-/usr/bin/foo --ignore-errors"
assert_eq "/usr/bin/foo" "$(service_start_binary "$SANDBOX/dash.service")" "- prefix"
_write_unit at.service "ExecStart=@/usr/bin/bar arg0 --flag"
assert_eq "/usr/bin/bar" "$(service_start_binary "$SANDBOX/at.service")" "@ prefix"
_write_unit colon.service "ExecStart=:/usr/bin/baz"
assert_eq "/usr/bin/baz" "$(service_start_binary "$SANDBOX/colon.service")" ": prefix"

t_begin "service_start_binary: quoted binary and env wrappers"
_write_unit quoted.service 'ExecStart="/usr/bin/echo" --arg'
assert_eq "/usr/bin/echo" "$(service_start_binary "$SANDBOX/quoted.service")" "quoted binary"
_write_unit env.service 'ExecStart=/usr/bin/env bash -c "echo hi"'
assert_eq "/usr/bin/env" "$(service_start_binary "$SANDBOX/env.service")" "env wrapper"

t_begin "service_start_binary: multiple ExecStart lines -> first wins, no SIGPIPE"
_write_unit multi.service $'ExecStart=/usr/bin/one --a\nExecStart=/usr/bin/two --b'
assert_eq "/usr/bin/one" "$(service_start_binary "$SANDBOX/multi.service")" "first ExecStart line wins"

t_begin "service_start_binary: no ExecStart -> empty (timers, sockets)"
_write_unit timer.service "[Timer]\nOnCalendar=daily"
assert_eq "" "$(service_start_binary "$SANDBOX/timer.service")" "timer unit"
_write_unit preonly.service "ExecStartPre=/usr/bin/foo"
assert_eq "" "$(service_start_binary "$SANDBOX/preonly.service")" "ExecStartPre only (not ExecStart)"
assert_eq "" "$(service_start_binary "$SANDBOX/nonexistent.service")" "missing file"

# --- service_can_start: start guard ------------------------------------------
t_begin "service_can_start: existing binary -> start allowed"
_write_unit good.service "ExecStart=/bin/echo hi"
assert_ok service_can_start good.service "$SANDBOX/good.service"

t_begin "service_can_start: missing binary -> start skipped (returns 1)"
_write_unit bad.service "ExecStart=/usr/bin/definitely-not-installed-xyz --run"
set +e
_out="$(service_can_start bad.service "$SANDBOX/bad.service")"
_rc=$?
set -e
assert_eq "1" "$_rc" "returns 1 -> skip start"
assert_str_contains "not found" "$_out" "warns the binary is missing"
assert_str_contains "restart loop" "$_out" "explains why (restart loop)"

t_begin "service_can_start: missing binary under --dry-run -> still skips, prints note"
DRY_RUN=1
set +e
_out="$(service_can_start bad.service "$SANDBOX/bad.service")"
_rc=$?
set -e
DRY_RUN=0
assert_eq "1" "$_rc" "dry-run returns 1 (plan is truthful)"
assert_str_contains "[dry-run]" "$_out" "prints a dry-run note"

t_begin "service_can_start: no ExecStart (timer) -> startable when no paired file given"
_write_unit only-timer.service "[Timer]\nOnCalendar=daily"
assert_ok service_can_start only-timer.service "$SANDBOX/only-timer.service"

t_begin "service_can_start: timer with missing paired-service binary -> skip start"
_write_unit t2.timer "[Timer]\nOnCalendar=daily"
_write_unit t2.service "ExecStart=/usr/bin/definitely-not-installed-xyz --run"
set +e
_out="$(service_can_start t2.timer "$SANDBOX/t2.timer" "$SANDBOX/t2.service")"
_rc=$?
set -e
assert_eq "1" "$_rc" "timer skipped when payload binary missing"
assert_str_contains "paired unit" "$_out" "names the paired unit"

DRY_RUN=1
set +e
_out="$(service_can_start t2.timer "$SANDBOX/t2.timer" "$SANDBOX/t2.service")"
_rc=$?
set -e
DRY_RUN=0
assert_eq "1" "$_rc" "dry-run still skips the timer (plan is truthful)"
assert_str_contains "[dry-run]" "$_out" "prints a dry-run note"

t_begin "service_can_start: timer with good paired-service binary -> startable"
_write_unit t3.timer "[Timer]\nOnCalendar=daily"
_write_unit t3.service "ExecStart=/bin/echo hi"
assert_ok service_can_start t3.timer "$SANDBOX/t3.timer" "$SANDBOX/t3.service"

t_begin "service_can_start: missing unit file -> startable (nothing to check)"
assert_ok service_can_start ghost.service "$SANDBOX/ghost.service"

sandbox_cleanup

t_summary
