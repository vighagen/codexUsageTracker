#!/usr/bin/env python3
"""Exercise activity monitoring against a local fake IPC server; no Codex account needed."""
import json, os, socket, sqlite3, struct, subprocess, sys, tempfile, time
from pathlib import Path
exe = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='orb-activity-test-') as directory:
    root = Path(directory); (root/'ipc').mkdir()
    db = sqlite3.connect(root/'state_5.sqlite')
    db.execute('create table threads (id text, archived integer, source text, updated_at integer)')
    db.execute("insert into threads values ('fixture',0,'vscode',100)")
    db.execute("insert into threads values ('project',0,'vscode',0)")
    for i in range(70): db.execute("insert into threads values (?,0,'vscode',?)",(f'older-{i}',i+1))
    db.commit(); db.close()
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
    subscriptions=set()
    while len(subscriptions)<72:
        message=receive()
        assert message['method']=='thread-stream-following-changed'
        subscriptions.add(message['params']['conversationId'])
    assert 'project' in subscriptions, 'Project outside the former 64-task window must be followed' 
    def change(value,task="fixture"):
        send({'type':'broadcast','method':'thread-stream-state-changed','version':11,'sourceClientId':'fixture-owner',
              'params':{'hostId':'local','conversationId':task,'change':value}})
        time.sleep(.3)
    def snapshot(revision,status):
        change({'type':'snapshot','revision':revision,'conversationState':{'threadRuntimeStatus':status,'requests':[]}})
    snapshot(1,{'type':'active','activeFlags':[]})
    change({'type':'patches','baseRevision':2500,'revision':2501,'patches':[
        {'op':'replace','path':['turnHistory','history','entitiesByKey','tail:0:local:project','items',175],
         'value':{'type':'reasoning'}}]}, 'project')
    snapshot(2,{'type':'idle'})
    change({'type':'patches','baseRevision':2501,'revision':2502,'patches':[
        {'op':'replace','path':['threadRuntimeStatus','activeFlags'],'value':['waitingOnApproval']}]},'project')
    snapshot(3,{'type':'active','activeFlags':[]})
    change({'type':'patches','baseRevision':2502,'revision':2503,'patches':[
        {'op':'replace','path':['threadRuntimeStatus','activeFlags'],'value':[]}]},'project')
    snapshot(4,{'type':'idle'})
    change({'type':'patches','baseRevision':2503,'revision':2504,'patches':[
        {'op':'replace','path':['threadRuntimeStatus'],'value':{'type':'idle'}}]},'project')
    client.close(); server.close()
    stdout,stderr=process.communicate(timeout=12)
    assert process.returncode == 0,stderr
    values=[line.split('Activity connected: ')[1] for line in stdout.splitlines() if line.startswith('Activity connected: ')]
    assert values == ['true, working tasks: 0','true, working tasks: 1','true, working tasks: 2',
                      'true, working tasks: 1','true, working tasks: 0','true, working tasks: 1',
                      'true, working tasks: 2','true, working tasks: 1','true, working tasks: 0',
                      'false, working tasks: 0'], values
    print('Multi-task IPC passed: 72 subscriptions; snapshot-less project; one task finishes while another works; waiting/resume; all done')
