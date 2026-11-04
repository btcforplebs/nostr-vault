import json, unicodedata
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
HISTORY=20
def holds(v,than):
    if not items(than)<=items(v): return False
    if than["kind"] in ENC and len(v["content"])<len(than["content"]): return False
    return True
def clean_client(raw):
    t="".join(ch for ch in raw if unicodedata.category(ch) not in ("Cc","Cf")).strip()
    return t[:60] if t else None
def judge(vs,k,own):
    """The alarm version vs[k] raises against the versions before it, or None."""
    vk=vs[k]
    top=min(k+LOOKBACK,len(vs)-1)
    trig=None
    for i in range(k+1,top+1):
        if not clobbered(vs[i],vk): continue
        if any(clobbered(vs[i],vs[j]) for j in range(k+1,i)): continue
        trig=i; break
    if trig is None: return None
    stop=top
    for m in range(k+1,top+1):
        if vs[m]["id"] in own: stop=m; break
    best=None
    for m in range(k+1,stop+1):
        if clobbered(vs[m],vk) and (best is None or len(items(vs[m]))>len(items(best)) or (len(items(vs[m]))==len(items(best)) and len(vs[m]["content"])>len(best["content"]))):
            best=vs[m]
    if best is None: return None
    b=best; ib=items(b); i0=items(vk)
    worth=len(ib)>=ALARM_MIN or (b["kind"] in ENC and len(b["content"])>=MIN_CONTENT)
    if not worth: return None
    kept=len(ib&i0)
    if len(i0)==0 and (b["kind"] not in ENC or len(vk["content"])==0): how="emptied"
    elif trig>k+1: how="drained"
    elif len(ib)>=MIN_ITEMS and kept*2<len(ib) and len(i0)*2>=len(ib): how="swapped"
    else: how="shrank"
    client=next((clean_client(t[1]) for t in vk["tags"] if len(t)>=2 and t[0]=="client" and clean_client(t[1])),None)
    claims=bool(client) and "nostr vault" in client.lower()
    return {"before":b["id"],"after":vk["id"],"how":how,"from":len(ib),"to":len(i0),"lost":len(ib-i0),"client":client,"claims_nostr_vault":claims}
def alarm(vs,own,dismissed):
    """The newest clobber among the newest HISTORY versions that no newer
    version undid (by holding the list from before again), not dismissed, not
    made by Nostr Vault on this device."""
    for k in range(0,min(HISTORY,len(vs))):
        vk=vs[k]
        if vk["id"] in own: continue
        a=judge(vs,k,own)
        if a is None: continue
        if vk["id"] in dismissed: return None
        before=next(v for v in vs if v["id"]==a["before"])
        if any(holds(vs[j],before) for j in range(0,k)): return None
        return a
    return None
