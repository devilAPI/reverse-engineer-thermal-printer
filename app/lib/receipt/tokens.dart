/// Placeholder tokens expanded at render time:
///
/// | Token | Example |
/// |---|---|
/// | `{date}` | 2026-11-15 |
/// | `{time}` | 14:05 |
/// | `{datetime}` | 2026-11-15 14:05 |
/// | `{date:dd.MM.yyyy HH:mm:ss}` | custom pattern: yyyy yy MM dd HH mm ss |
/// | `{n}` / `{n:0000}` | running number, optionally zero-padded |
///
/// Unknown `{...}` sequences are left untouched; `{{` prints a literal `{`.
class TokenContext {
  const TokenContext({required this.now, this.number = 1});

  final DateTime now;
  final int number;
}

final _token = RegExp(r'\{\{|\{(date|time|datetime|n)(?::([^{}]*))?\}');

String expandTokens(String s, TokenContext c) {
  if (!s.contains('{')) return s;
  return s.replaceAllMapped(_token, (m) {
    if (m[0] == '{{') return '{';
    final arg = m[2];
    switch (m[1]) {
      case 'date':
        return formatDate(c.now, arg ?? 'yyyy-MM-dd');
      case 'time':
        return formatDate(c.now, arg ?? 'HH:mm');
      case 'datetime':
        return formatDate(c.now, arg ?? 'yyyy-MM-dd HH:mm');
      case 'n':
        final n = '${c.number}';
        return arg != null && RegExp(r'^0+$').hasMatch(arg) ? n.padLeft(arg.length, '0') : n;
    }
    return m[0]!;
  });
}

/// True if [s] uses the running number (the counter advances when printed).
bool usesCounter(String s) => RegExp(r'\{n(:[^{}]*)?\}').hasMatch(s);

/// Minimal date pattern formatter (no locale data needed):
/// yyyy, yy, MM, dd, HH, mm, ss; everything else is copied.
String formatDate(DateTime t, String pattern) {
  String two(int v) => v.toString().padLeft(2, '0');
  return pattern.replaceAllMapped(RegExp('yyyy|yy|MM|dd|HH|mm|ss'), (m) => switch (m[0]) {
        'yyyy' => t.year.toString().padLeft(4, '0'),
        'yy' => two(t.year % 100),
        'MM' => two(t.month),
        'dd' => two(t.day),
        'HH' => two(t.hour),
        'mm' => two(t.minute),
        _ => two(t.second),
      });
}
