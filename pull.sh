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
# Each step says what it is doing as it starts. On a terminal a status line under them shows the file being compared, and
# the bytes and rate of a transfer; piped, there are only the lines that stay.

# shellcheck disable=SC1091,SC2154  # set by loop/project.sh
. "$adb_loop_path/phone.sh"

keep_days=${KEEP_DAYS:-7}
# shellcheck disable=SC2034  # for a project's pull_prunable_kind
min_kb=${PRUNE_MIN_KB:-100}
pull_wait_tries=${ADB_LOOP_WAIT_TRIES:-15}
pull_attempts=3
zip="cat"; unzip="cat"

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

# a line that stays, and takes the place of the status line (below) if one is showing
echo() {
  if [ -t 1 ]; then printf '\r\033[K'; fi
  command echo "$@"
}
# the line that the next one replaces, for what a terminal is waiting on; cut to fit, since a wrapped line would not go
status() {
  if [ -t 1 ]; then printf '\r\033[K  %s' "$(printf '%s' "$*" | cut -c1-76)"; fi
}
mb() { printf '%d.%d' $(($1 / 1048576)) $((($1 % 1048576) * 10 / 1048576)); }

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

# while a transfer runs: its bytes so far and its rate, every second. A background job ignores Ctrl-C, so it ends by
# itself once the script has gone
ticker() {
  out=$1; to=$2
  last=$(stat -c %s "$out" 2>/dev/null || command echo 0)
  while sleep 1 && kill -0 $$ 2>/dev/null; do
    now=$(stat -c %s "$out" 2>/dev/null || command echo 0)
    status "$(mb "$now") of $(mb "$to") MB, $(((now - last) / 1024)) kB/s"
    last=$now
  done
}

# the phone's bytes [from, to) of a file appended to a local file; fails when fewer arrived (the link dropped: what did
# arrive is an exact prefix, kept)
stream() {
  rel=$1; from=$2; to=$3; out=$4
  tick=
  if [ -t 1 ]; then
    ticker "$out" "$to" &
    tick=$!
  fi
  # time enough at 50 kB/s: a link that stalls ends the call, and the wait goes on from here
  z=$zip; u=$unzip
  if pull_compressed "$rel"; then z="cat"; u="cat"; fi
  timeout $((60 + (to - from) / 50000)) adb exec-out "tail -c +$((from + 1)) '$pull_remote/$rel' | head -c $((to - from)) | $z" | $u >> "$out" 2>/dev/null
  if [ -n "$tick" ]; then
    kill "$tick" 2>/dev/null
    wait "$tick" 2>/dev/null
    printf '\r\033[K'
  fi
  now=$(stat -c %s "$out")
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

# Fails when a file was not pulled or the phone went away. The lists go in on fd 3: in the same shell, so that a phone
# found again at another address stays found, and away from the standard input that adb shell reads.
pull_all() {
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
  total=$(printf '%s\n' "$list" | wc -l)
  echo "comparing $total files with this machine's copies"
  failed=0
  n=0
  while read -r pull_size pull_rel <&3; do
    [ -n "$pull_rel" ] && [ -n "$pull_size" ] || continue
    n=$((n + 1))
    pull_wanted "$pull_rel" || continue
    status "$n of $total: $pull_rel"
    attempt=1
    until fetch "$pull_rel" "$pull_size"; do
      if ! phone_wait "$pull_wait_tries"; then
        echo "the phone went away at $pull_rel; run again to go on (an interrupted append resumes)" >&2
        return 1
      fi
      attempt=$((attempt + 1))
      if [ "$attempt" -gt "$pull_attempts" ]; then
        failed=$((failed + 1))
        break
      fi
      echo "$pull_rel: the phone answers, going on (attempt $attempt)"
    done
  done 3<<EOF
$list
EOF
  if [ "$failed" -gt 0 ]; then echo "$failed file(s) not pulled" >&2; return 1; fi
  echo "all $total files compared"
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
