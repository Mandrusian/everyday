import json
import numpy as np, wave
SR=44100; B=0.535; bt=lambda n:n*B
N=int(41.6*SR); out=np.zeros(N); rng=np.random.default_rng(7)
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

TL=json.load(open('timeline.json'))
for t in TL['whooshes']: put(t,whoosh(0.35 if t>1 else 1.0,True,0.4))
put(0.7,whoosh(1.0,True,0.45))
for t in TL['thuds']: put(t,thud(55,0.3,0.8))
for t in TL['clicks']: put(t,click(0.9)); put(t+0.01,pop(900,0.18))
for i,t in enumerate(TL['pops']): put(t,pop(560+(i%4)*90,0.4))
for a,b in TL['typing']:
    k=a
    while k<b: put(k,tick(0.35)); k+=rng.uniform(0.035,0.07)
for t in TL['chime']: put(t,chime(0.3))
put(20.0,whoosh(0.3,True,0.35)); put(23.5,whoosh(0.3,False,0.35))
out=out/max(1e-9,np.abs(out).max())*0.9
w=wave.open('sfx.wav','wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes((out*32767).astype('<i2').tobytes()); w.close()
print('ok')
