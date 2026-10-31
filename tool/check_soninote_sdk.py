"""Offline integrity / configuration checks, not an iOS build or hardware test."""
from pathlib import Path
import hashlib
import json
import plistlib
import zipfile

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'third_party/soninote/sdk_manifest.json').read_text(encoding='utf-8'))
for item in manifest['files']:
    data = (root / item['path']).read_bytes()
    assert hashlib.sha256(data).hexdigest() == item['sha256'], item['path']
    assert len(data) == item['bytes']

with zipfile.ZipFile(root / manifest['files'][0]['path']) as archive:
    sdk_manifest = archive.read('AndroidManifest.xml').decode()
    assert 'android:minSdkVersion="21"' in sdk_manifest

project = (root / 'ios/Runner.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
for reference in ['SoniNoteBridge.m in Sources', 'libPNote.a in Frameworks']:
    assert project.count(reference) == 2, reference
assert project.count('OTHER_LDFLAGS = ("$(inherited)", "-ObjC"') == 3
assert project.count('LIBRARY_SEARCH_PATHS = ("$(inherited)", "$(SRCROOT)/Runner/SoniNote")') == 3
with (root / 'ios/Runner/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['NSBluetoothAlwaysUsageDescription']
assert 'bluetooth-central' in info['UIBackgroundModes']

android = (root / 'android/app/src/main/kotlin/com/example/yanshu/SoniNoteBridge.kt').read_text(encoding='utf-8')
ios = (root / 'ios/Runner/SoniNote/SoniNoteBridge.m').read_text(encoding='utf-8')
for text in [android, ios]:
    assert 'yanshu/soninote/events' in text
    assert 'startBtnBackRecord' in text and 'stopBtnBackRecord' in text
    assert 'pauseBtnBackRecord' in text and 'continueBtnBackRecord' in text
    for forbidden in ['sendOtaFile(', 'requestDeviceGotoOtaMode(',
                      'deleteReordFile(', 'sendOtaFile]', 'requestDeviceGotoOtaMode]']:
        assert forbidden not in text, forbidden

# Offline checks only: both native bridges must query and normalize SN events.
assert '"serial" -> PNote.getSn()' in android
assert '"7" -> "serial" to listOf("sn")' in android
assert 'isEqualToString:@"serial"]) [sdk getSn]' in ios
assert '@"7": @"serial"' in ios and '@"7": @[@"sn"]' in ios
assert 'scanRevision' in android and 'scanRevision' in ios

app_manifest = (root / 'android/app/src/main/AndroidManifest.xml').read_text(encoding='utf-8')
assert 'android.permission.BLUETOOTH_SCAN' in app_manifest
assert 'android.permission.WRITE_EXTERNAL_STORAGE" tools:node="remove"' in app_manifest
assert 'uses-permission-sdk-23 android:name="android.permission.ACCESS_FINE_LOCATION" tools:node="remove"' in app_manifest
print(json.dumps({'sdkHashes': 'passed', 'iosSourceAndLinkReferences': 'passed',
                  'plist': 'passed', 'nativeAllowlist': 'passed',
                  'hardwareTested': False, 'iosCompiled': False}, indent=2))
