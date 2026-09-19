"""Optional isolated launchd crash recovery smoke test; never changes network settings."""
import pathlib,tempfile,subprocess,plistlib,os,time,json,socket,hashlib,signal,urllib.request,sys
exe=str(pathlib.Path(sys.argv[1]).resolve());core=str(pathlib.Path(sys.argv[2]).resolve())
with tempfile.TemporaryDirectory(prefix='vorssaint-launchd-',dir='/private/tmp') as temp:
 root=pathlib.Path(temp)/'state';root.mkdir();work=root/'runtime';work.mkdir()
 config=work/'runtime.yaml';config.write_text(json.dumps({'mixed-port':27892,'external-controller':'127.0.0.1:29092','secret':'isolated-test','mode':'direct','proxies':[],'rules':['MATCH,DIRECT']}))
 label='com.vorssaint.proxy-lifetime-test.'+str(os.getpid());target='gui/'+str(os.getuid())+'/'+label
 plist=pathlib.Path(temp)/'agent.plist';plist.write_bytes(plistlib.dumps({'Label':label,'ProgramArguments':[exe,str(root)],'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':1}))
 control='/private/tmp/vorssaint-agent-'+str(os.getuid())+'-'+hashlib.sha256(str(root).replace('/private/tmp/','/tmp/',1).encode()).hexdigest()[:24]+'.sock'
 def req(command,**kwargs):
  with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as c:
   c.settimeout(10);c.connect(control);c.sendall(json.dumps(dict(command=command,identifier='test',**kwargs)).encode()+b'\n');data=b''
   while b'\n' not in data:data+=c.recv(8192)
   r=json.loads(data);assert r['success'],r;return r
 subprocess.run(['launchctl','bootstrap','gui/'+str(os.getuid()),str(plist)],check=True)
 pid=None;removed=False
 try:
  for _ in range(100):
   if pathlib.Path(control).exists():break
   time.sleep(.1)
  r=req('start',corePath=core,workPath=str(work),configPath=str(config));pid=r['corePID']
  opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
  for _ in range(50):
   try:
    with opener.open(urllib.request.Request('http://127.0.0.1:29092/version',headers={'Authorization':'Bearer isolated-test'}),timeout=1) as response:
     assert response.status==200
    break
   except Exception:time.sleep(.1)
  else:raise AssertionError('core did not become ready')
  req('commit')
  subprocess.run(['launchctl','kill','SIGKILL',target],check=True)
  removed=False
  for _ in range(100):
   try:os.kill(pid,0)
   except ProcessLookupError:removed=True;break
   time.sleep(.1)
  print('launchd cleans core after guardian crash:',removed,flush=True)
  assert removed,'orphaned core process'
  for _ in range(100):
   try:
    if req('status').get('corePID') is None:break
   except Exception:pass
   time.sleep(.1)
  else:raise AssertionError('agent did not restart')
  print('launchd restarted guardian without stale core session',flush=True)
 finally:
  subprocess.run(['launchctl','bootout',target],check=False)
  if pid and not removed:
   try:os.kill(pid,signal.SIGTERM)
   except ProcessLookupError:pass
