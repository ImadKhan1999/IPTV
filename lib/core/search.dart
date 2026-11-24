/// Forgiving text matching for search: ignores case, accents, punctuation and word order.
///
/// "bbc news" finds "BBC World News HD"; "cafe" finds "Café TV".
class SearchQuery {
  SearchQuery(String text) : words = normalize(text).split(' ').where((w) => w.isNotEmpty).toList();

  final List<String> words;

  bool get isEmpty => words.isEmpty;

  /// True when every word of the query appears in [text].
  bool matches(String text) {
    if (words.isEmpty) return false;
    final t = normalize(text);
    for (final w in words) {
      if (!t.contains(w)) return false;
    }
    return true;
  }

  /// Lower is better: exact name, then names starting with the query, then words starting with it.
  int rank(String text) {
    final t = normalize(text);
    final q = words.join(' ');
    if (t == q) return 0;
    if (t.startsWith(q)) return 1;
    if (t.split(' ').any((w) => w.startsWith(words.first))) return 2;
    return 3;
  }

  /// Items whose [name] matches, best first, at most [limit].
  List<T> filter<T>(Iterable<T> items, String Function(T) name, {int limit = 80}) {
    final hits = [
      for (final i in items)
        if (matches(name(i))) i,
    ];
    hits.sort((a, b) => rank(name(a)).compareTo(rank(name(b))));
    return hits.take(limit).toList();
  }

  static const _accents = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', //
    'ë': 'e', 'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ñ': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o',
    'ö': 'o', 'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ý': 'y', 'ÿ': 'y', 'ş': 's', 'ğ': 'g', 'ı': 'i',
  };

  static final _punct = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

  static String normalize(String s) {
    final lower = s.toLowerCase();
    final b = StringBuffer();
    for (final ch in lower.split('')) {
      b.write(_accents[ch] ?? ch);
    }
    return b.toString().replaceAll(_punct, ' ').trim();
  }
}
