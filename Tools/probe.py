# Read-only LAN probe: reads all v1 properties of xiaomi.airp.cpa4 using the token from Keychain (PurifierBar/purifier). Never prints the token.
# Usage: python3 -I Tools/probe.py [device IP]   (without an IP the device is found by broadcast)
import socket, json, hashlib, subprocess, time, sys
tok = subprocess.run(["security","find-generic-password","-s","PurifierBar","-a","purifier","-w"],capture_output=True,text=True).stdout.strip()
if len(tok)!=32: sys.exit(f"token: wrong length {len(tok)} (expected 32 hex)")
T=bytes.fromhex(tok); K=hashlib.md5(T).digest(); IV=hashlib.md5(K+T).digest()
def aes(data,dec):
    a=["openssl","enc","-aes-128-cbc","-K",K.hex(),"-iv",IV.hex()]+(["-d"] if dec else [])
    return subprocess.run(a,input=data,capture_output=True,check=True).stdout
HOST=sys.argv[1] if len(sys.argv)>1 else "255.255.255.255"
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(3); s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1)
s.sendto(bytes.fromhex("21310020"+"ff"*28),(HOST,54321))
h,(HOST,_)=s.recvfrom(1024); did=int.from_bytes(h[8:12],"big"); stamp=int.from_bytes(h[12:16],"big"); t0=time.time()
props=[(2,1,"on"),(2,2,"fault"),(2,4,"mode"),(3,4,"pm25"),(4,1,"filter_%"),(4,4,"filter_days"),(6,1,"sound"),(8,1,"child_lock"),(13,2,"screen"),(9,1,"rpm"),(9,11,"fav_level")]
msg=json.dumps({"id":1,"method":"get_properties","params":[{"did":str(did),"siid":a,"piid":b} for a,b,_ in props]}).encode()
enc=aes(msg,False)
hdr=bytes.fromhex("2131")+(len(enc)+32).to_bytes(2,"big")+(0).to_bytes(4,"big")+did.to_bytes(4,"big")+(stamp+int(time.time()-t0)).to_bytes(4,"big")
s.sendto(hdr+hashlib.md5(hdr+T+enc).digest()+enc,(HOST,54321))
r,_=s.recvfrom(4096); body=r[32:]
if hashlib.md5(r[:16]+T+body).digest()!=r[16:32]: sys.exit("checksum mismatch: token belongs to another device")
res=json.loads(aes(body,True).rstrip(b"\0"))
names={(a,b):n for a,b,n in props}
for x in res["result"]: print(f'{names[(x["siid"],x["piid"])]:12} {x.get("value")}  (code {x["code"]})')
