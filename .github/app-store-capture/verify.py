"""Reject incomplete/wrong-size capture sets; record original screenshot hashes."""
import hashlib,json,pathlib,struct,sys,os
root=pathlib.Path(sys.argv[1])
expected={'APP_IPHONE_67':(1320,2868),'APP_IPHONE_65':(1242,2688),'APP_IPAD_PRO_3GEN_129':(2752,2064),'APP_APPLE_VISION_PRO':(3840,2160)}
names=['01-workspace-list','02-workspace-detail','03-agent-conversation','04-note-tasks','05-pairing']
manifest={'candidateSha':(root/'candidate-sha.txt').read_text().strip(),'harnessSha':(root/'harness-sha.txt').read_text().strip(),'screenshots':[]}
slots = os.environ.get("CAPTURE_SLOTS")
if slots:
    assert slots in expected, slots
    expected = {slots: expected[slots]}
for slot,dimensions in expected.items():
    for name in names:
        path=root/slot/(name+'.png'); data=path.read_bytes()
        assert data[:8]==b'\x89PNG\r\n\x1a\n',path
        actual=struct.unpack('>II',data[16:24]); assert actual==dimensions,(path,actual,dimensions)
        manifest['screenshots'].append({'slot':slot,'name':name,'width':actual[0],'height':actual[1],'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)})
(root/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(f'Verified {len(manifest["screenshots"])} original simulator PNGs; visual review still required.')
