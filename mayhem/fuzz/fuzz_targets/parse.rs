#![no_main]

// Preserved from the legacy mayhemheroes integration (refs/legacy/mayhem:mayhem/fuzz/fuzz_targets/parse.rs):
// exercise feed_rs::parser::parse, the single public entry point that sniffs the input (first
// non-whitespace byte '<' vs '{') and dispatches to the Atom / RSS 0.9x / RSS 1.0 / RSS 2.0 XML
// parsers or the JSON Feed parser. A parse error (`Result::Err`) is an EXPECTED outcome for
// malformed/partial input — only a panic or sanitizer trip is a finding.
use feed_rs::parser::parse;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = parse(data);
});
