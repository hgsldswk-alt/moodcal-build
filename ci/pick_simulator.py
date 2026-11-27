import json
import sys

want_promax = '--promax' in sys.argv
devices = json.load(sys.stdin)['devices']
best = None
for runtime, items in devices.items():
    if 'iOS-' not in runtime:
        continue
    version = tuple(int(part) for part in runtime.rsplit('iOS-', 1)[-1].split('-') if part.isdigit())
    for device in items:
        if not (device.get('isAvailable') and device['name'].startswith('iPhone')):
            continue
        key = (version, 'Pro Max' in device['name'] if want_promax else True)
        if best is None or key > best[0]:
            best = (key, device['udid'], device['name'])
if best is None:
    sys.exit('No available iPhone simulator')
print(best[1])
print('Simulator:', best[2], file=sys.stderr)
