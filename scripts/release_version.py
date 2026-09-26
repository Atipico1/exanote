"""Reserve a monotonically increasing release version without moving existing tags."""
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess


def choose_version(minimum, reserved, requested=''):
    def parse(value):
        if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value):
            raise ValueError('Version must be MAJOR.MINOR.PATCH, for example 0.1.1')
        return tuple(map(int, value.split('.')))
    used = {parse(v.removeprefix('v')) for v in reserved if re.fullmatch(r'v?\d+\.\d+\.\d+', v)}
    floor = parse(minimum)
    if requested:
        version = parse(requested.removeprefix('v'))
        if version < floor or (used and version <= max(used)):
            raise ValueError('Requested version must exceed every existing release/tag and meet the source minimum')
    else:
        latest = max(used, default=(0, 0, 0))
        version = max(floor, (latest[0], latest[1], latest[2] + 1))
    return '.'.join(map(str, version))


if __name__ == '__main__':
    minimum = plistlib.loads(Path('native/App/Info.plist').read_bytes())['CFBundleShortVersionString']
    tags = subprocess.check_output(['git', 'tag', '--list'], text=True).splitlines()
    releases = subprocess.check_output(['gh', 'api', '--paginate', f'repos/{os.environ["GITHUB_REPOSITORY"]}/releases', '--jq', '.[].tag_name'], text=True).splitlines()
    version = choose_version(minimum, tags + releases, os.environ.get('REQUESTED_VERSION', ''))
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'version={version}\ntag=v{version}\n')
    with open(os.environ['GITHUB_ENV'], 'a') as output:
        output.write(f'RELEASE_VERSION={version}\nBUILD_NUMBER={100 + int(os.environ["GITHUB_RUN_NUMBER"])}\n')
    print(f'Release v{version}; build {100 + int(os.environ["GITHUB_RUN_NUMBER"])}')
