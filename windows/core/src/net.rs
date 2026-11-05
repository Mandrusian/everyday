//! Secure connections for the mail clients (TLS through the operating system: SChannel on Windows).
use crate::imap::{Imap, ImapError};
use crate::smtp::{self, SmtpError};
use native_tls::{TlsConnector, TlsStream};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::time::Duration;

fn tcp(host: &str, port: u16) -> std::io::Result<TcpStream> {
    let s = TcpStream::connect((host, port))?; s.set_read_timeout(Some(Duration::from_secs(60)))?; s.set_write_timeout(Some(Duration::from_secs(60)))?; Ok(s)
}
pub fn tls(host: &str, port: u16) -> Result<TlsStream<TcpStream>, String> {
    let c = TlsConnector::new().map_err(|e| e.to_string())?;
    c.connect(host, tcp(host, port).map_err(|e| format!("Could not reach {host}: {e}"))?).map_err(|e| format!("Secure connection to {host} failed: {e}"))
}

/// Opens an IMAP session over implicit TLS (port 993) and logs in.
pub fn imap_session(host: &str, port: u16, user: &str, password: &str) -> Result<Imap<TlsStream<TcpStream>>, ImapError> {
    let mut c = Imap::new(tls(host, port).map_err(ImapError::Io)?);
    c.greeting()?; c.login(user, password)?; Ok(c)
}

/// Sends one approved message. Port 465 is implicit TLS; anything else is upgraded with STARTTLS before the password is sent.
pub fn smtp_send(host: &str, port: u16, implicit_tls: bool, user: &str, password: &str, from: &str, to: &[String], message: &[u8]) -> Result<(), SmtpError> {
    if implicit_tls { return smtp::send(tls(host, port).map_err(SmtpError::Io)?, user, password, from, to, message); }
    let mut r = BufReader::new(tcp(host, port)?);
    let mut line = String::new(); r.read_line(&mut line)?;
    r.get_mut().write_all(b"EHLO everyday.local\r\n")?;
    loop { line.clear(); r.read_line(&mut line)?; if line.len() < 4 || line.as_bytes()[3] != b'-' { break; } }
    r.get_mut().write_all(b"STARTTLS\r\n")?; line.clear(); r.read_line(&mut line)?;
    if !line.starts_with("220") { return Err(SmtpError::Rejected("The server would not switch to a secure connection, so the password was not sent.".into())); }
    let plain = r.into_inner();
    let tls = TlsConnector::new().map_err(|e| SmtpError::Io(e.to_string()))?.connect(host, plain).map_err(|e| SmtpError::Io(format!("Secure connection failed: {e}")))?;
    smtp::send_after_greeting(tls, user, password, from, to, message)
}

#[allow(dead_code)]
fn _assert_traits<S: Read + Write>() {}
