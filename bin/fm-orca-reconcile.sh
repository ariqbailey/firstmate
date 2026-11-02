#!/usr/bin/env bash
# Resolve the Orca receipts a failed launch or registration left in a local
# Orca secondmate's home, from a fresh Orca read.
#
# Usage: fm-orca-reconcile.sh <secondmate-id>
#
# The home is the one this home's task record or data/secondmates.md names for
# <secondmate-id>. Two kinds of receipt are resolved, each only when Orca
# proves the outcome:
#   - A pending registration receipt (state/orca-registrations) rolls back when
#     Orca has no registration for its path, and is adopted as owned when Orca
#     has one (matching the id the add returned, when that was recorded) whose
#     root workspace and ready setup check out. An interrupted receipt write is
#     removed.
#   - The launch receipt (state/orca-secondmate-launch) retires when the task
#     record already names its terminal. Otherwise the terminal it names is
#     closed when it is in the home workspace, and the receipt goes once every
#     terminal left there is the recorded one.
# Anything uncertain refuses and keeps the receipt. This runs under the
# secondmate's task-record lock and the home's receipt lock, so it never races
# a spawn or retirement of the same secondmate. It never deletes an Orca
# registration, worktree, or setup.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '5p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ "$#" -eq 1 ] || usage
ID=$1
case "$ID" in ''|-*|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac

META="$STATE/$ID.meta"
HOME_PATH=
RECORDED_WORKSPACE=
RECORDED_TERMINAL=
if [ -e "$META" ] || [ -L "$META" ]; then
  [ -f "$META" ] && [ ! -L "$META" ] || die "unsafe task record $META"
  [ "$(fm_meta_get "$META" kind)" = secondmate ] || die "task $ID is not a secondmate"
  [ "$(fm_backend_of_meta "$META")" = orca ] || die "secondmate $ID is not recorded on backend=orca"
  HOME_PATH=$(fm_meta_get "$META" home)
elif [ -f "$DATA/secondmates.md" ]; then
  HOME_PATH=$(secondmate_registry_field "$DATA/secondmates.md" "$ID" home || true)
fi
[ -n "$HOME_PATH" ] || die "no home recorded or registered for secondmate $ID"
HOME_PATH=$(cd "$HOME_PATH" 2>/dev/null && pwd -P) || die "secondmate home for $ID is missing"
[ -f "$HOME_PATH/.fm-secondmate-home" ] || die "$HOME_PATH is not a seeded secondmate home"
[ "$(tr -d '[:space:]' < "$HOME_PATH/.fm-secondmate-home")" = "$ID" ] \
  || die "$HOME_PATH is seeded for another secondmate"

fm_backend_source orca || exit 1
fm_backend_orca_tool_check || exit 1

META_LOCK=$(fm_meta_lock_path "$META") || die "task record lock path is invalid for $ID"
mkdir -p "$STATE"
fm_lock_acquire_wait "$META_LOCK" || die "cannot lock the task record for $ID"
trap 'fm_lock_release "$META_LOCK" || true' EXIT
if [ -f "$META" ]; then
  RECORDED_WORKSPACE=$(fm_meta_get "$META" orca_worktree_id)
  RECORDED_TERMINAL=$(fm_meta_get "$META" terminal)
fi

fm_backend_orca_home_reconcile "$HOME_PATH"
fm_backend_orca_home_reconcile_launch "$HOME_PATH" "$RECORDED_WORKSPACE" "$RECORDED_TERMINAL"
echo "reconciled Orca receipts for secondmate $ID"
