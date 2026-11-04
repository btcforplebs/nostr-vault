import json
META={"d","title","name","description","image","alt","client"}
ENC={10000,10003,30000,30003}
MIN_ITEMS=10; MIN_CONTENT=1000; LOOKBACK=5; ALARM_MIN=3
def items(v):
    if v["kind"]==0:
        try: f=json.loads(v["content"])
        except Exception: return set()
        if not isinstance(f,dict): return set()
        return {k+"\0"+x for k,x in f.items() if isinstance(x,str) and x!=""}
    out=set()
    for t in v["tags"]:
        if not t or t[0] in META: continue
        out.add(t[0]+("\0"+t[1] if len(t)>1 else ""))
    return out
def clobbered(a,b):
    ia,ib=items(a),items(b); n=len(ia); kept=len(ia&ib)
    if n>0 and len(ib)==0: return True
    if n>=MIN_ITEMS and kept*2<n: return True
    if a["kind"] in ENC:
        la,lb=len(a["content"]),len(b["content"])
        if la>0 and lb==0: return True
        if la>=MIN_CONTENT and lb*2<la: return True
    return False
def alarm(vs,own,dismissed):
    if len(vs)<2: return None
    v0=vs[0]
    if v0["id"] in own or v0["id"] in dismissed: return None
    top=min(LOOKBACK,len(vs)-1)
    trig=None
    for i in range(1,top+1):
        if not clobbered(vs[i],v0): continue
        if any(clobbered(vs[i],vs[j]) for j in range(1,i)): continue
        trig=i; break
    if trig is None: return None
    # The list to offer back: the largest version within the lookback that
    # v0 clobbered, never older than the newest version Nostr Vault signed
    # (that one is the owner's own choice).
    stop=top
    for k in range(1,top+1):
        if vs[k]["id"] in own: stop=k; break
    best=None
    for k in range(1,stop+1):
        if clobbered(vs[k],v0) and (best is None or len(items(vs[k]))>len(items(best)) or (len(items(vs[k]))==len(items(best)) and len(vs[k]["content"])>len(best["content"]))):
            best=vs[k]
    if best is None: return None
    b=best; ib=items(b); i0=items(v0)
    worth=len(ib)>=ALARM_MIN or (b["kind"] in ENC and len(b["content"])>=MIN_CONTENT)
    if not worth: return None
    kept=len(ib&i0)
    if len(i0)==0 and (b["kind"] not in ENC or len(v0["content"])==0): how="emptied"
    elif trig>1: how="drained"
    elif len(ib)>=MIN_ITEMS and kept*2<len(ib) and len(i0)*2>=len(ib): how="swapped"
    else: how="shrank"
    client=next((t[1].strip()[:60] for t in v0["tags"] if len(t)>=2 and t[0]=="client" and t[1].strip()),None)
    return {"before":b["id"],"after":v0["id"],"how":how,"from":len(ib),"to":len(i0),"lost":len(ib-i0),"client":client}
