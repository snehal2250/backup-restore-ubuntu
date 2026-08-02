#!/bin/bash
# ---------------------------------------------------------------------------
# test_phases.sh — unit tests for the resumable-restore phase framework in
# lib/common.sh: phase_canonical (alias resolution), phase_enabled (legacy
# --configs-only/--packages-only modes + --from-phase/--only/--skip gating),
# and app_selected (--only/--skip app filtering in the apps phase).
# ---------------------------------------------------------------------------
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"

# Reset the flag state between groups.
reset_flags() {
  PHASES_FROM=""
  PHASES_ONLY=()
  PHASES_SKIP=()
  APPS_ONLY=()
  APPS_SKIP=()
  CONFIGS_ONLY=0
  PACKAGES_ONLY=0
}

# --- phase_canonical ---------------------------------------------------------
t_begin "phase_canonical: canonical names round-trip, aliases resolve, junk empty"
assert_eq "base"       "$(phase_canonical base)"       "base"
assert_eq "packages"   "$(phase_canonical packages)"   "packages"
assert_eq "apps"       "$(phase_canonical apps)"       "apps"
assert_eq "services"   "$(phase_canonical services)"   "services"
assert_eq "dotfiles"   "$(phase_canonical dotfiles)"   "dotfiles"
assert_eq "postinstall" "$(phase_canonical postinstall)" "postinstall"
assert_eq "dotfiles"   "$(phase_canonical user-data)"  "user-data alias"
assert_eq ""           "$(phase_canonical bogus)"      "unknown name"

# --- phase_enabled: defaults -------------------------------------------------
t_begin "phase_enabled: all phases run by default"
reset_flags
for _p in base packages apps services dotfiles postinstall; do
  assert_ok phase_enabled "$_p"
done

# --- phase_enabled: legacy modes ---------------------------------------------
t_begin "phase_enabled: --configs-only skips base/packages/postinstall"
reset_flags
CONFIGS_ONLY=1
assert_fail phase_enabled base
assert_fail phase_enabled packages
assert_ok phase_enabled apps
assert_ok phase_enabled services
assert_ok phase_enabled dotfiles
assert_fail phase_enabled postinstall

t_begin "phase_enabled: --packages-only skips dotfiles/postinstall"
reset_flags
PACKAGES_ONLY=1
assert_ok phase_enabled base
assert_ok phase_enabled packages
assert_ok phase_enabled apps
assert_ok phase_enabled services
assert_fail phase_enabled dotfiles
assert_fail phase_enabled postinstall

# --- phase_enabled: --from-phase ----------------------------------------------
t_begin "phase_enabled: --from-phase apps skips everything before apps"
reset_flags
PHASES_FROM="apps"
assert_fail phase_enabled base
assert_fail phase_enabled packages
assert_ok phase_enabled apps
assert_ok phase_enabled services
assert_ok phase_enabled dotfiles
assert_ok phase_enabled postinstall

t_begin "phase_enabled: --from-phase base runs everything"
reset_flags
PHASES_FROM="base"
assert_ok phase_enabled base
assert_ok phase_enabled packages
assert_ok phase_enabled apps

t_begin "phase_enabled: --from-phase postinstall runs only postinstall"
reset_flags
PHASES_FROM="postinstall"
assert_fail phase_enabled base
assert_fail phase_enabled packages
assert_fail phase_enabled apps
assert_fail phase_enabled services
assert_fail phase_enabled dotfiles
assert_ok phase_enabled postinstall

# --- phase_enabled: --only / --skip (phase names) -----------------------------
t_begin "phase_enabled: --only base,packages restricts to those"
reset_flags
PHASES_ONLY=(base packages)
assert_ok phase_enabled base
assert_ok phase_enabled packages
assert_fail phase_enabled apps
assert_fail phase_enabled services
assert_fail phase_enabled dotfiles
assert_fail phase_enabled postinstall

t_begin "phase_enabled: --skip services skips only that phase"
reset_flags
PHASES_SKIP=(services)
assert_fail phase_enabled services
assert_ok phase_enabled base
assert_ok phase_enabled packages
assert_ok phase_enabled apps
assert_ok phase_enabled dotfiles
assert_ok phase_enabled postinstall

t_begin "phase_enabled: app names in --only/--skip never gate whole phases"
reset_flags
APPS_ONLY=(code docker)
assert_ok phase_enabled apps
assert_ok phase_enabled base
reset_flags
APPS_SKIP=(code)
assert_ok phase_enabled apps

# --- phase_enabled: combinations ----------------------------------------------
t_begin "phase_enabled: --from-phase apps + --skip services"
reset_flags
PHASES_FROM="apps"
PHASES_SKIP=(services)
assert_fail phase_enabled base
assert_fail phase_enabled packages
assert_ok phase_enabled apps
assert_fail phase_enabled services
assert_ok phase_enabled dotfiles
assert_ok phase_enabled postinstall

t_begin "phase_enabled: --only apps + --configs-only"
reset_flags
CONFIGS_ONLY=1
PHASES_ONLY=(apps)
assert_fail phase_enabled base
assert_fail phase_enabled packages
assert_ok phase_enabled apps
assert_fail phase_enabled services
assert_fail phase_enabled dotfiles
assert_fail phase_enabled postinstall

# --- app_selected --------------------------------------------------------------
t_begin "app_selected: --only restricts the apps phase"
reset_flags
APPS_ONLY=(code docker)
assert_ok app_selected code
assert_ok app_selected docker
assert_fail app_selected tmux
assert_fail app_selected opencode

t_begin "app_selected: --skip excludes specific apps"
reset_flags
APPS_SKIP=(tmux)
assert_fail app_selected tmux
assert_ok app_selected code
assert_ok app_selected opencode

t_begin "app_selected: no selection -> every app runs"
reset_flags
assert_ok app_selected anything

# --- apply_selection (--only/--skip classification) ---------------------------
_FAKE_APPS=$'code\ndocker\ngit'

reset_flags
t_begin "apply_selection: phases and apps classify into separate arrays"
apply_selection only "$_FAKE_APPS" code docker base user-data
assert_eq "base"     "${PHASES_ONLY[0]}"  "phase only[0]"
assert_eq "dotfiles" "${PHASES_ONLY[1]}"  "user-data alias -> dotfiles"
assert_eq "code"     "${APPS_ONLY[0]}"   "app only[0]"
assert_eq "docker"   "${APPS_ONLY[1]}"   "app only[1]"
assert_eq "0"        "${#PHASES_SKIP[@]}" "no skips classified"
assert_eq "0"        "${#APPS_SKIP[@]}"  "no app skips classified"

reset_flags
t_begin "apply_selection: skip variant"
apply_selection skip "$_FAKE_APPS" git services
assert_eq "services" "${PHASES_SKIP[0]}" "phase skip"
assert_eq "git"      "${APPS_SKIP[0]}"   "app skip"

reset_flags
t_begin "apply_selection: empty tokens are ignored"
apply_selection only "$_FAKE_APPS" "" code
assert_eq "code" "${APPS_ONLY[0]}" "empty token skipped"

reset_flags
t_begin "apply_selection: unknown names die (typo guard, subshell-isolated)"
if ( apply_selection only "$_FAKE_APPS" nosuchapp ) >/dev/null 2>&1; then
  t_fail "unknown app should die"
else
  t_pass "unknown app dies"
fi
if ( apply_selection skip "$_FAKE_APPS" nosuchphase ) >/dev/null 2>&1; then
  t_fail "unknown phase should die"
else
  t_pass "unknown phase dies"
fi
# The arrays must be unchanged after the failed attempts.
assert_eq "0" "${#APPS_ONLY[@]}" "no apps classified after die"

# --- check_phase_conflicts (legacy-mode vs phase-filter contradictions) --------
t_begin "check_phase_conflicts: no flags -> no warnings"
reset_flags
assert_eq "" "$(check_phase_conflicts 2>&1)" "silent with no flags"

t_begin "check_phase_conflicts: warns when a legacy mode suppresses an --only phase"
reset_flags
PACKAGES_ONLY=1
PHASES_ONLY=(dotfiles)
_out="$(check_phase_conflicts 2>&1)"
assert_str_contains "dotfiles" "$_out" "names the suppressed phase"
assert_str_contains "suppressed" "$_out" "uses 'suppressed' wording"

t_begin "check_phase_conflicts: ALL --only phases suppressed -> stronger warning"
reset_flags
CONFIGS_ONLY=1
PHASES_ONLY=(base packages)
_out="$(check_phase_conflicts 2>&1)"
assert_str_contains "nothing will run" "$_out" "warns nothing will run"

t_begin "check_phase_conflicts: partial suppression warns but stays usable"
reset_flags
CONFIGS_ONLY=1
PHASES_ONLY=(base dotfiles)   # configs-only suppresses base, NOT dotfiles
_out="$(check_phase_conflicts 2>&1)"
assert_str_contains "base" "$_out" "warns base suppressed"
assert_str_contains "suppressed by" "$_out" "partial-suppression wording"

t_begin "check_phase_conflicts: warns when --from-phase is suppressed"
reset_flags
PACKAGES_ONLY=1
PHASES_FROM="dotfiles"
_out="$(check_phase_conflicts 2>&1)"
assert_str_contains "dotfiles" "$_out" "names the suppressed resume point"
assert_str_contains "may do nothing" "$_out" "may-do-nothing wording"

t_begin "check_phase_conflicts: warns cause-neutrally when --from-phase suppresses an --only phase"
reset_flags
PHASES_FROM="services"
PHASES_ONLY=(base)   # no legacy mode — suppression comes from --from-phase
_out="$(check_phase_conflicts 2>&1)"
assert_str_contains "base" "$_out" "names the suppressed phase"
assert_str_contains "phase gating" "$_out" "cause-neutral wording (not 'legacy mode')"

t_begin "check_phase_conflicts: compatible combos produce no warning"
reset_flags
CONFIGS_ONLY=1
PHASES_ONLY=(dotfiles)        # configs-only does NOT suppress dotfiles
assert_eq "" "$(check_phase_conflicts 2>&1)" "silent for compatible combo"

t_begin "check_phase_conflicts: --from-phase + a runnable later --only phase is NOT a conflict"
reset_flags
PHASES_FROM="services"
PHASES_ONLY=(dotfiles)        # dotfiles is after services and still runs
assert_eq "" "$(check_phase_conflicts 2>&1)" "silent — the run still does something"

t_begin "check_phase_conflicts: --from-phase with no runnable phase at/after it warns"
reset_flags
PHASES_FROM="services"
PHASES_SKIP=(services dotfiles postinstall)   # everything at/after services is skipped
_out="$(check_phase_conflicts 2>&1)"
assert_str_contains "services" "$_out" "names the resume point"
assert_str_contains "may do nothing" "$_out" "may-do-nothing wording"

t_begin "check_phase_conflicts: no redundant from-phase warning after an --only all-suppressed warning"
reset_flags
PHASES_FROM="services"
PHASES_ONLY=(base)            # the --only warning already says nothing will run
_out="$(check_phase_conflicts 2>&1)"
assert_str_contains "nothing will run" "$_out" "the --only all-suppressed warning fires"
if printf '%s\n' "$_out" | grep -q "no phase at or after"; then
  t_fail "redundant --from-phase warning emitted after the --only all-suppressed warning"
else
  t_pass "no redundant --from-phase warning"
fi

reset_flags

t_summary
