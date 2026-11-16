"""org_width.sh: what counts against the fill column, in the staged lines and in --all."""
import os
import subprocess
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPT = os.path.join(ROOT, "org_width.sh")
L = "x" * 95
OLD = "%s old prose too long %s" % (L, L)
GIT_ENV = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}


class OrgWidth(unittest.TestCase):
    def setUp(self):
        self.top = tempfile.mkdtemp()
        self.env = dict(os.environ, **GIT_ENV)
        self.git("init", "-q")
        self.write("a.org", ["* Old", OLD])
        self.git("add", "a.org")
        self.git("commit", "-qm", "a")

    def git(self, *args):
        subprocess.run(["git"] + list(args), cwd=self.top, env=self.env, check=True)

    def write(self, name, lines):
        with open(os.path.join(self.top, name), "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

    def run_it(self, *args):
        p = subprocess.run([SCRIPT] + list(args), cwd=self.top, env=self.env, capture_output=True, text=True)
        return p.returncode, p.stdout

    def test_only_added_lines(self):
        self.write("a.org", ["* Old", OLD, "short", "new %s prose" % L])
        self.git("add", "a.org")
        code, out = self.run_it()
        self.assertEqual(code, 1)
        self.assertEqual(out, "a.org:4: 105 characters, over 100\n")
        code, out = self.run_it("--all")
        self.assertEqual(out.splitlines(), ["a.org:2: 210 characters, over 100", "a.org:4: 105 characters, over 100"])

    def test_what_cannot_wrap(self):
        self.write("a.org", ["* Old", OLD, "| %s table %s |" % (L, L), "#+begin_src sh", L + " " + L,
                             "#+END_SRC", "#+CAPTION: %s %s" % (L, L), "see [[https://example.com/%s][a link]] ok" % L,
                             "and https://example.com/%s too" % L])
        self.git("add", "a.org")
        self.assertEqual(self.run_it(), (0, ""))

    def test_counts_characters(self):
        self.write("a.org", ["* Old", OLD, "ä" * 100, "ä" * 101])
        self.git("add", "a.org")
        self.assertEqual(self.run_it(), (1, "a.org:4: 101 characters, over 100\n"))

    def test_headings_count(self):
        self.write("a.org", ["* Old " + L, OLD])
        self.git("add", "a.org")
        self.assertEqual(self.run_it()[0], 1)

    def test_fill_column(self):
        self.write(".dir-locals.el", ["((org-mode . ((fill-column . 120))))"])
        self.write("a.org", ["* Old", OLD, "new %s prose" % L])
        self.git("add", "a.org")
        self.assertEqual(self.run_it(), (0, ""))

    def test_nothing_staged(self):
        self.assertEqual(self.run_it(), (0, ""))
        self.write("b.txt", [OLD])
        self.git("add", "b.txt")
        self.assertEqual(self.run_it(), (0, ""))


if __name__ == "__main__":
    unittest.main()
