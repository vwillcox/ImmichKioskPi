import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'media_cache.dart';

/// One recorded sample from the indoor sensor.
class IndoorReading {
  final DateTime time;
  final double temperatureC;
  final double humidity;

  const IndoorReading({
    required this.time,
    required this.temperatureC,
    required this.humidity,
  });

  Map<String, dynamic> toJson() => {
        't': time.millisecondsSinceEpoch,
        'c': temperatureC,
        'h': humidity,
      };

  static IndoorReading? fromJson(dynamic j) {
    if (j is! Map) return null;
    final t = j['t'], c = j['c'], h = j['h'];
    if (t is! num || c is! num || h is! num) return null;
    return IndoorReading(
      time: DateTime.fromMillisecondsSinceEpoch(t.toInt()),
      temperatureC: c.toDouble(),
      humidity: h.toDouble(),
    );
  }
}

/// Reads a Govee H510x thermometer/hygrometer over Bluetooth LE.
///
/// The sensor broadcasts its reading in the manufacturer data of its BLE
/// advertisements, so nothing needs pairing or connecting — the Pi just has to
/// be scanning. Govee packs temperature and humidity into one 3-byte
/// big-endian value:
///
///     temperature °C = (value ~/ 1000) / 10
///     humidity %     = (value % 1000) / 10
///
/// with bit 0x800000 marking a negative temperature, followed by a battery
/// percentage byte. Verified against a real H5104 and its own display:
/// `01 01 04 7a 4b 08` decodes to 29.3 °C / 45.1 %RH, matching the screen.
///
/// The sensor stores its own history internally, but exporting that needs
/// Govee's proprietary GATT protocol. Instead this records one reading an hour
/// of its own, so the chart fills out from the moment the kiosk starts.
class IndoorSensorService extends ChangeNotifier {
  static const String _bluez = 'org.bluez';
  static const String _adapterPath = '/org/bluez/hci0';
  static const String _deviceIface = 'org.bluez.Device1';
  static const String _adapterIface = 'org.bluez.Adapter1';

  /// Govee thermometer/hygrometer models advertise as GVH5xxx.
  static final RegExp _namePattern = RegExp(r'^GVH5\d{3}');

  /// How often to wake the radio and take a reading. BLE scanning and A2DP
  /// share one antenna, so a permanent scan makes music from the paired phone
  /// stutter. Indoor temperature moves slowly — hourly is plenty.
  static const Duration _scanPeriod = Duration(hours: 1);

  /// Give up on a scan if the sensor isn't heard; it normally answers within a
  /// few seconds, and the scan is stopped the moment a reading lands.
  static const Duration _scanTimeout = Duration(seconds: 45);

  /// A month of hourly samples.
  static const int _maxSamples = 744;

  /// Ignores repeat advertisements inside a single scan window.
  static const Duration _sampleInterval = Duration(minutes: 1);

  DBusClient? _client;
  StreamSubscription<DBusSignal>? _signalSub;
  Timer? _saveTimer;
  Timer? _scanTimer;
  Timer? _scanDeadline;
  bool _scanning = false;

  double? _temperatureC;
  double? _humidity;
  int? _battery;
  DateTime? _lastSeen;
  String _deviceName = '';

  double? get temperatureC => _temperatureC;
  double? get humidity => _humidity;
  int? get battery => _battery;
  DateTime? get lastSeen => _lastSeen;
  String get deviceName => _deviceName;

  /// True when a reading has arrived recently enough to trust — a little over
  /// two scan periods, so one missed scan doesn't blank the display.
  bool get available =>
      _temperatureC != null &&
      _lastSeen != null &&
      DateTime.now().difference(_lastSeen!) < _scanPeriod * 2.5;

  final List<IndoorReading> _history = [];
  List<IndoorReading> get history => List.unmodifiable(_history);

  File get _historyFile =>
      File(p.join(ImmichKioskPiCache.root, 'indoor_history.json'));

  Future<void> start() async {
    await _loadHistory();
    try {
      _client = DBusClient.system();
      _watch();
      // Devices BlueZ already knows about cost no radio time to read.
      await _seedFromKnownDevices();
      await _scanOnce();
      _scanTimer = Timer.periodic(_scanPeriod, (_) => _scanOnce());
    } catch (e) {
      debugPrint('IndoorSensorService.start error: $e');
    }
  }

  DBusRemoteObject get _adapter => DBusRemoteObject(_client!,
      name: _bluez, path: DBusObjectPath(_adapterPath));

  /// Open the radio just long enough to hear one advertisement.
  ///
  /// BlueZ only delivers advertisements while a discovery is running, and ties
  /// that discovery to the D-Bus connection that started it — so this client
  /// stays alive between scans even though discovery does not.
  Future<void> _scanOnce() async {
    if (_scanning || _client == null) return;
    _scanning = true;
    try {
      await _adapter.callMethod(
        _adapterIface,
        'SetDiscoveryFilter',
        [
          DBusDict.stringVariant({
            'Transport': const DBusString('le'),
            // Without this BlueZ reports each device once and we'd never see
            // updated readings.
            'DuplicateData': const DBusBoolean(true),
          })
        ],
        replySignature: DBusSignature(''),
      );
      await _adapter.callMethod(_adapterIface, 'StartDiscovery', [],
          replySignature: DBusSignature(''));
      _scanDeadline = Timer(_scanTimeout, _stopScan);
    } catch (e) {
      debugPrint('StartDiscovery error: $e');
      _scanning = false;
    }
  }

  Future<void> _stopScan() async {
    _scanDeadline?.cancel();
    _scanDeadline = null;
    if (!_scanning) return;
    _scanning = false;
    try {
      await _adapter.callMethod(_adapterIface, 'StopDiscovery', [],
          replySignature: DBusSignature(''));
    } catch (e) {
      debugPrint('StopDiscovery error: $e');
    }
  }

  Future<void> _seedFromKnownDevices() async {
    final root = DBusRemoteObjectManager(_client!,
        name: _bluez, path: DBusObjectPath('/'));
    final objects = await root.getManagedObjects();
    for (final entry in objects.entries) {
      final props = entry.value[_deviceIface];
      if (props == null) continue;
      _consider(props, entry.key.value);
    }
  }

  void _watch() {
    final root = DBusRemoteObjectManager(_client!,
        name: _bluez, path: DBusObjectPath('/'));
    _signalSub = root.signals.listen((signal) {
      if (signal is DBusPropertiesChangedSignal &&
          signal.propertiesInterface == _deviceIface) {
        _consider(signal.changedProperties, signal.path.value);
      } else if (signal is DBusObjectManagerInterfacesAddedSignal) {
        final props = signal.interfacesAndProperties[_deviceIface];
        if (props != null) _consider(props, signal.changedPath.value);
      }
    });
  }

  /// Names arrive in a different signal from manufacturer data, so remember
  /// which device paths belong to the sensor.
  final Set<String> _sensorPaths = {};

  void _consider(Map<String, DBusValue> props, String path) {
    final nameValue = props['Name'] ?? props['Alias'];
    if (nameValue is DBusString && _namePattern.hasMatch(nameValue.value)) {
      _deviceName = nameValue.value;
      _sensorPaths.add(path);
    }
    // Only ever decode data from a device identified by name as the sensor.
    // Plenty of other BLE devices broadcast manufacturer data that would
    // otherwise decode into a plausible-looking temperature.
    if (!_sensorPaths.contains(path)) return;

    final md = props['ManufacturerData'];
    if (md == null) return;
    try {
      final dict = md.asDict();
      for (final entry in dict.entries) {
        final bytes = (entry.value as DBusVariant).value.asByteArray().toList();
        final reading = decode(bytes);
        if (reading != null) {
          _apply(reading);
          return;
        }
      }
    } catch (e) {
      debugPrint('manufacturer data parse error: $e');
    }
  }

  /// Decode a Govee H510x advertisement payload. Returns null if it doesn't
  /// look like one.
  ///
  /// The 3-byte value packs both readings as
  /// `temperature_in_tenths * 1000 + humidity_in_tenths`, so the temperature
  /// needs integer division — dividing by 10000 instead would drag the
  /// humidity digits in as false precision (29.0446 °C rather than 29.0 °C).
  /// Matches the reference implementation in Home Assistant's ble_monitor.
  static Map<String, num>? decode(List<int> data) {
    if (data.length < 6) return null;
    var packed = (data[2] << 16) | (data[3] << 8) | data[4];
    final negative = (packed & 0x800000) != 0;
    packed &= 0x7FFFFF;
    var temp = (packed ~/ 1000) / 10.0;
    final hum = (packed % 1000) / 10.0;
    if (negative) temp = -temp;
    // Guard against decoding an unrelated advert as a plausible reading.
    if (temp < -40 || temp > 80 || hum > 100) return null;
    return {'temp': temp, 'hum': hum, 'batt': data[5]};
  }

  void _apply(Map<String, num> r) {
    // Heard it — close the radio straight away rather than sitting out the
    // rest of the window competing with A2DP.
    if (_scanning) unawaited(_stopScan());

    // The advertisement carries no checksum, so a garbled one can still decode
    // to an in-range value. A room can't swing 10°C between scans, and with
    // hourly samples one bad point would visibly wreck the chart's scale.
    final incoming = r['temp']!.toDouble();
    if (_temperatureC != null &&
        _lastSeen != null &&
        DateTime.now().difference(_lastSeen!) < _scanPeriod * 3 &&
        (incoming - _temperatureC!).abs() > 10) {
      debugPrint('discarding implausible indoor reading: $incoming');
      return;
    }

    _temperatureC = incoming;
    _humidity = r['hum']!.toDouble();
    _battery = r['batt']!.toInt();
    _lastSeen = DateTime.now();

    final last = _history.isEmpty ? null : _history.last;
    if (last == null ||
        _lastSeen!.difference(last.time) >= _sampleInterval) {
      _history.add(IndoorReading(
        time: _lastSeen!,
        temperatureC: _temperatureC!,
        humidity: _humidity!,
      ));
      if (_history.length > _maxSamples) {
        _history.removeRange(0, _history.length - _maxSamples);
      }
      _scheduleSave();
    }
    notifyListeners();
  }

  /// Readings arrive every few seconds; batch writes rather than hitting the
  /// disk each time.
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 30), _saveHistory);
  }

  Future<void> _loadHistory() async {
    try {
      final f = _historyFile;
      if (!await f.exists()) return;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return;
      _history
        ..clear()
        ..addAll(raw.map(IndoorReading.fromJson).whereType<IndoorReading>());
      notifyListeners();
    } catch (e) {
      debugPrint('indoor history load error: $e');
    }
  }

  Future<void> _saveHistory() async {
    try {
      final f = _historyFile;
      await f.parent.create(recursive: true);
      await f.writeAsString(
          jsonEncode(_history.map((r) => r.toJson()).toList()));
    } catch (e) {
      debugPrint('indoor history save error: $e');
    }
  }

  /// Samples from the last [window], for the chart.
  List<IndoorReading> recent(Duration window) {
    final cutoff = DateTime.now().subtract(window);
    return _history.where((r) => r.time.isAfter(cutoff)).toList();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _scanTimer?.cancel();
    _scanDeadline?.cancel();
    unawaited(_saveHistory());
    _signalSub?.cancel();
    _client?.close();
    super.dispose();
  }
}
