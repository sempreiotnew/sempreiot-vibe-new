import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/domain/led/led_language.dart';

/// The LED the wizard draws on the unit being set up follows
/// siot_ui_led.c's patterns for the states the phone can know: SETUP =
/// white blink (BLINK_HALF_TICKS × 50 ms on / off, phase starts "on"),
/// JOINING / OFFLINE = white breathe (BREATHE_PERIOD_TICKS × 50 ms, duty
/// up to BREATHE_MAX_DUTY / 255).
void main() {
  group('white blink (setup mode)', () {
    test('500 ms on, 500 ms off, starting on', () {
      LedLook at(int ms) => ledSetupLook(LedSetupPattern.whiteBlink, ms);
      expect(at(0).color, LedColor.white);
      expect(at(499).color, LedColor.white);
      expect(at(500).lit, isFalse);
      expect(at(999).lit, isFalse);
      expect(at(1000).color, LedColor.white);
      expect(at(0).intensity, 1.0);
    });
  });

  group('white breathe (configured, finding the network)', () {
    LedLook at(int ms) => ledSetupLook(LedSetupPattern.whiteBreathe, ms);

    test('dark at the start, brightest at half the period, dark again', () {
      expect(at(0).lit, isFalse);
      expect(at(ledBreathePeriodMs ~/ 2).color, LedColor.white);
      expect(at(ledBreathePeriodMs ~/ 2).intensity,
          closeTo(ledBreatheMaxDuty, 1e-9));
      expect(at(ledBreathePeriodMs).lit, isFalse);
    });

    test('a triangle: rises then falls, never above the max duty', () {
      final up = at(750).intensity;
      expect(up, closeTo(ledBreatheMaxDuty / 2, 1e-9));
      expect(at(2250).intensity, closeTo(up, 1e-9));
      for (var ms = 0; ms < 2 * ledBreathePeriodMs; ms += 50) {
        expect(at(ms).intensity, lessThanOrEqualTo(ledBreatheMaxDuty));
      }
    });

    test('the period is 3 s, the top about 25 % (siot_ui_led.c)', () {
      expect(ledBreathePeriodMs, 60 * 50);
      expect(ledBreatheMaxDuty, 64 / 255);
      expect(ledBreatheMaxDuty, closeTo(0.25, 0.01));
      expect(LedLook.dark.intensity, 0);
    });
  });
}
