import 'dart:js_interop';

@JS('dismissFctvBoot')
external void _dismissFctvBoot();

void dismissWebBoot() {
  try {
    _dismissFctvBoot();
  } catch (_) {
    // Boot already gone or running outside browser.
  }
}
