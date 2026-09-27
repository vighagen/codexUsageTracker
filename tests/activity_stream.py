#!/usr/bin/env python3
"""Exercise activity monitoring against a local fake IPC server; no Codex account needed."""
import json, os, socket, sqlite3, struct, subprocess, sys, tempfile, time
from pathlib import Path
exe = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='orb-activity-test-') as directory:
    root = Path(directory); (root/'ipc').mkdir()
    db = sqlite3.connect(root/'state_5.sqlite')
    db.execute('create table threads (id text, archived integer, source text, updated_at integer)')
    db.execute("insert into threads values ('fixture',0,'vscode',1)"); db.commit(); db.close()
    server = socket.socket(socket.AF_UNIX); server.bind(str(root/'ipc/ipc.sock')); server.listen(1); server.settimeout(5)
    process = subprocess.Popen([str(exe),'--activity-check'], env={**os.environ,'CODEX_HOME':str(root)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    client,_ = server.accept(); client.settimeout(5)
    def receive():
        def exact(n):
            b=b''
            while len(b)<n:
                p=client.recv(n-len(b))
                if not p:raise EOFError()
                b+=p
            return b
        return json.loads(exact(struct.unpack('<I',exact(4))[0]))
    def send(message):
        data=json.dumps(message).encode();client.sendall(struct.pack('<I',len(data))+data)
    initialize=receive(); assert initialize['method']=='initialize'
    send({'type':'response','method':'initialize','result':{'clientId':'observer'}})
    assert receive()['method']=='thread-stream-following-changed'
    def change(value):
        send({'type':'broadcast','method':'thread-stream-state-changed','version':11,'sourceClientId':'fixture-owner',
              'params':{'hostId':'local','conversationId':'fixture','change':value}})
        time.sleep(.6)
    def snapshot(revision,status):
        change({'type':'snapshot','revision':revision,'conversationState':{'threadRuntimeStatus':status,'requests':[]}})
    snapshot(1,{'type':'active','activeFlags':[]})
    change({'type':'patches','baseRevision':1,'revision':2,'patches':[{'op':'replace','path':['threadRuntimeStatus','activeFlags'],'value':['waitingOnUserInput']}]})
    change({'type':'patches','baseRevision':2,'revision':3,'patches':[{'op':'remove','path':['threadRuntimeStatus','activeFlags',0]}]})
    snapshot(4,{'type':'idle'})
    snapshot(5,{'type':'active','activeFlags':[]})
    client.close(); server.close()
    stdout,stderr=process.communicate(timeout=12)
    assert process.returncode == 0,stderr
    values=[line.split('Activity connected: ')[1] for line in stdout.splitlines() if line.startswith('Activity connected: ')]
    assert values == ['true, working tasks: 0','true, working tasks: 1','true, working tasks: 0','true, working tasks: 1','true, working tasks: 0','true, working tasks: 1','false, working tasks: 0'],values
    print('IPC lifecycle passed: active → waiting → active → complete → active → disconnected')
