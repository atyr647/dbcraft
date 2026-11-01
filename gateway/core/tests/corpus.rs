//! adacraft's byte-exact scenario corpus (adacraft/tests/corpus/*.scenario) against the frame splitter.
//!   * every serverbound input the corpus marks `accepted` must be cut by the splitter into whole frames that consume the input exactly;
//!   * the framing scenarios must give the same verdict: a length prefix that is oversize, overlong or negative is `rejected`, a short frame is `incomplete`.
//! (Packet-level verdicts such as an unknown packet id are the database's job, not the gateway's.)
//! The corpus directory comes from ADACRAFT_CORPUS (default: the adacraft checkout next to this repository's workspace); the test is skipped with a notice if it is absent.

use dbcraft_gateway_core::frame::{FrameSplitter, MAX_FRAME};

#[derive(PartialEq, Debug)]
enum Verdict {
    Accepted,
    Rejected,
    Incomplete,
}

/// Cuts `input` the way the gateway does and returns the verdict plus the number of frames.
fn run(input: &[u8]) -> (Verdict, usize) {
    let mut s = FrameSplitter::new();
    s.push(input);
    let mut n = 0;
    loop {
        match s.next(MAX_FRAME) {
            Ok(Some(_)) => n += 1,
            Ok(None) => return if s.buffered() == 0 { (Verdict::Accepted, n) } else { (Verdict::Incomplete, n) },
            Err(_) => return (Verdict::Rejected, n),
        }
    }
}

fn unhex(s: &str) -> Vec<u8> {
    s.split_whitespace().map(|b| u8::from_str_radix(b, 16).unwrap()).collect()
}

#[test]
fn the_framing_scenarios_by_hand() {
    assert_eq!(run(&unhex("80 80 80 01")).0, Verdict::Rejected); // framing-oversize-length
    assert_eq!(run(&unhex("80 80 80 80 80 80 01")).0, Verdict::Rejected); // overlong-varint-length
    assert_eq!(run(&unhex("FF FF FF FF 0F 00")).0, Verdict::Rejected); // negative-length
    assert_eq!(run(&unhex("10 00 89 06")).0, Verdict::Incomplete); // truncated-frame
    assert_eq!(run(&unhex("02 00 00 00")).0, Verdict::Rejected); // length-payload-mismatch: a frame, then a zero length
}

#[test]
fn every_accepted_serverbound_input_of_the_corpus_is_whole_frames() {
    let dir = std::env::var("ADACRAFT_CORPUS").unwrap_or_else(|_| "/home/user/atyr647/adacraft/tests/corpus".to_string());
    let rd = match std::fs::read_dir(&dir) {
        Ok(r) => r,
        Err(_) => {
            eprintln!("SKIPPED: corpus directory {dir} not found (set ADACRAFT_CORPUS)");
            return;
        }
    };
    let (mut checked, mut framing_checked) = (0, 0);
    for e in rd.flatten() {
        let path = e.path();
        if path.extension().and_then(|x| x.to_str()) != Some("scenario") {
            continue;
        }
        let text = std::fs::read_to_string(&path).unwrap();
        let name = path.file_stem().unwrap().to_string_lossy().to_string();
        let (mut dir_, mut input, mut outcome) = (String::new(), String::new(), String::new());
        let mut flush = |dir_: &str, input: &str, outcome: &str| {
            if input.is_empty() || dir_ != "serverbound" {
                return;
            }
            let bytes = unhex(input);
            let (v, n) = run(&bytes);
            match outcome {
                "accepted" => {
                    assert_eq!(v, Verdict::Accepted, "{name}: accepted input is not whole frames ({input})");
                    assert_eq!(n, 1, "{name}: expected exactly one frame ({input})");
                    checked += 1;
                }
                "rejected" | "incomplete" if name.starts_with("framing-") || name.contains("varint") || name.contains("length") || name.contains("truncated") => {
                    let want = if outcome == "rejected" { Verdict::Rejected } else { Verdict::Incomplete };
                    assert_eq!(v, want, "{name}: framing verdict differs ({input})");
                    framing_checked += 1;
                }
                _ => {}
            }
        };
        for line in text.lines() {
            let l = line.trim();
            if l.starts_with("step:") {
                flush(&dir_, &input, &outcome);
                dir_.clear();
                input.clear();
                outcome.clear();
            } else if let Some(v) = l.strip_prefix("direction:") {
                dir_ = v.trim().to_string();
            } else if let Some(v) = l.strip_prefix("input:") {
                input = v.trim().to_string();
            } else if let Some(v) = l.strip_prefix("outcome:") {
                outcome = v.trim().to_string();
            }
        }
        flush(&dir_, &input, &outcome);
    }
    eprintln!("corpus: {checked} accepted inputs and {framing_checked} framing verdicts checked");
    assert!(checked >= 5, "suspiciously few accepted inputs: {checked}");
    assert!(framing_checked >= 4, "suspiciously few framing verdicts: {framing_checked}");
}
