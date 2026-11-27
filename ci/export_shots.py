import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

NAMES = re.compile(r'(?:store-(?:zh-Hans|zh-Hant|en|ja)-(?:01-today|02-month|03-backfill|04-export|05-card)|paid-01-paywall)(?=$|[\s._-])')
EXPECTED = {'paid-01-paywall'} | {
    f'store-{lang}-{shot}' for lang in ('en', 'zh-Hans', 'zh-Hant')
    for shot in ('01-today', '02-month', '03-backfill', '04-export', '05-card')
}


def attachments(payload):
    if isinstance(payload, dict):
        if 'exportedFileName' in payload:
            yield payload
        for value in payload.values():
            yield from attachments(value)
    elif isinstance(payload, list):
        for value in payload:
            yield from attachments(value)


def collect(raw, output, review=None):
    manifest = json.loads((raw / 'manifest.json').read_text(encoding='utf-8'))
    found = {}
    for attachment in attachments(manifest):
        exported = raw / attachment['exportedFileName']
        name = NAMES.search(attachment.get('suggestedHumanReadableName', '') + ' ' + attachment.get('displayName', '')
                            + ' ' + exported.name)
        if not name or not exported.is_file() or exported.suffix.lower() != '.png':
            continue
        if name[0] in found:
            raise SystemExit(f'Duplicate screenshot: {name[0]}')
        found[name[0]] = exported
    missing = EXPECTED - found.keys()
    if missing:
        raise SystemExit('Missing screenshots: ' + ', '.join(sorted(missing)))
    output.mkdir(parents=True, exist_ok=True)
    for name, source in found.items():
        shutil.copy2(source, output / f'{name}.png')
        if name == 'paid-01-paywall' and review is not None:
            review.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, review)
    print(f'Exported {len(found)} screenshots to {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('result', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--review', type=Path)
    parser.add_argument('--from-manifest', action='store_true')
    args = parser.parse_args()
    if args.from_manifest:
        collect(args.result, args.output, args.review)
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=args.output.parent) as temporary:
            raw = Path(temporary)
            subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(args.result),
                            '--output-path', str(raw)], check=True)
            collect(raw, args.output, args.review)
