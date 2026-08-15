import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_kiosk_pi/services/dashboard_service.dart';

void main() {
  group('the senders page is refused off the local network', () {
    bool local(String a) => DashboardService.debugIsLocal(InternetAddress(a));

    test('accepts loopback and home networks', () {
      expect(local('127.0.0.1'), isTrue);
      expect(local('192.168.1.10'), isTrue);
      expect(local('10.0.0.5'), isTrue);
      expect(local('172.16.0.1'), isTrue);
      expect(local('172.31.255.254'), isTrue);
      expect(local('169.254.1.1'), isTrue);
    });

    test('refuses public addresses', () {
      expect(local('8.8.8.8'), isFalse);
      expect(local('1.1.1.1'), isFalse);
      expect(local('93.184.216.34'), isFalse);
    });

    test('refuses addresses that merely look private', () {
      // 172.15 and 172.32 are outside the private range, and 10x/192.1681
      // are ordinary public addresses that a sloppy prefix check would admit.
      expect(local('172.15.0.1'), isFalse);
      expect(local('172.32.0.1'), isFalse);
      expect(local('101.2.3.4'), isFalse);
      expect(local('192.1.68.1'), isFalse);
    });

    test('handles IPv6 loopback and unique-local', () {
      expect(local('::1'), isTrue);
      expect(local('fd00::1'), isTrue);
      expect(local('2606:4700:4700::1111'), isFalse);
    });
  });
}
