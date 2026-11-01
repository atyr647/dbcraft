import zlib, random, math, struct, time
random.seed(7)
def varint(n):
    o=bytearray()
    while True:
        b=n&127; n>>=7
        if n: o.append(b|128)
        else: o.append(b); return bytes(o)
def pack(idx,bits):
    per=64//bits; out=bytearray()
    for i in range(0,4096,per):
        w=0
        for j,v in enumerate(idx[i:i+per]): w|=v<<(j*bits)
        out+=struct.pack('>Q',w)
    return bytes(out)
def noise(x,z): return 64+14*math.sin(x/9.0)+9*math.sin(z/7.0+x/23.0)+5*math.sin((x+z)/3.1)
def chunk(cx,cz,kind):
    # 24 sections y=-64..319. kind: 'terrain' | 'flat'
    h=[[int(noise(cx*16+x,cz*16+z)) if kind=='terrain' else 64 for z in range(16)] for x in range(16)]
    body=bytearray()
    for s in range(24):
        y0=-64+s*16
        idx=[];pal={}
        def pid(n):
            if n not in pal: pal[n]=len(pal)
            return pal[n]
        for yy in range(16):
            for z in range(16):
                for x in range(16):
                    y=y0+yy; hh=h[x][z]
                    if y>hh: n=0
                    elif y==hh: n=2
                    elif y>hh-4: n=3
                    elif y<-60 and random.random()<.3: n=5
                    else:
                        n=1
                        if kind=='terrain' and random.random()<.04: n=random.choice([6,7,8,9])  # ores
                    idx.append(pid(n))
        cnt=sum(1 for v in idx if v!=pid(0)) if 0 in pal else 4096
        body+=struct.pack('>h',cnt)
        if len(pal)==1: body+=bytes([0])+varint(list(pal)[0])+varint(0)
        else:
            bits=max(4,(len(pal)-1).bit_length())
            body+=bytes([bits])+varint(len(pal))+b''.join(varint(n+100) for n in pal)+varint(4096//(64//bits)+(1 if 4096%(64//bits) else 0))+pack(idx,bits)
        body+=bytes([0])+varint(1)+varint(0)  # biomes single
    hm=b''.join(struct.pack('>Q',random.getrandbits(63)) for _ in range(37))*2  # heightmaps
    light=b''
    for s in range(26):
        sky = b'\xff'*2048 if s>=10 else bytes((random.choice([0xff,0xee,0xdd]) for _ in range(2048)))
        light+=varint(2048)+sky
    for s in range(26): light+=varint(2048)+b'\x00'*2048
    return bytes(body)+hm+light
def tm(f,*a):
    t=time.perf_counter(); r=f(*a); return r,(time.perf_counter()-t)*1000
def comp(d,lvl=6,strat=zlib.Z_DEFAULT_STRATEGY):
    c=zlib.compressobj(lvl,zlib.DEFLATED,15,8,strat); return c.compress(d)+c.flush()
for kind in ('flat','terrain'):
    d=chunk(3,5,kind); print(f"\n[{kind}] raw chunk payload {len(d)/1024:.1f} KiB")
    for name,lvl,st in [('zlib L1',1,0),('zlib L6',6,0),('zlib L9',9,0),('RLE-only (distance-1 matches)',6,zlib.Z_RLE),('Huffman-only',6,zlib.Z_HUFFMAN_ONLY),('fixed-Huffman+LZ',6,zlib.Z_FIXED)]:
        c,ms=tm(comp,d,lvl,st); print(f"  {name:32s} {len(c)/1024:7.1f} KiB  ratio {len(d)/len(c):5.1f}x  {ms:6.2f} ms")
    # light-only share
print("\nBandwidth sketch: a joining player loads (2*10+1)^2=441 chunks")
