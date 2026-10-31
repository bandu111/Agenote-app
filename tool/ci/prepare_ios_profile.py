"""Install App Store profiles for Runner and its local Live Activity extension."""
import base64
import datetime
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import uuid


def validate_profile(profile, team, bundle, installed):
    entitlements = profile['Entitlements']
    if team not in profile['TeamIdentifier'] or entitlements['application-identifier'] != f'{team}.{bundle}':
        raise ValueError('Provisioning profile team or Bundle ID mismatch: ' + bundle)
    if profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices') or entitlements.get('get-task-allow'):
        raise ValueError('An App Store distribution profile is required: ' + bundle)
    if profile['ExpirationDate'].replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError('Provisioning profile expired: ' + bundle)
    matches = [hashlib.sha1(c).hexdigest().upper() for c in profile['DeveloperCertificates']
               if hashlib.sha1(c).hexdigest().upper() in installed]
    if len(matches) != 1:
        raise ValueError('Profile must match exactly one valid installed signing identity: ' + bundle)
    name = profile['Name']
    if '\n' in name or '\r' in name: raise ValueError('Invalid profile name')
    return str(uuid.UUID(profile['UUID'])).upper(), name, matches[0]


def main():
    temporary = Path(os.environ['RUNNER_TEMP'])
    team, bundle = os.environ['APPLE_TEAM_ID'], os.environ['APPLE_BUNDLE_ID']
    if not os.environ.get('RECORDING_MOBILEPROVISION_BASE64', '').strip():
        raise ValueError('Live Activity extension requires RECORDING_MOBILEPROVISION_BASE64 for ' + bundle + '.RecordingActivity')
    identities = subprocess.check_output(['security','find-identity','-v','-p','codesigning',os.environ['KEYCHAIN_PATH']], text=True)
    installed = set(re.findall(r'\b[0-9A-Fa-f]{40}\b', identities.upper()))
    profiles = {}; identity = None
    for prefix, secret, target, filename in [
        ('PROFILE', 'MOBILEPROVISION_BASE64', bundle, 'yanshu.mobileprovision'),
        ('RECORDING_PROFILE', 'RECORDING_MOBILEPROVISION_BASE64', bundle+'.RecordingActivity', 'agenote-recording.mobileprovision'),
    ]:
        path = temporary / filename
        path.write_bytes(base64.b64decode(''.join(os.environ[secret].split()), validate=True));path.chmod(0o600)
        data = plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(path)]))
        profile_uuid, name, cert = validate_profile(data, team, target, installed)
        if identity is not None and identity != cert: raise ValueError('App and extension must use the same signing identity')
        identity = cert; profiles[target] = name
        for directory in [Path.home()/'Library/MobileDevice/Provisioning Profiles',Path.home()/'Library/Developer/Xcode/UserData/Provisioning Profiles']:
            directory.mkdir(parents=True,exist_ok=True)
            copied=directory/f'{profile_uuid}.mobileprovision';shutil.copy2(path,copied);copied.chmod(0o600)
        with open(os.environ['GITHUB_ENV'],'a',encoding='utf-8') as env:
            env.write(f'{prefix}_UUID={profile_uuid}\n{prefix}_NAME={name}\n')
    with open(os.environ['GITHUB_ENV'],'a',encoding='utf-8') as env: env.write(f'SIGNING_CERT_SHA1={identity}\n')
    with (temporary/'ExportOptions.plist').open('wb') as file:
        plistlib.dump({'method':'app-store-connect','teamID':team,'signingStyle':'manual',
            'signingCertificate':identity,'provisioningProfiles':profiles,
            'manageAppVersionAndBuildNumber':False,'uploadSymbols':True},file)
    print('Validated App Store signing profiles for app and local recording activity extension')

if __name__ == '__main__': main()
