import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/device_update_words.dart';
import 'package:sempreiot_central_app/features/central/domain/ota/firmware_version.dart';

void main() {
  group('a firmware that is not newer than what the units run', () {
    test('the same version', () {
      expect(deviceUpdateNotNewerText('0.2.5', ['0.2.5', '0.2.5']),
          'É a versão que eles já rodam');
      expect(deviceUpdateNotNewerText('0.2.5', ['0.2.5']),
          'É a versão que ele já roda');
    });

    test('an older version says so, and what they run (bench 2026-10-02)', () {
      // Units on 2.2.5 (a build meant as 0.2.5): 0.2.6 is OLDER, not "the
      // version they already run".
      expect(compareFirmwareVersions('0.2.6', '2.2.5'), lessThan(0));
      expect(deviceUpdateNotNewerText('0.2.6', ['2.2.5', '2.2.5', '2.2.5']),
          'Mais antiga que a que eles rodam (v2.2.5)');
      expect(deviceUpdateNotNewerText('0.2.6', ['0.2.6', '2.2.5']),
          'Mais antiga que a que eles rodam (v2.2.5)');
    });
  });

  test('what the chosen units run', () {
    expect(deviceUpdateRunsText(['0.2.5']), 'roda v0.2.5');
    expect(deviceUpdateRunsText(['0.2.5', '0.2.5']), 'rodam v0.2.5');
    expect(
        deviceUpdateRunsText(['2.2.5', '0.2.5', '']), 'rodam v0.2.5 a v2.2.5');
    expect(deviceUpdateRunsText(['', '']), '');
  });

  test('semver order', () {
    expect(compareFirmwareVersions('0.2.6', '0.2.5'), greaterThan(0));
    expect(compareFirmwareVersions('0.1.1-dev', '0.1.1'), lessThan(0));
    expect(compareFirmwareVersions('v0.2.0', '0.2.0'), 0);
    expect(compareFirmwareVersions('0.10.0', '0.9.9'), greaterThan(0));
  });

  test('newer, the same, or older than what they run', () {
    expect(deviceUpdateVersionKind('0.2.6', ['0.2.5', '0.2.5']),
        DeviceUpdateVersionKind.newer);
    expect(deviceUpdateVersionKind('0.2.6', ['0.2.6', '']),
        DeviceUpdateVersionKind.newer,
        reason: 'one never said');
    expect(deviceUpdateVersionKind('0.2.6', ['0.2.6', '0.2.6']),
        DeviceUpdateVersionKind.same);
    expect(deviceUpdateVersionKind('0.2.6', ['2.2.5']),
        DeviceUpdateVersionKind.older);
    expect(
        deviceUpdateConfirmText(DeviceUpdateVersionKind.older, '0.2.6',
            all: false),
        'Voltar para v0.2.6');
    expect(
        deviceUpdateConfirmText(DeviceUpdateVersionKind.same, '0.2.6',
            all: true),
        'Reinstalar tudo (v0.2.6)');
    expect(deviceUpdateAskFirst(DeviceUpdateVersionKind.newer, '0.2.6', []),
        isNull);
    final back = deviceUpdateAskFirst(
        DeviceUpdateVersionKind.older, '0.2.6', ['2.2.5', '2.2.5'])!;
    expect(back.title, 'Voltar para uma versão anterior?');
    expect(back.body, startsWith('Rodam v2.2.5 e vão para v0.2.6'));
  });
}
