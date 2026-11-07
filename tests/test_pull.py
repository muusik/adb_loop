"""pull.sh over a stub adb that runs the phone's commands on a local directory, under the two shapes its projects use: an
app's whole directory mirrored with rules per kind of file, and one flat directory of recordings picked by name."""
import os
import shutil
import subprocess
import tempfile
import time
import unittest

from stub_adb import StubAdb

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
REMOTE = "/sdcard/app/files"
# CUTS names a file holding how many transfers to cut, each at 20000 bytes, after each of which CUT_DOWN shells fail, or
# with THEN_GONE every call does, through the file GONE. A shell eats its standard input, as the real one does.
BODY = r"""
[ "$1" = -s ] && shift 2
how=$1
case "$how" in
  connect) exit 0 ;;
  shell|exec-out)
    shift
    [ "$how" = shell ] && [ ! -t 0 ] && cat > /dev/null
    [ ! -e "$GONE" ] || exit 1
    if [ "$*" = true ]; then
      down=$(cat "$DOWN" 2>/dev/null || echo 0)
      if [ "$down" -gt 0 ]; then echo $((down - 1)) > "$DOWN"; exit 1; fi
      exit 0
    fi
    [ -z "$NOGZIP" ] || case "$*" in *"command -v gzip"*) exit 0 ;; esac
    cmd=$(printf '%s' "$*" | sed "s#REMOTE#$PHONE#g")
    case "$cmd" in
      *"tail -c"*)
        cuts=$(cat "$CUTS" 2>/dev/null || echo 0)
        if [ "$cuts" -gt 0 ]; then
          echo $((cuts - 1)) > "$CUTS"
          sh -c "$cmd" | head -c 20000
          [ -z "$THEN_GONE" ] || : > "$GONE"
          echo "${CUT_DOWN:-0}" > "$DOWN"
          exit 1
        fi ;;
    esac
    exec sh -c "$cmd" ;;
esac
""".replace("REMOTE", REMOTE)
APP_RULES = """
pull_append_only() { case "$1" in Logs/*) return 0 ;; *) return 1 ;; esac; }
pull_prunable_kind() { case "$1" in Logs/notes.tsv) return 1 ;; Logs/*) [ "$2" -ge $((min_kb * 1024)) ] ;; *) return 1 ;; esac; }
pull_prune_find() { echo "find Logs $1"; }
"""
FLAT_RULES = """
pull_append_only() { return 0; }
pull_prunable_kind() { case "$1" in imu-*.csv) [ "$2" -ge $((min_kb * 1024)) ] ;; *) return 1 ;; esac; }
pull_wanted() { case "$1" in imu-*"$WANT"*.csv) return 0 ;; *) return 1 ;; esac; }
"""
MAIN = """
phone_reach
pull_ask_gzip
pull_all %s || exit 1
[ -n "$KEEP" ] || prune_phone
echo finished
"""


class PullCase(unittest.TestCase):
    rules = APP_RULES
    dirs = "."

    def setUp(self):
        self.top = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.top)
        self.stub = StubAdb(self.top, BODY)
        self.phone = os.path.join(self.top, "phone")
        self.here = os.path.join(self.top, "here")
        os.makedirs(self.phone)
        self.script = os.path.join(self.top, "s.sh")
        with open(self.script, "w") as f:
            f.write('adb_loop_path=%s\nadb_loop_default=lan:5555\npull_remote=%s\npull_dest=%s\n'
                    '. "$adb_loop_path/pull.sh"\n%s%s' % (ROOT, REMOTE, self.here, self.rules, MAIN % self.dirs))
        self.cuts = os.path.join(self.top, "cuts")
        self.down = os.path.join(self.top, "down")
        self.gone = os.path.join(self.top, "gone")
        marker = os.path.join(self.top, "marker")
        open(marker, "w").close()
        self.env = self.stub.env()
        self.env.pop("ANDROID_SERIAL", None)
        self.env.update(PHONE=self.phone, CUTS=self.cuts, DOWN=self.down, GONE=self.gone, KEEP="1", WANT="",
                        ADB_LOOP_CONTAINER_MARKERS=marker, ADB_LOOP_WAIT_TRIES="2")

    def put(self, name, data=None, size=300000, days=0):
        path = os.path.join(self.phone, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        data = os.urandom(size) if data is None else data
        with open(path, "wb") as f:
            f.write(data)
        if days:
            old = time.time() - days * 86400
            os.utime(path, (old, old))
        return data

    def have(self, name, data):
        os.makedirs(os.path.dirname(os.path.join(self.here, name)), exist_ok=True)
        with open(os.path.join(self.here, name), "wb") as f:
            f.write(data)

    def got(self, name):
        with open(os.path.join(self.here, name), "rb") as f:
            return f.read()

    def write(self, path, n):
        with open(path, "w") as f:
            f.write(str(n))

    def pull(self, **env):
        return subprocess.run(["sh", self.script], env=dict(self.env, **env), capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=60)

    def ok(self, **env):
        r = self.pull(**env)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def transfers(self):
        return [c for c in self.stub.calls() if "tail -c" in c]


class Mirror(PullCase):
    def test_new_files_arrive_in_their_directories_and_a_second_run_fetches_nothing(self):
        body = self.put("Logs/a.csv")
        profile = self.put("profile.json", b"{}")
        self.ok()
        self.assertEqual((self.got("Logs/a.csv"), self.got("profile.json")), (body, profile))
        before = len(self.transfers())
        r = self.ok()
        self.assertEqual(len(self.transfers()), before)
        self.assertIn("all 2 files compared", r.stdout)

    def test_plain_bytes_without_a_gzip_on_the_phone(self):
        body = self.put("Logs/a.csv")
        self.ok(NOGZIP="1")
        self.assertEqual(self.got("Logs/a.csv"), body)
        self.assertNotIn("gzip -1", " ".join(self.transfers()))

    def test_a_grown_file_has_only_its_tail_fetched(self):
        body = self.put("Logs/a.csv")
        self.have("Logs/a.csv", body[:100000])
        self.ok()
        self.assertEqual(self.got("Logs/a.csv"), body)
        self.assertEqual(len(self.transfers()), 1)
        self.assertIn("tail -c +100001", self.transfers()[0])

    def test_a_copy_that_is_not_the_files_start_is_kept_as_stale(self):
        body = self.put("Logs/a.csv")
        self.have("Logs/a.csv", b"x" * 1000)
        self.ok()
        self.assertEqual(self.got("Logs/a.csv"), body)
        self.assertEqual(self.got("Logs/a.csv.stale"), b"x" * 1000)

    def test_a_copy_longer_than_the_phones_is_kept_as_stale(self):
        body = self.put("profile.json", size=1000)
        self.have("profile.json", b"x" * 2000)
        self.ok()
        self.assertEqual(self.got("profile.json"), body)
        self.assertEqual(self.got("profile.json.stale"), b"x" * 2000)

    def test_a_small_file_rewritten_in_place_is_fetched_and_an_append_only_one_is_not(self):
        body = self.put("profile.json", size=1000)
        self.have("profile.json", b"x" * 1000)
        log = self.put("Logs/a.csv", size=1000)
        self.have("Logs/a.csv", b"y" * 1000)
        self.ok()
        self.assertEqual(self.got("profile.json"), body)
        self.assertEqual(self.got("Logs/a.csv"), b"y" * 1000)
        self.assertNotEqual(log, b"y" * 1000)

    def test_a_cut_link_goes_on_in_the_same_run_from_where_it_stopped(self):
        for nogzip in ("", "1"):
            with self.subTest(nogzip=nogzip):
                body = self.put("Logs/a%s.csv" % nogzip)
                self.write(self.cuts, 1)
                calls = len(self.transfers())
                r = self.ok(NOGZIP=nogzip, CUT_DOWN="1")
                self.assertEqual(self.got("Logs/a%s.csv" % nogzip), body)
                self.assertIn("interrupted at", r.stderr)
                self.assertIn("(attempt 2)", r.stdout)
                resumed = self.transfers()[calls + 1]
                self.assertNotIn("tail -c +1 ", resumed)
                self.assertIn("finished", r.stdout)

    def test_a_cut_whole_fetch_resumes_its_part(self):
        body = self.put("store.bin", size=300000)
        self.write(self.cuts, 1)
        r = self.ok(NOGZIP="1")
        self.assertEqual(self.got("store.bin"), body)
        self.assertIn("resuming at 20000 of 300000", r.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.here, "store.bin.part")))

    def test_a_phone_that_does_not_come_back_ends_it_and_the_next_run_goes_on(self):
        body = self.put("Logs/a.csv")
        self.write(self.cuts, 1)
        r = self.pull(NOGZIP="1", THEN_GONE="1")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("the phone went away at Logs/a.csv", r.stderr)
        self.assertNotIn("finished", r.stdout)
        self.assertEqual(self.got("Logs/a.csv"), body[:20000])
        os.remove(self.gone)
        self.ok(NOGZIP="1")
        self.assertEqual(self.got("Logs/a.csv"), body)
        self.assertIn("tail -c +20001", self.transfers()[-1])

    def test_a_file_that_keeps_failing_is_given_up_after_its_attempts_and_the_others_still_come(self):
        bad = self.put("Logs/a.csv")
        other = self.put("Logs/b.csv", size=1000)
        self.write(self.cuts, 3)
        r = self.pull(NOGZIP="1")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("1 file(s) not pulled", r.stderr)
        self.assertEqual(self.got("Logs/b.csv"), other)
        self.assertEqual(self.got("Logs/a.csv"), bad[:60000])

    def test_no_list_from_a_phone_that_has_gone_is_a_failure_not_nothing_to_pull(self):
        self.put("Logs/a.csv")
        script = os.path.join(self.top, "gone_after_reach.sh")
        with open(self.script) as f:
            body = f.read().replace("pull_ask_gzip", ': > "$GONE"')
        with open(script, "w") as f:
            f.write(body)
        r = subprocess.run(["sh", script], env=self.env, capture_output=True, text=True, stdin=subprocess.DEVNULL,
                           timeout=60)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("the phone went away while listing", r.stderr)

    def test_an_empty_directory_is_nothing_to_pull(self):
        r = self.ok()
        self.assertIn("nothing to pull", r.stderr)

    def test_the_prune_takes_every_old_file_held_of_its_kinds_and_nothing_else(self):
        self.put("Logs/old1.csv", days=30)
        self.put("Logs/old2.csv", days=30)
        self.put("Logs/old3.csv", days=30)
        self.put("Logs/young.csv", days=1)
        self.put("Logs/small.csv", size=2000, days=30)
        self.put("Logs/notes.tsv", days=30)
        self.put("store.bin", days=30)
        r = self.ok(KEEP="")
        self.assertEqual(sorted(os.listdir(os.path.join(self.phone, "Logs"))), ["notes.tsv", "small.csv", "young.csv"])
        self.assertTrue(os.path.exists(os.path.join(self.phone, "store.bin")))
        self.assertIn("pruned 3 files", r.stdout)
        for name in ("old1.csv", "old2.csv", "old3.csv"):
            self.assertTrue(os.path.exists(os.path.join(self.here, "Logs", name)))

    def test_the_prune_keeps_a_file_whose_copy_differs(self):
        self.put("Logs/old.csv", days=30)
        self.have("Logs/old.csv", b"x" * 300000)
        r = self.ok(KEEP="")
        self.assertTrue(os.path.exists(os.path.join(self.phone, "Logs", "old.csv")))
        self.assertIn("kept on the phone: Logs/old.csv", r.stderr)
        self.assertIn("pruned 0 files", r.stdout)


class Flat(PullCase):
    rules = FLAT_RULES

    def test_only_the_recordings_named_come(self):
        one = self.put("imu-20261103-1.csv", size=1000)
        self.put("imu-20261104-2.csv", size=1000)
        self.put("other.txt", size=10)
        self.ok(WANT="20261103")
        self.assertEqual(os.listdir(self.here), ["imu-20261103-1.csv"])
        self.assertEqual(self.got("imu-20261103-1.csv"), one)

    def test_a_cut_recording_goes_on_and_is_whole(self):
        body = self.put("imu-1.csv")
        self.write(self.cuts, 1)
        self.ok(CUT_DOWN="1")
        self.assertEqual(self.got("imu-1.csv"), body)

    def test_the_prune_takes_old_recordings_only(self):
        self.put("imu-old.csv", days=30)
        self.put("imu-new.csv", days=1)
        self.put("other.txt", days=30)
        r = self.ok(KEEP="")
        self.assertEqual(sorted(os.listdir(self.phone)), ["imu-new.csv", "other.txt"])
        self.assertIn("pruned 1 files", r.stdout)
        self.assertTrue(os.path.exists(os.path.join(self.here, "imu-old.csv")))


if __name__ == "__main__":
    unittest.main()
