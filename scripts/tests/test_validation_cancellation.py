"""Actual Unix signals exercise the disposable validator's owned-child boundary."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


RUNNER = Path(__file__).resolve().parents[1] / 'validation_runner'


@unittest.skipUnless(hasattr(os, 'waitid') and hasattr(signal, 'pthread_sigmask'), 'Linux Actions runner process supervision')
class CancellationTests(unittest.TestCase):
    def _run(self, mode, cancellation=None, repeated=False, after_timeout=False):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            child = directory / 'child.py'
            child.write_text('''import os, signal, subprocess, sys, time
from pathlib import Path
root = Path(sys.argv[1])
mode = sys.argv[2]
def release(number, frame):
    (root / "released").write_text("owned child handled termination")
    raise SystemExit(0)
signal.signal(signal.SIGTERM, signal.SIG_IGN if mode in ("ignore", "timeout_ignore") else release)
if mode == "grandchild" or mode.startswith("exit_"):
    subprocess.Popen([sys.executable, "-c", "import os,signal,sys,time;from pathlib import Path;signal.signal(signal.SIGTERM,signal.SIG_IGN);p=Path(sys.argv[1]);t=p.with_suffix('.tmp');t.write_text(str(os.getpid()));os.replace(t,p);time.sleep(60)", str(root/"grandchild")])
    while not (root / "grandchild").exists(): time.sleep(0.01)
(root / "ready.tmp").write_text(str(os.getpid()))
os.replace(root / "ready.tmp", root / "ready")
if mode.startswith("exit_"): raise SystemExit(7 if mode=="exit_error" else 0)
while True: time.sleep(0.05)
''')
            parent = directory / 'parent.py'
            parent.write_text('''import json, os, signal, subprocess, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import validate
root=Path(sys.argv[2])
mode=sys.argv[3]
validate.CHILD_GRACE_SECONDS=0.4
validate.CHILD_REAP_SECONDS=1
report={"status":"running","phase":"ocr","current_chunk":"owned-fixture","chunks":[{"id":"already-completed"}]}
def checkpoint():
    if mode=="disk_error" and report.get("cancellation_signal") and not report.get("artifact_write_failed"):
        raise OSError("private filesystem failure")
    validate.persist_report(root,report)
control=validate.ChildSupervisor(report,checkpoint)
if mode=="exit_signal":
    original_exited=control._exited
    signalled=False
    def exit_boundary(child):
        global signalled
        exited=original_exited(child)
        if exited and not signalled:
            signalled=True
            os.kill(os.getpid(),signal.SIGTERM)
        return exited
    control._exited=exit_boundary
control.install()
try:
    checkpoint()
    control.run([sys.executable,str(root/"child.py"),str(root),mode],cwd=root,
                env={"PATH":os.environ.get("PATH","")},timeout=0.5 if mode.startswith("timeout") else 20)
    report.update(status="passed")
except validate.ValidationCancelled:
    report.update(status="cancelled",error_type="ValidationCancelled")
except subprocess.TimeoutExpired:
    report.update(status="failed",error_type="TimeoutExpired")
except subprocess.CalledProcessError as error:
    report.update(status="failed",error_type="CalledProcessError",exit_code=error.returncode)
finally:
    checkpoint()
    control.restore()
''')
            process = subprocess.Popen([sys.executable, str(parent), str(RUNNER), str(directory), mode],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            settled = False
            try:
                deadline = time.monotonic() + 5
                while not (directory / 'ready').exists() and time.monotonic() < deadline:
                    if process.poll() is not None:
                        self.fail('Supervision fixture exited before its child became ready')
                    time.sleep(0.01)
                self.assertTrue((directory / 'ready').exists())
                child_pid = int((directory / 'ready').read_text())
                if cancellation is not None:
                    if after_timeout:
                        deadline = time.monotonic() + 3
                        while time.monotonic() < deadline:
                            snapshot = json.loads((directory / 'validation.json').read_text())
                            if snapshot.get('child_cleanup', {}).get('reason') == 'timeout':
                                break
                            time.sleep(0.01)
                        else:
                            self.fail('Timeout cleanup was not observed before cancellation')
                    os.kill(process.pid, cancellation)
                    if repeated:
                        time.sleep(0.05)
                        os.kill(process.pid, signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0, stderr.decode())
                report = json.loads((directory / 'validation.json').read_text())
                self.assertEqual(report['phase'], 'ocr')
                self.assertEqual(report['current_chunk'], 'owned-fixture')
                self.assertEqual(report['chunks'], [{'id': 'already-completed'}])
                self.assertTrue(report['child_cleanup']['child_reaped'])
                self.assertEqual(report['child_cleanup']['lease_release'], 'unconfirmed')
                self.assertEqual((directory / 'validation.json').stat().st_mode & 0o777, 0o600)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child_pid, 0)
                if (directory / 'grandchild').exists():
                    state_path = Path('/proc') / (directory / 'grandchild').read_text() / 'stat'
                    deadline = time.monotonic() + 2
                    while state_path.exists() and time.monotonic() < deadline:
                        # A killed orphan may briefly await init's reaper.
                        try:
                            state = state_path.read_text().rsplit(')', 1)[1].split()[0]
                        except FileNotFoundError:
                            break
                        if state == 'Z':
                            break
                        time.sleep(0.01)
                    else:
                        self.assertFalse(state_path.exists(), 'Owned grandchild is still running')
                self.assertEqual(list(directory.glob('.validation-*')), [])
                settled = True
                return report, (directory / 'released').exists()
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    # A timed-out fixture must also settle its separately owned child.
                    if (directory / 'ready').exists():
                        try:
                            os.killpg(int((directory / 'ready').read_text()), signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    process.wait(timeout=5)
                if not settled and (directory / 'grandchild').exists() and (directory / 'ready').exists():
                    # Failed regression runs may leave a grandchild holding the
                    # recorded group after the fixture's leader has exited.
                    try:
                        group = int((directory / 'ready').read_text())
                        descendant = int((directory / 'grandchild').read_text())
                        if os.getpgid(descendant) == group and os.getsid(descendant) == group:
                            os.killpg(group, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_sigint_and_sigterm_allow_owned_child_to_release_and_save_cancelled_artifact(self):
        for cancellation in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=cancellation):
                report, released = self._run('graceful', cancellation)
                self.assertEqual(report['status'], 'cancelled')
                self.assertEqual(report['cancellation_signal'], signal.Signals(cancellation).name)
                self.assertTrue(released)
                self.assertFalse(report['child_cleanup']['grace_exhausted'])

    def test_repeated_cancellation_kills_and_reaps_ignoring_child_after_bounded_grace(self):
        report, released = self._run('ignore', signal.SIGINT, repeated=True)
        self.assertEqual(report['status'], 'cancelled')
        self.assertTrue(report['child_cleanup']['grace_exhausted'])
        self.assertEqual(report['child_cleanup']['exit_code'], -signal.SIGKILL)
        self.assertFalse(released)

    def test_timeout_remains_failure_while_child_gets_cleanup_opportunity(self):
        report, released = self._run('timeout')
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['error_type'], 'TimeoutExpired')
        self.assertEqual(report['child_cleanup']['reason'], 'timeout')
        self.assertTrue(released)

    def test_cancel_signal_during_timeout_cleanup_does_not_replace_the_timeout_failure(self):
        report, released = self._run('timeout_ignore', signal.SIGTERM, after_timeout=True)
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['error_type'], 'TimeoutExpired')
        self.assertEqual(report['child_cleanup']['reason'], 'timeout')
        self.assertFalse(released)

    def test_checkpoint_error_during_signal_does_not_interrupt_owned_child_cleanup(self):
        report, released = self._run('disk_error', signal.SIGTERM)
        self.assertEqual(report['status'], 'cancelled')
        self.assertTrue(report['artifact_write_failed'])
        self.assertTrue(released)
        self.assertNotIn('private filesystem', json.dumps(report))

    def test_exited_leader_cannot_leave_its_process_group_running(self):
        report, released = self._run('grandchild', signal.SIGTERM)
        self.assertTrue(released)
        self.assertTrue(report['child_cleanup']['group_kill_sent'])

    def test_successful_early_exit_settles_surviving_grandchild_before_reaping_leader(self):
        report, released = self._run('exit_zero')
        self.assertEqual(report['status'], 'passed')
        self.assertEqual(report['child_cleanup']['exit_code'], 0)
        self.assertTrue(report['child_cleanup']['group_kill_sent'])
        self.assertFalse(released)

    def test_failed_early_exit_settles_surviving_grandchild_and_preserves_exit_status(self):
        report, released = self._run('exit_error')
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['error_type'], 'CalledProcessError')
        self.assertEqual(report['exit_code'], 7)
        self.assertEqual(report['child_cleanup']['exit_code'], 7)
        self.assertTrue(report['child_cleanup']['group_kill_sent'])
        self.assertFalse(released)

    def test_signal_at_observed_leader_exit_still_settles_grandchild_before_reaping(self):
        report, released = self._run('exit_signal')
        self.assertEqual(report['status'], 'cancelled')
        self.assertEqual(report['cancellation_signal'], 'SIGTERM')
        self.assertEqual(report['child_cleanup']['exit_code'], 0)
        self.assertTrue(report['child_cleanup']['group_kill_sent'])
        self.assertFalse(released)


if __name__ == '__main__':
    unittest.main()
