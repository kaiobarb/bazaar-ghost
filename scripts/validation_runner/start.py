"""Register once using a stdin token, then erase it from the listener environment."""
import os
import re
import subprocess
import sys


def registration(label, token):
    if not re.fullmatch(r'bazaarghost-validation-[a-f0-9]{32}', label):
        raise ValueError('Expected a unique validation runner label')
    if not token or len(token) > 2048 or any(character.isspace() for character in token):
        raise ValueError('A single registration token is required on stdin')
    command = ['./config.sh', '--unattended', '--ephemeral', '--disableupdate', '--no-default-labels',
               '--url', 'https://github.com/liftaris/bazaar-ghost', '--name', label, '--labels', label, '--work', '_work']
    return command, {'ACTIONS_RUNNER_INPUT_TOKEN': token}


def main():
    if os.geteuid() == 0:
        raise SystemExit('Validation runner must not run as root')
    os.umask(0o077)
    token = sys.stdin.readline(2050).strip()
    command, private = registration(os.environ.get('RUNNER_LABEL', ''), token)
    token = None
    result = subprocess.run(command, env={**os.environ, **private}, capture_output=True, text=True, timeout=120)
    private.clear()
    if result.returncode:
        # Registration diagnostics are retained privately by the runner, never print a token-bearing response.
        raise SystemExit(f'Runner registration failed (exit {result.returncode})')
    print('Registered one-job validation runner; awaiting the dedicated workflow', flush=True)
    clean = {key: value for key, value in os.environ.items() if not key.startswith('ACTIONS_RUNNER_INPUT_')}
    os.execvpe('./run.sh', ['./run.sh'], clean)


if __name__ == '__main__':
    main()
