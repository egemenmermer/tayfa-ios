#!/usr/bin/env python3
"""Local archive checks only; does not contact Apple or certify physical media."""
import argparse
import datetime
import fnmatch
import json
import plistlib
import re
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('archive', type=Path)
parser.add_argument('--report', type=Path)
parser.add_argument('--origin', help='Expected ROOMS_API_ORIGIN, e.g. https://rooms.example.com; any HTTPS origin is accepted when omitted.')
args = parser.parse_args()
archive = args.archive.resolve()
# Bundle ID and team come from project.yml, so a fork with its own IDs verifies against its own values.
spec = (Path(__file__).resolve().parent.parent / 'project.yml').read_text()
bundle_id = re.search(r'^    PRODUCT_BUNDLE_IDENTIFIER: (\S+)$', spec, re.M).group(1)
team = re.search(r'^    DEVELOPMENT_TEAM: (\S+)$', spec, re.M).group(1)

def require(condition, message):
    if not condition:
        raise SystemExit('Archive verification failed: ' + message)

def plist(path):
    require(path.is_file(), f'Missing {path.name}')
    return plistlib.loads(path.read_bytes())

metadata = plist(archive / 'Info.plist')
relative = metadata.get('ApplicationProperties', {}).get('ApplicationPath')
require(relative == 'Applications/ROOMS.app', 'Archive is not a ROOMS iPhone app archive')
app = archive / 'Products' / relative
info = plist(app / 'Info.plist')
require(info.get('CFBundleIdentifier') == bundle_id, 'Wrong bundle ID')
require(info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'Wrong platform')
require(info.get('MinimumOSVersion') == '17.0', 'Unexpected deployment target')
require(info.get('UIDeviceFamily') == [1], 'Target must be iPhone')
origin = info.get('ROOMSAPIOrigin') or ''
require(re.fullmatch(r'https://[^/?#@\s]+/?', origin) is not None, 'Server origin missing or not HTTPS; set Configuration/Local.xcconfig')
require(args.origin is None or origin.rstrip('/') == args.origin.rstrip('/'), 'Wrong server origin')
require(not info.get('NSAppTransportSecurity', {}).get('NSAllowsArbitraryLoads'), 'ATS disabled')
# voip keeps the call in Picture in Picture in the background (5788cef).
require(info.get('UIBackgroundModes') == ['audio', 'voip'], 'Unexpected background capabilities')
require(bool(info.get('NSMicrophoneUsageDescription')), 'Missing microphone purpose')
require(bool(info.get('NSCameraUsageDescription')), 'Missing room camera purpose')
require((app / 'Assets.car').is_file(), 'Compiled asset catalog missing; development icon bypass is not a beta archive')
require(bool(info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {}).get('CFBundleIconName')), 'Compiled app icon metadata missing')
icons = list(app.glob('AppIcon*.png'))
require(bool(icons), 'Compiled icon PNGs missing')
for icon in icons:
    output = subprocess.run(['sips', '-g', 'hasAlpha', str(icon)], check=True, capture_output=True, text=True).stdout
    require('hasAlpha: no' in output, 'App icon contains an alpha channel')

exe = app / info['CFBundleExecutable']
arch = subprocess.run(['xcrun', 'lipo', '-archs', str(exe)], check=True, capture_output=True, text=True).stdout.strip()
require(arch == 'arm64', 'Expected device arm64 executable')

def uuids(path):
    output = subprocess.run(['xcrun', 'dwarfdump', '--uuid', str(path)], check=True, capture_output=True, text=True).stdout
    return set(re.findall(r'UUID: ([0-9A-Fa-f-]+) \(arm64\)', output))

dsym = archive / 'dSYMs' / 'ROOMS.app.dSYM'
require(dsym.is_dir(), 'Missing app dSYM')
require(uuids(exe) and uuids(exe) == uuids(dsym), 'App binary and dSYM UUID mismatch')
manifest = plist(app / 'PrivacyInfo.xcprivacy')
reasons = {row['NSPrivacyAccessedAPIType']: set(row['NSPrivacyAccessedAPITypeReasons']) for row in manifest.get('NSPrivacyAccessedAPITypes', [])}
require('CA92.1' in reasons.get('NSPrivacyAccessedAPICategoryUserDefaults', set()), 'Missing local preferences reason')
require('35F9.1' in reasons.get('NSPrivacyAccessedAPICategorySystemBootTime', set()), 'Missing elapsed timer reason')
require(manifest.get('NSPrivacyTracking') is False and manifest.get('NSPrivacyTrackingDomains') == [], 'Unexpected tracking declaration')
privacy_paths = [
    'LiveKit_LiveKit.bundle/PrivacyInfo.xcprivacy',
    'Frameworks/LiveKitWebRTC.framework/PrivacyInfo.xcprivacy',
    'Frameworks/RustLiveKitUniFFI.framework/PrivacyInfo.xcprivacy',
]
for path in privacy_paths:
    plist(app / path)
signing = 'unsigned/ad-hoc'
profile_path = app / 'embedded.mobileprovision'
if profile_path.exists():
    output = subprocess.run(['security', 'cms', '-D', '-i', str(profile_path)], check=True, capture_output=True).stdout
    profile = plistlib.loads(output)
    entitlements = profile.get('Entitlements', {})
    require(profile.get('TeamIdentifier') == [team], 'Wrong signing team')
    require(profile.get('ExpirationDate', datetime.datetime.min) > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Expired signing profile')
    prefix = profile.get('ApplicationIdentifierPrefix', [''])[0]
    require(fnmatch.fnmatch(prefix + '.' + info['CFBundleIdentifier'], entitlements.get('application-identifier', '')), 'Signing profile does not match bundle')
    if entitlements.get('get-task-allow'):
        signing = 'development'
    elif profile.get('ProvisionedDevices'):
        signing = 'ad-hoc distribution'
    elif profile.get('ProvisionsAllDevices'):
        signing = 'enterprise'
    else:
        signing = 'App Store distribution (local checks only)'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
report = {
    'archive': str(archive), 'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
    'configuration': 'Release', 'architecture': arch, 'appDSYMMatches': True,
    'compiledAssetCatalog': True, 'opaqueAppIcons': True, 'privacyManifests': ['PrivacyInfo.xcprivacy'] + privacy_paths,
    'signing': signing, 'appleValidation': 'not performed', 'uploaded': False,
    'physicalAcceptance': 'pending owner checks',
}
if args.report:
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
