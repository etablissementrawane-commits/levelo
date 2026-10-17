List<Map<String, dynamic>> decodeStoredMaps(dynamic stored) {
  if (stored is! Iterable) return [];
  final decoded = <Map<String, dynamic>>[];
  for (final value in stored) {
    if (value is Map) decoded.add(Map<String, dynamic>.from(value));
  }
  return decoded;
}
