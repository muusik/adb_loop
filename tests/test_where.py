"""where.sh: runs_in does what it says on each kind of machine, and the listing reads what the scripts declare."""
import os
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ABSENT = "/nonexistent/marker"


def machine(kind, launcher=True, container=False, local_adb=False):
    """A checkout with one script declaring kind, a stub launcher, run as a machine of the given sort."""
    top = tempfile.mkdtemp()
    os.mkdir(os.path.join(top, "loop"))
    shutil.copy(os.path.join(ROOT, "where.sh"), os.path.join(top, "loop"))
    script = os.path.join(top, "loop", "s.sh")
    with open(script, "w") as f:
        f.write('#!/bin/sh\n. "$(dirname "$0")/where.sh"\nruns_in %s "$@"\necho "here $*"\n' % kind)
    os.chmod(script, os.stat(script).st_mode | stat.S_IEXEC)
    stub = os.path.join(top, "bl")
    with open(stub, "w") as f:
        # --image-name answers as the launcher does; anything else says how it was called, and from where
        f.write('#!/bin/sh\n[ "$1" = --image-name ] && exit 0\necho "bl[$(basename "$PWD")] $*"\nexit 7\n')
    os.chmod(stub, 0o755)
    marker = os.path.join(top, "marker")
    open(marker, "w").close()
    env = dict(os.environ)
    env["BL_LAUNCHER"] = stub if launcher else os.path.join(top, "none")
    env["ADB_LOOP_CONTAINER_MARKERS"] = marker if container else ABSENT
    env.pop("ADB_LOOP_LOCAL_ADB", None)
    if local_adb:
        env["ADB_LOOP_LOCAL_ADB"] = "1"
    return top, script, env


class RunsIn(unittest.TestCase):
    def run_it(self, kind, *args, **sort):
        top, script, env = machine(kind, **sort)
        self.addCleanup(shutil.rmtree, top)
        r = subprocess.run(["sh", script, *args], env=env, capture_output=True, text=True, cwd="/")
        return r, os.path.basename(top)

    def test_in_the_container_all_run_here(self):
        for kind in ("container", "adb_client", "agent_session"):
            r, _ = self.run_it(kind, "a", container=True)
            self.assertEqual((r.returncode, r.stdout), (0, "here a\n"), kind)

    def test_where_the_launcher_is_they_go_through_it_from_the_root(self):
        for kind in ("container", "adb_client"):
            r, top = self.run_it(kind, "a", "b c")
            self.assertEqual(r.returncode, 7, kind)
            self.assertEqual(r.stdout, "bl[%s] --exec /home/node/repos/%s/loop/s.sh a b c\n" % (top, top), kind)

    def test_without_a_launcher(self):
        self.assertEqual(self.run_it("container", launcher=False)[0].returncode, 2)
        self.assertEqual(self.run_it("adb_client", "a", launcher=False)[0].stdout, "here a\n")
        self.assertEqual(self.run_it("laptop", "a", launcher=False)[0].stdout, "here a\n")

    def test_refusals(self):
        self.assertEqual(self.run_it("agent_session")[0].returncode, 2)
        self.assertEqual(self.run_it("laptop")[0].returncode, 2)
        self.assertEqual(self.run_it("laptop", container=True)[0].returncode, 2)
        self.assertEqual(self.run_it("nowhere", container=True)[0].returncode, 2)

    def test_local_adb_overrides_the_launcher(self):
        self.assertEqual(self.run_it("adb_client", "a", local_adb=True)[0].stdout, "here a\n")
        self.assertEqual(self.run_it("laptop", "a", local_adb=True)[0].stdout, "here a\n")

    def test_bl_args_and_bl_after(self):
        top, script, env = machine("container")
        self.addCleanup(shutil.rmtree, top)
        with open(script) as f:
            body = f.read()
        with open(script, "w") as f:
            f.write(body.replace("runs_in", 'bl_args="--publish 1:2"\nafter() { echo "after $1"; exit 5; }\n'
                                            'bl_after=after\nruns_in', 1))
        r = subprocess.run(["sh", script, "a"], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 5)
        self.assertEqual(r.stdout.split("\n")[1], "after 7")
        self.assertIn("--publish 1:2 --exec", r.stdout)


class Listing(unittest.TestCase):
    def listing(self, *scripts):
        """loop/where.sh as a project has it, beside (name, first lines, executable) scripts."""
        top = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, top)
        loop = os.path.join(top, "loop")
        os.mkdir(loop)
        for name, body in (("where.sh", '#!/bin/sh\n# the listing\n# runs_in anywhere\n. "%s"\n'
                            % os.path.join(ROOT, "where.sh")),) + scripts:
            path = os.path.join(loop, name)
            with open(path, "w") as f:
                f.write(body)
            os.chmod(path, 0o755)
        return subprocess.run(["sh", os.path.join(loop, "where.sh")], capture_output=True, text=True)

    def test_lists_each_script_under_its_place(self):
        r = self.listing(("a.sh", "#!/bin/sh\n# what a does\nruns_in adb_client\n"))
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        self.assertIn("  a.sh               what a does", lines)
        self.assertLess(lines.index("adb_client: talks to the phone over adb; through the container where the "
                                    "launcher is, else this machine's adb"),
                        lines.index("  a.sh               what a does"))

    def test_a_script_that_does_not_say_fails_the_listing(self):
        r = self.listing(("b.sh", "#!/bin/sh\n# what b does\n"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("does not say where it runs: b.sh", r.stderr)


if __name__ == "__main__":
    unittest.main()
