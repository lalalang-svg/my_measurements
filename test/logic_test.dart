import 'package:flutter_test/flutter_test.dart';
import 'package:my_measurements/main.dart';

Reading example(String context) => Reading.fromMap({
  'id': 1, 'measured_at': '2026-03-03T09:00', 'pulse': 80,
  'systolic': 130, 'diastolic': 85,
  'glucose_tenths': 56, 'glucose_context': context, 'note': '',
});

void main() {
  test('03.03 без условий не классифицируется', () {
    expect(resultFor(example('unknown'), 55), contains('сравнение недоступно'));
    expect(resultFor(example('unknown'), 55), isNot(contains('выше')));
  });
  test('04.03 натощак сравнивается с личным ориентиром', () {
    expect(resultFor(example('fasting'), 55), contains('5.6 выше личного ориентира 5.5'));
  });
  test('сотые доли глюкозы не принимаются', () {
    expect(() => parseGlucose('5,65'), throwsFormatException);
  });
}
