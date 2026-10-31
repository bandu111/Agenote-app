"""Read-only Apple processing check; no tester invitations or metadata edits."""
import base64
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import urllib.error
import http.client
import urllib.parse
import urllib.request
import uuid
import zipfile


def base64url(value):
    return base64.urlsafe_b64encode(value).rstrip(b'=').decode()


def raw_signature(der):
    # OpenSSL encodes the two P-256 integers as a short DER sequence.
    if len(der) > 72 or der[0] != 0x30 or der[1] != len(der) - 2:
        raise ValueError('Invalid P-256 DER signature')
    offset, values = 2, []
    for _ in range(2):
        if der[offset] != 2:
            raise ValueError('Invalid ECDSA integer')
        length = der[offset + 1]
        integer = int.from_bytes(der[offset + 2:offset + 2 + length], 'big')
        if length not in range(1, 34) or not 0 < integer < 2**256:
            raise ValueError('Invalid P-256 signature component')
        values.append(integer.to_bytes(32, 'big'))
        offset += length + 2
    if offset != len(der):
        raise ValueError('Trailing signature data')
    return b''.join(values)


def read_json_with_retry(request, attempts=4):
    """Retry temporary Apple/network failures; never hide auth or build errors."""
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code not in {408, 429, 500, 502, 503, 504}:
                raise
            failure = f'HTTP {error.code}'
        except (TimeoutError, urllib.error.URLError, http.client.HTTPException) as error:
            failure = type(error).__name__
        if attempt + 1 == attempts:
            raise RuntimeError(f'Apple status query unavailable after {attempts} attempts ({failure}); '
                               'IPA upload may have succeeded. Check App Store Connect before re-uploading.')
        delay = min(5 * 2**attempt, 20)
        print(f'Apple status query temporarily unavailable ({failure}); retrying in {delay}s', flush=True)
        time.sleep(delay)


def main():
    ipa = Path(os.environ.get('IPA_PATH', 'build/ci-artifacts/YanShu-AppStore.ipa'))
    with zipfile.ZipFile(ipa) as archive:
        names = [n for n in archive.namelist() if n.startswith('Payload/')
                 and n.count('/') == 2 and n.endswith('.app/Info.plist')]
        if len(names) != 1:
            raise ValueError('Expected one iOS app in IPA')
        info = plistlib.loads(archive.read(names[0]))
    bundle = os.environ['APPLE_BUNDLE_ID']
    if info['CFBundleIdentifier'] != bundle:
        raise ValueError('IPA Bundle ID mismatch')
    if int(info.get('DTSDKName', 'iphoneos0').removeprefix('iphoneos').split('.')[0]) < 26:
        raise ValueError('Rebuild with iOS 26 SDK or later before uploading')
    version, build = info['CFBundleShortVersionString'], str(info['CFBundleVersion'])
    issuer = str(uuid.UUID(os.environ['ASC_ISSUER_ID'].strip()))
    key_id = os.environ['ASC_KEY_ID'].strip()
    if not key_id.isalnum() or len(key_id) != 10:
        raise ValueError('Invalid App Store Connect key ID')
    with tempfile.TemporaryDirectory(prefix='yanshu-asc-', dir=os.environ.get('RUNNER_TEMP')) as directory:
        key = Path(directory) / 'api.p8'
        key.write_text(os.environ['ASC_PRIVATE_KEY'], encoding='utf-8')
        key.chmod(0o600)

        def get(path):
            now = int(time.time())
            header = base64url(json.dumps({'alg': 'ES256', 'kid': key_id, 'typ': 'JWT'}).encode())
            payload = base64url(json.dumps({'iss': issuer, 'iat': now, 'exp': now + 300,
                                            'aud': 'appstoreconnect-v1'}).encode())
            message = (header + '.' + payload).encode()
            signature = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(key)],
                                       input=message, capture_output=True, check=True).stdout
            token = message.decode() + '.' + base64url(raw_signature(signature))
            request = urllib.request.Request('https://api.appstoreconnect.apple.com' + path,
                                             headers={'Authorization': 'Bearer ' + token})
            return read_json_with_retry(request)

        apps = get('/v1/apps?' + urllib.parse.urlencode({'filter[bundleId]': bundle}))['data']
        if len(apps) != 1:
            raise ValueError('API key must have access to the matching App Store Connect app')
        app_id = apps[0]['id']
        if os.environ.get('ASC_PREFLIGHT_ONLY') == '1':
            print(f'Apple API and IPA identity validated: {bundle} {version} ({build})')
            return
        deadline = time.monotonic() + 900
        while time.monotonic() < deadline:
            uploads = get(f'/v1/apps/{app_id}/buildUploads?' + urllib.parse.urlencode({
                'filter[cfBundleVersion]': build, 'filter[cfBundleShortVersionString]': version,
                'include': 'build', 'limit': 5}))
            for upload in uploads['data']:
                state = upload['attributes']['state']
                if state['state'] == 'FAILED':
                    raise RuntimeError('Apple rejected the build: ' + json.dumps(state.get('errors', []), ensure_ascii=False))
            builds = get('/v1/builds?' + urllib.parse.urlencode({
                'filter[app]': app_id, 'filter[version]': build, 'include': 'buildBetaDetail', 'limit': 10}))
            for item in builds['data']:
                state = item['attributes']['processingState']
                if state in {'FAILED', 'INVALID'}:
                    raise RuntimeError(f'Apple build processing returned {state}')
                if state == 'VALID':
                    beta = [x['attributes'] for x in builds.get('included', []) if x['type'] == 'buildBetaDetails']
                    print(f'Apple processing VALID: {bundle} {version} ({build})')
                    print('TestFlight state: ' + json.dumps(beta, ensure_ascii=False))
                    if os.environ.get('GITHUB_STEP_SUMMARY'):
                        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as summary:
                            summary.write(f'Apple processing **VALID**: {version} ({build}).\n\n'
                                          f'[Open TestFlight](https://appstoreconnect.apple.com/apps/{app_id}/testflight/ios)\n\n'
                                          'Complete export compliance and select a tester group in App Store Connect if required.\n')
                    return
            print(f'Waiting for Apple processing: {version} ({build})', flush=True)
            time.sleep(20)
        raise TimeoutError('Apple processing has not completed after 15 minutes; check App Store Connect before re-uploading')


if __name__ == '__main__':
    main()
