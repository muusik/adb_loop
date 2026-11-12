# shellcheck shell=sh
# lease.sh: a named lease shared by every session and job on the machine, held by a part of a script. Sourced.
#
#   lease_take NAME [SECONDS]   waits up to SECONDS (default 600) for NAME, then holds it; 0 held, 75 still busy
#   lease_drop NAME             lets it go; the script's end lets go of what it still holds
#   lease_held NAME             whether this script, or one it was started from, holds NAME
#   lease_device                the lease for the device ANDROID_SERIAL names: emulator for emulator-*, else phone
#
# The lease is bread_ladder's (bl-lease run, a lock in a directory every container of the machine mounts): what one
# job's script holds, another's waits for, in this container or another, and bl-lease list says who holds it. Where
# bl-lease is not on the PATH (the laptop, a machine without bread_ladder) there is no one to share with, and these do
# nothing. A lease this script or one it was started from already holds (BL_LEASES_HELD, inherited) is not taken again:
# the second taker would wait for the first, which waits for it.
#
# bl-lease holds a lease while a command runs. Here that command is a stand-in that lives until lease_drop ends it, or
# until the script exits, whichever is first; a script killed with -9 lets go a second later.

# The variable that holds NAME's stand-in: lease_pid_ and NAME with what a name may not have as _.
lease_var() { printf 'lease_pid_%s' "$1" | tr -c 'A-Za-z0-9_' _; }

lease_held() { case " ${BL_LEASES_HELD:-} " in *" $1 "*) return 0 ;; esac; return 1; }

lease_take() {
  lease_name=$1
  ! lease_held "$lease_name" || return 0
  command -v bl-lease >/dev/null 2>&1 || return 0
  lease_dir=$(mktemp -d) || return 1
  : > "$lease_dir/said"
  # The stand-in writes its pid once it runs, which is once the lease is held; the status, once bl-lease has ended.
  # None of them keeps the script's output open: a parent that reads it to the end before it reaps the script (a
  # $(...), a pipe) would wait for the stand-in, which waits for the script to be gone. bl-lease's messages (who holds
  # it, the wait) go through a file, passed on as they come.
  # shellcheck disable=SC2016  # expanded by the stand-in's shell
  { bl-lease run "$lease_name" -w "${2:-600}" -- \
      sh -c 'echo $$ > "$1.new" && mv "$1.new" "$1" && exec tail --pid="$2" -f /dev/null' \
      "lease for $(basename "$0")" "$lease_dir/held" $$ 2> "$lease_dir/said"
    echo $? > "$lease_dir/status"
  } < /dev/null > /dev/null 2>&1 &
  lease_job=$!
  lease_shown=0
  while :; do
    lease_said=$(wc -c < "$lease_dir/said")
    if [ "$lease_said" -gt "$lease_shown" ]; then
      tail -c +$((lease_shown + 1)) "$lease_dir/said" | head -c $((lease_said - lease_shown)) >&2
      lease_shown=$lease_said
    fi
    if [ -s "$lease_dir/held" ] || [ -s "$lease_dir/status" ]; then break; fi
    command sleep 0.1
  done
  if [ ! -s "$lease_dir/held" ]; then
    tail -c +$((lease_shown + 1)) "$lease_dir/said" >&2 2>/dev/null
    lease_status=$(cat "$lease_dir/status")
    wait "$lease_job"
    rm -rf "$lease_dir"
    return "$lease_status"
  fi
  eval "$(lease_var "$lease_name")=\"\$(cat \"\$lease_dir/held\") \$lease_job \$lease_dir\""
  BL_LEASES_HELD="${BL_LEASES_HELD:+$BL_LEASES_HELD }$lease_name"
  export BL_LEASES_HELD
}

lease_drop() {
  lease_name=$1
  eval "lease_held=\${$(lease_var "$lease_name"):-}"
  # shellcheck disable=SC2154  # set by the eval
  [ -n "$lease_held" ] || return 0
  # shellcheck disable=SC2086  # the stand-in's pid, the job's and the directory
  set -- $lease_held
  kill "$1" 2>/dev/null
  wait "$2"
  rm -rf "$3"
  eval "unset $(lease_var "$lease_name")"
  # shellcheck disable=SC2086  # one name a line
  BL_LEASES_HELD=$(printf '%s\n' $BL_LEASES_HELD | grep -vxF "$lease_name" | tr '\n' ' ')
  BL_LEASES_HELD=${BL_LEASES_HELD% }
  export BL_LEASES_HELD
}

lease_device() {
  case "${ANDROID_SERIAL:-}" in emulator-*) echo emulator ;; *) echo phone ;; esac
}
