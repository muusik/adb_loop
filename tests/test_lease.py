"""lease.sh over bread_ladder's bl-lease, with the leases in a directory of the test's own."""
import os
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


@unittest.skipUnless(shutil.which("bl-lease"), "no bl-lease here (bread_ladder's)")
class Lease(unittest.TestCase):
    def setUp(self):
        self.top = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.top)
        self.env = dict(os.environ, BL_LEASE_DIR=os.path.join(self.top, "leases"))
        self.env.pop("BL_LEASES_HELD", None)

    def script(self, code):
        path = os.path.join(self.top, "s%d.sh" % len(os.listdir(self.top)))
        with open(path, "w") as f:
            f.write('. %s/lease.sh\n%s\n' % (ROOT, code))
        return ["sh", path]

    def run_sh(self, code, **env):
        return subprocess.run(self.script(code), env=dict(self.env, **env), capture_output=True, text=True,
                              timeout=60)

    def free(self, name):
        """Whether NAME can be taken at once."""
        return subprocess.run(["bl-lease", "run", name, "-w", "0", "--", "true"], env=self.env,
                              capture_output=True).returncode == 0

    def holder(self):
        """A script that holds x until told to go (the file go), started in the background."""
        go = os.path.join(self.top, "go")
        p = subprocess.Popen(self.script('lease_take x || exit 9; echo held; while [ ! -e %s ]; do sleep 0.1; done; '
                                         'lease_drop x; echo dropped' % go),
                             env=self.env, stdout=subprocess.PIPE, text=True)
        self.assertEqual(p.stdout.readline(), "held\n")
        return p, go

    def test_take_holds_and_drop_lets_go(self):
        p, go = self.holder()
        self.assertFalse(self.free("x"))
        listing = subprocess.run(["bl-lease", "list"], env=self.env, capture_output=True, text=True).stdout
        self.assertIn("lease for", listing)
        open(go, "w").close()
        self.assertEqual(p.stdout.readline(), "dropped\n")
        self.assertTrue(self.free("x"))
        p.wait(10)

    def test_busy_is_75_after_the_wait(self):
        p, go = self.holder()
        started = time.monotonic()
        r = self.run_sh("lease_take x 1; echo $?")
        self.assertEqual(r.stdout, "75\n", r.stderr)
        self.assertLess(time.monotonic() - started, 10)
        self.assertIn("held by", r.stderr)
        open(go, "w").close()
        p.wait(10)

    def test_the_scripts_end_lets_go(self):
        r = self.run_sh("lease_take x && echo held")
        self.assertEqual(r.stdout, "held\n", r.stderr)
        deadline = time.monotonic() + 5
        while not self.free("x") and time.monotonic() < deadline:
            time.sleep(0.2)
        self.assertTrue(self.free("x"))

    def test_held_by_the_parent_is_not_taken_again(self):
        child = self.script("lease_take x 0 && lease_held x && echo child ok; lease_drop x")
        r = self.run_sh('lease_take x || exit 9; sh %s; lease_held x && echo parent holds; [ "$BL_LEASES_HELD" = x ] '
                        '&& echo listed; lease_drop x; lease_held x || echo dropped; [ -z "$BL_LEASES_HELD" ] && '
                        'echo empty' % child[1])
        self.assertEqual(r.stdout, "child ok\nparent holds\nlisted\ndropped\nempty\n", r.stderr)

    def test_two_leases_at_once(self):
        r = self.run_sh('lease_take build-a && lease_take phone && echo "$BL_LEASES_HELD"; lease_drop build-a; '
                        'echo "$BL_LEASES_HELD"; lease_held phone && echo phone')
        self.assertEqual(r.stdout, "build-a phone\nphone\nphone\n", r.stderr)

    def test_nothing_without_bl_lease(self):
        r = self.run_sh("lease_take x && lease_drop x && echo fine", PATH="/usr/bin:/bin")
        if shutil.which("bl-lease", path="/usr/bin:/bin"):
            self.skipTest("bl-lease is in /usr/bin here")
        self.assertEqual(r.stdout, "fine\n", r.stderr)

    def test_the_device(self):
        r = self.run_sh("lease_device; ANDROID_SERIAL=emulator-5554 lease_device; ANDROID_SERIAL=lan:5555 lease_device",
                        ANDROID_SERIAL="")
        self.assertEqual(r.stdout, "phone\nemulator\nphone\n")


if __name__ == "__main__":
    unittest.main()
