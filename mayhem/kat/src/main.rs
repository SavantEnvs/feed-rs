// mayhem/kat — known-answer-test probe for mayhem/test.sh.
//
// See mayhem/kat/Cargo.toml for why this exists as a separate, dynamically linked binary rather
// than relying on `cargo test` alone.
//
// Exercises three of the parser modules the mayhem `parse` fuzz target covers (Atom, RSS 1.0/RDF,
// JSON Feed) via the real public `feed_rs::parser::parse` entry point, against FIXED fixtures
// already shipped by upstream under feed-rs/fixture/, and prints the exact computed values as
// `KAT_<NAME>=<value>`. mayhem/test.sh matches each line EXACTLY (grep -qxF). Fixtures are pulled
// in at COMPILE time via include_str! (not read from disk at runtime) so the probe's behavior
// can't depend on the process's working directory.
use feed_rs::parser::parse;

const ATOM_SPEC: &str = include_str!("../../../feed-rs/fixture/atom/atom_spec_1.xml");
const RSS1_SPEC: &str = include_str!("../../../feed-rs/fixture/rss1/rss_1.0_spec_1.xml");
const JSONFEED_SPEC: &str = include_str!("../../../feed-rs/fixture/jsonfeed/jsonfeed_spec_1.json");

fn main() {
    // 1) Atom (feed-rs/fixture/atom/atom_spec_1.xml — the Atom spec's own worked example, also
    //    used by upstream's own parser::atom::tests). Assert the feed title, entry count, the
    //    single entry's `updated` timestamp (Atom's per-entry "published" analogue), and the
    //    entry's link href — drives XML parsing + namespace dispatch + timestamp parsing + the
    //    Atom entry model conversion.
    let atom = parse(ATOM_SPEC.as_bytes()).unwrap_or_else(|e| panic!("kat: failed to parse atom_spec_1.xml: {e:?}"));
    let title = atom.title.as_ref().unwrap_or_else(|| panic!("kat: atom feed has no title")).content.clone();
    println!("KAT_ATOM_TITLE={title}");
    println!("KAT_ATOM_ENTRY_COUNT={}", atom.entries.len());
    let entry = atom.entries.first().unwrap_or_else(|| panic!("kat: atom feed has no entries"));
    let updated = entry.updated.unwrap_or_else(|| panic!("kat: atom entry has no 'updated' timestamp"));
    println!("KAT_ATOM_ENTRY_UPDATED={}", updated.to_rfc3339());
    let link = entry.links.first().unwrap_or_else(|| panic!("kat: atom entry has no links"));
    println!("KAT_ATOM_ENTRY_LINK={}", link.href);

    // 2) RSS 1.0 / RDF (feed-rs/fixture/rss1/rss_1.0_spec_1.xml — the RSS 1.0 spec's own example).
    //    A distinct parser module (rdf:RDF root dispatch) from both Atom and RSS 2. Assert the
    //    channel title, item count, and the first item's link.
    let rss1 = parse(RSS1_SPEC.as_bytes()).unwrap_or_else(|e| panic!("kat: failed to parse rss_1.0_spec_1.xml: {e:?}"));
    let title = rss1.title.as_ref().unwrap_or_else(|| panic!("kat: rss1 feed has no title")).content.clone();
    println!("KAT_RSS1_TITLE={title}");
    println!("KAT_RSS1_ENTRY_COUNT={}", rss1.entries.len());
    let entry = rss1.entries.first().unwrap_or_else(|| panic!("kat: rss1 feed has no entries"));
    let link = entry.links.first().unwrap_or_else(|| panic!("kat: rss1 entry has no links"));
    println!("KAT_RSS1_ENTRY_LINK={}", link.href);

    // 3) JSON Feed (feed-rs/fixture/jsonfeed/jsonfeed_spec_1.json — the JSON Feed spec's own
    //    example). Drives the OTHER half of the sniffing dispatch in parser::parse (first
    //    non-whitespace byte '{' instead of '<') and the serde_json-based JSON Feed parser.
    //    Assert the feed title, item count, the item's `date_published` (converted to UTC), and
    //    its url.
    let jf = parse(JSONFEED_SPEC.as_bytes()).unwrap_or_else(|e| panic!("kat: failed to parse jsonfeed_spec_1.json: {e:?}"));
    let title = jf.title.as_ref().unwrap_or_else(|| panic!("kat: jsonfeed has no title")).content.clone();
    println!("KAT_JSONFEED_TITLE={title}");
    println!("KAT_JSONFEED_ENTRY_COUNT={}", jf.entries.len());
    let entry = jf.entries.first().unwrap_or_else(|| panic!("kat: jsonfeed has no entries"));
    let published = entry.published.unwrap_or_else(|| panic!("kat: jsonfeed entry has no 'published' timestamp"));
    println!("KAT_JSONFEED_ENTRY_PUBLISHED={}", published.to_rfc3339());
    let link = entry.links.first().unwrap_or_else(|| panic!("kat: jsonfeed entry has no links"));
    println!("KAT_JSONFEED_ENTRY_LINK={}", link.href);
}
