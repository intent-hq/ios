"""Stage capture-only test sources without editing the candidate application."""
import pathlib, re, subprocess

BASE = '3f70e5e51f3e4b84157e571875661b9d171cf272'
subprocess.run(['git', 'diff', '--exit-code', BASE, '--', 'Intent/'], check=True)
p = pathlib.Path('Intent.xcodeproj/project.pbxproj')
s = p.read_text()
old = '\t\t\tpath = IntentUITests;'
assert s.count(old) == 1
s = s.replace(old, '\t\t\tpath = ".github/app-store-capture/Tests";')
for key in ['EB655EF62F669E6C00176730', 'EB655EF72F669E6C00176730']:
    pattern = rf'({key} /\* (?:Debug|Release) \*/ = \{{.*?buildSettings = \{{)(.*?)(\n\t\t\t\}};)'
    def patch(m):
        body = m[2].replace('TARGETED_DEVICE_FAMILY = "1,2";', 'TARGETED_DEVICE_FAMILY = "1,2,7";')
        body += '\n\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator xros xrsimulator";\n\t\t\t\tXROS_DEPLOYMENT_TARGET = 2.0;'
        return m[1] + body + m[3]
    s, count = re.subn(pattern, patch, s, count=1, flags=re.S)
    assert count == 1
p.write_text(s)
subprocess.run(['git', 'diff', '--exit-code', BASE, '--', 'Intent/'], check=True)
print('Candidate Intent/ unchanged; capture-only UI test target staged.')
