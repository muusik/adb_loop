"""stream.sh over a stub adb that runs the phone's command on a local directory: the framing of many files in one stream,
the two buckets (plain and gzip) and the hashes at once, a stream cut short, a plan sent in pieces, and the verdicts."""
import hashlib
import os
import shutil
import subprocess
import tempfile
import time
import unittest

from stub_adb import StubAdb

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
REMOTE = "/sdcard/app/files"
# CUT_PLAIN / CUT_PACKED / CUT_HASH: that call (plain, through gzip, the hashes) cut after that many bytes. WAIT_FOR: the
# plain stream starts only once the gzip one and the hashes have (files they touch), so that a run that makes the calls
# one after the other fails. STALL_PLAIN / STALL_HASH: that call sends that many bytes, then nothing, until it is ended.
# SLOW_PLAIN: the plain call sends its bytes 1000 at a time, every half second.
BODY = r"""
[ "$1" = -s ] && shift 2
shift
cmd=$(printf '%s' "$*" | sed "s#REMOTE#$PHONE#g")
case "$cmd" in
  *md5sum*) : > "$TOP/hash-started"; cut=${CUT_HASH:-} ;;
  *"| gzip"*) : > "$TOP/packed-started"; cut=${CUT_PACKED:-} ;;
  *)
    if [ -n "${WAIT_FOR:-}" ]; then
      n=0
      while [ ! -e "$TOP/packed-started" ] || [ ! -e "$TOP/hash-started" ]; do
        n=$((n + 1)); [ "$n" -lt 50 ] || exit 1; sleep 0.1
      done
    fi
    cut=${CUT_PLAIN:-} ;;
esac
case "$cmd" in *md5sum*) stall=${STALL_HASH:-} ;; *"| gzip"*) stall= ;; *) stall=${STALL_PLAIN:-} ;; esac
if [ -n "$cut" ]; then sh -c "$cmd" | head -c "$cut"; exit 1; fi
if [ -n "$stall" ]; then sh -c "$cmd" | head -c "$stall"; exec sleep 300; fi
case "$cmd" in *md5sum*|*"| gzip"*) ;; *)
  if [ -n "${SLOW_PLAIN:-}" ]; then
    sh -c "$cmd" > "$TOP/slow"; n=$(stat -c %s "$TOP/slow"); i=0
    while [ "$i" -lt "$n" ]; do tail -c +$((i + 1)) "$TOP/slow" | head -c 1000; i=$((i + 1000)); sleep 0.5; done
    exit 0
  fi ;;
esac
exec sh -c "$cmd"
"""
RULES = """
pull_append_only() { case "$1" in Logs/*) return 0 ;; *) return 1 ;; esac; }
pull_compressed() { case "$1" in *.jpg|*.gz) return 0 ;; *) return 1 ;; esac; }
"""
MAIN = """
zip="gzip -1"; unzip="gzip -dc"
stream_plan "$(cat "$TOP/plan")" "$TOP/lines"
"""
# the line after each file's bytes: "-- " and 16 hex digits
TOKEN = 20


class StreamCase(unittest.TestCase):
    def setUp(self):
        self.top = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.top)
        self.stub = StubAdb(self.top, BODY.replace("REMOTE", REMOTE))
        self.phone = os.path.join(self.top, "phone")
        self.here = os.path.join(self.top, "here")
        os.makedirs(self.phone)
        self.script = os.path.join(self.top, "s.sh")
        with open(self.script, "w") as f:
            f.write('adb_loop_path=%s\npull_remote=%s\npull_dest=%s\n. "$adb_loop_path/pull.sh"\n'
                    '. "$adb_loop_path/stream.sh"\n%s%s' % (ROOT, REMOTE, self.here, RULES, MAIN))
        self.env = self.stub.env()
        self.env.update(PHONE=self.phone, TOP=self.top, XDG_DATA_HOME=os.path.join(self.top, "xdg"))
        for k in ("CUT_PLAIN", "CUT_PACKED", "CUT_HASH", "WAIT_FOR", "STREAM_PLAN_BYTES", "STALL_PLAIN", "STALL_HASH",
                  "SLOW_PLAIN", "ADB_LOOP_STALL"):
            self.env.pop(k, None)

    def put(self, name, data):
        path = os.path.join(self.phone, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        return data

    def have(self, name, data):
        path = os.path.join(self.here, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)

    def got(self, name):
        with open(os.path.join(self.here, name), "rb") as f:
            return f.read()

    def exists(self, name):
        return os.path.exists(os.path.join(self.here, name))

    def size_here(self, name):
        path = os.path.join(self.here, name)
        return os.path.getsize(path) if os.path.exists(path) else 0

    def run_plan(self, lines, **env):
        """lines: (from, len, rel). The script's result; the stream's lines (done, cut, short, skip) in order; the
        verdicts as {rel: ok/bad/unverified}"""
        with open(os.path.join(self.top, "plan"), "w") as f:
            f.write("".join("%d %d %s\n" % line for line in lines))
        for marker in ("packed-started", "hash-started"):
            if os.path.exists(os.path.join(self.top, marker)):
                os.remove(os.path.join(self.top, marker))
        e = dict(self.env, **env)
        r = subprocess.run(["sh", self.script], env=e, capture_output=True, timeout=60)
        with open(os.path.join(self.top, "lines")) as f:
            out = f.read().splitlines()
        self.stalled = [x for x in out if x.startswith("stalled ")]
        stream = [x for x in out if x.split(" ")[0] in ("done", "cut", "short", "skip")]
        verdicts = {x.split(" ", 1)[1]: x.split(" ")[0] for x in out if x.split(" ")[0] in ("ok", "bad", "unverified")}
        return r, stream, verdicts

    def whole(self, *names):
        """a plan for these files of the phone, from the sizes here (an append-only copy, else the .part)"""
        plan = []
        for n in names:
            size = os.path.getsize(os.path.join(self.phone, n))
            have = self.size_here(n if n.startswith("Logs/") else n + ".part")
            plan.append((have, size - have, n))
        return plan


class Framing(StreamCase):
    def test_hostile_contents_and_names(self):
        """bytes that look like headers or the end, no final newline, empty files, spaces and nested directories"""
        files = {
            "Logs/a b.csv": b"5 0 Logs/x\n-- end\n" * 3000 + b"no newline",
            "Logs/empty.csv": b"",
            "pics/one.jpg": os.urandom(150000),
            "pics/deep/two.jpg": b"\n" * 1000,
            "pics/empty.jpg": b"",
            "notes.tsv": b"-- end",
            "x/y/z b.bin": os.urandom(70000) + b"\n-- end\n",
        }
        for n, d in files.items():
            self.put(n, d)
        r, lines, verdicts = self.run_plan(self.whole(*files))
        self.assertEqual(r.returncode, 0, r.stderr)
        for n, d in files.items():
            self.assertEqual(self.got(n), d, n)
            self.assertFalse(self.exists(n + ".part"), n)
        self.assertEqual(sorted(lines), sorted("done %s 0 %d" % (n, len(d)) for n, d in files.items()))
        self.assertEqual(verdicts, {n: "ok" for n in files})

    def test_buckets_and_hashes_go_in_their_own_calls(self):
        self.put("pics/one.jpg", os.urandom(1000))
        self.put("old.gz", os.urandom(1000))
        self.put("Logs/a.csv", b"a,b\n" * 1000)
        r, _, _ = self.run_plan(self.whole("pics/one.jpg", "old.gz", "Logs/a.csv"))
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = self.stub.calls()
        self.assertEqual(len(calls), 3)
        packed = [c for c in calls if "| gzip -1" in c]
        plain = [c for c in calls if "| cat" in c]
        hashes = [c for c in calls if "md5sum" in c]
        self.assertEqual((len(packed), len(plain), len(hashes)), (1, 1, 1))
        self.assertIn("Logs/a.csv", packed[0])
        self.assertNotIn("one.jpg", packed[0])
        self.assertIn("one.jpg", plain[0])
        self.assertIn("old.gz", plain[0])
        for n in ("Logs/a.csv", "one.jpg", "old.gz"):
            self.assertIn(n, hashes[0])

    def test_the_three_calls_run_at_once(self):
        self.put("pics/one.jpg", os.urandom(1000))
        self.put("Logs/a.csv", b"a,b\n" * 1000)
        r, lines, verdicts = self.run_plan(self.whole("pics/one.jpg", "Logs/a.csv"), WAIT_FOR="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(lines), 2)
        self.assertEqual(set(verdicts.values()), {"ok"})

    def test_only_one_bucket(self):
        self.put("pics/one.jpg", b"jpeg")
        r, lines, verdicts = self.run_plan(self.whole("pics/one.jpg"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.stub.calls()), 2)
        self.assertEqual(lines, ["done pics/one.jpg 0 4"])
        self.assertEqual(verdicts, {"pics/one.jpg": "ok"})

    def test_a_tail_from_the_size_here(self):
        data = self.put("Logs/a.csv", os.urandom(50000))
        self.have("Logs/a.csv", data[:12345])
        r, lines, verdicts = self.run_plan(self.whole("Logs/a.csv"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.got("Logs/a.csv"), data)
        self.assertEqual(lines, ["done Logs/a.csv 12345 %d" % (50000 - 12345)])
        self.assertEqual(verdicts, {"Logs/a.csv": "ok"})

    def test_a_growing_file_is_hashed_as_far_as_the_plan(self):
        data = self.put("Logs/a.csv", os.urandom(50000))
        r, lines, verdicts = self.run_plan([(0, 30000, "Logs/a.csv")])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.got("Logs/a.csv"), data[:30000])
        self.assertEqual(verdicts, {"Logs/a.csv": "ok"})

    def test_a_shorter_file_is_put_back_and_the_stream_ends(self):
        self.put("Logs/a.csv", b"short")
        before = self.put("Logs/b.csv", os.urandom(3000))
        self.have("Logs/b.csv", before[:1000])
        self.put("Logs/c.csv", b"c" * 100)
        r, lines, _ = self.run_plan([(0, 100, "Logs/c.csv"), (1000, 4000, "Logs/b.csv"), (0, 100, "Logs/a.csv")])
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(lines, ["done Logs/c.csv 0 100", "short Logs/b.csv 1000 4000"])
        self.assertEqual(self.got("Logs/b.csv"), before[:1000])
        self.assertFalse(self.exists("Logs/a.csv"))
        r, lines, _ = self.run_plan([p for p in self.whole("Logs/a.csv", "Logs/b.csv", "Logs/c.csv") if p[1] > 0])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.got("Logs/b.csv"), before)
        self.assertEqual(self.got("Logs/a.csv"), b"short")

    def test_a_file_gone_from_the_phone(self):
        after = self.put("pics/b.jpg", os.urandom(3000))
        r, lines, _ = self.run_plan([(0, 500, "pics/gone.jpg"), (0, 3000, "pics/b.jpg")])
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(lines, ["short pics/gone.jpg 0 500"])
        self.assertEqual(self.size_here("pics/gone.jpg.part"), 0)
        r, lines, _ = self.run_plan(self.whole("pics/b.jpg"))
        self.assertEqual(self.got("pics/b.jpg"), after)

    def test_a_copy_not_at_the_plans_start_is_skipped_and_the_rest_framed(self):
        self.put("Logs/a.csv", b"x" * 500)
        after = self.put("Logs/b.csv", os.urandom(3000))
        self.have("Logs/a.csv", b"x" * 10)
        r, lines, verdicts = self.run_plan([(0, 500, "Logs/a.csv"), (0, 3000, "Logs/b.csv")])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.got("Logs/a.csv"), b"x" * 10)
        self.assertEqual(self.got("Logs/b.csv"), after)
        self.assertEqual(lines, ["skip Logs/a.csv 10 0", "done Logs/b.csv 0 3000"])
        self.assertEqual(verdicts, {"Logs/b.csv": "ok"})

    def test_the_plan_in_pieces(self):
        files = {"pics/%03d.jpg" % i: os.urandom(i * 7) for i in range(60)}
        files.update({"Logs/%03d.csv" % i: os.urandom(i * 11) for i in range(60)})
        for n, d in files.items():
            self.put(n, d)
        r, lines, verdicts = self.run_plan(self.whole(*files), STREAM_PLAN_BYTES="300")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertGreater(len([c for c in self.stub.calls() if "md5sum" in c]), 4)
        self.assertGreater(len([c for c in self.stub.calls() if "md5sum" not in c]), 4)
        for n, d in files.items():
            self.assertEqual(self.got(n), d, n)
        self.assertEqual(len(lines), 120)
        self.assertEqual(verdicts, {n: "ok" for n in files})


class Hashes(StreamCase):
    def test_an_append_to_a_copy_that_was_not_the_start_is_kept_aside(self):
        data = self.put("Logs/a.csv", os.urandom(5000))
        wrong = os.urandom(1000)
        self.have("Logs/a.csv", wrong)
        r, lines, verdicts = self.run_plan(self.whole("Logs/a.csv"))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(verdicts, {"Logs/a.csv": "bad"})
        self.assertFalse(self.exists("Logs/a.csv"))
        self.assertEqual(self.got("Logs/a.csv.stale"), wrong)
        r, lines, verdicts = self.run_plan(self.whole("Logs/a.csv"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.got("Logs/a.csv"), data)

    def test_a_part_not_the_start_of_the_phones_file_is_dropped(self):
        data = self.put("pics/a.jpg", os.urandom(5000))
        self.have("pics/a.jpg", b"old copy")
        self.have("pics/a.jpg.part", os.urandom(1000))
        r, lines, verdicts = self.run_plan(self.whole("pics/a.jpg"))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(verdicts, {"pics/a.jpg": "bad"})
        self.assertFalse(self.exists("pics/a.jpg.part"))
        self.assertEqual(self.got("pics/a.jpg"), b"old copy")
        r, lines, verdicts = self.run_plan(self.whole("pics/a.jpg"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.got("pics/a.jpg"), data)

    def test_no_hashes_leaves_the_files_unverified(self):
        data = self.put("pics/a.jpg", os.urandom(5000))
        self.put("Logs/a.csv", b"a" * 100)
        r, lines, verdicts = self.run_plan(self.whole("pics/a.jpg", "Logs/a.csv"), CUT_HASH="0")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(verdicts, {"pics/a.jpg": "unverified", "Logs/a.csv": "unverified"})
        self.assertEqual(self.got("pics/a.jpg.part"), data)
        self.assertFalse(self.exists("pics/a.jpg"))

    def test_hashes_cut_short_verify_those_that_came(self):
        self.put("Logs/b.csv", b"b" * 100)
        for i in range(3):
            self.put("pics/%d.jpg" % i, os.urandom(1000))
        r, lines, verdicts = self.run_plan(self.whole("pics/0.jpg", "pics/1.jpg", "pics/2.jpg", "Logs/b.csv"),
                                           CUT_HASH=str(2 * (32 + 2 + len("pics/0.jpg") + 1)))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(verdicts, {"pics/0.jpg": "ok", "pics/1.jpg": "ok", "pics/2.jpg": "unverified",
                                    "Logs/b.csv": "unverified"})


class HashCall(StreamCase):
    """stream_hashes alone: which files get their range hashed besides the one md5sum"""

    def hashes(self, plan):
        with open(os.path.join(self.top, "plan"), "w") as f:
            f.write("".join("%d %d %s\n" % line for line in plan))
        script = os.path.join(self.top, "h.sh")
        with open(script, "w") as f:
            f.write('adb_loop_path=%s\npull_remote=%s\npull_dest=%s\n. "$adb_loop_path/pull.sh"\n'
                    '. "$adb_loop_path/stream.sh"\n%s\n: > "$TOP/lines"\nstream_hashes "$(cat "$TOP/plan")" "$TOP/lines"\n'
                    % (ROOT, REMOTE, self.here, RULES))
        r = subprocess.run(["sh", script], env=self.env, capture_output=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(self.top, "lines")) as f:
            return [line.split(" ", 2)[1:] for line in f.read().splitlines()]

    def test_only_a_grown_or_missing_append_only_file_has_its_range_hashed(self):
        a = self.put("Logs/a.csv", os.urandom(1000))
        b = self.put("Logs/b b.csv", os.urandom(2000))
        c = self.put("Logs/c.csv", os.urandom(3000))
        d = self.put("pics/d.jpg", os.urandom(500))
        lines = self.hashes([(0, 1000, "Logs/a.csv"), (0, 700, "Logs/gone.csv"), (100, 1900, "Logs/b b.csv"),
                             (0, 2500, "Logs/c.csv"), (0, 500, "pics/d.jpg")])
        md5 = lambda data: hashlib.md5(data).hexdigest()
        empty = md5(b"")
        self.assertEqual(lines, [[md5(a), "Logs/a.csv"], [md5(b), "Logs/b b.csv"], [md5(c), "Logs/c.csv"],
                                 [md5(d), "pics/d.jpg"], [empty, "Logs/gone.csv"], [md5(c[:2500]), "Logs/c.csv"]])


class Cut(StreamCase):
    def files(self):
        return {"pics/%d.jpg" % i: self.put("pics/%d.jpg" % i, os.urandom(10000)) for i in range(3)}

    def test_cut_in_a_file_leaves_an_exact_prefix_and_a_new_plan_goes_on(self):
        files = self.files()
        names = sorted(files)
        # the first file's header and bytes, the second's header and 4321 of its bytes
        h1 = len("10000 0 %s\n" % names[0])
        h2 = len("10000 0 %s\n" % names[1])
        r, lines, verdicts = self.run_plan(self.whole(*names), CUT_PLAIN=str(h1 + 10000 + TOKEN + h2 + 4321))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(lines, ["done %s 0 10000" % names[0], "cut %s 4321 10000" % names[1]])
        self.assertEqual(verdicts, {names[0]: "ok"})
        self.assertEqual(self.got(names[0]), files[names[0]])
        self.assertEqual(self.got(names[1] + ".part"), files[names[1]][:4321])
        self.assertFalse(self.exists(names[2] + ".part"))
        plan = [p for p in self.whole(*names[1:]) if p[1] > 0]
        self.assertEqual(plan, [(4321, 5679, names[1]), (0, 10000, names[2])])
        r, lines, verdicts = self.run_plan(plan)
        self.assertEqual(r.returncode, 0, r.stderr)
        for n in names:
            self.assertEqual(self.got(n), files[n])

    def test_cut_in_a_header(self):
        files = self.files()
        names = sorted(files)
        h1 = len("10000 0 %s\n" % names[0])
        r, lines, _ = self.run_plan(self.whole(*names), CUT_PLAIN=str(h1 + 10000 + TOKEN + 5))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(lines, ["done %s 0 10000" % names[0]])
        self.assertFalse(self.exists(names[1] + ".part"))

    def test_cut_between_the_bytes_and_the_token(self):
        files = self.files()
        names = sorted(files)
        h1 = len("10000 0 %s\n" % names[0])
        r, lines, verdicts = self.run_plan(self.whole(*names), CUT_PLAIN=str(h1 + 10000))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(lines, ["cut %s 10000 10000" % names[0]])
        self.assertEqual(self.got(names[0] + ".part"), files[names[0]])

    def test_cut_just_before_the_end(self):
        files = self.files()
        names = sorted(files)
        full = sum(len("10000 0 %s\n" % n) + 10000 + TOKEN for n in names)
        r, lines, verdicts = self.run_plan(self.whole(*names), CUT_PLAIN=str(full))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(len(lines), 3)
        self.assertEqual(set(verdicts.values()), {"ok"})

    def test_cut_gzip_stream_leaves_prefixes(self):
        data = {"Logs/%d.csv" % i: self.put("Logs/%d.csv" % i, os.urandom(40000)) for i in range(3)}
        r, lines, _ = self.run_plan(self.whole(*sorted(data)), CUT_PACKED="50000")
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(lines[-1].startswith("cut "), lines)
        for n, d in data.items():
            got = self.got(n) if self.exists(n) else b""
            self.assertEqual(got, d[:len(got)], n)
        r, lines, _ = self.run_plan([p for p in self.whole(*sorted(data)) if p[1] > 0])
        self.assertEqual(r.returncode, 0, r.stderr)
        for n, d in data.items():
            self.assertEqual(self.got(n), d)



class Watchdog(StreamCase):
    def files(self):
        return {"pics/%d.jpg" % i: self.put("pics/%d.jpg" % i, os.urandom(10000)) for i in range(3)}

    def test_a_stalled_call_is_ended_with_an_exact_prefix(self):
        files = self.files()
        names = sorted(files)
        h1 = len("10000 0 %s\n" % names[0])
        h2 = len("10000 0 %s\n" % names[1])
        start = time.monotonic()
        r, lines, verdicts = self.run_plan(self.whole(*names), ADB_LOOP_STALL="2",
                                           STALL_PLAIN=str(h1 + 10000 + TOKEN + h2 + 4321))
        self.assertLess(time.monotonic() - start, 20)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.stalled, ["stalled plain 2"])
        self.assertEqual(lines, ["done %s 0 10000" % names[0], "cut %s 4321 10000" % names[1]])
        self.assertEqual(verdicts, {names[0]: "ok"})
        self.assertEqual(self.got(names[1] + ".part"), files[names[1]][:4321])
        r, lines, verdicts = self.run_plan([p for p in self.whole(*names) if p[1] > 0])
        self.assertEqual(r.returncode, 0, r.stderr)
        for n in names:
            self.assertEqual(self.got(n), files[n])

    def test_a_stalled_hash_call_leaves_the_files_unverified(self):
        files = self.files()
        names = sorted(files)
        start = time.monotonic()
        r, lines, verdicts = self.run_plan(self.whole(*names), ADB_LOOP_STALL="2", STALL_HASH="0")
        self.assertLess(time.monotonic() - start, 20)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.stalled, ["stalled hashes 2"])
        self.assertEqual(len(lines), 3)
        self.assertEqual(set(verdicts.values()), {"unverified"})

    def test_a_slow_call_that_keeps_coming_is_not_ended(self):
        files = self.files()
        names = sorted(files)
        r, lines, verdicts = self.run_plan(self.whole(*names), ADB_LOOP_STALL="2", SLOW_PLAIN="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.stalled, [])
        self.assertEqual(set(verdicts.values()), {"ok"})
        for n in names:
            self.assertEqual(self.got(n), files[n])


if __name__ == "__main__":
    unittest.main()
