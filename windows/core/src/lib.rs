//! everyday. core logic, ported one for one from the Swift `EverydayCore` so the Mac and Windows apps behave the same.
//! Every module has tests copied from the Swift checks (`Sources/EverydayChecks/main.swift`).
pub mod ai;
pub mod briefing;
pub mod bundler;
pub mod citations;
pub mod calendar;
pub mod chat;
pub mod imap;
pub mod interest;
pub mod mailrules;
pub mod mime;
pub mod net;
pub mod news;
pub mod service;
pub mod secrets;
pub mod quickadd;
pub mod repeat;
pub mod schedule;
pub mod tasks;
pub mod tts;
pub mod skim;
pub mod smtp;
pub mod store;
pub mod updates;
