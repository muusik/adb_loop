"""install.sh over a stub adb that keeps the phone's state in files: whether the app runs, its update time, what an
install does to it."""
import os
import shutil
import subprocess
import tempfile
import unittest

from stub_adb import StubAdb

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PACKAGE = "com.example.app"
# $STATE holds the files: running (the app's pid), updated (lastUpdateTime), label (the label file on the phone),
# logcat (cleared or not). An install moves the update time on, unless $STALE (says success, leaves the old build) or
# $INCOMPATIBLE. With $DROP, that many update-time readings after the install answer nothing. A shell eats its standard
# input, as the real one does.
BODY = r"""
[ "$1" = -s ] && shift 2
case "$1" in
  install)
    [ -z "$INCOMPATIBLE" ] || { echo "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]"; exit 1; }
    [ -z "$FAIL" ] || { echo "Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]"; exit 1; }
    rm -f "$STATE/running"
    echo "${BL_LEASES_HELD:-}" > "$STATE/leases"
    [ -n "$STALE" ] || echo "2026-11-07 12:00:01" > "$STATE/updated"
    echo "${DROP:-0}" > "$STATE/drop"
    echo Success ;;
  logcat) [ "$2" = -c ] && echo cleared > "$STATE/logcat" ;;
  get-serialno) echo USB123 ;;
  shell)
    shift
    [ -t 0 ] || cat > /dev/null
    case "$*" in
      "pidof $PACKAGE") cat "$STATE/running" 2>/dev/null || exit 1 ;;
      "dumpsys package $PACKAGE")
        drop=$(cat "$STATE/drop" 2>/dev/null || echo 0)
        if [ "$drop" -gt 0 ]; then echo $((drop - 1)) > "$STATE/drop"; exit 1; fi
        [ -f "$STATE/updated" ] && echo "    lastUpdateTime=$(cat "$STATE/updated")" ;;
      *resolve-activity*) echo "priority=0"; echo "$PACKAGE/.Main_abc" ;;
      "am start"*) echo "$*" >> "$STATE/started" ;;
      echo*|cat*) sh -c "$(printf '%s' "$*" | sed "s#/data/local/tmp/#$STATE/#")" ;;
    esac ;;
esac
"""


class Phone(unittest.TestCase):
    """The stub phone and a run of install.sh over it."""

    def setUp(self):
        self.top = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.top)
        self.stub = StubAdb(self.top, BODY)
        self.state = os.path.join(self.top, "state")
        os.mkdir(self.state)
        self.write("updated", "2026-11-01 08:00:00\n")
        self.log = os.path.join(self.top, "logs", "installed.tsv")

    def write(self, name, text):
        with open(os.path.join(self.state, name), "w") as f:
            f.write(text)

    def read(self, name):
        path = os.path.join(self.state, name)
        if not os.path.exists(path):
            return None
        with open(path) as f:
            return f.read()

    def run_it(self, code, label_file="/data/local/tmp/app_installed", serial="lan:5555", repo="", **env_extra):
        script = os.path.join(self.top, "s.sh")
        with open(script, "w") as f:
            f.write('adb_loop_path=%s\nadb_loop_package=%s\nadb_loop_label_file=%s\nadb_loop_install_log=%s\n'
                    'adb_loop_repo=%s\n. "$adb_loop_path/install.sh"\n'
                    'install_before_clear() { echo "kept $(cat $STATE/logcat 2>/dev/null || echo full)"; }\n'
                    'sleep() { :; }\n%s\n' % (ROOT, PACKAGE, label_file, self.log, repo, code))
        env = self.stub.env()
        env.pop("ANDROID_SERIAL", None)
        if serial:
            env["ANDROID_SERIAL"] = serial
        # the leases in a directory of the test's own, never the machine's
        env.update(STATE=self.state, PACKAGE=PACKAGE, BL_LEASE_DIR=os.path.join(self.top, "leases"), **env_extra)
        return subprocess.run(["sh", script], env=env, capture_output=True, text=True, timeout=60)


class Install(Phone):
    def test_installed_recorded_and_the_logcat_kept_then_cleared(self):
        r = self.run_it("install_apk app.apk v1.2-3-abc")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("install -r --fastdeploy app.apk", self.stub.calls())
        self.assertIn("kept full", r.stdout)
        self.assertEqual(self.read("logcat"), "cleared\n")
        self.assertEqual(self.read("app_installed"), "v1.2-3-abc\n")
        with open(self.log) as f:
            fields = f.read().rstrip("\n").split("\t")
        self.assertEqual(fields[1:], ["v1.2-3-abc", "lan:5555", "app.apk"])
        self.assertIn("installed v1.2-3-abc on lan:5555", r.stdout)

    @unittest.skipUnless(shutil.which("bl-lease"), "no bl-lease here (bread_ladder's)")
    def test_the_install_holds_the_devices_lease(self):
        r = self.run_it("install_apk app.apk v1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.read("leases"), "phone\n")
        self.write("updated", "2026-11-01 08:00:00\n")
        r = self.run_it("install_apk app.apk v2", serial="emulator-5554")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.read("leases"), "emulator\n")
        # let go of after the install
        env = dict(os.environ, BL_LEASE_DIR=os.path.join(self.top, "leases"))
        free = subprocess.run(["bl-lease", "run", "phone", "-w", "0", "--", "true"], env=env, capture_output=True)
        self.assertEqual(free.returncode, 0, free.stderr)

    @unittest.skipUnless(shutil.which("bl-lease"), "no bl-lease here (bread_ladder's)")
    def test_a_lease_the_script_holds_is_not_taken_again(self):
        r = self.run_it('. "$adb_loop_path/lease.sh"; lease_take phone 5 && install_apk app.apk v1 && lease_held phone')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.read("leases"), "phone\n")

    def test_a_running_app_is_started_again_with_its_extras(self):
        self.write("running", "4242\n")
        r = self.run_it("install_apk app.apk v1 --es session sim")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.read("started"), "am start -n %s/.Main_abc --es session sim\n" % PACKAGE)

    def test_a_closed_app_stays_closed(self):
        r = self.run_it("install_apk app.apk v1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNone(self.read("started"))

    def test_success_with_the_old_build_left_is_a_failure(self):
        r = self.run_it("install_apk app.apk v1", STALE="1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("not updated", r.stderr)
        self.assertIsNone(self.read("logcat"))
        self.assertFalse(os.path.exists(self.log))

    def test_a_phone_that_drops_after_the_install_is_read_again(self):
        r = self.run_it("install_apk app.apk v1", DROP="3")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_a_phone_that_stays_gone_is_a_failure(self):
        r = self.run_it("install_apk app.apk v1", DROP="20")
        self.assertEqual(r.returncode, 1)
        self.assertIn("unreadable", r.stderr)

    def test_another_key_is_its_own_status(self):
        r = self.run_it("install_apk app.apk v1", INCOMPATIBLE="1")
        self.assertEqual(r.returncode, 3)
        self.assertIn("signed by another key", r.stderr)
        self.assertIn("INSTALL_FAILED_UPDATE_INCOMPATIBLE", r.stdout)

    def test_a_failed_install_is_a_failure_with_adbs_reason_shown(self):
        r = self.run_it("install_apk app.apk v1", FAIL="1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("INSUFFICIENT_STORAGE", r.stdout)

    def test_no_label_file_and_no_serial(self):
        r = self.run_it("install_apk app.apk", label_file="", serial="")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNone(self.read("app_installed"))
        with open(self.log) as f:
            self.assertEqual(f.read().split("\t")[1:3], ["unknown", "USB123"])

    def test_the_package_was_not_installed_before(self):
        os.remove(os.path.join(self.state, "updated"))
        r = self.run_it("install_apk app.apk v1")
        self.assertEqual(r.returncode, 0, r.stderr)


class Order(Phone):
    """The order check: a build without work the phone's build has, and some branch still holds, is not installed."""

    def setUp(self):
        super().setUp()
        self.repo = os.path.join(self.top, "repo")
        self.git("init", "-q", "-b", "main", self.repo)
        self.base = self.commit("base")
        self.git("tag", "-a", "v1.0", "-m", "v1.0")
        self.landed = self.commit("landed")

    def git(self, *args):
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                   GIT_COMMITTER_EMAIL="t@t")
        cwd = self.repo if os.path.isdir(getattr(self, "repo", "")) else None
        return subprocess.run(["git"] + list(args), cwd=cwd, env=env, check=True, capture_output=True,
                              text=True).stdout.strip()

    def commit(self, msg):
        self.git("commit", "-q", "--allow-empty", "-m", msg)
        return self.git("rev-parse", "--short=7", "HEAD")

    def install(self, label, **env_extra):
        return self.run_it("install_apk app.apk %s" % label, repo=self.repo, **env_extra)

    def test_a_build_without_landed_work_is_refused(self):
        self.write("app_installed", "v1.0-1-%s\n" % self.landed)
        self.git("checkout", "-q", "-b", "side", "v1.0")
        side = self.commit("side")
        r = self.install("v1.0-1-%s" % side)
        self.assertEqual(r.returncode, 4)
        self.assertIn("lacks %s \"landed\", which main holds" % self.landed, r.stderr)
        self.assertNotIn("install -r", self.stub.calls())
        self.assertEqual(self.read("app_installed"), "v1.0-1-%s\n" % self.landed)

    def test_on_purpose_it_installs(self):
        self.write("app_installed", "v1.0-1-%s\n" % self.landed)
        r = self.install("v1.0", adb_loop_install_older="yes")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_a_build_that_holds_the_phones_installs(self):
        self.write("app_installed", "v1.0-dirty\n")
        newer = self.commit("newer")
        r = self.install("v1.0-2-g%s-dirty" % newer)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_the_jobs_own_build_before_its_rebase_is_left_behind(self):
        self.git("checkout", "-q", "-b", "job", "v1.0")
        before = self.commit("job's work")
        self.git("checkout", "-q", "main")
        self.git("branch", "-q", "-D", "job")
        after = self.commit("job's work, rebased")
        self.write("app_installed", "v1.0-1-%s\n" % before)
        r = self.install("v1.0-2-%s" % after)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_another_jobs_unlanded_work_is_kept(self):
        self.git("checkout", "-q", "-b", "other", "main")
        other = self.commit("other's work")
        self.git("checkout", "-q", "main")
        self.write("app_installed", "v1.0-2-%s\n" % other)
        mine = self.commit("mine")
        r = self.install("v1.0-2-%s" % mine)
        self.assertEqual(r.returncode, 4)
        self.assertIn("which other holds", r.stderr)

    def test_a_label_that_names_no_commit_here_is_said_and_installed(self):
        self.write("app_installed", "v9.9-1-abcdef0\n")
        r = self.install("v1.0-1-%s" % self.landed)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("no commit here", r.stderr)

    def test_the_same_label_installs_again(self):
        self.write("app_installed", "unknown\n")
        r = self.install("unknown")
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == "__main__":
    unittest.main()
