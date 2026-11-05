//! Local document store: the same layout as the Mac app (`docs(kind, id, sort, json)`), on SQLite.
use rusqlite::{params, Connection};
use serde::{de::DeserializeOwned, Serialize};

pub struct Store { conn: Connection }

impl Store {
    pub fn open(path: Option<&str>) -> rusqlite::Result<Store> {
        let conn = match path { Some(p) => Connection::open(p)?, None => Connection::open_in_memory()? };
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS docs(kind TEXT NOT NULL, id TEXT NOT NULL, sort REAL NOT NULL DEFAULT 0, json TEXT NOT NULL, PRIMARY KEY(kind, id));
            CREATE INDEX IF NOT EXISTS docs_kind_sort ON docs(kind, sort DESC);
            CREATE INDEX IF NOT EXISTS docs_email_thread ON docs(json_extract(json, '$.threadId')) WHERE kind = 'email';")?;
        Ok(Store { conn })
    }

    pub fn put<T: Serialize>(&self, kind: &str, id: &str, sort: f64, value: &T) -> rusqlite::Result<()> {
        let json = serde_json::to_string(value).map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
        self.conn.execute("INSERT INTO docs(kind,id,sort,json) VALUES(?1,?2,?3,?4) ON CONFLICT(kind,id) DO UPDATE SET sort=excluded.sort, json=excluded.json", params![kind, id, sort, json])?;
        Ok(())
    }
    /// Documents that no longer decode are skipped, never an error: stored data from older versions keeps loading.
    pub fn get<T: DeserializeOwned>(&self, kind: &str, id: &str) -> Option<T> {
        let json: String = self.conn.query_row("SELECT json FROM docs WHERE kind=?1 AND id=?2", params![kind, id], |r| r.get(0)).ok()?;
        serde_json::from_str(&json).ok()
    }
    pub fn all<T: DeserializeOwned>(&self, kind: &str, limit: usize) -> Vec<T> {
        let mut st = match self.conn.prepare("SELECT json FROM docs WHERE kind=?1 ORDER BY sort DESC LIMIT ?2") { Ok(s) => s, Err(_) => return vec![] };
        let rows = st.query_map(params![kind, limit as i64], |r| r.get::<_, String>(0));
        match rows { Ok(it) => it.filter_map(|j| j.ok()).filter_map(|j| serde_json::from_str(&j).ok()).collect(), Err(_) => vec![] }
    }
    /// All document IDs without decoding or loading potentially large message bodies.
    pub fn ids(&self, kind: &str) -> rusqlite::Result<Vec<String>> {
        let mut st = self.conn.prepare("SELECT id FROM docs WHERE kind=?1")?;
        let rows = st.query_map(params![kind], |r| r.get(0))?;
        rows.collect()
    }
    pub fn all_where<T: DeserializeOwned>(&self, kind: &str, field: &str, equals: &str) -> Vec<T> {
        let mut st = match self.conn.prepare("SELECT json FROM docs WHERE kind=?1 AND json_extract(json, ?2)=?3") { Ok(s) => s, Err(_) => return vec![] };
        let path = format!("$.{field}");
        let rows = st.query_map(params![kind, path, equals], |r| r.get::<_, String>(0));
        match rows { Ok(it) => it.filter_map(|j| j.ok()).filter_map(|j| serde_json::from_str(&j).ok()).collect(), Err(_) => vec![] }
    }
    pub fn delete(&self, kind: &str, id: &str) -> rusqlite::Result<()> { self.conn.execute("DELETE FROM docs WHERE kind=?1 AND id=?2", params![kind, id])?; Ok(()) }
    pub fn delete_all(&self, kind: &str) -> rusqlite::Result<()> { self.conn.execute("DELETE FROM docs WHERE kind=?1", params![kind])?; Ok(()) }
    pub fn wipe_everything(&self) -> rusqlite::Result<()> { self.conn.execute("DELETE FROM docs", [])?; Ok(()) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;
    #[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
    struct Email { id: String, #[serde(rename = "threadId")] thread_id: String, subject: String, #[serde(default)] attachment_names: Option<Vec<String>> }
    fn e(id: &str, t: &str) -> Email { Email { id: id.into(), thread_id: t.into(), subject: "s".into(), attachment_names: None } }
    #[test] fn put_get_all_delete() {
        let s = Store::open(None).unwrap();
        s.put("email", "a", 1.0, &e("a", "t1")).unwrap(); s.put("email", "b", 2.0, &e("b", "t1")).unwrap();
        assert_eq!(s.get::<Email>("email", "a").unwrap().id, "a");
        assert_eq!(s.all::<Email>("email", 10).iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), ["b", "a"]);
        s.delete("email", "a").unwrap(); assert!(s.get::<Email>("email", "a").is_none());
    }
    #[test] fn thread_lookup_uses_the_json_index() {
        let s = Store::open(None).unwrap();
        for i in 0..50 { s.put("email", &format!("m{i}"), i as f64, &e(&format!("m{i}"), if i % 10 == 0 { "t-hot" } else { "t-cold" })).unwrap(); }
        assert_eq!(s.all_where::<Email>("email", "threadId", "t-hot").len(), 5);
    }
    #[test] fn old_stored_documents_without_new_fields_still_load() {
        let s = Store::open(None).unwrap();
        s.conn.execute("INSERT INTO docs(kind,id,sort,json) VALUES('email','old',0,'{\"id\":\"old\",\"threadId\":\"t\",\"subject\":\"x\"}')", []).unwrap();
        let got: Email = s.get("email", "old").unwrap(); assert_eq!(got.attachment_names, None);
    }
    #[test] fn undecodable_documents_are_skipped_not_fatal() {
        let s = Store::open(None).unwrap();
        s.conn.execute("INSERT INTO docs(kind,id,sort,json) VALUES('task','bad',9,'not json')", []).unwrap();
        s.put("task", "a", 1.0, &e("a", "t")).unwrap();
        assert_eq!(s.all::<Email>("task", 10).len(), 1);
    }
    #[test] fn wipe_clears_everything() { let s = Store::open(None).unwrap(); s.put("x", "1", 0.0, &e("1", "t")).unwrap(); s.wipe_everything().unwrap(); assert!(s.all::<Email>("x", 5).is_empty()); }
}
