import Foundation

/// Word matching for chat retrieval and library search that forgives word
/// forms: "decide" finds "decision", "price" finds "pricing", "start" finds
/// "starting".
///
/// Exact matching missed the obvious — "what did we decide" found nothing in a
/// transcript that said "decision" — and the miss is silent: chat answers "your
/// meetings don't mention that" about something they plainly do. A stemmer is
/// deliberately the whole fix rather than an embedding model: it is
/// deterministic, testable, instant, and has nothing to download.
public enum SearchTerms {
    /// Shortest stem allowed to match by prefix. Below this, "sam" would match
    /// "same" and "plan" would be the only thing standing between "pla" and
    /// "plastic".
    static let minimumPrefixStem = 4

    /// Suffixes stripped to reach a stem, longest first so "ations" is tried
    /// before "s".
    private static let suffixes = [
        "ational", "ations", "ation", "itions", "ition", "sions", "sion", "tions", "tion",
        "ments", "ment", "ingly", "ings", "ing", "edly", "ers", "er", "ed", "ies", "es",
        "ly", "s",
    ]

    /// A light stem: lowercase, common inflectional and derivational suffixes
    /// removed, trailing "e" dropped. Not linguistically exact — it only has to
    /// make related forms share a prefix.
    public static func stem(_ word: String) -> String {
        var stem = word.lowercased()
        guard stem.count > 4, stem.allSatisfy(\.isLetter) else { return stem }
        for suffix in suffixes where stem.hasSuffix(suffix) && stem.count - suffix.count >= 3 {
            stem.removeLast(suffix.count)
            if suffix == "ies" { stem += "y" }
            break
        }
        if stem.count > 4, stem.hasSuffix("e") { stem.removeLast() }
        return stem
    }

    /// Whether a question word and a text word are the same word in another
    /// form: identical, or one stem a prefix of the other with enough letters
    /// in common to mean something.
    public static func matches(_ query: String, _ word: String) -> Bool {
        if query == word { return true }
        let a = stem(query)
        let b = stem(word)
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= minimumPrefixStem && long.hasPrefix(short)
    }

    /// How many of `terms` appear, in some form, among `words`.
    public static func matchCount(_ terms: Set<String>, in words: Set<String>) -> Int {
        terms.filter { term in
            words.contains(term) || words.contains { matches(term, $0) }
        }.count
    }

    /// Whether every word of `query` appears somewhere in `text`, in some form.
    /// The library's search box: typing "acme pricing" keeps only meetings that
    /// mention both.
    public static func text(_ text: String, matchesQuery query: String) -> Bool {
        let terms = Set(Transcript.normalize(query))
        guard !terms.isEmpty else { return true }
        let words = Set(Transcript.normalize(text))
        return matchCount(terms, in: words) == terms.count
    }
}
