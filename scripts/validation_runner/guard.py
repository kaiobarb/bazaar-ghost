"""An image-owned pre-job boundary, before checkout or repository code executes."""
import os

REPOSITORY = 'liftaris/bazaar-ghost'
REF = 'refs/heads/codex/cloudflare-validation'
WORKFLOW = f'{REPOSITORY}/.github/workflows/validate-recording.yml@{REF}'


def validate_job(values):
    expected = {'GITHUB_REPOSITORY': REPOSITORY, 'GITHUB_REF': REF,
                'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_WORKFLOW_REF': WORKFLOW}
    if any(values.get(key) != value for key, value in expected.items()):
        raise ValueError('Runner accepts only the dedicated validation workflow and branch')


if __name__ == '__main__':
    try:
        validate_job(os.environ)
    except ValueError as error:
        raise SystemExit(str(error)) from None
    print('Validation runner job boundary verified')
