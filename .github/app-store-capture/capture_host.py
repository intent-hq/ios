"""Acknowledge XCTest requests only after saving the real simulator frame."""
import pathlib, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
udid = sys.argv[2]
allowed = {'01-workspace-list', '02-workspace-detail', '03-agent-conversation', '04-note-tasks', '05-pairing'}
while not (root/'stop').exists():
    request = root/'request'
    if request.exists():
        name = request.read_text()
        if name not in allowed:
            raise ValueError('Unknown screenshot name')
        done = root/(name+'.done')
        if not done.exists():
            subprocess.run(['xcrun', 'simctl', 'io', udid, 'screenshot', str(root/(name+'.png'))], check=True)
            done.touch()
    time.sleep(0.1)
