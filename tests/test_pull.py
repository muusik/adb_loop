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
# with THEN_GONE every call does, through the file GONE. HASH_FAILS names a file holding how many hash calls fail.
# SHRINK: a file cut to SHRINK_TO bytes as the first transfer starts. STREAM_FAIL: every transfer fails at once. STALL:
# the first transfer sends 20000 bytes, then nothing until it is ended. SLOW: transfers come 20000 bytes every 0.2 s.
# A shell
# eats its standard input, as the real one does.
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
    case "$*" in *"cmd wifi status"*) cat "$PROBE"; exit 0 ;; esac
    cmd=$(printf '%s' "$*" | sed "s#REMOTE#$PHONE#g")
    case "$cmd" in
      *md5sum*)
        hf=$(cat "$HASH_FAILS" 2>/dev/null || echo 0)
        if [ "$hf" -gt 0 ]; then echo $((hf - 1)) > "$HASH_FAILS"; exit 1; fi ;;
      *"tail -c"*)
        if [ -n "$SHRINK" ] && [ ! -e "$CUTS.shrunk" ]; then : > "$CUTS.shrunk"; truncate -s "$SHRINK_TO" "$PHONE/$SHRINK"; fi
        [ -z "$STREAM_FAIL" ] || exit 1
        if [ -n "$STALL" ] && [ ! -e "$CUTS.stalled" ]; then : > "$CUTS.stalled"; sh -c "$cmd" | head -c 20000; exec sleep 300; fi
        if [ -n "$SLOW" ]; then
          sh -c "$cmd" > "$CUTS.slow"; n=$(stat -c %s "$CUTS.slow"); i=0
          while [ "$i" -lt "$n" ]; do tail -c +$((i + 1)) "$CUTS.slow" | head -c 20000; i=$((i + 20000)); sleep 0.2; done
          exit 0
        fi
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
"""
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
    remote = REMOTE
    # the script's lines that say where the files land
    dest = None

    def setUp(self):
        self.top = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.top)
        self.stub = StubAdb(self.top, BODY.replace("REMOTE", self.remote))
        self.phone = os.path.join(self.top, "phone")
        self.here = os.path.join(self.top, "here")
        os.makedirs(self.phone)
        self.script = os.path.join(self.top, "s.sh")
        with open(self.script, "w") as f:
            dest = "pull_dest=%s\n" % self.here if self.dest is None else self.dest
            f.write('adb_loop_path=%s\nadb_loop_default=lan:5555\npull_remote=%s\n%s'
                    '. "$adb_loop_path/pull.sh"\n%s%s' % (ROOT, self.remote, dest, self.rules, MAIN % self.dirs))
        self.cuts = os.path.join(self.top, "cuts")
        self.down = os.path.join(self.top, "down")
        self.gone = os.path.join(self.top, "gone")
        marker = os.path.join(self.top, "marker")
        open(marker, "w").close()
        self.env = self.stub.env()
        self.env.pop("ANDROID_SERIAL", None)
        self.hash_fails = os.path.join(self.top, "hash_fails")
        self.env.update(PHONE=self.phone, CUTS=self.cuts, HASH_FAILS=self.hash_fails, SHRINK="", SHRINK_TO="0",
                        STREAM_FAIL="", STALL="", SLOW="", DOWN=self.down, GONE=self.gone, KEEP="1", WANT="",
                        ADB_LOOP_CONTAINER_MARKERS=marker, ADB_LOOP_WAIT_TRIES="2",
                        ADB_LOOP_STATUS_DIR=os.path.join(self.top, "status"), PROBE=os.devnull,
                        ADB_LOOP_ROOT_MOUNT="none", XDG_DATA_HOME=os.path.join(self.top, "xdg"))

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
        # a session of its own: no controlling terminal, as under a background job or a CI runner
        return subprocess.run(["sh", self.script], env=dict(self.env, **env), capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=60, start_new_session=True)

    def ok(self, **env):
        r = self.pull(**env)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def transfers(self):
        """the calls that carry files (the streams), not their hashes"""
        return [c for c in self.stub.calls() if "tail -c" in c]

    @staticmethod
    def header(name, size):
        """the frame's header before a file sent from its start: a plain stream cut at 20000 bytes has 20000 less this of
        the file"""
        return len("%d 0 %s\n" % (size, name))


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

    def test_no_terminal_is_no_complaint(self):
        self.put("Logs/a.csv", b"x" * 100)
        self.assertNotIn("/dev/tty", self.ok().stderr)

    def test_plain_bytes_without_a_gzip_on_the_phone(self):
        body = self.put("Logs/a.csv")
        self.ok(NOGZIP="1")
        self.assertEqual(self.got("Logs/a.csv"), body)
        self.assertNotIn("gzip -1", " ".join(self.transfers()))

    def test_a_compressed_file_goes_plain_and_a_cut_one_goes_on(self):
        body = self.put("Logs/a.gz")
        self.write(self.cuts, 1)
        self.ok(CUT_DOWN="1")
        self.assertEqual(self.got("Logs/a.gz"), body)
        self.assertTrue(self.transfers())
        self.assertFalse([c for c in self.transfers() if "gzip -1" in c])

    def test_a_grown_file_has_only_its_tail_fetched(self):
        body = self.put("Logs/a.csv")
        self.have("Logs/a.csv", body[:100000])
        self.ok()
        self.assertEqual(self.got("Logs/a.csv"), body)
        self.assertEqual(len(self.transfers()), 1)
        self.assertIn("'100000 200000 Logs/a.csv'", self.transfers()[0])

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
                self.assertIn("pass 2:", r.stdout)
                resumed = self.transfers()[calls + 1]
                self.assertRegex(resumed, r"'[1-9][0-9]* [0-9]+ Logs/a%s.csv'" % nogzip)
                self.assertIn("finished", r.stdout)

    def test_a_cut_whole_fetch_resumes_its_part(self):
        body = self.put("store.bin", size=300000)
        self.write(self.cuts, 1)
        self.ok(NOGZIP="1")
        self.assertEqual(self.got("store.bin"), body)
        got = 20000 - self.header("store.bin", 300000)
        self.assertIn("'%d %d store.bin'" % (got, 300000 - got), self.transfers()[1])
        self.assertFalse(os.path.exists(os.path.join(self.here, "store.bin.part")))

    def test_a_phone_that_does_not_come_back_ends_it_and_the_next_run_goes_on(self):
        body = self.put("Logs/a.csv")
        self.write(self.cuts, 1)
        r = self.pull(NOGZIP="1", THEN_GONE="1")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("the phone went away after pass 1", r.stderr)
        self.assertNotIn("finished", r.stdout)
        got = 20000 - self.header("Logs/a.csv", 300000)
        self.assertEqual(self.got("Logs/a.csv"), body[:got])
        os.remove(self.gone)
        self.ok(NOGZIP="1")
        self.assertEqual(self.got("Logs/a.csv"), body)
        self.assertIn("'%d %d Logs/a.csv'" % (got, 300000 - got), self.transfers()[-1])

    def test_a_file_that_keeps_failing_is_given_up_after_its_attempts_and_the_others_still_come(self):
        bad = self.put("Logs/a.csv")
        other = self.put("Logs/b.csv", size=1000)
        self.write(self.cuts, 3)
        r = self.pull(NOGZIP="1")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("Logs/a.csv: not pulled after 3 attempts", r.stderr)
        self.assertIn("1 file(s) not pulled", r.stderr)
        self.assertEqual(self.got("Logs/b.csv"), other)
        got = self.got("Logs/a.csv")
        self.assertEqual(got, bad[:len(got)])
        self.assertGreater(len(got), 55000)

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

    def prune_calls(self):
        calls = self.stub.calls()
        return calls[next(i for i, c in enumerate(calls) if "-mtime" in c):]

    def test_the_prune_hashes_and_deletes_many_files_in_one_call_each(self):
        for i in range(40):
            self.put("Logs/old %02d.csv" % i, size=200000 + i, days=30)
        self.ok()
        r = self.ok(KEEP="")
        self.assertEqual(os.listdir(os.path.join(self.phone, "Logs")), [])
        self.assertIn("pruned 40 files", r.stdout)
        calls = self.prune_calls()
        self.assertEqual(len([c for c in calls if "md5sum" in c]), 1)
        self.assertEqual(len([c for c in calls if "rm --" in c]), 1)

    def test_the_prune_of_more_append_only_names_than_one_argument_holds(self):
        # 1200 long names: a 100 kB piece of the plan made a hash command of about 400 kB, over Linux's 128 kB for one
        # argument, and no file was pruned (2026-11-21)
        long = "x" * 80
        for i in range(1200):
            self.put("Logs/%s%04d.csv" % (long, i), size=10, days=30)
        self.ok(PRUNE_MIN_KB="0")
        r = self.ok(KEEP="", PRUNE_MIN_KB="0")
        self.assertIn("pruned 1200 files", r.stdout)
        self.assertNotIn("Argument list too long", r.stderr)
        self.assertEqual(os.listdir(os.path.join(self.phone, "Logs")), [])
        self.assertLess(max(len(c) for c in self.prune_calls()), 131072)

    def test_the_prune_splits_its_calls_by_stream_plan_bytes(self):
        for i in range(40):
            self.put("Logs/old%02d.csv" % i, size=200000 + i, days=30)
        self.ok()
        r = self.ok(KEEP="", STREAM_PLAN_BYTES="200")
        self.assertEqual(os.listdir(os.path.join(self.phone, "Logs")), [])
        self.assertIn("pruned 40 files", r.stdout)
        calls = self.prune_calls()
        self.assertGreater(len([c for c in calls if "md5sum" in c]), 1)
        self.assertGreater(len([c for c in calls if "rm --" in c]), 1)


# what the phone's link probe answered on a Moto Z2 (2026-11-12), and the same phone on a weak 2.4 GHz access point
WIFI5_SCREEN_OFF = """WifiInfo: SSID: "home", BSSID: e4:8d:8c:69:33:0c, MAC: 6e:c3:c2:02:1e:d3, IP: /192.168.1.196, \
Security type: 4, Supplicant state: COMPLETED, Wi-Fi standard: 11ac, RSSI: -68, Link speed: 433Mbps, Tx Link speed: 433Mbps, \
Max Supported Tx Link speed: 433Mbps, Rx Link speed: -1Mbps, Max Supported Rx Link speed: 433Mbps, Frequency: 5580MHz, Net ID: 3
screen: mScreenOn=false
saver: 0
suspendopt: null
vpn: tun1    inet 100.64.0.3
vpnapp: VPN:com.tailscale.ipn
"""
WIFI4_WEAK = """WifiInfo: SSID: "far", BSSID: d4:ca:6d:e9:61:a1, MAC: 6e:c3:c2:02:1e:d3, IP: /192.168.1.196, \
Security type: 2, Supplicant state: COMPLETED, Wi-Fi standard: 11n, RSSI: -81, Link speed: 43Mbps, Tx Link speed: 43Mbps, \
Max Supported Tx Link speed: 72Mbps, Rx Link speed: -1Mbps, Max Supported Rx Link speed: 72Mbps, Frequency: 2472MHz, Net ID: 4
screen: mScreenOn=true
saver: 0
suspendopt: null
vpn:
vpnapp:
"""


class Passes(PullCase):
    def hashes(self):
        return [c for c in self.stub.calls() if "md5sum" in c]

    def test_many_files_in_one_call_a_bucket_and_one_for_the_hashes(self):
        files = {"Logs/%02d.csv" % i: self.put("Logs/%02d.csv" % i, size=1000 + i) for i in range(30)}
        files.update({"pics/%02d.jpg" % i: self.put("pics/%02d.jpg" % i, size=500 + i) for i in range(30)})
        r = self.ok()
        for n, d in files.items():
            self.assertEqual(self.got(n), d, n)
        self.assertEqual((len(self.transfers()), len(self.hashes())), (2, 1))
        self.assertIn("pass 1: 60 file(s)", r.stdout)
        self.assertNotIn("pass 2", r.stdout)
        # the second run: the pictures, not append-only, compared by hash, the logs by size
        self.ok()
        self.assertEqual((len(self.transfers()), len(self.hashes())), (2, 2))
        self.assertIn("pics/00.jpg", self.hashes()[1])
        self.assertNotIn("Logs/00.csv", self.hashes()[1])

    def test_a_pass_whose_hashes_did_not_come_is_followed_by_one_of_hashes_only(self):
        body = self.put("Logs/a.csv", size=5000)
        part = self.put("store.bin", size=5000)
        self.write(self.hash_fails, 1)
        r = self.ok()
        self.assertEqual((self.got("Logs/a.csv"), self.got("store.bin")), (body, part))
        self.assertIn("its hash from the phone did not come", r.stderr)
        self.assertIn("pass 2: 0 file(s), 0 kB; 2 compared by hash", r.stdout)
        self.assertEqual((len(self.transfers()), len(self.hashes())), (1, 2))

    def test_an_append_never_verified_is_cut_back_and_the_next_run_fetches_it_again(self):
        body = self.put("Logs/a.csv", size=5000)
        self.have("Logs/a.csv", body[:1000])
        self.write(self.hash_fails, 3)
        r = self.pull()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("Logs/a.csv: what was appended could not be verified, cut back to 1000 bytes", r.stderr)
        self.assertEqual(self.got("Logs/a.csv"), body[:1000])
        self.ok()
        self.assertEqual(self.got("Logs/a.csv"), body)
        self.assertIn("'1000 4000 Logs/a.csv'", self.transfers()[-1])

    def test_a_whole_part_from_an_earlier_run_is_only_hashed(self):
        body = self.put("store.bin", size=5000)
        self.have("store.bin.part", body)
        self.ok()
        self.assertEqual(self.got("store.bin"), body)
        self.assertFalse(os.path.exists(os.path.join(self.here, "store.bin.part")))
        self.assertEqual((len(self.transfers()), len(self.hashes())), (0, 1))

    def test_a_file_shorter_than_listed_is_listed_again(self):
        self.put("store.bin", size=300000)
        r = self.ok(SHRINK="store.bin", SHRINK_TO="1000")
        self.assertIn("store.bin: shorter on the phone than listed", r.stderr)
        with open(os.path.join(self.phone, "store.bin"), "rb") as f:
            self.assertEqual(self.got("store.bin"), f.read())
        self.assertEqual(len(self.got("store.bin")), 1000)

    def test_passes_that_bring_nothing_end_the_pull(self):
        self.put("Logs/a.csv", size=1000)
        r = self.pull(STREAM_FAIL="1")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("nothing came in 3 passes", r.stderr)
        self.assertEqual(len(self.transfers()), 3)

    def test_a_stalled_call_is_ended_and_the_next_pass_goes_on(self):
        body = self.put("store.bin", size=300000)
        start = time.monotonic()
        r = self.ok(STALL="1", ADB_LOOP_STALL="2")
        self.assertLess(time.monotonic() - start, 30)
        self.assertRegex(r.stderr, r"nothing came on the (plain|gzip) call for 2 s; it was ended")
        self.assertEqual(self.got("store.bin"), body)
        self.assertEqual(len(self.transfers()), 2)


class Progress(PullCase):
    def status(self):
        directory = os.path.join(self.top, "status")
        files = [f for f in os.listdir(directory) if f.endswith(".status")]
        self.assertEqual(len(files), 1, os.listdir(directory))
        self.assertFalse([f for f in os.listdir(directory) if f.endswith(".progress")])
        with open(os.path.join(directory, files[0])) as f:
            return dict(line.rstrip("\n").split("=", 1) for line in f)

    def probe(self, text):
        path = os.path.join(self.top, "probe")
        with open(path, "w") as f:
            f.write(text)
        return path

    def test_the_status_file_ends_done_with_the_bytes_fetched_and_the_pull_is_summed_up(self):
        self.put("Logs/a.csv", size=300000)
        body = self.put("Logs/b.csv", size=200000)
        self.have("Logs/b.csv", body[:50000])
        r = self.ok()
        self.assertIn("about 440 kB to fetch, in 2", r.stdout)
        self.assertIn("fetched 440 kB", r.stdout)
        st = self.status()
        self.assertEqual((st["state"], st["bytes_done"], st["bytes_total"]), ("done", "450000", "450000"))
        self.assertEqual((st["files_done"], st["files"]), ("2", "2"))
        self.assertEqual(st["label"], "here")

    def test_while_a_pass_runs_the_status_file_counts_its_bytes_and_names_the_file_at_hand(self):
        self.put("Logs/a.csv", size=300000)
        seen = []
        p = subprocess.Popen(["sh", self.script], env=dict(self.env, SLOW="1", NOGZIP="1"), stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, start_new_session=True)
        directory = os.path.join(self.top, "status")
        while p.poll() is None:
            for name in os.listdir(directory) if os.path.isdir(directory) else []:
                if name.endswith(".status"):
                    try:
                        with open(os.path.join(directory, name)) as f:
                            st = dict(line.rstrip("\n").split("=", 1) for line in f if "=" in line)
                    except FileNotFoundError:
                        continue
                    if st.get("state") == "transferring":
                        seen.append((int(st["bytes_done"]), st["file"], st["bytes_total"]))
            time.sleep(0.1)
        out, err = p.communicate()
        self.assertEqual(p.returncode, 0, out + err)
        between = [s for s in seen if 0 < s[0] < 300000]
        self.assertTrue(between, seen)
        self.assertEqual({(s[1], s[2]) for s in between}, {("Logs/a.csv", "300000")})
        self.assertEqual([s[0] for s in between], sorted(s[0] for s in between))
        self.assertEqual(self.status()["bytes_done"], "300000")

    def test_a_failed_pull_says_so_in_the_status_file(self):
        self.put("Logs/a.csv")
        self.write(self.cuts, 1)
        r = self.pull(NOGZIP="1", THEN_GONE="1")
        self.assertEqual(r.returncode, 1, r.stdout)
        st = self.status()
        self.assertEqual((st["state"], st["bytes_done"]), ("failed", str(20000 - self.header("Logs/a.csv", 300000))))

    def test_the_link_in_words_and_what_slows_it(self):
        self.put("Logs/a.csv", size=1000)
        r = self.ok(PROBE=self.probe(WIFI5_SCREEN_OFF))
        self.assertIn("link: Wi-Fi 5, 5 GHz ch 116, home, signal fair (-68 dBm), 433 of 433 Mbit/s | screen off: power save"
                      " | VPN tailscale | adb over network", r.stdout)
        self.assertIn("the screen is off", r.stdout)
        st = self.status()
        self.assertEqual((st["wifi_gen"], st["band"], st["screen"], st["power_save"], st["vpn"]),
                         ("Wi-Fi 5", "5 GHz", "off", "on", "tailscale"))

    def test_a_weak_24_ghz_link_is_named_as_such(self):
        self.put("Logs/a.csv", size=1000)
        r = self.ok(PROBE=self.probe(WIFI4_WEAK))
        self.assertIn("link: Wi-Fi 4, 2.4 GHz ch 13, far, signal weak (-81 dBm), 43 of 72 Mbit/s | screen on", r.stdout)
        self.assertIn("2.4 GHz, several times slower", r.stdout)
        self.assertIn("the signal is weak", r.stdout)
        self.assertNotIn("the screen is off", r.stdout)
        self.assertEqual(self.status()["vpn"], "")


class Seed(PullCase):
    """A store renamed on the phone (store.bin to store.bin.v1, a new store.bin begun) is the copy here under its old
    name: a project's pull_seed puts it in place, and only the rest comes."""
    rules = APP_RULES.replace("Logs/*) return 0", "Logs/*|store.bin.v*) return 0") + """
pull_seed() {
  case "$1" in
    store.bin.v*)
      old=$pull_dest/${1%.v*}
      [ -f "$old" ] || return 0
      n=$(stat -c %s "$old")
      [ -n "$TRUST" ] || [ "$(local_md5 "$old")" = "$(phone_md5 "$1" "$n")" ] || return 0
      echo "$1: the store as it was, renamed from ${old##*/}"
      mv "$old" "$pull_dest/$1" ;;
  esac
}
"""

    def test_a_renamed_store_is_moved_into_place_and_only_its_tail_fetched(self):
        old = os.urandom(200000)
        self.put("store.bin.v1", old + os.urandom(1000))
        new = self.put("store.bin", size=3000)
        self.have("store.bin", old)
        r = self.ok()
        self.assertIn("store.bin.v1: the store as it was, renamed from store.bin", r.stdout)
        with open(os.path.join(self.phone, "store.bin.v1"), "rb") as f:
            self.assertEqual(self.got("store.bin.v1"), f.read())
        self.assertEqual(self.got("store.bin"), new)
        self.assertIn("'200000 1000 store.bin.v1'", "".join(self.transfers()))
        self.assertEqual(sorted(os.listdir(self.here)), ["store.bin", "store.bin.v1"])
        self.assertIn("about 4 kB to fetch", r.stdout)

    def test_a_copy_that_is_not_the_renamed_store_stays(self):
        self.put("store.bin.v1", size=201000)
        new = self.put("store.bin", size=3000)
        old = os.urandom(200000)
        self.have("store.bin", old)
        r = self.ok()
        self.assertNotIn("renamed from", r.stdout)
        self.assertEqual(self.got("store.bin"), new)
        self.assertEqual(self.got("store.bin.stale"), old)

    def test_a_seed_that_was_not_the_start_is_kept_as_stale_and_the_file_fetched_whole(self):
        body = self.put("store.bin.v1", size=201000)
        self.put("store.bin", size=3000)
        old = os.urandom(200000)
        self.have("store.bin", old)
        r = self.ok(TRUST="1")
        self.assertIn("renamed from store.bin", r.stdout)
        self.assertEqual(self.got("store.bin.v1"), body)
        self.assertEqual(self.got("store.bin.v1.stale"), old)
        self.assertIn("pass 2", r.stdout)


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


class Dest(PullCase):
    """Where the files land when the project does not say: its data directory's phone/, by the path below files/."""
    remote = "/sdcard/Android/data/com.example.app/files/logs"
    rules = FLAT_RULES.replace("imu-*", "*")
    dest = "adb_loop_name=proj\n"

    def setUp(self):
        super().setUp()
        self.here = os.path.join(self.top, "xdg", "proj", "phone", "logs")

    def test_the_data_directorys_phone_mirror_by_the_path_below_files(self):
        body = self.put("a.csv", size=1000)
        r = self.ok()
        self.assertIn("into %s" % self.here, r.stdout)
        self.assertEqual(self.got("a.csv"), body)

    def test_the_projects_own_variable_names_another_data_directory(self):
        body = self.put("a.csv", size=1000)
        with open(self.script) as f:
            text = f.read()
        with open(self.script, "w") as f:
            f.write(text.replace("adb_loop_name=proj\n", 'adb_loop_name=proj\nadb_loop_data=${MY_DATA:-}\n'))
        self.ok(MY_DATA=os.path.join(self.top, "mine"))
        with open(os.path.join(self.top, "mine", "phone", "logs", "a.csv"), "rb") as f:
            self.assertEqual(f.read(), body)
        self.assertFalse(os.path.exists(os.path.join(self.top, "xdg")))

    def test_in_the_container_a_directory_on_its_own_root_is_refused_before_anything_is_fetched(self):
        self.put("a.csv", size=1000, days=30)
        root = subprocess.run(["stat", "-c", "%m", self.top], capture_output=True, text=True).stdout.strip()
        r = self.pull(ADB_LOOP_ROOT_MOUNT=root, KEEP="")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn(".bl-mounts", r.stderr)
        self.assertEqual(self.transfers(), [])
        self.assertEqual(os.listdir(self.phone), ["a.csv"])

    def test_outside_the_container_any_directory_will_do(self):
        self.put("a.csv", size=1000)
        root = subprocess.run(["stat", "-c", "%m", self.top], capture_output=True, text=True).stdout.strip()
        self.ok(ADB_LOOP_ROOT_MOUNT=root, ADB_LOOP_CONTAINER_MARKERS=os.path.join(self.top, "none"))
        self.assertTrue(os.path.exists(os.path.join(self.here, "a.csv")))


class NoDest(PullCase):
    remote = "/sdcard/somewhere"
    dest = ""

    def test_neither_a_dest_nor_a_name_is_refused(self):
        self.put("a.csv", size=1000)
        r = self.pull()
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("no pull_dest", r.stderr)


if __name__ == "__main__":
    unittest.main()
