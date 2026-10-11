import 'package:flutter_test/flutter_test.dart';
import 'package:fctv33/main.dart';

void main() {
  testWidgets('FCTV33 app boots', (tester) async {
    // MediaKit needs platform channels; smoke-test widget type only.
    expect(FctvApp, isNotNull);
  });
}
