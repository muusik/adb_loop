# shellcheck shell=sh
# phone.sh: reaching the phone over adb. Sourced after the project's loop/project.sh, which sets:
#
#   adb_loop_address       the address the user asked for, usually from the project's own variable; empty for none
#   adb_loop_default       the address to try when none was asked for
#   adb_loop_last_address  optional: a file holding the phone's last known host, tried second while under 12 hours old
#   adb_loop_on_connect    optional: a function to call once the phone answers over the network
#
# An address with a port is connected to first. One without is used as an adb serial (emulator-5554).
# shellcheck disable=SC2154  # set by loop/project.sh
. "$adb_loop_path/where.sh"

# Ctrl-C reaches the command: plain timeout moves to a process group of its own, so the terminal's signal ends only the
# script around it, and adb waits on to the end of its limit.
timeout() { command timeout --foreground "$@"; }

# Whether a shell opens on this address. Not get-state, which says "device" while a restarted adbd still closes what is
# opened; and adb connect says "failed to connect" with status 0, and hangs for minutes on an address with no route. A
# shell reads its standard input, which in a while-read loop is the rest of the list.
phone_answers() {
  case "$1" in
    *:*) timeout 5 adb connect "$1" >/dev/null 2>&1 ;;
  esac
  timeout 10 adb -s "$1" shell true </dev/null >/dev/null 2>&1
}

# Points ANDROID_SERIAL at the first address that answers, one try each; phone_tried lists them for the message when none
# does.
phone_connect() {
  if [ -n "${adb_loop_address:-}" ]; then
    set -- "$adb_loop_address"
  else
    set -- "${adb_loop_default:-}"
    if [ -n "${adb_loop_last_address:-}" ] && [ -f "$adb_loop_last_address" ] &&
       [ $(($(date +%s) - $(stat -c %Y "$adb_loop_last_address"))) -lt 43200 ]; then
      phone_last=$(head -n 1 "$adb_loop_last_address" | tr -d ' \r')
      [ -z "$phone_last" ] || set -- "$1" "$phone_last:5555"
    fi
  fi
  phone_tried=
  for phone_serial in "$@"; do
    [ -n "$phone_serial" ] || continue
    phone_tried="${phone_tried:+$phone_tried, }$phone_serial"
    if phone_answers "$phone_serial"; then
      ANDROID_SERIAL=$phone_serial
      export ANDROID_SERIAL
      [ -z "${adb_loop_on_connect:-}" ] || "$adb_loop_on_connect"
      return 0
    fi
  done
  return 1
}

# The network in the container, or when an address was asked for; else this machine's adb, whatever has it (USB or
# wireless). A project's scripts may act on where they run, so the default address is not tried outside the container.
phone_by_address() { in_container || [ -n "${adb_loop_address:-}" ]; }

# Until the phone answers, up to TRIES times (default 1), 2 s apart: a dropped link comes back by itself. Fails when not.
phone_wait() {
  phone_tries=${1:-1}
  while :; do
    if phone_by_address; then
      phone_connect && return 0
    else
      timeout 10 adb shell true </dev/null >/dev/null 2>&1 && return 0
    fi
    phone_tries=$((phone_tries - 1))
    [ "$phone_tries" -gt 0 ] || return 1
    sleep 2
  done
}

# The first thing a script declared adb_client does with the phone: TRIES as phone_wait, or the script ends with exit 1.
phone_reach() {
  phone_wait "${1:-1}" && return 0
  if phone_by_address; then
    echo "the phone does not answer at ${phone_tried:-no address}" >&2
  else
    echo "no phone on this machine's adb${ANDROID_SERIAL:+ at $ANDROID_SERIAL}" >&2
  fi
  exit 1
}
