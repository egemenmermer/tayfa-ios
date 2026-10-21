#!/usr/bin/env python3
"""Sign a local device-only PoC using an existing valid Apple development profile.

No certificates, profile contents or private keys are stored in source control.
This is not an App Store archive/export path.
"""
import argparse, datetime, fnmatch, hashlib, plistlib, shutil, subprocess
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('--app',required=True)
parser.add_argument('--profile',required=True)
parser.add_argument('--identity',required=True)
parser.add_argument('--device',required=True)
parser.add_argument('--development-icon',action='store_true',help='Use ordinary PNG icons for the device PoC when actool is unavailable.')
args=parser.parse_args()
app=Path(args.app).resolve();profile=Path(args.profile).resolve()
data=subprocess.run(['security','cms','-D','-i',str(profile)],check=True,capture_output=True).stdout
p=plistlib.loads(data)
info_path=app/'Info.plist';info=plistlib.loads(info_path.read_bytes())
bundle=info['CFBundleIdentifier'];team=p['TeamIdentifier'][0];prefix=p['ApplicationIdentifierPrefix'][0]
entitlements=p['Entitlements']
if not entitlements.get('get-task-allow') or p['ExpirationDate']<=datetime.datetime.now():raise SystemExit('A current development profile is required.')
if args.device not in p.get('ProvisionedDevices',[]):raise SystemExit('Device is not authorized by the profile.')
if not fnmatch.fnmatch(prefix+'.'+bundle,entitlements['application-identifier']):raise SystemExit('Bundle ID does not match profile.')
if args.identity.upper() not in [hashlib.sha1(c).hexdigest().upper() for c in p['DeveloperCertificates']]:raise SystemExit('Signing identity does not belong to the profile.')
if args.development_icon:
    source=Path(__file__).resolve().parent.parent/'Apps/ROOMS/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
    for size in [120,180]:
        subprocess.run(['sips','-z',str(size),str(size),str(source),'--out',str(app/f'DevelopmentIcon{size}.png')],check=True,capture_output=True)
    info['CFBundleIcons']={'CFBundlePrimaryIcon':{'CFBundleIconFiles':['DevelopmentIcon120','DevelopmentIcon180'],'UIPrerenderedIcon':False}}
    info_path.write_bytes(plistlib.dumps(info))
# Only the development artifact receives the signed Apple profile.
shutil.copyfile(profile,app/'embedded.mobileprovision')
app_entitlements={
    'application-identifier':prefix+'.'+bundle,
    'com.apple.developer.team-identifier':team,
    'keychain-access-groups':[prefix+'.'+bundle],
    'get-task-allow':True,
}
output=app.parent/'development-entitlements.plist';output.write_bytes(plistlib.dumps(app_entitlements))
for framework in sorted((app/'Frameworks').glob('*.framework')):
    subprocess.run(['codesign','--force','--sign',args.identity,'--timestamp=none',str(framework)],check=True)
for library in sorted((app/'Frameworks').glob('*.dylib')):
    subprocess.run(['codesign','--force','--sign',args.identity,'--timestamp=none',str(library)],check=True)
subprocess.run(['codesign','--force','--sign',args.identity,'--timestamp=none','--entitlements',str(output),str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
print('Development app signed and verified:',app)
