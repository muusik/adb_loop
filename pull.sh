# shellcheck shell=sh
# pull.sh: a directory of an app's on the phone, mirrored here as deltas. Sourced by a project's loop/pull.sh, which
# sets pull_remote (the directory on the phone) and pull_dest (the one here), redefines the pull_* rules below for its own
# files, then calls phone_reach, pull_ask_gzip, pull_all and, unless told to keep, prune_phone.
#
# adb has no rsync (adb sync is for system images, push --sync is push-only), so each file on the phone is compared with
# the copy here. The same size: skipped, unless pull_same_size_is_same says otherwise and it is under 1 MB, when its md5
# decides. An append-only file that the copy is a prefix of (its md5 against the phone's first bytes), or that has no
# copy, has only its tail fetched, up to the size listed, so a file still growing is taken as far as the listing saw it.
# An append-only copy that is not the start of the phone's file, or any copy longer than the phone's, is kept as .stale
# before the whole file comes. A whole file goes into <copy>.part and replaces the copy once its md5 is the phone's.
#
# Every transfer resumes: the bytes go through the phone's gzip and are unpacked here as they come, and a link that drops
# leaves an exact prefix (gunzip writes what it has decoded). adb pull would delete what it got. Without a gzip on the
# phone the bytes go plain, and so do a file's that pull_compressed names: gzip would cost the phone's CPU and save
# nothing. When a transfer stops, the pull waits for the phone and goes on from there, up to
# ADB_LOOP_WAIT_TRIES tries of it answering (default 15, about half a minute or more) and 3 attempts at a file. Android
# restarts adbd when the screen is locked or unlocked, if Developer options' "Default USB configuration" is anything but
# "No data transfer". A phone that does not come back ends the pull with exit 1; the next run goes on.
#
# prune_phone removes files not modified for KEEP_DAYS days (default 7) of the kinds pull_prunable_kind names, each only
# once the copy here is byte for byte the phone's (size and md5).
#
# Each step says what it is doing as it starts. While pull_all runs, a second process (the monitor) keeps two status lines
# under them on a terminal: the whole pull's progress (bytes, rate, time left, the file at hand) and the link (link.sh:
# the Wi-Fi, the band, the signal, the screen and its power save, a VPN, which way adb goes), asked every 15 s, with a
# line that stays whenever the link changes. Piped, there are only the lines that stay. Either way it writes the same as
# key=value lines to $ADB_LOOP_STATUS_DIR/pull-<pid>.status (default $XDG_RUNTIME_DIR/adb_loop, else /tmp/adb_loop), once
# a second, for a viewer such as Claude Code's pane (README); the last state, done or failed, stays there for a day.

# shellcheck disable=SC1091,SC2154  # set by loop/project.sh
. "$adb_loop_path/phone.sh"
. "$adb_loop_path/link.sh"

keep_days=${KEEP_DAYS:-7}
# shellcheck disable=SC2034  # for a project's pull_prunable_kind
min_kb=${PRUNE_MIN_KB:-100}
pull_wait_tries=${ADB_LOOP_WAIT_TRIES:-15}
pull_attempts=3
zip="cat"; unzip="cat"
pull_status_dir=${ADB_LOOP_STATUS_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/adb_loop}
# the whole pull's progress, for the monitor: its pid while it runs, the bytes fetched, the file being written
pull_monitor=; pull_done=0; pull_need=0; pull_out=; pull_from=0; pull_rel=; pull_n=0; pull_total=0; pull_state=

# --- the rules, for a project to redefine after sourcing this; $1 is a path relative to pull_remote

# only ever appended to: a tail is enough. Default: nothing is
pull_append_only() { return 1; }
# the same size means the same file, with no md5 round trip. Default: what is append-only
pull_same_size_is_same() { pull_append_only "$1"; }
# $2 is its size: of a kind that may go from the phone once it is old and held here. Default: nothing may
pull_prunable_kind() { return 1; }
# already compressed, so its bytes go plain, not through the phone's gzip. Default: .gz, .xz, .zst, .bz2, .zip
pull_compressed() { case "$1" in *.gz|*.xz|*.zst|*.bz2|*.zip) return 0 ;; *) return 1 ;; esac; }
# to be pulled at all. Default: everything
pull_wanted() { return 0; }
# the phone's command that lists what may be pruned, given the find arguments in $1 that select and print the old files.
# Default: the whole directory
pull_prune_find() { echo "find . $1"; }
# for a file that needs more than the above, called first from fetch with rel, size, copy and have set. It may change
# have, and sets pull_handled=yes when it has dealt with the file, its status then being fetch's. Default: nothing does
pull_fetch_first() { return 0; }

# --- what the steps say

# a line that stays, and takes the place of the status lines (below) if they are showing; one write, so that the
# monitor's drawing cannot land in the middle of it
echo() {
  if [ -t 1 ]; then printf '\r\033[J%s\n' "$*"; else printf '%s\n' "$*"; fi
}
# what a terminal is waiting on: handed to the monitor while it runs, else the line that the next one replaces, cut to
# fit, since a wrapped line would not go
status() {
  if [ -n "$pull_monitor" ]; then pull_progress "$*"
  elif [ -t 1 ]; then printf '\r\033[K  %s' "$(printf '%s' "$*" | cut -c1-76)"; fi
}
mb() { printf '%d.%d' $(($1 / 1048576)) $((($1 % 1048576) * 10 / 1048576)); }
# bytes, as kB or MB; a second, as kB/s or MB/s
pull_bytes() { if [ "$1" -ge 1048576 ]; then echo "$(mb "$1") MB"; else echo "$((($1 + 1023) / 1024)) kB"; fi; }
pull_rate() { echo "$(pull_bytes "$1")/s"; }
# seconds, as people say them
pull_dur() {
  if [ "$1" -lt 60 ]; then echo "$1 s"
  elif [ "$1" -lt 600 ]; then echo "$(($1 / 60)) min $(($1 % 60)) s"
  elif [ "$1" -lt 3600 ]; then echo "$(($1 / 60)) min"
  else printf '%d h %02d min\n' $(($1 / 3600)) $(($1 % 3600 / 60)); fi
}

# --- the transfer

# md5 of a local file, and of the phone's first N bytes of a file (all of it without N)
local_md5() { md5sum "$1" | cut -d' ' -f1; }
phone_md5() {
  status "the phone is hashing $1"
  if [ -n "$2" ]; then timeout 120 adb exec-out "head -c $2 '$pull_remote/$1' | md5sum" | tr -d '\r' | cut -d' ' -f1
  else timeout 120 adb exec-out "md5sum '$pull_remote/$1'" | tr -d '\r' | cut -d' ' -f1; fi
}

pull_ask_gzip() {
  if [ -n "$(timeout 20 adb exec-out 'command -v gzip' | tr -d '\r')" ]; then zip="gzip -1"; unzip="gzip -dc"; fi
}

# the phone's bytes [from, to) of a file appended to a local file; fails when fewer arrived (the link dropped: what did
# arrive is an exact prefix, kept)
stream() {
  rel=$1; from=$2; to=$3; out=$4
  # time enough at 50 kB/s: a link that stalls ends the call, and the wait goes on from here
  z=$zip; u=$unzip
  if pull_compressed "$rel"; then z="cat"; u="cat"; fi
  pull_out=$out; pull_from=$(stat -c %s "$out" 2>/dev/null || printf 0); pull_state=transferring
  pull_progress
  timeout $((60 + (to - from) / 50000)) adb exec-out "tail -c +$((from + 1)) '$pull_remote/$rel' | head -c $((to - from)) | $z" | $u >> "$out" 2>/dev/null
  now=$(stat -c %s "$out")
  pull_done=$((pull_done + now - pull_from)); pull_out=; pull_state=comparing
  pull_progress
  if [ "$now" -ne "$to" ]; then
    echo "$rel: interrupted at $now of $to bytes" >&2
    return 1
  fi
}

# a file whose prefix may not hold, whole into <copy>.part (resumed while its prefix matches), then over the copy once
# the md5 matches
whole() {
  rel=$1; size=$2; copy=$3
  part="$copy.part"
  got=0
  [ -f "$part" ] && got=$(stat -c %s "$part")
  if [ "$got" -gt "$size" ] || { [ "$got" -gt 0 ] && [ "$(local_md5 "$part")" != "$(phone_md5 "$rel" "$got")" ]; }; then
    rm -f "$part"; got=0
  fi
  [ "$got" -gt 0 ] && echo "$rel: resuming at $got of $size bytes"
  : >> "$part" && stream "$rel" "$got" "$size" "$part" || return 1
  if [ "$(local_md5 "$part")" = "$(phone_md5 "$rel")" ]; then
    mv "$part" "$copy"
  else
    rm -f "$part"
    echo "$rel: changed on the phone while it was fetched (still being written?); the old copy stays, next run fetches it again" >&2
  fi
}

# the copy moved aside before the phone's file is fetched whole: to <copy>.stale, or with a time stamp when one is there
keep_stale() {
  rel=$1; copy=$2; why=$3
  stale="$copy.stale"
  [ -e "$stale" ] && stale="$copy.stale.$(date +%Y%m%d%H%M%S)"
  echo "$rel: $why — fetching whole, the old copy kept as $(basename "$stale")"
  mv "$copy" "$stale"
}

# one file, relative to pull_remote, of the given size on the phone
fetch() {
  rel=$1; size=$2
  copy="$pull_dest/$rel"
  mkdir -p "$(dirname "$copy")"
  have=0
  [ -f "$copy" ] && have=$(stat -c %s "$copy")
  # an append-only file with no copy but the part of a whole fetch that a dropped link cut short (its old copy had been
  # longer and went to .stale): go on from that part, its prefix checked below like any copy's
  if [ "$have" -eq 0 ] && [ -f "$copy.part" ] && pull_append_only "$rel"; then
    mv "$copy.part" "$copy" && have=$(stat -c %s "$copy")
  fi
  pull_handled=no
  pull_fetch_first
  pull_first_status=$?
  [ "$pull_handled" = no ] || return "$pull_first_status"
  if [ "$have" -eq "$size" ]; then
    pull_same_size_is_same "$rel" && return 0
    if [ "$size" -lt 1048576 ] && [ "$(local_md5 "$copy")" != "$(phone_md5 "$rel")" ]; then
      echo "$rel: changed in place, fetching $size bytes"
      whole "$rel" "$size" "$copy"
    fi
  elif [ "$have" -gt "$size" ]; then
    keep_stale "$rel" "$copy" "local $have bytes, phone $size" && whole "$rel" "$size" "$copy"
  elif pull_append_only "$rel" && { [ "$have" -eq 0 ] || [ "$(local_md5 "$copy")" = "$(phone_md5 "$rel" "$have")" ]; }; then
    echo "$rel: appending $((size - have)) bytes ($have → $size)"
    : >> "$copy" && stream "$rel" "$have" "$size" "$copy"
  elif [ "$have" -gt 0 ] && pull_append_only "$rel"; then
    keep_stale "$rel" "$copy" "not the start of the phone's file ($have bytes here, $size there)" && whole "$rel" "$size" "$copy"
  else
    echo "$rel: fetching $size bytes"
    whole "$rel" "$size" "$copy"
  fi
}

# every file under the given directories (relative, "." for all), as "size path" lines
list_files() {
  timeout 60 adb exec-out "cd '$pull_remote' 2>/dev/null && find $* -type f -exec stat -c '%s %n' {} + 2>/dev/null" | tr -d '\r' | sed 's| \./| |'
}

# how much there is to fetch, by the sizes here and there: pull_need bytes in pull_need_files files, pull_total wanted.
# A same-size file counts as nothing, an append-only copy that turns out not to be the start as its tail: an estimate
pull_plan() {
  printf '%s\n' "$1" | while read -r s r; do
    [ -n "$r" ] && pull_wanted "$r" && printf '%s %s\n' "$s" "$r"
  done > "$pull_tmp.remote"
  find "$pull_dest" -type f -printf '%s %P\n' > "$pull_tmp.local" 2>/dev/null
  # shellcheck disable=SC2046  # three numbers
  set -- $(awk 'FILENAME == ARGV[1] { p = $0; sub(/^[0-9]+ /, "", p); have[p] = $1 + 0; next }
    NF >= 2 { p = $0; sub(/^[0-9]+ /, "", p); s = $1 + 0; h = (p in have) ? have[p] : 0; n++
              if (s > h) { need += s - h; files++ } else if (s < h) { need += s; files++ } }
    END { printf "%.0f %d %d\n", need, files, n }' "$pull_tmp.local" "$pull_tmp.remote")
  rm -f "$pull_tmp.local" "$pull_tmp.remote"
  pull_need=${1:-0}; pull_need_files=${2:-0}; pull_total=${3:-0}
}

# the main shell's side for the monitor: one line each, replaced whole, with $1 what it is doing when that changed
pull_progress() {
  [ -n "$pull_monitor" ] || return 0
  [ $# -eq 0 ] || pull_activity=$1
  printf '%s\n' "$pull_state" "$pull_n" "$pull_total" "$pull_done" "$pull_need" "$pull_out" "$pull_from" "$pull_rel" \
    "$pull_activity" > "$pull_pf.tmp" && mv -f "$pull_pf.tmp" "$pull_pf"
}

pull_cols() {
  c=$(stty size < /dev/tty 2>/dev/null | cut -d' ' -f2)
  # a terminal that does not say its size answers 0 (a pty no one sized): cut -c1--3 fails on every line
  case "$c" in ''|*[!0-9]*) c=80 ;; *) [ "$c" -ge 20 ] || c=80 ;; esac
  echo "$c"
}

# The monitor, in the background while pull_all runs: every second it reads the main shell's progress and the size of
# the file being written, every 15 s the link; it draws the two status lines on a terminal and writes the status file.
# It ends when told (USR1, after the main shell wrote done or failed) or when the main shell has gone (Ctrl-C).
pull_monitor_loop() {
  main=$1
  trap ':' USR1
  # the link as pull_monitor_start found it
  m_t0=$(date +%s); m_last_t=$m_t0; m_last=0; m_rate=0; m_eta_rate=0; m_still=0; m_probe_t=$m_t0; m_key=$pull_link_key
  m_hist=
  m_hints=$(link_hints | paste -sd ';' - | sed 's/;/; /g')
  m_cols=$(pull_cols)
  p_state=listing; p_n=0; p_total=0; p_done=0; p_need=0; p_out=; p_from=0; p_rel=; p_act=
  while :; do
    m_now=$(date +%s)
    { read -r p_state; read -r p_n; read -r p_total; read -r p_done; read -r p_need; read -r p_out; read -r p_from
      read -r p_rel; read -r p_act; } < "$pull_pf" 2>/dev/null
    kill -0 "$main" 2>/dev/null || p_state=stopped
    m_live=${p_done:-0}
    if [ -n "$p_out" ]; then
      m_size=$(stat -c %s "$p_out" 2>/dev/null || printf '%s' "$p_from")
      m_live=$((m_live + m_size - p_from))
    fi
    m_dt=$((m_now - m_last_t))
    if [ "$m_dt" -ge 1 ]; then
      if [ -n "$p_out" ] && [ "$m_live" -eq "$m_last" ]; then m_still=$((m_still + m_dt)); else m_still=0; fi
      m_last_t=$m_now; m_last=$m_live
      # time:bytes once a second or so, the last half minute of them. The rate shown is over the last 5 s; the time left
      # is from the last 30 s, since a link in power save comes in bursts and stalls of ten seconds and more
      m_hist="$m_hist $m_now:$m_live"
      # shellcheck disable=SC2086  # the samples, split
      set -- $m_hist
      while [ $# -gt 31 ]; do shift; done
      m_hist="$*"
      m_eta_rate=$(pull_hist_rate "$m_now" "$m_live" "$1")
      while [ $# -gt 6 ]; do shift; done
      m_rate=$(pull_hist_rate "$m_now" "$m_live" "$1")
    fi
    if [ $((m_now - m_probe_t)) -ge 15 ] && [ "$p_state" != "done" ] && [ "$p_state" != "failed" ]; then
      # one cut short by a slow link (its last line missing) leaves the link as it was
      m_raw=$(link_probe)
      case "$m_raw" in *"vpnapp:"*) link_read "$m_raw" ;; esac
      m_probe_t=$(date +%s)
      m_cols=$(pull_cols)
      m_hints=$(link_hints | paste -sd ';' - | sed 's/;/; /g')
      m_k=$(pull_link_key)
      if [ "$m_k" != "$m_key" ]; then
        echo "link now: $(link_summary)"
        link_hints | while read -r h; do echo "  $h"; done
        m_key=$m_k
      fi
    fi
    m_total=${p_need:-0}
    [ "$m_total" -ge "$m_live" ] || m_total=$m_live
    m_left=$((m_total - m_live))
    m_eta=
    [ "$m_eta_rate" -le 0 ] || [ "$m_left" -le 0 ] || m_eta=$((m_left / m_eta_rate))
    if [ "$m_total" -gt 0 ]; then m_pct=$((m_live * 100 / m_total)); else m_pct=100; fi
    m_elapsed=$((m_now - m_t0))
    case "$p_state" in
      listing) m_l1="listing the files on the phone" ;;
      *)
        m_l1="$m_pct% $(pull_bytes "$m_live") of $(pull_bytes "$m_total")"
        if [ "$m_still" -ge 5 ]; then m_l1="$m_l1 | stalled $(pull_dur "$m_still")"
        else m_l1="$m_l1 | $(pull_rate "$m_rate")"; fi
        [ -z "$m_eta" ] || m_l1="$m_l1 | about $(pull_dur "$m_eta") left"
        [ -z "$p_act" ] || m_l1="$m_l1 | $p_act" ;;
    esac
    m_l2=$(link_summary)
    case "$p_state" in
      done|failed|stopped)
        m_l1="$p_state: $(pull_bytes "$m_live") in $(pull_dur "$m_elapsed")"
        [ "$m_elapsed" -le 0 ] || m_l1="$m_l1, $(pull_rate $((m_live / m_elapsed))) on average" ;;
    esac
    { printf '%s=%s\n' version 1 pid "$main" label "$pull_label" dest "$pull_dest" serial "${ANDROID_SERIAL:-}" \
        state "$p_state" started "$m_t0" updated "$m_now" elapsed_s "$m_elapsed" \
        files_done "$p_n" files "$p_total" file "$p_rel" activity "$p_act" \
        bytes_done "$m_live" bytes_total "$m_total" rate "$m_rate" eta_s "$m_eta" stalled_s "$m_still" \
        wifi "$link_wifi" wifi_gen "$link_gen" wifi_std "$link_std" ssid "$link_ssid" band "$link_band" \
        channel "$link_channel" rssi "$link_rssi" signal "$link_signal" link_mbps "$link_tx" link_max_mbps "$link_txmax" \
        screen "$link_screen" power_save "$link_powersave" battery_saver "$link_saver" vpn "$link_vpn_app" \
        route "$link_route" hints "$m_hints" line1 "$m_l1" line2 "$m_l2"
    } > "$pull_sf.tmp" && mv -f "$pull_sf.tmp" "$pull_sf"
    case "$p_state" in
      done|failed|stopped)
        if [ -t 1 ]; then printf '\r\033[J'; fi
        return 0 ;;
    esac
    if [ -t 1 ]; then
      printf '\r\033[J  %s\n  %s\033[1A\r' "$(printf '%s' "$m_l1" | cut -c1-$((m_cols - 3)))" \
        "$(printf '%s' "$m_l2" | cut -c1-$((m_cols - 3)))"
    fi
    sleep 1 &
    wait $!
  done
}

# bytes a second from the sample $3 (time:bytes) to now ($1, $2)
pull_hist_rate() {
  h_t=${3%%:*}; h_b=${3#*:}
  if [ "$1" -gt "$h_t" ]; then echo $((($2 - h_b) / ($1 - h_t))); else echo 0; fi
}

# what in the link, changed, is said again (not the signal or the rate, which move all the time)
pull_link_key() { echo "$link_wifi $link_bssid $link_band $link_powersave $link_saver $link_vpn_app $link_route"; }

# the link said first, before the listing that a slow link makes long; then the monitor
pull_monitor_start() {
  link_read "$(link_probe)"
  pull_link_key=$(pull_link_key)
  echo "link: $(link_summary)"
  link_hints | while read -r h; do echo "  $h"; done
  mkdir -p "$pull_status_dir" 2>/dev/null || return 0
  find "$pull_status_dir" -name 'pull-*' -mmin +1440 -exec rm -f {} + 2>/dev/null
  pull_pf="$pull_status_dir/pull-$$.progress"; pull_sf="$pull_status_dir/pull-$$.status"
  if [ -z "${pull_label:-}" ]; then
    pull_label=$(printf '%s' "$pull_remote" | sed -n 's#.*/Android/data/\([^/]*\)/.*#\1#p')
    [ -n "$pull_label" ] || pull_label=$(basename "$pull_dest")
  fi
  pull_done=0; pull_need=0; pull_out=; pull_n=0; pull_total=0; pull_state=listing; pull_activity=
  pull_monitor=starting
  pull_progress "listing the files on the phone"
  pull_monitor_loop $$ &
  pull_monitor=$!
}

# $1: pull_all's status
pull_monitor_stop() {
  [ -n "$pull_monitor" ] || return 0
  if [ "$1" -eq 0 ]; then pull_state="done"; else pull_state="failed"; fi
  pull_out=
  pull_progress
  kill -USR1 "$pull_monitor" 2>/dev/null
  wait "$pull_monitor" 2>/dev/null
  pull_monitor=
  rm -f "$pull_pf"
}

# Fails when a file was not pulled or the phone went away. Shown as it goes by the monitor, and summed up at the end.
pull_all() {
  pull_t0=$(date +%s)
  pull_tmp="${TMPDIR:-/tmp}/adb_loop_pull-$$"
  pull_monitor_start
  pull_files "$@"
  pull_rc=$?
  pull_monitor_stop "$pull_rc"
  pull_t=$(($(date +%s) - pull_t0))
  if [ "$pull_done" -gt 0 ]; then
    if [ "$pull_t" -gt 0 ]; then
      echo "fetched $(pull_bytes "$pull_done") in $(pull_dur "$pull_t"), $(pull_rate $((pull_done / pull_t))) on average"
    else echo "fetched $(pull_bytes "$pull_done")"; fi
  fi
  return "$pull_rc"
}

# The lists go in on fd 3: in the same shell, so that a phone found again at another address stays found, and away from
# the standard input that adb shell reads.
pull_files() {
  echo "listing the files on the phone"
  list=$(list_files "$@")
  if [ -z "$list" ]; then
    # no list says nothing about the files when the phone has gone
    if ! phone_wait "$pull_wait_tries"; then
      echo "the phone went away while listing; run again" >&2
      return 1
    fi
    list=$(list_files "$@")
  fi
  if [ -z "$list" ]; then echo "nothing to pull under $* on the phone" >&2; return 0; fi
  pull_plan "$list"
  if [ "$pull_need" -gt 0 ]; then
    echo "comparing $pull_total files with this machine's copies; about $(pull_bytes "$pull_need") to fetch, in $pull_need_files"
  else echo "comparing $pull_total files with this machine's copies"; fi
  pull_state=comparing
  failed=0
  pull_n=0
  while read -r pull_size pull_rel <&3; do
    [ -n "$pull_rel" ] && [ -n "$pull_size" ] || continue
    pull_wanted "$pull_rel" || continue
    pull_n=$((pull_n + 1))
    status "$pull_n of $pull_total: $pull_rel"
    attempt=1
    until fetch "$pull_rel" "$pull_size"; do
      pull_state=waiting
      status "waiting for the phone, at $pull_rel"
      if ! phone_wait "$pull_wait_tries"; then
        echo "the phone went away at $pull_rel; run again to go on (an interrupted append resumes)" >&2
        return 1
      fi
      attempt=$((attempt + 1))
      if [ "$attempt" -gt "$pull_attempts" ]; then
        failed=$((failed + 1))
        break
      fi
      pull_state=comparing
      echo "$pull_rel: the phone answers, going on (attempt $attempt)"
    done
  done 3<<EOF
$list
EOF
  if [ "$failed" -gt 0 ]; then echo "$failed file(s) not pulled" >&2; return 1; fi
  echo "all $pull_total files compared"
}

# --- the prune

# whether this machine holds a byte-for-byte copy of it
held() {
  rel=$1; size=$2
  copy="$pull_dest/$rel"
  [ -f "$copy" ] && [ "$(stat -c %s "$copy")" -eq "$size" ] && [ "$(local_md5 "$copy")" = "$(phone_md5 "$rel")" ]
}

# pull_held_also: more of the message, where else the files are held
prune_phone() {
  echo "looking for files on the phone older than $keep_days days"
  old=$(timeout 60 adb exec-out "cd '$pull_remote' 2>/dev/null && { $(pull_prune_find "-type f -mtime +$keep_days -exec stat -c '%s %n' {} +"); } 2>/dev/null" |
        tr -d '\r' | sed 's| \./| |')
  count=0; bytes=0
  while read -r pull_size pull_rel <&3; do
    [ -n "$pull_rel" ] && [ -n "$pull_size" ] || continue
    pull_prunable_kind "$pull_rel" "$pull_size" || continue
    if held "$pull_rel" "$pull_size"; then
      timeout 20 adb shell rm "'$pull_remote/$pull_rel'" < /dev/null && count=$((count + 1)) && bytes=$((bytes + pull_size)) && echo "pruned from the phone: $pull_rel ($pull_size bytes)"
    else
      echo "kept on the phone: $pull_rel (the copy here is missing or differs: move it aside and pull again)" >&2
    fi
  done 3<<EOF
$old
EOF
  echo "pruned $count files, $((bytes / 1048576)) MB, older than $keep_days days (KEEP_DAYS) and held here${pull_held_also:-}"
}
