# shellcheck shell=sh
# install.sh: a build installed over the app on the phone. Sourced after the project's loop/project.sh, which sets, as well
# as phone.sh's settings:
#
#   adb_loop_package      the app's package (com.example.app)
#   adb_loop_label_file   optional: a file on the phone that gets the label of the build installed, for what reads it there
#   adb_loop_install_log  optional: a file here that gets a line per install: date, label, the phone, the APK
#   adb_loop_repo         optional: the git repository the labels' commits are in (the project's checkout). With it and
#                         a label file, an install that would take work off the phone is refused (below)
#   adb_loop_install_older  "yes": install even so, on purpose
#
# A project may redefine, after sourcing this:
#
#   install_before_clear  called before the phone's logcat is cleared, to keep what the last build logged. Default: nothing
#
# install_apk APK LABEL [EXTRA ...] installs on the phone that ANDROID_SERIAL names (phone_reach or phone_connect first),
# with adb's --fastdeploy: only the APK's entries that differ from the installed one's cross the link, from Google's
# platform-tools 36.0.0 (37.0.1 refuses it on an API 35 phone, and Debian's adb installs the whole APK). An install can say
# success and leave the old build in place (over a VPN, once), so the package's update time is read before and after, and
# the same time is a failure. Then the logcat is cleared, so that the next dump starts with this build, the label
# recorded, and the app, which an install ends, started again if it was running, never on a phone where it was closed;
# EXTRA goes to its am start (--es key value). Returns 0 when installed, 3 when the phone's copy is signed by another key
# (what to do then, an uninstall that deletes the app's data, is the project's), 4 when the phone's build has work this
# one lacks (below), 1 for any other failure. It holds the
# device's lease while it installs (lease.sh: phone, or emulator for an emulator), unless the script holds it already,
# as one does that checks the phone before it installs.
#
# Jobs that build in worktrees of their own install beside each other, and one branched before another's work landed
# would put a build without that work over it (bsfc_mapper, 2026-11-12: a worktree's build replaced the landed one for
# four minutes). So with adb_loop_repo and a label file, the label on the phone is read first (under the lease), and
# the install returns 4, nothing done, when the phone's build has commits that this one lacks and that some branch
# still holds: work that landed, or another job's that has not yet. Commits on no branch any more are left behind
# freely: the job's own build before bl-land rebased it, or before an amend. A label is git describe's (a tag, or
# tag-N-hash, the hash with or without its "g", "-dirty" or not) or a bare hash; one that names no commit here (a
# checkout that has not fetched it, "unknown") is said and the install goes on.

# shellcheck disable=SC1091,SC2154  # set by loop/project.sh
. "$adb_loop_path/phone.sh"
. "$adb_loop_path/lease.sh"

install_before_clear() { return 0; }

# The app's process id on the phone, empty when it is not running.
app_pid() { timeout 20 adb shell pidof "$adb_loop_package" </dev/null 2>/dev/null | tr -d '\r'; }

# The package's lastUpdateTime, empty when the phone does not answer or the app is not installed.
app_updated() {
  timeout 20 adb shell dumpsys package "$adb_loop_package" </dev/null | tr -d '\r' |
    sed -n 's/^ *lastUpdateTime=//p' | head -n 1
}

# The launcher activity, resolved by the package manager: its class name may carry a build hash.
app_activity() {
  app_activity_found=$(timeout 20 adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER \
    "$adb_loop_package" </dev/null | tr -d '\r' | tail -n 1)
  case "$app_activity_found" in "$adb_loop_package"/*) echo "$app_activity_found" ;; *) return 1 ;; esac
}

# Starts the app's launcher activity; the arguments go to am start (--es key value).
app_start() {
  app_start_activity=$(app_activity) || { echo "the app's launcher activity was not found; not started" >&2; return 1; }
  timeout 30 adb shell am start -n "$app_start_activity" "$@" </dev/null >/dev/null
}

install_apk() {
  install_lease=$(lease_device)
  if lease_held "$install_lease"; then
    install_apk_held "$@"
    return
  fi
  lease_take "$install_lease" || { echo "the $install_lease lease stayed busy: not installed" >&2; return 1; }
  install_apk_held "$@"
  install_status=$?
  lease_drop "$install_lease"
  return $install_status
}

# The commit a label names, empty when it names none here.
label_commit() {
  label_commit_l=${1%-dirty}
  case "$label_commit_l" in *-[0-9]*-*) label_commit_l=${label_commit_l##*-}; label_commit_l=${label_commit_l#g} ;; esac
  git -C "$adb_loop_repo" rev-parse --verify --quiet "$label_commit_l^{commit}" 2>/dev/null
}

# 0 when the build labelled $1 holds what the phone's does (or there is nothing to tell by), 4 when it does not.
install_in_order() {
  [ -n "${adb_loop_label_file:-}" ] && [ -n "${adb_loop_repo:-}" ] || return 0
  [ "${adb_loop_install_older:-no}" != yes ] || return 0
  order_phone=$(timeout 20 adb shell cat "$adb_loop_label_file" </dev/null 2>/dev/null | tr -d '\r\n')
  case "$order_phone" in ""|*[!A-Za-z0-9._-]*) return 0 ;; esac
  [ "$order_phone" != "$1" ] || return 0
  order_old=$(label_commit "$order_phone") ||
    { echo "the phone's build, $order_phone, is no commit here: installing without the order check" >&2; return 0; }
  order_new=$(label_commit "$1") ||
    { echo "$1 is no commit here: installing without the order check" >&2; return 0; }
  for order_c in $(git -C "$adb_loop_repo" rev-list "$order_new..$order_old"); do
    order_on=$(git -C "$adb_loop_repo" for-each-ref --contains "$order_c" --format='%(refname:short)' refs/heads |
      head -n 1)
    [ -z "$order_on" ] && continue
    echo "the phone has $order_phone; $1 lacks $(git -C "$adb_loop_repo" log -1 --format='%h "%s"' "$order_c")," \
      "which $order_on holds: not installed (rebase onto it, or install the older build on purpose)" >&2
    return 4
  done
}

install_apk_held() {
  install_file=$1; install_label=${2:-unknown}
  shift $(($# < 2 ? $# : 2))
  install_in_order "$install_label" || return
  install_was_running=$(app_pid)
  install_before=$(app_updated)
  install_started=$(date +%s)
  install_out=$(mktemp) || return 1
  # the output on the terminal as it comes, and kept for the reason of a failure; the status through a file, since a
  # pipeline's is tee's
  { timeout 300 adb install -r --fastdeploy "$install_file" </dev/null 2>&1; command echo $? > "$install_out.rc"; } |
    tee "$install_out"
  install_rc=$(cat "$install_out.rc" 2>/dev/null || command echo 1)
  install_incompatible=no
  grep -q INSTALL_FAILED_UPDATE_INCOMPATIBLE "$install_out" && install_incompatible=yes
  rm -f "$install_out" "$install_out.rc"
  if [ "$install_incompatible" = yes ]; then
    echo "the copy on ${ANDROID_SERIAL:-the phone} is signed by another key: not installed" >&2
    return 3
  fi
  [ "$install_rc" -eq 0 ] || { echo "adb install failed (status $install_rc)" >&2; return 1; }
  echo "install took $(($(date +%s) - install_started)) s"
  # read again while the phone does not answer: it dropped off adb mid-install once, and an empty reading passed
  install_after=$(app_updated); install_i=0
  while [ -z "$install_after" ] && [ $install_i -lt 6 ]; do
    sleep 5; install_i=$((install_i + 1)); install_after=$(app_updated)
  done
  if [ -z "$install_after" ] || [ "$install_after" = "$install_before" ]; then
    echo "the phone's package was not updated (lastUpdateTime ${install_after:-unreadable}, before ${install_before:-none}): not installed" >&2
    return 1
  fi
  { install_before_clear; true; } &&
  timeout 20 adb logcat -c </dev/null || return 1
  if [ -n "${adb_loop_label_file:-}" ]; then
    timeout 20 adb shell "echo '$install_label' > '$adb_loop_label_file'" </dev/null || return 1
  fi
  install_phone=${ANDROID_SERIAL:-$(timeout 10 adb get-serialno </dev/null 2>/dev/null)}
  if [ -n "${adb_loop_install_log:-}" ]; then
    mkdir -p "$(dirname "$adb_loop_install_log")" &&
    printf '%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "$install_label" "$install_phone" "$install_file" >> "$adb_loop_install_log" ||
      return 1
  fi
  echo "installed $install_label on ${install_phone:-the phone}"
  [ -n "$install_was_running" ] || return 0
  app_start "$@" && echo "started the app again${1:+ ($*)}"
}
