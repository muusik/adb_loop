#!/bin/sh
# org_width.sh: Org prose stays within the fill column, so the files read the same in Emacs, in a terminal and in
# review. A project's .githooks/pre-commit runs it (core.hooksPath, see README /Org line width/).
#
#   org_width.sh          the lines the staged commit adds to .org files, as the hook checks them
#   org_width.sh --all    every line of every tracked .org file, as they are in the working tree
#
# The width is the fill-column of the checkout's .dir-locals.el, else 100. What cannot wrap is not counted: table
# rows, the lines of #+begin_X ... #+end_X blocks, #+ keyword lines (#+CAPTION:, #+ATTR_HTML:), and a line that is too
# long only because of a link or URL (Org never splits one). Headings count: shorten one rather than let it run on.
# Characters are counted, not bytes. Exit 1 with each line that runs over; 0 when none does.

set -u
top=$(git rev-parse --show-toplevel) || exit 2
cd "$top" || exit 2

width=100
if [ -f .dir-locals.el ]; then
  w=$(sed -n 's/.*(fill-column *\. *\([0-9][0-9]*\)).*/\1/p' .dir-locals.el | head -n 1)
  [ -n "$w" ] && width=$w
fi

all=0
case "${1:-}" in
  --all) all=1 ;;
  "") ;;
  *) echo "usage: org_width.sh [--all]" >&2; exit 2 ;;
esac

# check FILE RANGES: the lines of the text on stdin over the width, of those in RANGES ("start count" pairs, or "all")
check() {
  LC_ALL=C awk -v file="$1" -v ranges="$2" -v width="$width" '
    BEGIN {
      n = split(ranges, r, " ")
      for (i = 1; i + 1 <= n; i += 2) for (j = r[i]; j < r[i] + r[i + 1]; j++) want[j] = 1
      every = (ranges == "all")
    }
    function chars(s) { gsub(/[\200-\277]/, "", s); return length(s) }
    {
      line = $0
      sub(/\r$/, "", line)
      low = tolower(line)
      if (low ~ /^[ \t]*#\+begin_/) { inblock = 1; next }
      if (low ~ /^[ \t]*#\+end_/) { inblock = 0; next }
      if (inblock || line ~ /^[ \t]*\|/ || line ~ /^[ \t]*#\+/) next
      if (!every && !(NR in want)) next
      n = chars(line)
      if (n <= width) next
      bare = line
      gsub(/\[\[[^]]*\](\[[^]]*\])?\]/, "L", bare)
      gsub(/https?:\/\/[^ \t]+/, "L", bare)
      if (chars(bare) <= width) next
      printf "%s:%d: %d characters, over %d\n", file, NR, n, width
      bad = 1
    }
    END { exit bad }'
}

status=0
if [ "$all" = 1 ]; then
  files=$(git -c core.quotePath=false ls-files -- '*.org')
else
  files=$(git -c core.quotePath=false diff --cached --name-only --diff-filter=ACMR -- '*.org')
fi
[ -z "$files" ] && exit 0

# one path per line; no .org file here has a newline in its name
while IFS= read -r f; do
  if [ "$all" = 1 ]; then
    [ -f "$f" ] || continue
    check "$f" all <"$f" || status=1
  else
    # the added lines' ranges from the zero-context diff's hunk headers: "@@ -a,b +c,d @@", d omitted when 1
    ranges=$(git diff --cached -U0 --no-color -- "$f" |
      sed -n 's/^@@ [^+]*+\([0-9][0-9]*\)\(,\([0-9][0-9]*\)\)\{0,1\} @@.*/\1 \3/p' |
      awk '{ print $1, ($2 == "" ? 1 : $2) }' | tr '\n' ' ')
    [ -n "${ranges% }" ] || continue
    git show ":$f" | check "$f" "$ranges" || status=1
  fi
done <<EOF
$files
EOF

if [ "$status" = 1 ]; then
  cat >&2 <<EOF
Org prose wraps at $width (.dir-locals.el's fill-column): refill the paragraph (M-q in Emacs, or the org skill's
org_reflow.py) or shorten the heading. Tables, #+begin_X blocks, #+ lines and links are not counted.
EOF
fi
exit "$status"
