"""The harness the library's tests stand on: a script finds the stub, which records the call and answers as told."""
import subprocess
import tempfile
import unittest

from stub_adb import StubAdb


class StubAdbTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = tmp.name

    def adb(self, stub, *args):
        return subprocess.run(["sh", "-c", 'adb "$@"', "sh", *args], env=stub.env(), capture_output=True, text=True)

    def test_no_calls_yet(self):
        self.assertEqual(StubAdb(self.dir).calls(), [])

    def test_records_each_call_in_order(self):
        stub = StubAdb(self.dir)
        self.adb(stub, "-s", "emulator-5554", "shell", "true")
        self.adb(stub, "devices")
        self.assertEqual(stub.calls(), ["-s emulator-5554 shell true", "devices"])

    def test_answers_as_the_body_says(self):
        stub = StubAdb(self.dir, 'echo "got $1"\nexit 3')
        r = self.adb(stub, "connect")
        self.assertEqual((r.returncode, r.stdout), (3, "got connect\n"))


if __name__ == "__main__":
    unittest.main()
