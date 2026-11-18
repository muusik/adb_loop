# shellcheck shell=sh
# pull.sh: a directory of an app's on the phone, mirrored here as deltas. Sourced by a project's loop/pull.sh, which
# sets pull_remote (the directory on the phone) and, if it must, pull_dest (the one here), redefines the pull_* rules below
# for its own files, then calls phone_reach, pull_ask_gzip, pull_all and, unless told to keep, prune_phone.
#
# Where the files land (docs/data-dirs.org): pull_dest, else the project's data directory's phone/, at the same path below
# the app's files/ as pull_remote: .../files/imu-logs into DATA/phone/imu-logs. DATA is $adb_loop_data when the project
# sets it (from a variable of its own), else $XDG_DATA_HOME/$adb_loop_name, the name being the repository's. In the
# container a directory on the container's own root goes with it, and the prune would have deleted the phone's copy:
# a pull there exits 2 and names .bl-mounts, the file that mounts the host's directory.
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
. "$adb_loop_path/stream.sh"

keep_days=${KEEP_DAYS:-7}
# shellcheck disable=SC2034  # for a project's pull_prunable_kind
min_kb=${PRUNE_MIN_KB:-100}
pull_wait_tries=${ADB_LOOP_WAIT_TRIES:-15}
pull_attempts=3
zip="cat"; unzip="cat"
pull_status_dir=${ADB_LOOP_STATUS_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/adb_loop}
# the whole pull's progress, for the monitor: its pid while it runs, the bytes fetched before the pass at hand (whose own
# the monitor reads from the pass's lines and the buckets' files), the files done before it
pull_monitor=; pull_done=0; pull_need=0; pull_n=0; pull_total=0; pull_state=

# --- the rules, for a project to redefine after sourcing this; $1 is a path relative to pull_remote

# only ever appended to: a tail is enough. Default: nothing is
pull_append_only() { return 1; }
# the same size means the same file, with no md5 round trip. Default: what is append-only
pull_same_size_is_same() { pull_append_only "$1"; }
# $2 is its size: of a kind that may go from the phone once it is old and held here. Default: nothing may
pull_prunable_kind() { return 1; }
# already compressed, so its bytes go plain, not through the phone's gzip. Default: archives (.gz .xz .zst .bz2 .zip .7z
# .apk) and media: pictures (.jpg .jpeg .png .webp .heic .avif), video (.mp4 .webm .mkv .3gp), sound (.m4a .aac .mp3
# .ogg .opus .amr), in either case
pull_compressed() {
  case "$1" in
    *.[gG][zZ]|*.[xX][zZ]|*.[zZ][sS][tT]|*.[bB][zZ]2|*.[zZ][iI][pP]|*.7[zZ]|*.[aA][pP][kK]) return 0 ;;
    *.[jJ][pP][gG]|*.[jJ][pP][eE][gG]|*.[pP][nN][gG]|*.[wW][eE][bB][pP]|*.[hH][eE][iI][cC]|*.[aA][vV][iI][fF]) return 0 ;;
    *.[mM][pP]4|*.[wW][eE][bB][mM]|*.[mM][kK][vV]|*.3[gG][pP]) return 0 ;;
    *.[mM]4[aA]|*.[aA][aA][cC]|*.[mM][pP]3|*.[oO][gG][gG]|*.[oO][pP][uU][sS]|*.[aA][mM][rR]) return 0 ;;
    *) return 1 ;;
  esac
}
# to be pulled at all. Default: everything
pull_wanted() { return 0; }
# the phone's command that lists what may be pruned, given the find arguments in $1 that select and print the old files.
# Default: the whole directory
pull_prune_find() { echo "find . $1"; }
# for a file on the phone ($1, of $2 bytes) with neither a copy nor a .part here, before the first pass (a later one
# would find the files that pass fetched, the old one's new name among them): it may put a file here at
# $(stream_target "$1") that is the start of the phone's (one renamed on the phone, held here under its old name), and
# only the rest is fetched. The pass hashes the whole after, as any append: one that was not the start is cut back and
# kept as .stale (an append-only file) or dropped (a .part), so a project checks first what it cannot lose
# (phone_md5). Its status is ignored. Default: nothing
pull_seed() { return 0; }

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

# the copy moved aside before the phone's file is fetched whole: to <copy>.stale, or with a time stamp when one is there
keep_stale() {
  rel=$1; copy=$2; why=$3
  stale="$copy.stale"
  [ -e "$stale" ] && stale="$copy.stale.$(date +%Y%m%d%H%M%S)"
  echo "$rel: $why — fetching whole, the old copy kept as $(basename "$stale")"
  mv "$copy" "$stale"
}

# every file under the given directories (relative, "." for all), as "size path" lines
list_files() {
  timeout 60 adb exec-out "cd '$pull_remote' 2>/dev/null && find $* -type f -exec stat -c '%s %n' {} + 2>/dev/null" | tr -d '\r' | sed 's| \./| |'
}

# how much there is to fetch, by the sizes here and there (pull_classify's): pull_need bytes in pull_need_files files,
# pull_total wanted. A same-size file counts as nothing, an append-only copy that turns out not to be the start as its
# tail: an estimate
pull_plan() {
  find "$pull_dest" -type f -printf '%s %P\n' > "$pull_tmp.local" 2>/dev/null
  # shellcheck disable=SC2046  # three numbers
  set -- $(awk 'FILENAME == ARGV[1] { p = $0; sub(/^[0-9]+ /, "", p); have[p] = $1 + 0; next }
    NF >= 4 { p = $0; sub(/^[0-9]+ [01] [01] /, "", p); s = $1 + 0; h = (p in have) ? have[p] : 0; n++
              if (s > h) { need += s - h; files++ } else if (s < h) { need += s; files++ } }
    END { printf "%.0f %d %d\n", need, files, n }' "$pull_tmp.local" "$pull_tmp.remote")
  rm -f "$pull_tmp.local"
  pull_need=${1:-0}; pull_need_files=${2:-0}; pull_total=${3:-0}
}

# the main shell's side for the monitor: one line each, replaced whole, with $1 what it is doing when that changed
pull_progress() {
  [ -n "$pull_monitor" ] || return 0
  [ $# -eq 0 ] || pull_activity=$1
  printf '%s\n' "$pull_state" "$pull_n" "$pull_total" "$pull_done" "$pull_need" "$pull_activity" > "$pull_pf.tmp" &&
    mv -f "$pull_pf.tmp" "$pull_pf"
}

# The pass at hand, while its calls run, as "bytes files rel": the bytes and files that came (the pass's done lines),
# plus what the buckets' files at hand have grown by; rel the one of them with the most still to come
pull_pass_live() {
  l_b=0; l_n=0
  read -r l_b l_n <<EOF
$(awk '$1 == "done" { b += $NF; n++ } END { printf "%.0f %d\n", b, n }' "$pull_tmp.lines" 2>/dev/null)
EOF
  l_rel=; l_most=-1
  for l_at in "$pull_tmp.at"/*; do
    l_out=; l_have=0; l_len=0
    { read -r l_out; read -r l_have l_len; } < "$l_at" 2>/dev/null
    [ -n "$l_out" ] && [ "${l_len:-0}" -gt 0 ] || continue
    l_got=$(($(stat -c %s "$l_out" 2>/dev/null || echo "$l_have") - l_have))
    [ "$l_got" -ge 0 ] || l_got=0
    [ "$l_got" -le "$l_len" ] || l_got=$l_len
    l_b=$((${l_b:-0} + l_got))
    if [ $((l_len - l_got)) -gt "$l_most" ]; then
      l_most=$((l_len - l_got)); l_rel=${l_out#"$pull_dest/"}; l_rel=${l_rel%.part}
    fi
  done
  echo "${l_b:-0} ${l_n:-0} $l_rel"
}

pull_cols() {
  c=$({ stty size < /dev/tty; } 2>/dev/null | cut -d' ' -f2)
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
  p_state=listing; p_n=0; p_total=0; p_done=0; p_need=0; p_act=
  while :; do
    m_now=$(date +%s)
    { read -r p_state; read -r p_n; read -r p_total; read -r p_done; read -r p_need; read -r p_act; } < "$pull_pf" 2>/dev/null
    kill -0 "$main" 2>/dev/null || p_state=stopped
    m_live=${p_done:-0}; m_n=${p_n:-0}; m_rel=
    if [ "$p_state" = transferring ]; then
      read -r m_b m_c m_rel <<EOF
$(pull_pass_live)
EOF
      m_live=$((m_live + m_b)); m_n=$((m_n + m_c))
    fi
    m_dt=$((m_now - m_last_t))
    if [ "$m_dt" -ge 1 ]; then
      if [ "$p_state" = transferring ] && [ "$m_live" -eq "$m_last" ]; then m_still=$((m_still + m_dt)); else m_still=0; fi
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
        [ -z "$m_rel" ] || m_l1="$m_l1 | $m_n of ${p_total:-0}: ${m_rel##*/}"
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
        files_done "$m_n" files "$p_total" file "$m_rel" activity "$p_act" \
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
  pull_done=0; pull_need=0; pull_n=0; pull_total=0; pull_state=listing; pull_activity=
  pull_monitor=starting
  pull_progress "listing the files on the phone"
  pull_monitor_loop $$ &
  pull_monitor=$!
}

# $1: pull_all's status
pull_monitor_stop() {
  [ -n "$pull_monitor" ] || return 0
  if [ "$1" -eq 0 ]; then pull_state="done"; else pull_state="failed"; fi
  pull_progress
  kill -USR1 "$pull_monitor" 2>/dev/null
  wait "$pull_monitor" 2>/dev/null
  pull_monitor=
  rm -f "$pull_pf"
}

# pull_dest from the project's data directory when it is not set, made, and refused (exit 2) where it would not outlast the
# container. Called by pull_all and prune_phone; a project may call it first, to stop before the phone is reached.
pull_resolve_dest() {
  if [ -z "${pull_dest:-}" ]; then
    pull_files_at=$(printf '%s' "$pull_remote" | sed -n 's#^.*/Android/data/[^/]*/files\(/.*\)\{0,1\}/*$#\1#p')
    pull_data=${adb_loop_data:-}
    if [ -z "$pull_data" ] && [ -n "${adb_loop_name:-}" ]; then
      pull_data=${XDG_DATA_HOME:-$HOME/.local/share}/$adb_loop_name
    fi
    if [ -z "$pull_data" ] || ! printf '%s' "$pull_remote" | grep -q '/Android/data/[^/]*/files\(/\|$\)'; then
      echo "pull.sh: no pull_dest, and no adb_loop_name or adb_loop_data with a pull_remote under an app's files/" >&2
      exit 2
    fi
    pull_dest=$pull_data/phone$pull_files_at
  fi
  mkdir -p "$pull_dest" || exit 1
  # ADB_LOOP_ROOT_MOUNT: the tests' stand-in for the container's root, which a temporary directory is on
  if in_container && [ "$(stat -c %m "$pull_dest")" = "${ADB_LOOP_ROOT_MOUNT:-/}" ]; then
    echo "pull.sh: $pull_dest is not on a mount from the host, so it goes when the container does; list the data" \
         "directory in the checkout's .bl-mounts (\$XDG_DATA_HOME/NAME /home/node/.local/share/NAME) and start a new session" >&2
    exit 2
  fi
}

# Fails when a file was not pulled or the phone went away. Shown as it goes by the monitor, and summed up at the end.
pull_all() {
  pull_resolve_dest
  echo "into $pull_dest"
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

# --- the passes (stream.sh): every file in one plan, sent in a few calls at once, then planned again from what that left

# the listing into list; once more after waiting for the phone when it came empty. Fails when the phone has gone
pull_list() {
  list=$(list_files "$@")
  [ -z "$list" ] || return 0
  phone_wait "$pull_wait_tries" || return 1
  list=$(list_files "$@")
}

# the wanted files of a listing ($1) as "size a same rel" into $pull_tmp.remote: a 1 when pull_append_only, same 1
# when pull_same_size_is_same
pull_classify() {
  printf '%s\n' "$1" | while read -r c_s c_r; do
    [ -n "$c_r" ] && pull_wanted "$c_r" || continue
    c_a=0; pull_append_only "$c_r" && c_a=1
    c_m=0; pull_same_size_is_same "$c_r" && c_m=1
    printf '%s %s %s %s\n' "$c_s" "$c_a" "$c_m" "$c_r"
  done > "$pull_tmp.remote"
}

# the files on the phone ($pull_tmp.remote) with neither a copy nor a .part here, each offered to pull_seed
pull_pass_seed() {
  find "$pull_dest" -type f -printf '%s %P\n' > "$pull_tmp.local" 2>/dev/null
  awk 'FILENAME == ARGV[1] { p = $0; sub(/^[0-9]+ /, "", p); loc[p] = 1; next }
       { r = $0; sub(/^[0-9]+ [01] [01] /, "", r); if (!(r in loc) && !((r ".part") in loc)) print $1, r }' \
    "$pull_tmp.local" "$pull_tmp.remote" > "$pull_tmp.new"
  while read -r n_size n_rel <&3; do pull_seed "$n_rel" "$n_size" < /dev/null; done 3< "$pull_tmp.new"
  rm -f "$pull_tmp.local" "$pull_tmp.new"
}

# A pass's work into $pull_tmp.todo, from the phone's files ($pull_tmp.remote), the sizes here and what the passes before
# left ($pull_tmp.state: "fails N rel", "unverified FROM rel", "differs rel"). Lines, in the order they are done:
#   promote rel      an append-only file's .part, left by a whole fetch cut short, becomes its copy
#   drop rel         a .part longer than the phone's file goes
#   stale H S rel    the copy goes aside (keep_stale): longer than the phone's (H > S), or an append-only one that differs
#   giveup rel       its attempts are spent
#   plan F L rel     the phone's bytes [F, F + L) into its target (L 0: only hashed)
#   check S rel      a copy of the phone's size, compared by hash
# An append-only file's tail goes onto its copy, any other file whole into its .part (a .part of the phone's size only
# hashed). A same-size copy is left alone when pull_same_size_is_same, or when it is 1 MB or more; else checked, and
# fetched whole once it differs.
pull_pass_todo() {
  find "$pull_dest" -type f -printf '%s %P\n' > "$pull_tmp.local" 2>/dev/null
  awk -v max="$pull_attempts" '
    FILENAME == ARGV[1] { r = $0
      if ($1 == "fails") { sub(/^fails [0-9]+ /, "", r); fails[r] = $2 }
      else if ($1 == "unverified") { sub(/^unverified [0-9]+ /, "", r); unv[r] = 1 }
      else if ($1 == "differs") { sub(/^differs /, "", r); dif[r] = 1 }
      next }
    FILENAME == ARGV[2] { p = $0; sub(/^[0-9]+ /, "", p); loc[p] = $1 + 0; next }
    { s = $1 + 0; a = $2 + 0; same = $3 + 0; r = $0; sub(/^[0-9]+ [01] [01] /, "", r)
      h = (r in loc) ? loc[r] : -1; p = ((r ".part") in loc) ? loc[r ".part"] : -1
      if (fails[r] + 0 >= max) { print "giveup", r; next }
      if (a) {
        if (h < 0 && p >= 0) { print "promote", r; h = p; p = -1 }
        if ((r in unv) && h == s) { print "plan", s, 0, r; next }
        if (h > s || (h > 0 && (r in dif))) { print "stale", h, s, r; print "plan", 0, s, r; next }
        if (h < 0) h = 0
        if (h == s) { if (!same && s < 1048576) print "check", s, r; next }
        print "plan", h, s - h, r; next
      }
      if ((r in unv) && p == s) { print "plan", s, 0, r; next }
      if (h > s) print "stale", h, s, r
      else if (h == s && !(r in dif)) { if (!same && s < 1048576) print "check", s, r; next }
      if (p > s) { print "drop", r; p = -1 }
      if (p < 0) p = 0
      print "plan", p, s - p, r
    }' "$pull_tmp.state" "$pull_tmp.local" "$pull_tmp.remote" > "$pull_tmp.todo"
  rm -f "$pull_tmp.local"
}

# what pull_pass_todo said to do before the calls
pull_pass_prepare() {
  while read -r t_what t_rest; do
    case "$t_what" in
      promote) mv "$pull_dest/$t_rest.part" "$pull_dest/$t_rest" ;;
      drop) rm -f "$pull_dest/$t_rest.part" ;;
      stale)
        t_h=${t_rest%% *}; t_rest=${t_rest#* }; t_s=${t_rest%% *}; t_rest=${t_rest#* }
        if [ "$t_h" -gt "$t_s" ]; then keep_stale "$t_rest" "$pull_dest/$t_rest" "local $t_h bytes, phone $t_s"
        else keep_stale "$t_rest" "$pull_dest/$t_rest" "changed on the phone at the same size"; fi ;;
    esac
  done < "$pull_tmp.todo"
}

# The state after a pass, from the one before, the pass's todo and its lines: a file that did not come or was not
# verified has one attempt less; one done but unverified keeps the size it had before, to be cut back to if it never is
pull_pass_state() {
  awk 'FILENAME == ARGV[1] { r = $0
         if ($1 == "fails") { sub(/^fails [0-9]+ /, "", r); fails[r] = $2 }
         else if ($1 == "unverified") { sub(/^unverified [0-9]+ /, "", r); unv[r] = $2 }
         else if ($1 == "differs") { sub(/^differs /, "", r); dif[r] = 1 }
         next }
       FILENAME == ARGV[2] { if ($1 == "plan") { r = $0; sub(/^plan [0-9]+ [0-9]+ /, "", r); delete dif[r] } next }
       { t = $1; r = $0 }
       t == "done" { sub(/^done /, "", r); sub(/ [0-9]+ [0-9]+$/, "", r); from[r] = $(NF - 1); next }
       t == "cut" || t == "short" || t == "skip" { sub(/^[a-z]+ /, "", r); sub(/ [0-9]+ [0-9]+$/, "", r)
                                                   fails[r]++; delete unv[r]; next }
       t == "ok" || t == "same" { sub(/^[a-z]+ /, "", r); delete unv[r]; delete dif[r]; next }
       t == "bad" || t == "unchecked" { sub(/^[a-z]+ /, "", r); fails[r]++; delete unv[r]; next }
       t == "unverified" { sub(/^unverified /, "", r); fails[r]++; if (!(r in unv)) unv[r] = from[r]; next }
       t == "differs" { sub(/^differs /, "", r); dif[r] = 1; next }
       END { for (r in fails) print "fails", fails[r], r
             for (r in unv) print "unverified", unv[r], r
             for (r in dif) print "differs", r }' "$pull_tmp.state" "$pull_tmp.todo" "$pull_tmp.lines" > "$pull_tmp.state.new"
  mv "$pull_tmp.state.new" "$pull_tmp.state"
}

# What a pass's lines say: the bytes that came onto pull_done, a line for each file that did not come or was not
# verified (a line of their own for the rest: keep_stale's, stream_verify's). Fails when nothing came at all
pull_pass_report() {
  r_moved=0
  while IFS= read -r r_line; do
    case "$r_line" in
      "bytes "*) r_line=${r_line#bytes }; pull_done=$((pull_done + ${r_line% *})); r_moved=${r_line#* } ;;
      "E "*) echo "${r_line#E }" >&2 ;;
      "O "*) echo "${r_line#O }" ;;
    esac
  done <<EOF
$(awk 'FILENAME == ARGV[1] { if ($1 == "plan") { r = $0; sub(/^plan [0-9]+ [0-9]+ /, "", r); from[r] = $2 } next }
       { t = $1; r = $0; sub(/^[a-z]+ /, "", r) }
       t == "done" { sub(/ [0-9]+ [0-9]+$/, "", r); b += $NF; if ($NF > 0) moved++; next }
       t == "cut" { sub(/ [0-9]+ [0-9]+$/, "", r); b += $(NF - 1); if ($(NF - 1) > 0) moved++
                    printf "E %s: interrupted at %.0f of %.0f bytes\n", r, from[r] + $(NF - 1), from[r] + $NF; next }
       t == "short" { sub(/ [0-9]+ [0-9]+$/, "", r)
                      print "E " r ": shorter on the phone than listed (changed or gone); listed again"; next }
       t == "skip" { sub(/ [0-9]+ [0-9]+$/, "", r)
                     print "E " r ": " $(NF - 1) " bytes here, not the " $NF " planned from; planned again"; next }
       t == "ok" || t == "same" { moved++; next }
       t == "stalled" { print "E nothing came on the " $2 " call for " $3 " s; it was ended"; next }
       t == "unverified" { print "E " r ": its hash from the phone did not come; hashed again"; next }
       t == "unchecked" { print "E " r ": its hash from the phone did not come; compared again"; next }
       t == "differs" { print "O " r ": changed in place, fetching it whole"; next }
       END { printf "bytes %.0f %d\n", b, moved }' "$pull_tmp.todo" "$pull_tmp.lines")
EOF
  pull_progress
  [ "$r_moved" -gt 0 ]
}

# The end of the passes: the files given up named, and an append-only file whose appended bytes were never verified cut
# back to its size before them, so that the next run fetches them again. Fails when there was either
pull_pass_end() {
  e_rc=0; e_n=0
  while read -r e_what e_rel; do
    [ "$e_what" = giveup ] || continue
    echo "$e_rel: not pulled after $pull_attempts attempts" >&2
    e_n=$((e_n + 1))
  done < "$pull_tmp.todo"
  [ "$e_n" -eq 0 ] || { echo "$e_n file(s) not pulled" >&2; e_rc=1; }
  while read -r e_what e_from e_rel; do
    [ "$e_what" = unverified ] || continue
    e_rc=1
    if pull_append_only "$e_rel"; then
      e_copy="$pull_dest/$e_rel"
      [ "$(stat -c %s "$e_copy" 2>/dev/null || echo 0)" -le "$e_from" ] || truncate -s "$e_from" "$e_copy"
      echo "$e_rel: what was appended could not be verified, cut back to $e_from bytes for the next run" >&2
    else
      echo "$e_rel: its .part could not be verified; the next run hashes it" >&2
    fi
  done < "$pull_tmp.state"
  return "$e_rc"
}

# The lists go into files: in the same shell, so that a phone found again at another address stays found.
pull_files() {
  echo "listing the files on the phone"
  if ! pull_list "$@"; then echo "the phone went away while listing; run again" >&2; return 1; fi
  if [ -z "$list" ]; then echo "nothing to pull under $* on the phone" >&2; return 0; fi
  pull_classify "$list"
  pull_pass_seed
  pull_plan
  if [ "$pull_need" -gt 0 ]; then
    echo "comparing $pull_total files with this machine's copies; about $(pull_bytes "$pull_need") to fetch, in $pull_need_files"
  else echo "comparing $pull_total files with this machine's copies"; fi
  : > "$pull_tmp.state"
  stream_at_dir=$pull_tmp.at
  mkdir -p "$stream_at_dir"
  f_pass=0; f_stuck=0; f_rc=0
  while :; do
    f_pass=$((f_pass + 1))
    pull_state=comparing
    pull_pass_todo
    pull_pass_prepare
    f_plan=$(sed -n 's/^plan //p' "$pull_tmp.todo")
    f_checks=$(sed -n 's/^check //p' "$pull_tmp.todo")
    [ -n "$f_plan$f_checks" ] || break
    read -r f_n f_b f_c <<EOF
$(awk '$1 == "plan" && $3 > 0 { n++; b += $3; next } $1 == "plan" || $1 == "check" { c++ }
       END { printf "%d %.0f %d\n", n, b, c }' "$pull_tmp.todo")
EOF
    pull_n=$((pull_total - f_n - f_c))
    f_say="pass $f_pass: $f_n file(s), $(pull_bytes "$f_b")"
    [ "$f_c" -eq 0 ] || f_say="$f_say; $f_c compared by hash"
    echo "$f_say"
    pull_state=transferring
    status "$f_say"
    stream_plan "$f_plan" "$pull_tmp.lines" "$f_checks"
    f_ok=$?
    pull_state=comparing
    if pull_pass_report; then f_stuck=0; else f_stuck=$((f_stuck + 1)); fi
    pull_pass_state
    [ "$f_ok" -ne 0 ] || break
    if [ "$f_stuck" -ge "$pull_attempts" ]; then
      echo "nothing came in $f_stuck passes; run again" >&2
      f_rc=1; break
    fi
    pull_state=waiting
    status "waiting for the phone, after pass $f_pass"
    if ! phone_wait "$pull_wait_tries" || ! pull_list "$@" || [ -z "$list" ]; then
      echo "the phone went away after pass $f_pass; run again to go on (what came is kept)" >&2
      f_rc=1; break
    fi
    pull_classify "$list"
  done
  pull_pass_end || f_rc=1
  rm -f "$pull_tmp.remote" "$pull_tmp.todo" "$pull_tmp.state" "$pull_tmp.lines"
  rm -rf "$stream_at_dir"; stream_at_dir=
  [ "$f_rc" -eq 0 ] || return 1
  pull_n=$pull_total
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
  pull_resolve_dest
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
