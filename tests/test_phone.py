"""phone.sh over a stub adb: which address is tried and how, and what ends a script."""
import os
import shutil
import subprocess
import tempfile
import time
import unittest

from stub_adb import StubAdb

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
# Answers on the addresses in $UP, after $DOWN shells have failed. get-state says "device" whatever the shell does, as
# after an adbd restart. A shell eats its standard input, as the real one does.
BODY = r"""
serial=
[ "$1" = -s ] && { serial=$2; shift 2; }
case "$1" in
  connect) echo "failed to connect" ;;
  get-state) echo device ;;
  shell)
    [ -t 0 ] || cat > /dev/null
    failed=$(cat "$COUNT" 2>/dev/null || echo 0)
    if [ "$failed" -lt "${DOWN:-0}" ]; then echo $((failed + 1)) > "$COUNT"; exit 1; fi
    if [ -z "$serial" ]; then [ "$UP" = any ]; exit; fi
    case " $UP " in *" $serial "*) exit 0 ;; esac
    exit 1 ;;
esac
"""


class Phone(unittest.TestCase):
    def setUp(self):
        self.top = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.top)
        self.stub = StubAdb(self.top, BODY)
        self.last = os.path.join(self.top, "phone_addr")
        self.marker = os.path.join(self.top, "marker")
        open(self.marker, "w").close()

    def run_it(self, code, container=True, up="", down=0, address="", default="lan:5555", stdin=None):
        script = os.path.join(self.top, "s.sh")
        with open(script, "w") as f:
            f.write('adb_loop_path=%s\nadb_loop_address=%s\nadb_loop_default=%s\nadb_loop_last_address=%s\n'
                    '. "$adb_loop_path/phone.sh"\n%s\n' % (ROOT, address, default, self.last, code))
        env = self.stub.env()
        env.pop("ANDROID_SERIAL", None)
        env.update(ADB_LOOP_CONTAINER_MARKERS=self.marker if container else "/nonexistent/marker", UP=up,
                   DOWN=str(down), COUNT=os.path.join(self.top, "count"))
        return subprocess.run(["sh", script], env=env, capture_output=True, text=True, input=stdin, timeout=60)

    def reach(self, **kw):
        return self.run_it('phone_reach\necho "at $ANDROID_SERIAL"', **kw)

    def test_the_default_address_is_connected_to(self):
        r = self.reach(up="lan:5555")
        self.assertEqual((r.returncode, r.stdout), (0, "at lan:5555\n"), r.stderr)
        self.assertIn("connect lan:5555", self.stub.calls())

    def test_get_state_saying_device_is_not_an_answer(self):
        r = self.reach(up="")
        self.assertEqual(r.returncode, 1)
        self.assertIn("the phone does not answer at lan:5555", r.stderr)

    def test_an_address_with_no_port_is_a_serial_not_connected_to(self):
        r = self.reach(up="emulator-5554", address="emulator-5554")
        self.assertEqual(r.stdout, "at emulator-5554\n", r.stderr)
        self.assertFalse([c for c in self.stub.calls() if c.startswith("connect")])

    def test_an_address_asked_for_is_the_only_one_tried(self):
        with open(self.last, "w") as f:
            f.write("10.0.0.9\n")
        r = self.reach(up="lan:5555", address="other:5555")
        self.assertEqual(r.returncode, 1)
        self.assertIn("at other:5555\n", r.stderr)

    def test_the_last_address_is_tried_second_with_its_port(self):
        with open(self.last, "w") as f:
            f.write("10.0.0.9\r\n")
        r = self.reach(up="10.0.0.9:5555")
        self.assertEqual(r.stdout, "at 10.0.0.9:5555\n", r.stderr)
        r = self.reach(up="lan:5555")
        self.assertEqual(r.stdout, "at lan:5555\n", r.stderr)

    def test_a_last_address_over_12_hours_old_is_not_tried(self):
        with open(self.last, "w") as f:
            f.write("10.0.0.9\n")
        old = time.time() - 12 * 3600 - 60
        os.utime(self.last, (old, old))
        r = self.reach(up="10.0.0.9:5555")
        self.assertEqual(r.returncode, 1)
        self.assertIn("at lan:5555\n", r.stderr)

    def test_on_connect_runs_once_the_phone_answers_and_not_before(self):
        code = 'said() { echo connected; }\nadb_loop_on_connect=said\nphone_connect || echo none'
        self.assertEqual(self.run_it(code, up="lan:5555").stdout, "connected\n")
        self.assertEqual(self.run_it(code, up="").stdout, "none\n")

    def test_outside_the_container_it_is_this_machines_adb(self):
        r = self.reach(container=False, up="any")
        self.assertEqual((r.returncode, r.stdout), (0, "at \n"), r.stderr)
        self.assertEqual(self.stub.calls(), ["shell true"])

    def test_outside_the_container_no_phone_ends_the_script(self):
        r = self.reach(container=False, up="")
        self.assertEqual((r.returncode, r.stdout), (1, ""))
        self.assertIn("no phone on this machine's adb", r.stderr)

    def test_outside_the_container_an_address_asked_for_is_used(self):
        r = self.reach(container=False, up="phone.lan:5555", address="phone.lan:5555")
        self.assertEqual(r.stdout, "at phone.lan:5555\n", r.stderr)

    def test_waits_for_a_link_to_come_back(self):
        r = self.run_it('phone_wait 3 && echo "at $ANDROID_SERIAL"', up="lan:5555", down=2)
        self.assertEqual(r.stdout, "at lan:5555\n", r.stderr)

    def test_gives_up_after_its_tries(self):
        r = self.run_it("phone_wait 2 || echo gave up", up="lan:5555", down=5)
        self.assertEqual(r.stdout, "gave up\n")
        self.assertEqual(len([c for c in self.stub.calls() if "shell true" in c]), 2)

    def test_inside_a_while_read_loop_it_leaves_the_list_alone(self):
        code = "while read -r line; do phone_wait; echo \"$line\"; done"
        for container, up in ((True, "lan:5555"), (False, "any")):
            r = self.run_it(code, container=container, up=up, stdin="a\nb\nc\n")
            self.assertEqual(r.stdout, "a\nb\nc\n", r.stderr)

    def test_timeout_keeps_the_foreground_so_ctrl_c_reaches_adb(self):
        r = self.run_it("command() { echo \"$*\"; }\ntimeout 5 adb devices")
        self.assertEqual(r.stdout, "timeout --foreground 5 adb devices\n")


if __name__ == "__main__":
    unittest.main()
