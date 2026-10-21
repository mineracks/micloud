#!/usr/bin/python3
# iCloud FileProvider control: status / evict / download  (materialize primitive PoC)
import sys, time
from Foundation import NSFileManager, NSURL
KEY_STATUS="NSURLUbiquitousItemDownloadingStatusKey"
KEY_UP="NSURLUbiquitousItemIsUploadedKey"
KEY_DL="NSURLUbiquitousItemIsDownloadingKey"
def u(p): return NSURL.fileURLWithPath_(p)
def vals(p):
    v,err=u(p).resourceValuesForKeys_error_([KEY_STATUS,KEY_UP,KEY_DL],None)
    if v is None: return {"error":str(err)}
    return {k.replace("NSURLUbiquitousItem",""): v.objectForKey_(k) for k in [KEY_STATUS,KEY_UP,KEY_DL]}
fm=NSFileManager.defaultManager()
cmd=sys.argv[1]; path=sys.argv[2]
if cmd=="status":
    print(vals(path))
elif cmd=="evict":
    ok,err=fm.evictUbiquitousItemAtURL_error_(u(path),None)
    print("evict ok=%s err=%s"%(bool(ok),err)); print(vals(path))
elif cmd=="download":
    to=float(sys.argv[3]) if len(sys.argv)>3 else 120
    ok,err=fm.startDownloadingUbiquitousItemAtURL_error_(u(path),None)
    print("start ok=%s err=%s"%(bool(ok),err))
    t0=time.time()
    while time.time()-t0<to:
        st=str(vals(path).get("DownloadingStatusKey",""))
        if "Current" in st: print("MATERIALIZED status=%s after %.1fs"%(st,time.time()-t0)); sys.exit(0)
        time.sleep(1)
    print("TIMEOUT %s"%vals(path)); sys.exit(1)
