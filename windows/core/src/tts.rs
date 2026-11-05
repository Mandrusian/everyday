//! Natural voices through Gemini speech models: request building, PCM to WAV, and splitting long text into sentence-sized chunks.
//! The text is sent to Google with the reader's own key only when they choose a natural voice; otherwise the system voice is used.
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::{json, Value};

pub const VOICES_MALE: &[&str] = &["Charon", "Achird", "Iapetus", "Orus", "Algenib", "Fenrir", "Puck", "Enceladus", "Umbriel", "Schedar"];

/// `style` is spoken aloud by the model, so it is left empty by default.
pub fn request_body(text: &str, voice: &str, style: &str) -> Value {
    let prompt = if style.trim().is_empty() { text.to_string() } else { format!("{style}: {text}") };
    json!({"contents": [{"parts": [{"text": prompt}]}], "generationConfig": {"responseModalities": ["AUDIO"], "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": voice}}}}})
}
pub fn url(model: &str) -> String { format!("https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent") }

/// The base64 PCM (24 kHz, 16-bit, mono) inside a response.
pub fn pcm_from_response(body: &str) -> Result<Vec<u8>, String> {
    let v: Value = serde_json::from_str(body).map_err(|_| "The speech service returned something unreadable.".to_string())?;
    if let Some(m) = v["error"]["message"].as_str() { return Err(m.to_string()); }
    let data = v["candidates"][0]["content"]["parts"].as_array().and_then(|p| p.iter().find_map(|x| x["inlineData"]["data"].as_str())).ok_or("The speech service returned no audio.")?;
    B64.decode(data).map_err(|e| e.to_string())
}

pub fn wav(pcm: &[u8], sample_rate: u32) -> Vec<u8> {
    let (ch, bits) = (1u16, 16u16); let byte_rate = sample_rate * ch as u32 * bits as u32 / 8;
    let mut w = Vec::with_capacity(44 + pcm.len());
    w.extend(b"RIFF"); w.extend((36 + pcm.len() as u32).to_le_bytes()); w.extend(b"WAVEfmt "); w.extend(16u32.to_le_bytes()); w.extend(1u16.to_le_bytes());
    w.extend(ch.to_le_bytes()); w.extend(sample_rate.to_le_bytes()); w.extend(byte_rate.to_le_bytes()); w.extend((ch * bits / 8).to_le_bytes()); w.extend(bits.to_le_bytes());
    w.extend(b"data"); w.extend((pcm.len() as u32).to_le_bytes()); w.extend(pcm); w
}

/// Sentence-sized pieces (about `max` characters) so the first sound starts quickly and the next piece can be fetched while one plays.
pub fn chunks(text: &str, max: usize) -> Vec<String> {
    let mut out = vec![]; let mut cur = String::new();
    for s in text.split_inclusive(|c| ".!?\n".contains(c)) {
        if !cur.is_empty() && cur.chars().count() + s.chars().count() > max { out.push(cur.trim().to_string()); cur.clear(); }
        cur.push_str(s);
    }
    if !cur.trim().is_empty() { out.push(cur.trim().to_string()); }
    out
}

/// Disk-cache key: the same text, voice and model always map to the same file.
pub fn cache_key(text: &str, voice: &str, model: &str) -> String {
    let mut h: u64 = 0xcbf29ce484222325; for b in format!("{model}|{voice}|{text}").bytes() { h ^= b as u64; h = h.wrapping_mul(0x100000001b3); } format!("{h:016x}.wav")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn the_request_asks_for_audio_with_the_chosen_voice_and_no_spoken_direction() {
        let b = request_body("Good morning.", "Charon", ""); assert_eq!(b["contents"][0]["parts"][0]["text"], "Good morning.");
        assert_eq!(b["generationConfig"]["speechConfig"]["voiceConfig"]["prebuiltVoiceConfig"]["voiceName"], "Charon"); assert_eq!(b["generationConfig"]["responseModalities"][0], "AUDIO");
        assert_eq!(request_body("x", "Puck", "Say calmly")["contents"][0]["parts"][0]["text"], "Say calmly: x");
    }
    #[test] fn audio_is_read_from_the_response_and_errors_are_explained() {
        let pcm = [1u8, 0, 2, 0, 3, 0]; let body = format!(r#"{{"candidates":[{{"content":{{"parts":[{{"inlineData":{{"mimeType":"audio/L16;rate=24000","data":"{}"}}}}]}}}}]}}"#, B64.encode(pcm));
        assert_eq!(pcm_from_response(&body).unwrap(), pcm);
        assert_eq!(pcm_from_response(r#"{"error":{"message":"quota"}}"#).unwrap_err(), "quota"); assert!(pcm_from_response(r#"{"candidates":[]}"#).is_err());
    }
    #[test] fn wav_has_a_valid_header_for_24khz_16bit_mono() {
        let w = wav(&[0u8; 100], 24000);
        assert_eq!(&w[0..4], b"RIFF"); assert_eq!(&w[8..12], b"WAVE"); assert_eq!(u32::from_le_bytes(w[24..28].try_into().unwrap()), 24000);
        assert_eq!(u32::from_le_bytes(w[28..32].try_into().unwrap()), 48000); assert_eq!(u32::from_le_bytes(w[40..44].try_into().unwrap()), 100); assert_eq!(w.len(), 144);
    }
    #[test] fn long_text_splits_on_sentences() {
        let c = chunks("First one. Second one is a bit longer. Third.", 25); assert_eq!(c, ["First one.", "Second one is a bit longer.", "Third."]);
        assert_eq!(chunks("Short.", 200), ["Short."]); assert!(chunks("   ", 10).is_empty());
    }
    #[test] fn the_cache_key_depends_on_text_voice_and_model() {
        assert_eq!(cache_key("a", "Charon", "m"), cache_key("a", "Charon", "m")); assert_ne!(cache_key("a", "Charon", "m"), cache_key("a", "Puck", "m")); assert_ne!(cache_key("a", "Charon", "m"), cache_key("b", "Charon", "m"));
    }
}
