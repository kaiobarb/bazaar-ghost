#!/usr/bin/env python3
"""Set reviewed creator links and per-video profiles without refetching media."""

import argparse
import json
from uuid import UUID

from catalog_api import api


def positive_id(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError('Expected a positive internal ID')
    return number


def account_id(value):
    try:
        return str(UUID(value))
    except ValueError as error:
        raise argparse.ArgumentTypeError('Expected a platform account UUID') from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='kind', required=True)
    account = commands.add_parser('account', help='Set or clear a verified Twitch creator link')
    account.add_argument('id', type=account_id)
    link = account.add_mutually_exclusive_group(required=True)
    link.add_argument('--streamer-id', type=positive_id)
    link.add_argument('--clear-streamer', action='store_true')
    video = commands.add_parser('video', help='Set or clear one recording\'s profile override')
    video.add_argument('id', type=positive_id, help='Internal video ID returned by cataloging')
    video.add_argument('--account-id', type=account_id, required=True, help='Expected owning platform account')
    profile = video.add_mutually_exclusive_group(required=True)
    profile.add_argument('--profile-id', type=positive_id)
    profile.add_argument('--clear-profile', action='store_true')
    args = parser.parse_args()
    if args.kind == 'account':
        result = api(f'accounts/{args.id}', method='PATCH', body={'streamer_id': args.streamer_id})
    else:
        result = api(f'videos/{args.id}', method='PATCH', body={
            'account_id': args.account_id, 'sfde_profile_id': args.profile_id,
        })
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
