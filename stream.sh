# shellcheck shell=sh
# shellcheck disable=SC2154  # pull_dest, pull_remote, zip, unzip: set by pull.sh and the project
# stream.sh: many files' bytes in one adb call, framed so that this side can split them again. Sourced by pull.sh, whose
# pull_files makes the plans (the passes), and whose pull_remote, pull_dest, rules (pull_compressed, pull_append_only)
# and gzip (pull_ask_gzip) it uses.
#
# A plan is lines "from len rel": the phone's bytes [from, from + len) of rel, below pull_remote. The phone sends, for
# each line, a header "len from rel", then the bytes, then a line "-- TOKEN", the token new for each call; after the last
# file a line "-- end". The demuxer reads a header with read (byte by byte from a pipe) and the bytes with head -c, which
# reads no further than it needs, so the token's line is where the shell's read starts. A file that has become shorter
# than the plan says (or gone) sends fewer bytes: the token is not where it should be, the file is cut back to the size
# it had before and the call ends; a plan made again from the listing goes on. Padding instead would keep the stream
# going, but costs the phone two more processes a file, at about 11 ms each on a Z2 Force (2026-11-18).
#
# The files that pull_compressed names go in one stream, plain; the rest in another, through the phone's gzip; both at
# once. A plan longer than STREAM_PLAN_BYTES (the command that carries it goes over adb) is sent in several calls, one
# after another, in each stream.
#
# A third call, at the same time, carries only hashes: for each line of the plan, the md5 of the phone's bytes [0, from +
# len), what the file here will be once it came. The whole files' in one md5sum, an append-only file's through head -c.
# Here each file is hashed as soon as its bytes are in, in the background, while the next ones come. Once the calls
# end, a file whose hashes agree is taken (a .part goes over its copy); one whose do not is dropped (a .part) or kept
# aside as .stale (an append-only copy, cut back to what it was: not the start of the phone's file), and fetched again;
# one whose phone hash did not come stays as it is, for a hash in the next pass. A line of length 0 is only hashed, and
# copies already of the phone's size can be given to be compared.
#
# A stream that stops early leaves the file at hand an exact prefix, as pull.sh's transfers do: a plan made again from
# the sizes here goes on from there.
#
# A call has no timeout, since a plan may be any size, but a watchdog: a call that has written nothing here for
# ADB_LOOP_STALL seconds (60) is ended, with a line "stalled CALL SECONDS", and the pass ends with what came. What it
# watches is the file being written (a bucket's target, the hash call's lines) and its size, every second; a stretch
# with no output longer than that on the phone's side (md5sum over a single file of several GB) would be cut short too.

stream_end="-- end"
stream_plan_bytes=${STREAM_PLAN_BYTES:-100000}
stream_stall=${ADB_LOOP_STALL:-60}
# the file in which a bucket's demuxer names what it is writing, for the watchdog and pull.sh's monitor: the path, then
# "have len", the size it had and the bytes to come; empty between files (set by stream_bucket)
stream_at=
# where the buckets' files go, at/plain and at/gzip, when set (pull.sh's monitor reads them); else a temporary directory
stream_at_dir=

# where rel's bytes are appended: the copy for an append-only file, else its .part. A project may redefine it
stream_target() {
  if pull_append_only "$1"; then printf '%s\n' "$pull_dest/$1"; else printf '%s\n' "$pull_dest/$1.part"; fi
}

# the phone's command that sends a plan ($1) through a compressor ($2), with the token $3 after each file. A file from
# its start is one process (head), a tail two
stream_command() {
  # shellcheck disable=SC2016  # expanded on the phone
  printf '%s' "cd '$pull_remote' && { for e in"
  printf '%s\n' "$1" | while read -r f l r; do [ -n "$r" ] && printf " '%s %s %s'" "$f" "$l" "$r"; done
  # shellcheck disable=SC2016  # expanded on the phone
  printf '%s\n' '; do f=${e%% *}; e=${e#* }; l=${e%% *}; r=${e#* }; echo "$l $f $r";'\
' if [ "$f" -eq 0 ]; then head -c $l "$r"; else tail -c +$((f + 1)) "$r" | head -c $l; fi 2>/dev/null;'\
" echo '-- $3'; done; echo '$stream_end'; } | $2"
}

# A stream on the standard input, split into its files, the token $1 after each. On fd 4, a line for each: "done rel
# from len" when all its bytes came (and, once hashed, "here md5 rel"), "cut rel got len" when the stream stopped in it, "skip rel have from" when the copy
# was not the size the plan started from (its bytes are read and dropped), "short rel from len" when the token was not
# after its bytes (the file is cut back to from). Returns 0 when the end came, 1 when the stream stopped early or a file
# was short, 2 when a header was not one. Returns once the hashes are written.
stream_demux() {
  stream_demux_files "$@"
  d_rc=$?
  wait
  return "$d_rc"
}

stream_demux_files() {
  d_dir=
  while IFS= read -r h; do
    [ "$h" != "$stream_end" ] || return 0
    d_len=${h%% *}; h=${h#* }; d_from=${h%% *}; d_rel=${h#* }
    case "$d_len$d_from" in ''|*[!0-9]*) echo "stream: not a header: $d_len $d_from $d_rel" >&2; return 2 ;; esac
    d_out=$(stream_target "$d_rel")
    [ "${d_out%/*}" = "$d_dir" ] || { d_dir=${d_out%/*}; mkdir -p "$d_dir"; }
    d_have=$(stat -c %s "$d_out" 2>/dev/null || echo 0)
    if [ "$d_have" -ne "$d_from" ]; then
      # read and dropped: into a file of its own when watched, so that a long one is seen to come
      d_skip=/dev/null
      [ -z "$stream_at" ] || { d_skip=$stream_at.skip; printf '%s\n0 0\n' "$d_skip" > "$stream_at"; }
      head -c "$d_len" > "$d_skip"
      if IFS= read -r h && [ "$h" = "-- $1" ]; then
        printf 'skip %s %s %s\n' "$d_rel" "$d_have" "$d_from" >&4
        continue
      fi
      printf 'short %s %s %s\n' "$d_rel" "$d_from" "$d_len" >&4
      return 1
    fi
    [ -z "$stream_at" ] || printf '%s\n%s %s\n' "$d_out" "$d_have" "$d_len" > "$stream_at"
    head -c "$d_len" >> "$d_out"
    d_got=$(($(stat -c %s "$d_out") - d_have))
    if [ "$d_got" -ne "$d_len" ] || ! IFS= read -r h; then
      # the stream ended in the file or right after it. A short file's bytes run on into its token (and on, to the
      # end): when the token is in what came, the file is put back; when not, all that came is the file's
      if tail -c "$d_got" "$d_out" | grep -aqF -- "-- $1"; then
        truncate -s "$d_have" "$d_out"
        printf 'short %s %s %s\n' "$d_rel" "$d_from" "$d_len" >&4
      else
        printf 'cut %s %s %s\n' "$d_rel" "$d_got" "$d_len" >&4
      fi
      return 1
    fi
    if [ "$h" != "-- $1" ]; then
      truncate -s "$d_have" "$d_out"
      printf 'short %s %s %s\n' "$d_rel" "$d_from" "$d_len" >&4
      return 1
    fi
    printf 'done %s %s %s\n' "$d_rel" "$d_from" "$d_len" >&4
    # its bytes are counted by the done line now, not by its size
    [ -z "$stream_at" ] || : > "$stream_at"
    { d_md5=$(md5sum < "$d_out"); printf 'here %s %s\n' "${d_md5%% *}" "$d_rel" >&4; } &
  done
  return 1
}

# The phone's command $1 into the FIFO $2, by adb in the background, with a watchdog over the file that $3 names: a call
# whose file has kept its name and size for stream_stall seconds is ended, with a line "stalled $4 SECONDS" into $5.
# stream_call_end ends both once the reader is done
stream_call() {
  adb exec-out "$1" > "$2" &
  c_adb=$!
  stream_watch "$c_adb" "$3" "$4" "$5" &
  c_watch=$!
}
stream_call_end() {
  kill "$c_adb" "$c_watch" 2>/dev/null
  wait "$c_adb" 2>/dev/null
  wait "$c_watch" 2>/dev/null
}
stream_watch() {
  w_last=; w_still=0
  while sleep 1; do
    kill -0 "$1" 2>/dev/null || return 0
    w_at=; read -r w_at < "$2" 2>/dev/null
    w_now="$(stat -c %s "$w_at" 2>/dev/null) $w_at"
    if [ "$w_now" != "$w_last" ]; then w_last=$w_now; w_still=0; continue; fi
    w_still=$((w_still + 1))
    [ "$w_still" -ge "$stream_stall" ] || continue
    printf 'stalled %s %s\n' "$3" "$w_still" >> "$4"
    kill "$1" 2>/dev/null
    return 0
  done
}

# one bucket's plan ($1) in calls of up to stream_plan_bytes each, through $2 on the phone and $3 here; the lines into
# $4, the call named $5 in them. Stops at the first call that does not reach its end
stream_bucket() {
  [ -n "$1" ] || return 0
  b_tmp=$(mktemp -d) || return 1
  printf '%s\n' "$1" > "$b_tmp/plan"
  # whole lines, each piece at most stream_plan_bytes (a longer line alone)
  split -C "$stream_plan_bytes" "$b_tmp/plan" "$b_tmp/piece."
  mkfifo "$b_tmp/fifo" || { rm -rf "$b_tmp"; return 1; }
  stream_at=$b_tmp/at
  [ -z "$stream_at_dir" ] || stream_at=$stream_at_dir/$5
  b_rc=0
  for b_piece in "$b_tmp"/piece.*; do
    b_token=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    : > "$stream_at"
    stream_call "$(stream_command "$(cat "$b_piece")" "$2" "$b_token")" "$b_tmp/fifo" "$stream_at" "$5" "$4"
    # shellcheck disable=SC2086  # the command, with its options
    $3 < "$b_tmp/fifo" 2>/dev/null | stream_demux "$b_token" 4>> "$4"
    b_rc=$?
    stream_call_end
    [ "$b_rc" -eq 0 ] || break
  done
  [ -z "$stream_at_dir" ] || rm -f "$stream_at" "$stream_at.skip"
  stream_at=
  rm -rf "$b_tmp"
  return "$b_rc"
}

# The phone's command that hashes, for each line of a plan ($1), its bytes [0, from + len). All of them in one md5sum,
# "md5  rel" lines. An append-only file may be growing, so its size is taken just before and just after: when both are
# the plan's end, md5sum read just that; else, after "-- ranges", its name and "md5  -" of its first bytes, which a
# reader takes over the whole file's. The sizes are matched by name, so a file gone is one that gets its range hashed.
# A file's range alone costs the phone two processes, about 21 ms (Z2 Force, 2026-11-18): 3.3 s for 152 small files,
# where the one md5sum took 0.14 s.
stream_hash_command() {
  h_all=; h_grow=; h_ranges=
  while read -r h_f h_l h_r; do
    [ -n "$h_r" ] || continue
    h_all="$h_all '$h_r'"
    if pull_append_only "$h_r"; then h_grow="$h_grow '$h_r'"; h_ranges="$h_ranges '$((h_f + h_l)) $h_r'"; fi
  done <<EOF
$1
EOF
  printf '%s' "cd '$pull_remote' && {"
  [ -z "$h_grow" ] || printf '%s' " b=\$(stat -c '%s %n'$h_grow 2>/dev/null);"
  [ -z "$h_all" ] || printf '%s' " md5sum$h_all 2>/dev/null;"
  [ -z "$h_grow" ] || printf '%s' " a=\$(stat -c '%s %n'$h_grow 2>/dev/null);"
  printf '%s' " echo '-- ranges';"
  # each line of b and a, in the order of the plan, taken off the front when it is the file's; a missing file's not
  # there, so the next one's stays
  # shellcheck disable=SC2016  # expanded on the phone
  [ -z "$h_ranges" ] || printf '%s' ' n=$(echo; echo .); n=${n%.}; b="$b$n"; a="$a$n"; for e in'"$h_ranges"'; do l=${e%% *}; r=${e#* }; sb=; sa=;'\
' x=${b%%"$n"*}; if [ "${x#* }" = "$r" ]; then sb=${x%% *}; b=${b#*"$n"}; fi;'\
' x=${a%%"$n"*}; if [ "${x#* }" = "$r" ]; then sa=${x%% *}; a=${a#*"$n"}; fi;'\
' if [ "$sb" != "$l" ] || [ "$sa" != "$l" ]; then echo "$r"; head -c $l "$r" 2>/dev/null | md5sum; fi; done;'
  printf '%s\n' " }"
}

# the hash stream on the standard input, as "phone md5 rel" lines; a range's after its whole file's, which it replaces
stream_hash_lines() {
  p_ranges=; p_cr=$(printf '\r')
  while IFS= read -r p_h; do
    p_h=${p_h%"$p_cr"}
    if [ -z "$p_ranges" ]; then
      if [ "$p_h" = "-- ranges" ]; then p_ranges=yes; continue; fi
      printf 'phone %s %s\n' "${p_h%% *}" "${p_h#*  }"
    else
      IFS= read -r p_m || break
      p_m=${p_m%"$p_cr"}
      printf 'phone %s %s\n' "${p_m%% *}" "$p_h"
    fi
  done
}

# the hashes of a plan ($1), in calls of up to a quarter of stream_plan_bytes each, into $2: the command names an
# append-only file four times (md5sum, two stats, its range), about 3.4 times the plan's bytes, and Linux takes no
# argument over 128 kB (adb: "Argument list too long", and no hashes at all; 2026-11-21, 1537 old frames). Each call's
# lines go into a file of their own first, for the watchdog, since the other calls write to $2 as well
stream_hashes() {
  [ -n "$1" ] || return 0
  b_tmp=$(mktemp -d) || return 1
  printf '%s\n' "$1" > "$b_tmp/plan"
  split -C "$((stream_plan_bytes / 4))" "$b_tmp/plan" "$b_tmp/piece."
  mkfifo "$b_tmp/fifo" || { rm -rf "$b_tmp"; return 1; }
  printf '%s\n' "$b_tmp/lines" > "$b_tmp/at"
  b_rc=0
  for b_piece in "$b_tmp"/piece.*; do
    stream_call "$(stream_hash_command "$(cat "$b_piece")")" "$b_tmp/fifo" "$b_tmp/at" hashes "$2"
    stream_hash_lines < "$b_tmp/fifo" > "$b_tmp/lines"
    b_rc=$?
    stream_call_end
    cat "$b_tmp/lines" >> "$2"
    [ "$b_rc" -eq 0 ] || break
  done
  rm -rf "$b_tmp"
  return "$b_rc"
}

# The files of a pass, by the lines in $1 (a later hash of a file over an earlier), each with a verdict into $1. A file
# done: "ok rel" (taken: a .part goes over its copy), "bad rel" (a .part dropped; an append-only copy cut back to what it
# was before and kept aside, as not the start of the phone's file), "unverified rel" (as it is). A copy checked: "same
# rel", "differs rel" or "unchecked rel", nothing changed. Fails when any was not ok or same.
stream_verify() {
  awk '{ t = $1; r = $0
         if (t == "done") { sub(/^done /, "", r); sub(/ [0-9]+ [0-9]+$/, "", r); from[r] = $(NF - 1); order[++n] = r }
         else if (t == "check") { sub(/^check /, "", r); checked[++m] = r }
         else if (t == "here" || t == "phone" || t == "copy") { sub(/^[a-z]+ [^ ]* /, "", r); h[t, r] = $2 } }
       END { for (i = 1; i <= n; i++) { r = order[i]
               if ((("here", r) in h) && (("phone", r) in h)) print (h["here", r] == h["phone", r] ? "ok" : "bad"), from[r], r
               else print "unverified", from[r], r }
             for (i = 1; i <= m; i++) { r = checked[i]
               if ((("copy", r) in h) && (("phone", r) in h)) print (h["copy", r] == h["phone", r] ? "same" : "differs"), 0, r
               else print "unchecked", 0, r } }' "$1" > "$1.verdicts"
  v_rc=0
  while read -r v_what v_from v_rel; do
    v_out=$(stream_target "$v_rel")
    case "$v_what" in
      ok) [ "$v_out" = "$pull_dest/$v_rel" ] || mv "$v_out" "$pull_dest/$v_rel" ;;
      same) ;;
      bad)
        v_rc=1
        if [ "$v_out" = "$pull_dest/$v_rel" ] && [ "$v_from" -gt 0 ]; then
          truncate -s "$v_from" "$v_out"
          keep_stale "$v_rel" "$v_out" "not the start of the phone's file ($v_from bytes here)"
        else
          rm -f "$v_out"
          echo "$v_rel: not the phone's bytes (changed while it was fetched?); fetched again in the next pass" >&2
        fi ;;
      *) v_rc=1 ;;
    esac
    printf '%s %s\n' "$v_what" "$v_rel" >> "$1"
  done < "$1.verdicts"
  rm -f "$1.verdicts"
  return "$v_rc"
}

# Here, while the calls run: the lines of a plan ($1) with nothing to fetch, their target hashed as it is ("done",
# "here"), and the copies to check ($2, "size rel"), hashed ("check", "copy"); into $3
stream_here() {
  printf '%s\n' "$1" | while read -r e_f _ e_r; do
    [ -n "$e_r" ] || continue
    e_out=$(stream_target "$e_r")
    # an empty file is all there: its target made
    [ "$e_f" -gt 0 ] || [ -e "$e_out" ] || { mkdir -p "${e_out%/*}" && : > "$e_out"; }
    e_m=$(md5sum 2>/dev/null < "$e_out") || continue
    printf 'done %s %s 0\nhere %s %s\n' "$e_r" "$e_f" "${e_m%% *}" "$e_r"
  done >> "$3"
  printf '%s\n' "$2" | while read -r _ e_r; do
    [ -n "$e_r" ] || continue
    e_m=$(md5sum 2>/dev/null < "$pull_dest/$e_r") || continue
    printf 'check %s\ncopy %s %s\n' "$e_r" "${e_m%% *}" "$e_r"
  done >> "$3"
}

# A plan ($1) in three calls at once: the files that pull_compressed names, plain; the rest through the phone's gzip;
# the hashes of all. A line of length 0 is only hashed, its target as it is. The copies in $3 ("size rel"), already the
# phone's size, are hashed as well and compared. The lines into the file $2, made new. Fails when a call stopped early,
# a file was not verified or a copy differs.
stream_plan() {
  s_plain=; s_packed=; s_here=
  s_nl='
'
  while read -r s_f s_l s_r; do
    [ -n "$s_r" ] || continue
    if [ "$s_l" -eq 0 ]; then s_here="$s_here$s_f $s_l $s_r$s_nl"
    elif pull_compressed "$s_r"; then s_plain="$s_plain$s_f $s_l $s_r$s_nl"
    else s_packed="$s_packed$s_f $s_l $s_r$s_nl"; fi
  done <<EOF
$1
EOF
  s_hash=$1
  [ -z "${3:-}" ] || s_hash="$s_hash$s_nl$(printf '%s\n' "$3" | sed '/./s/^/0 /')"
  : > "$2"
  stream_bucket "$s_plain" cat cat "$2" plain &
  s_plain_pid=$!
  stream_bucket "$s_packed" "$zip" "$unzip" "$2" gzip &
  s_packed_pid=$!
  stream_hashes "$s_hash" "$2" &
  s_hash_pid=$!
  stream_here "$s_here" "${3:-}" "$2"
  wait "$s_plain_pid"; s_rc1=$?
  wait "$s_packed_pid"; s_rc2=$?
  wait "$s_hash_pid"; s_rc3=$?
  stream_verify "$2"; s_rc4=$?
  [ "$s_rc1" -eq 0 ] && [ "$s_rc2" -eq 0 ] && [ "$s_rc3" -eq 0 ] && [ "$s_rc4" -eq 0 ]
}
