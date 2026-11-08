# shellcheck shell=sh
# where.sh: where a project's loop scripts run. A project's executable loop/where.sh sources this after loop/project.sh.
# Run, that lists each script in loop/ under its place, and exits 1 when one does not say. Sourced, it gives the scripts
# runs_in, the one line that both says and enforces where a script runs:
#
#   . "$(dirname "$0")/where.sh"
#   runs_in container "$@"
#
# container      needs the image's tools: where the launcher is, runs itself again in the container; else refuses
# adb_client     talks to the phone over adb from a computer: where the launcher is, runs itself again in the container
#                (the phone over the network); elsewhere runs here, on this machine's adb (USB or wireless)
# agent_session  only inside an agent's session; refuses elsewhere
# laptop         where the phone gets plugged in: refuses in the container and where the launcher is
#
# The launcher is bread_ladder's bl, or $BL_LAUNCHER. A machine that has one and must still use its own adb (a laptop
# that also has bl) sets ADB_LOOP_LOCAL_ADB=1. Refusals exit 2. A file that cannot source this says so in a comment that
# starts a line, "runs_in <anywhere|on_phone>", which only the listing reads. A script sources this before it changes
# directory: "$0" is how it finds its checkout.
#
# bl_args: more arguments for the launcher (a published port). bl_after: a function to call with the container's exit
# code, in the checkout's root on this machine, instead of ending with the container.

in_container() {
  # ADB_LOOP_CONTAINER_MARKERS: tests/test_where.py plays a machine outside the container
  for marker in ${ADB_LOOP_CONTAINER_MARKERS:-/.dockerenv /run/.containerenv}; do
    [ -f "$marker" ] && return 0
  done
  return 1
}

has_launcher() {
  [ -z "${ADB_LOOP_LOCAL_ADB:-}" ] && "${BL_LAUNCHER:-bl}" --image-name >/dev/null 2>&1
}

# The launcher picks the checkout by the directory it starts in and mounts it at /home/node/repos/<its name>.
in_container_again() {
  cd "$(dirname "$0")/.." || exit 1
  self=/home/node/repos/$(basename "$PWD")/loop/$(basename "$0")
  echo "loop/$(basename "$0"): running it in the agent's container" >&2
  # shellcheck disable=SC2086  # bl_args is several words on purpose
  if [ -n "${bl_after:-}" ]; then
    "${BL_LAUNCHER:-bl}" ${bl_args:-} --exec "$self" "$@"
    "$bl_after" $?
    exit
  fi
  # shellcheck disable=SC2086
  exec "${BL_LAUNCHER:-bl}" ${bl_args:-} --exec "$self" "$@"
}

runs_in() {
  where_kind=$1
  shift
  case "$where_kind" in
    container)
      in_container && return 0
      has_launcher && in_container_again "$@"
      echo "loop/$(basename "$0") runs in the agent's container, and this machine has no launcher (${BL_LAUNCHER:-bl})" >&2
      exit 2 ;;
    adb_client)
      in_container && return 0
      has_launcher && in_container_again "$@"
      return 0 ;;
    agent_session)
      in_container && return 0
      echo "loop/$(basename "$0") runs inside an agent's session" >&2
      exit 2 ;;
    laptop)
      if in_container || has_launcher; then
        echo "loop/$(basename "$0") is the laptop's (a laptop that also has ${BL_LAUNCHER:-bl}: ADB_LOOP_LOCAL_ADB=1)" >&2
        exit 2
      fi ;;
    *)
      echo "runs_in: no such place: $where_kind" >&2
      exit 2 ;;
  esac
}

where_kind_of() { sed -n -E 's/^(# )?runs_in ([a-z_]+).*/\2/p' "$1" | head -n 1; }

where_list() {
  where_dir=$(dirname "$0")
  while read -r kind meaning; do
    echo "$kind: $meaning"
    for f in "$where_dir"/*; do
      [ -f "$f" ] && [ -x "$f" ] && [ "$(where_kind_of "$f")" = "$kind" ] || continue
      # the header's first line: a usage line, or what the script is
      about=$(sed -n '2,6{/shellcheck/d;/runs_in/d;s/^# *//;s/^"""//;p;q;}' "$f" | cut -c1-96)
      printf '  %-18s %s\n' "$(basename "$f")" "$about"
    done
  done <<EOF
container needs the image's tools; reruns in the container where the launcher is, else refuses
adb_client talks to the phone over adb; through the container where the launcher is, else this machine's adb
agent_session only inside an agent's session
laptop only where the phone gets plugged in
on_phone pushed to the phone and run there
anywhere needs nothing of the above
EOF
  missing=0
  for f in "$where_dir"/*; do
    [ -f "$f" ] && [ -x "$f" ] && [ -z "$(where_kind_of "$f")" ] || continue
    echo "does not say where it runs: $(basename "$f")" >&2
    missing=1
  done
  return $missing
}

if [ "$(basename "$0")" = where.sh ]; then
  where_list
  exit $?
fi
