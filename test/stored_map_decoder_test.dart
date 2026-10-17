import 'package:flutter_test/flutter_test.dart';
import 'package:habgame/logic/stored_map_decoder.dart';

void main() {
  test('Hive dynamic maps decode into typed app maps', () {
    final hiveValue = <dynamic>[
      <dynamic, dynamic>{'id': 'habit-1', 'title': 'Read'},
    ];
    expect(decodeStoredMaps(hiveValue), [
      {'id': 'habit-1', 'title': 'Read'},
    ]);
  });

  test('missing or non-list values decode as an empty list', () {
    expect(decodeStoredMaps(null), isEmpty);
    expect(decodeStoredMaps('unexpected'), isEmpty);
  });
}
