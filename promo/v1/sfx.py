import numpy as np, wave
SR=44100; B=0.535; bt=lambda n:n*B
N=int(22.2*SR); out=np.zeros(N); rng=np.random.default_rng(7)
def put(t,s,g=1.0):
    i=int(t*SR); s=s*g; e=min(N,i+len(s)); 
    if i<N: out[i:e]+=s[:e-i]
def env(n,a,d): x=np.arange(n)/SR; return np.minimum(1,x/a)*np.exp(-x/d)
def lp(x,c):
    y=np.zeros_like(x); s=0
    for i in range(len(x)):
        a=c[i] if hasattr(c,'__len__') else c; s+=a*(x[i]-s); y[i]=s
    return y
def whoosh(dur,up=True,g=1):
    n=int(dur*SR); x=rng.standard_normal(n); k=np.linspace(0,1,n); k=k if up else k[::-1]
    c=0.01+0.30*k**2; y=lp(x,c); y-=lp(y,0.002)  # rough bandpass
    e=np.sin(np.pi*np.linspace(0,1,n))**1.5; return y*e*g*3.2
def thud(f=55,d=0.22,g=1):
    n=int(0.7*SR); x=np.arange(n)/SR; fr=f*(1+1.5*np.exp(-x*30)); ph=2*np.pi*np.cumsum(fr)/SR
    return np.sin(ph)*np.exp(-x/d)*g
def click(g=1):
    n=int(0.06*SR); x=np.arange(n)/SR; nz=rng.standard_normal(n); nz-=lp(nz,0.1)
    return (nz*np.exp(-x/0.004)*0.8+np.sin(2*np.pi*1900*x)*np.exp(-x/0.006)*0.5)*g
def pop(f=620,g=1):
    n=int(0.14*SR); x=np.arange(n)/SR; fr=f*(1+0.8*np.exp(-x*40)); return np.sin(2*np.pi*np.cumsum(fr)/SR)*np.exp(-x/0.035)*g
def tick(g=1):
    n=int(0.02*SR); x=np.arange(n)/SR; nz=rng.standard_normal(n); nz-=lp(nz,rng.uniform(.05,.2)); return nz*np.exp(-x/0.004)*g
def chime(g=1):
    n=int(1.6*SR); x=np.arange(n)/SR
    return (np.sin(2*np.pi*880*x)+0.6*np.sin(2*np.pi*1320*x)+0.3*np.sin(2*np.pi*1760*x))*np.exp(-x/0.5)*np.minimum(1,x/0.005)*g
# intro
put(0.0,whoosh(2.1,True,0.5)); put(bt(4),thud(52,0.3,0.9))
# cuts
for n in (12,20,28,34): put(bt(n)-0.12,whoosh(0.3,True,0.45)); put(bt(n),thud(60,0.18,0.55))
# S2
for i in range(4): put(bt(8)+i*B*0.5,pop(560+i*70,0.45))
put(bt(10),whoosh(0.45,False,0.4))
# S3 typing
t0=bt(12.8); tot=bt(4.2)
for k in range(int(tot*22)): put(t0+k/22+rng.uniform(0,0.02),tick(0.35))
put(bt(17),pop(700,0.35)); put(bt(19),click(0.9)); put(bt(19)+0.12,whoosh(0.4,False,0.3))
# S4
put(bt(22.2),whoosh(0.5,True,0.5))
t0=bt(23); tot=bt(3.4)
for k in range(int(tot*20)): put(t0+k/20+rng.uniform(0,0.02),tick(0.35))
put(bt(27),pop(760,0.5)); put(bt(27)+0.08,pop(1010,0.3))
# S5
for n in (28.3,30.3,32.2): put(bt(n),thud(48,0.35,0.8))
# S6
put(bt(34)+0.1,whoosh(0.9,True,0.35)); put(bt(37),chime(0.28))
out=out/max(1e-9,np.abs(out).max())*0.9
w=wave.open('sfx.wav','wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes((out*32767).astype('<i2').tobytes()); w.close()
print('ok')
