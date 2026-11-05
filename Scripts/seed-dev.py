#!/usr/bin/env python3
"""Fills the DEV database (everyday-dev.sqlite) with invented mail so screens can be checked without touching real data."""
import sqlite3, json, os, datetime, subprocess
db = os.path.expanduser("~/Library/Application Support/everyday/everyday-dev.sqlite")
os.makedirs(os.path.dirname(db), exist_ok=True)
c = sqlite3.connect(db)
c.execute("CREATE TABLE IF NOT EXISTS docs(kind TEXT NOT NULL, id TEXT NOT NULL, sort REAL NOT NULL DEFAULT 0, json TEXT NOT NULL, PRIMARY KEY(kind, id))")
c.execute("DELETE FROM docs WHERE kind IN ('email','triage','briefing','taskSuggestion','handledThread','mailRule','bundleSummary')")
now = datetime.datetime.now(datetime.timezone.utc)
def iso(m): return (now - datetime.timedelta(minutes=m)).strftime("%Y-%m-%dT%H:%M:%SZ")
mails = [
 ("g1","no-reply@accounts.google.com","Google","App password created","A new app password was created for your Google account.",12,"important",78,"An app password was created for your account; check your security activity if this wasn't you.",None,["Check security activity"],False),
 ("g2","no-reply@accounts.google.com","Google","App password removed","An app password was removed.",35,"important",70,"An app password used to sign in to your account was removed.",None,[],False),
 ("g3","no-reply@accounts.google.com","Google","Security alert: new sign-in","New sign-in on a Mac.",70,"important",76,"A new sign-in on a Mac was detected.",None,["Check sign-in"],False),
 ("g4","noreply@google.com","Google One","Final reminder: update payment details","Update by November 6.",120,"deadline",88,"Final reminder to update your Google One payment details by November 6.","2026-11-06T09:00:00Z",["Update payment details"],False),
 ("d1","dana.whitfield@example.com","Dana Whitfield","Thursday roadmap sync","Does 3pm still work, and who presents?",25,"needsReply",85,"Dana asks if Thursday 3pm still works and who presents the Q1 plan.",None,["Confirm attendance"],True),
 ("n1","hello@importai.example.com","Import AI","Import AI 412","Weekly newsletter on AI research.",300,"newsletter",12,"Weekly AI research newsletter.",None,[],False),
 ("n2","news@thenewsletter.example.com","The Newsletter","Your Thursday briefing","Top stories.",360,"newsletter",10,"A daily digest of top stories.",None,[],False),
 ("n3","updates@shop.example.com","Shoe Shop","50% off this weekend","Sale.",500,"promo",5,"Promotional sale email.",None,[],False),
]
for (id,addr,name,subj,snip,ago,cat,pr,summ,dl,items,reply) in mails:
    m = {"id":id,"threadId":"t"+id,"fromName":name,"fromAddress":addr,"to":"me@example.com","subject":subj,"snippet":snip,"body":snip+"\n\nThis is invented demo mail.","date":iso(ago),"labelIds":["INBOX","UNREAD"],"hasAttachments":False,"messageIdHeader":"<"+id+"@demo>"}
    t = {"messageId":id,"category":cat,"priority":pr,"summary":summ,"actionItems":items,"needsReply":reply,"promptVersion":1}
    if dl: t["deadline"]=dl
    ts = (now - datetime.timedelta(minutes=ago)).timestamp()
    c.execute("INSERT OR REPLACE INTO docs VALUES('email',?,?,?)",(id,ts,json.dumps(m)))
    c.execute("INSERT OR REPLACE INTO docs VALUES('triage',?,?,?)",(id,pr,json.dumps(t)))
brief = {"generatedAt":iso(1),"model":"demo","emailCount":8,"storyCount":10,"eventCount":0,
 "text":"<<u|Update your Google One payment details>> by <<d|Friday 6 November>> to keep access. <<p|Dana>> is waiting on a reply about the <<d|Thursday>> roadmap sync. Google also sent <<u|three account security notices>> today. It is <<n|30°C>> in <<n|Cairns>>.",
 "replies":[{"id":"r1","label":"That was me","kind":"handled","messageIds":["g1","g2","g3"],"text":""},{"id":"r2","label":"Add payment as task","kind":"task","messageIds":["g4"],"text":""},{"id":"r3","label":"Remind me tonight","kind":"remind","messageIds":["d1"],"text":""},{"id":"r4","label":"What were the sign-ins?","kind":"ask","messageIds":["g3"],"text":"What were the new sign-ins about?"}]}
c.execute("INSERT OR REPLACE INTO docs VALUES('briefing','latest',0,?)",(json.dumps(brief),))
c.commit(); c.close()
suite = "everyday.app.dev"
for k,v in [("mail.backend","gmail"),("google.email","demo@example.com"),("onboarded",True),("userName","Xavi")]:
    subprocess.run(["defaults","write",suite,k,"-bool" if v is True else "-string","YES" if v is True else str(v)],check=True)
print("seeded", db)
