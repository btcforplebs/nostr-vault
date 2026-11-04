# My devices (Your space): one device's mesh status from its FIPS overlay adverts (kind 37195, d "fips-overlay-v1",
# NIP-40 expiration, refreshed about every 30 min, valid 1 h) and, on a device with a running engine, whether it is
# connected now. Generates status-cases.json; Swift (MyDevicesStatus.swift) and the web (my-devices.js) must agree.
import json
D="fips-overlay-v1"; SKEW=600; FALLBACK_TTL=3600
def tag(e,n):
    for t in e.get("tags",[]):
        if len(t)>=2 and t[0]==n: return t[1]
    return None
def status(adverts, now, connected, checked):
    if connected: return {"state":"connected","last_seen":now}
    if not checked: return {"state":"unchecked","last_seen":None}
    ok=[e for e in adverts if tag(e,"d")==D and isinstance(e.get("created_at"),int) and e["created_at"]<=now+SKEW]
    if not ok: return {"state":"unknown","last_seen":None}
    e=max(ok,key=lambda e:e["created_at"])
    exp=tag(e,"expiration")
    try: exp=int(exp) if exp is not None else None
    except ValueError: exp=None
    live = exp>now if exp is not None else now-e["created_at"]<FALLBACK_TTL
    return {"state":"online" if live else "offline","last_seen":e["created_at"]}
N=1793800000
def ad(at,exp="auto",d=D):
    tags=[["d",d]]
    if exp=="auto": tags.append(["expiration",str(at+3600)])
    elif exp is not None: tags.append(["expiration",str(exp)])
    return {"created_at":at,"tags":tags}
cases=[
 ("connected wins over everything",[],True,False),
 ("fresh advert is online",[ad(N-120)],False,True),
 ("expired advert is offline, last seen kept",[ad(N-5000)],False,True),
 ("newest of several counts",[ad(N-9000),ad(N-200),ad(N-4000)],False,True),
 ("no advert is unknown",[],False,True),
 ("relays not reached is unchecked",[ad(N-60)],False,False),
 ("another d tag is not a mesh advert",[ad(N-60,d="other")],False,True),
 ("no expiration: online within an hour",[ad(N-1800,exp=None)],False,True),
 ("no expiration: offline after an hour",[ad(N-3700,exp=None)],False,True),
 ("bad expiration falls back to the hour",[ad(N-100,exp="soon")],False,True),
 ("advert from the far future is ignored",[ad(N+5000)],False,True),
 ("small clock skew is fine",[ad(N+300)],False,True),
]
out={"rule":{"d":D,"skew":SKEW,"fallback_ttl":FALLBACK_TTL},"now":N,"cases":[{"name":n,"adverts":a,"connected":c,"checked":k,"expect":status(a,N,c,k)} for n,a,c,k in cases]}
json.dump(out,open("status-cases.json","w"),indent=1)
for c in out["cases"]: print(c["name"],"->",c["expect"])
