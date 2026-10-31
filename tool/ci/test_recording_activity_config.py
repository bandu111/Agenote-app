"""Windows-compatible signing/config checks; these do not compile Swift."""
import copy
import datetime
import hashlib
from pathlib import Path
import plistlib
import unittest
import xml.etree.ElementTree as ET

from prepare_ios_profile import validate_profile

ROOT = Path(__file__).resolve().parents[2]


class ProfileValidationTests(unittest.TestCase):
    def setUp(self):
        self.cert = b'test certificate, not signing material'
        self.digest = hashlib.sha1(self.cert).hexdigest().upper()
        self.profile = {
            'Entitlements': {'application-identifier': 'TEAM.com.example.app.RecordingActivity'},
            'TeamIdentifier': ['TEAM'], 'Name': 'Recording App Store',
            'UUID': '21fea3a3-c2d1-41c8-a6ec-956691f01521',
            'ExpirationDate': datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1),
            'DeveloperCertificates': [self.cert],
        }

    def validate(self, profile):
        return validate_profile(profile, 'TEAM', 'com.example.app.RecordingActivity', {self.digest})

    def test_matching_app_store_extension(self):
        self.assertEqual(self.validate(self.profile)[2], self.digest)

    def test_app_profile_cannot_sign_extension(self):
        self.profile['Entitlements']['application-identifier'] = 'TEAM.com.example.app'
        with self.assertRaises(ValueError): self.validate(self.profile)

    def test_expired_or_device_profile_rejected(self):
        for update in [
            {'ExpirationDate': datetime.datetime(2000, 1, 1)},
            {'ProvisionedDevices': ['test-device']},
            {'ProvisionsAllDevices': True},
            {'DeveloperCertificates': [b'wrong certificate']},
        ]:
            with self.subTest(update=update):
                profile = copy.deepcopy(self.profile); profile.update(update)
                with self.assertRaises(ValueError): self.validate(profile)

    def test_development_entitlement_rejected(self):
        self.profile['Entitlements']['get-task-allow'] = True
        with self.assertRaises(ValueError): self.validate(self.profile)


class NativeConfigurationTests(unittest.TestCase):
    def test_soninote_logical_flags_are_boxed_as_booleans(self):
        source = (ROOT / 'ios/Runner/SoniNote/SoniNoteBridge.m').read_text(encoding='utf-8')
        self.assertIn('@"saved": @((BOOL)(!query && [state isEqualToString:@"idle"]))', source)
        self.assertIn('@"enabled": @( (BOOL)(self.central != nil && self.central.state == CBManagerStatePoweredOn) )', source)

    def test_local_activity_and_custom_route_registered(self):
        with (ROOT / 'ios/Runner/Info.plist').open('rb') as f: app = plistlib.load(f)
        self.assertTrue(app['NSSupportsLiveActivities'])
        self.assertFalse(app['FlutterDeepLinkingEnabled'])
        self.assertIn('agenote', [s for item in app['CFBundleURLTypes'] for s in item['CFBundleURLSchemes']])
        with (ROOT / 'ios/RecordingActivity/Info.plist').open('rb') as f: widget = plistlib.load(f)
        self.assertEqual(widget['NSExtension']['NSExtensionPointIdentifier'], 'com.apple.widgetkit-extension')

    def test_extension_scheme_points_at_real_target(self):
        scheme = ET.parse(ROOT / 'ios/Runner.xcodeproj/xcshareddata/xcschemes/AgenoteRecordingActivity.xcscheme')
        ref = scheme.find('.//BuildableReference')
        project = (ROOT / 'ios/Runner.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        self.assertIn(ref.attrib['BlueprintIdentifier'] + ' /* AgenoteRecordingActivity */ = {isa = PBXNativeTarget;', project)
        self.assertIn('Embed App Extensions', project)


if __name__ == '__main__': unittest.main()
