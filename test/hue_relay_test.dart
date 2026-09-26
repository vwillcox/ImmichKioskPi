import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:home_canvas/dashboard/dashboard_model.dart';
import 'package:home_canvas/services/hue_relay.dart';

void main() {
  test('Alexa\'s Hue requests go on; the editor\'s own stay', () {
    for (final hue in [
      '/description.xml',
      '/api',
      '/api/',
      '/api/1f2e3d4c5b6a79880f1e2d3c4b5a6978/lights',
      '/api/1f2e3d4c5b6a79880f1e2d3c4b5a6978/lights/7/state',
      '/api/someone/config',
    ]) {
      expect(HueRelay.handles(hue), isTrue, reason: hue);
    }
    for (final own in [
      '/',
      '/notes',
      '/api/schema',
      '/api/dashboard',
      '/api/volume',
      '/api/sounds/file',
      '/api/background.jpg',
      '/fonts/Inter.ttf',
    ]) {
      expect(HueRelay.handles(own), isFalse, reason: own);
    }
  });

  test('a request and its answer are passed through whole', () async {
    final hue = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    hue.listen((r) async {
      final body = await utf8.decoder.bind(r).join();
      r.response
        ..statusCode = 201
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'method': r.method,
          'path': r.uri.path,
          'query': r.uri.query,
          'body': body,
        }));
      await r.response.close();
    });
    final relay = HueRelay(Uri.parse('http://127.0.0.1:${hue.port}'));
    final front = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    front.listen(relay.forward);

    final client = HttpClient();
    final req = await client.put(
      '127.0.0.1',
      front.port,
      '/api/abc/lights/1/state?x=1',
    );
    req.write('{"on":true}');
    final res = await req.close();
    final got = jsonDecode(await utf8.decoder.bind(res).join());
    expect(res.statusCode, 201);
    expect(got, {
      'method': 'PUT',
      'path': '/api/abc/lights/1/state',
      'query': 'x=1',
      'body': '{"on":true}',
    });

    client.close(force: true);
    await front.close(force: true);
    await hue.close(force: true);
  });

  test('nobody there is a bad gateway, not a hang', () async {
    // A port nothing is listening on.
    final gone = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = gone.port;
    await gone.close(force: true);
    final front = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    front.listen(HueRelay(Uri.parse('http://127.0.0.1:$port')).forward);
    final client = HttpClient();
    final res = await (await client.get('127.0.0.1', front.port, '/api'))
        .close();
    expect(res.statusCode, HttpStatus.badGateway);
    client.close(force: true);
    await front.close(force: true);
  });

  test('off unless asked for, and kept once it is', () {
    final s = DashboardSettings.fromJson({});
    expect(s.webPort, 0);
    expect(s.hueRelay, '');
    final back = DashboardSettings.fromJson(
      (DashboardSettings.fromJson({})
            ..webPort = 80
            ..hueRelay = 'http://10.0.0.2:8300')
          .toJson(),
    );
    expect(back.webPort, 80);
    expect(back.hueRelay, 'http://10.0.0.2:8300');
  });
}
