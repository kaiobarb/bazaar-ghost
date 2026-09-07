"""Send catalog changes to the backend's atomic revision and ownership checks."""

from catalog_api import api, fence


def save_video(video, account, explicit_ranges=False, job=None):
    return api('videos', body={'video': video, 'account_id': account['id'],
                              'explicit_ranges': explicit_ranges, **fence(job)}, method='POST')
