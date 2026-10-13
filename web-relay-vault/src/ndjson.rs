//! NDJSON framing: one JSON value per `\n`-terminated line, UTF-8. Same caps as
//! the page (`web-relay/src/fips/nip01.js`): a line over 512 KiB is a protocol
//! error.

use serde_json::Value;

pub const MAX_LINE: usize = 512 * 1024;

#[derive(Debug, PartialEq)]
pub enum FrameError {
    LineTooLong,
    BadJson(String),
}

#[derive(Default)]
pub struct LineDecoder {
    buf: Vec<u8>,
}

impl LineDecoder {
    /// Feed stream bytes, get back every complete line as JSON.
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<Value>, FrameError> {
        self.buf.extend_from_slice(bytes);
        let mut out = Vec::new();
        while let Some(nl) = self.buf.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = self.buf.drain(..=nl).collect();
            let line = &line[..line.len() - 1];
            if line.len() > MAX_LINE {
                return Err(FrameError::LineTooLong);
            }
            if line.iter().all(u8::is_ascii_whitespace) {
                continue;
            }
            out.push(serde_json::from_slice(line).map_err(|e| FrameError::BadJson(e.to_string()))?);
        }
        if self.buf.len() > MAX_LINE {
            return Err(FrameError::LineTooLong);
        }
        Ok(out)
    }
}

pub fn encode(message: &Value) -> Vec<u8> {
    // serde_json escapes newlines inside strings, so the only `\n` is the terminator.
    let mut line = serde_json::to_vec(message).expect("a JSON value always serializes");
    line.push(b'\n');
    line
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn splits_lines_across_chunks() {
        let mut d = LineDecoder::default();
        let a = encode(&json!(["EOSE", "s"]));
        let b = encode(&json!(["NOTICE", "two\nlines"]));
        let all = [a, b].concat();
        let (x, y) = all.split_at(7);
        assert!(d.push(x).unwrap().is_empty());
        let got = d.push(y).unwrap();
        assert_eq!(got, vec![json!(["EOSE", "s"]), json!(["NOTICE", "two\nlines"])]);
    }

    #[test]
    fn refuses_an_unterminated_line_over_the_cap() {
        let mut d = LineDecoder::default();
        assert_eq!(d.push(&vec![b'a'; MAX_LINE + 1]), Err(FrameError::LineTooLong));
    }
}
