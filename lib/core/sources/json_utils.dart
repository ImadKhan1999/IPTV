/// Lenient readers for IPTV panel JSON, where numbers arrive as strings, strings as
/// numbers, and missing values as null, "" or false.
library;

String? jStr(Object? v) {
  if (v == null || v == false) return null;
  final s = v.toString().trim();
  return s.isEmpty || s == 'null' ? null : s;
}

int? jInt(Object? v) {
  if (v is int) return v;
  if (v is double) return v.toInt();
  final s = jStr(v);
  return s == null ? null : (int.tryParse(s) ?? double.tryParse(s)?.toInt());
}

double? jDouble(Object? v) {
  if (v is num) return v.toDouble();
  final s = jStr(v);
  return s == null ? null : double.tryParse(s);
}

bool jBool(Object? v) => v == true || v == 1 || v == '1' || v == 'true';

List<Map<String, dynamic>> jList(Object? v) {
  if (v is List) return v.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  if (v is Map) return v.values.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  return const [];
}

Map<String, dynamic> jMap(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
