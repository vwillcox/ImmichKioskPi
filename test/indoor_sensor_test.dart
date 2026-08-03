import 'package:flutter_test/flutter_test.dart';
import 'package:immich_kiosk_pi/services/indoor_sensor_service.dart';

const hci0 = '/org/bluez/hci0'; // Pi's built-in radio — also carries A2DP
const hci1 = '/org/bluez/hci1'; // USB dongle

void main() {
  group('adapter choice', () {
    test('uses the only controller when there is just one', () {
      expect(IndoorSensorService.chooseAdapter([hci0], {}), hci0);
    });

    test('prefers the USB dongle over the built-in radio', () {
      expect(IndoorSensorService.chooseAdapter([hci0, hci1], {}), hci1);
    });

    test('never scans on the controller carrying audio', () {
      expect(IndoorSensorService.chooseAdapter([hci0, hci1], {hci1}), hci0);
    });

    test('order of discovery does not matter', () {
      expect(IndoorSensorService.chooseAdapter([hci1, hci0], {}), hci1);
    });

    test('falls back to a busy controller rather than giving up', () {
      expect(
          IndoorSensorService.chooseAdapter([hci0, hci1], {hci0, hci1}), hci1);
    });

    test('falls back to hci0 when BlueZ reports no controllers', () {
      expect(IndoorSensorService.chooseAdapter([], {}), hci0);
    });
  });

  group('Govee decode', () {
    test('matches the reading on the device screen', () {
      // Captured from the real H5104 while its display read 29.3 / 45%.
      final r = IndoorSensorService.decode([0x01, 0x01, 0x04, 0x7a, 0x4b, 0x08]);
      expect(r, isNotNull);
      expect(r!['temp'], closeTo(29.3, 0.001));
      expect(r['hum'], closeTo(45.1, 0.001));
      expect(r['batt'], 8);
    });

    test('temperature uses integer division, not 1/10000', () {
      // Dividing by 10000 would give 29.0446 — humidity digits as false
      // precision. The temperature is only ever a tenth of a degree.
      final r = IndoorSensorService.decode([0x01, 0x01, 0x04, 0x6d, 0xce, 0x50]);
      expect(r!['temp'], closeTo(29.0, 0.001));
    });

    test('rejects a payload that is too short to be a reading', () {
      expect(IndoorSensorService.decode([0x01, 0x01, 0x04]), isNull);
    });

    test('rejects out-of-range values from a garbled advert', () {
      expect(IndoorSensorService.decode([0x00, 0x00, 0x7f, 0xff, 0xff, 0x50]),
          isNull);
    });
  });
}
