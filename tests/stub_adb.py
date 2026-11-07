"""A stand-in for adb on the PATH: each call appends its arguments to a log, then runs the test's shell body."""
import os
import shlex


class StubAdb:
    """The body sees the call's arguments as "$@", and its exit status is adb's (0 when it does not say)."""

    def __init__(self, directory, body=""):
        self.directory = directory
        self.calls_file = os.path.join(directory, "adb.calls")
        path = os.path.join(directory, "adb")
        with open(path, "w") as f:
            f.write('#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\n%s\n' % (shlex.quote(self.calls_file), body))
        os.chmod(path, 0o755)

    def env(self, base=None):
        """The environment for a script under test: this adb first on the PATH."""
        env = dict(os.environ if base is None else base)
        env["PATH"] = self.directory + os.pathsep + env.get("PATH", "")
        return env

    def calls(self):
        """Each call's arguments, as one line, oldest first."""
        if not os.path.exists(self.calls_file):
            return []
        with open(self.calls_file) as f:
            return f.read().splitlines()
