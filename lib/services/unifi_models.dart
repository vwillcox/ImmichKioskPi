/// Models for the UniFi Network Integration API.
///
/// Written against what a Dream Router 7 on Network 10.5.67 actually returns,
/// not against the documentation — the field names below were read off a live
/// console. Everything is optional-tolerant, because a console with different
/// hardware (no radios on a switch, no uplink on an access point) simply omits
/// sections rather than sending nulls.
library;

double? _d(Object? v) => (v as num?)?.toDouble();
int? _i(Object? v) => (v as num?)?.toInt();

/// An adopted UniFi device: the router, a switch, an access point.
class UnifiDevice {
  const UnifiDevice({
    required this.id,
    required this.name,
    required this.model,
    required this.state,
    this.ipAddress = '',
    this.macAddress = '',
    this.firmwareVersion = '',
    this.firmwareUpdatable = false,
    this.ports = const [],
  });

  final String id;
  final String name;
  final String model;

  /// `ONLINE` on a healthy device. Anything else is worth showing.
  final String state;

  final String ipAddress;
  final String macAddress;
  final String firmwareVersion;
  final bool firmwareUpdatable;
  final List<UnifiPort> ports;

  bool get online => state.toUpperCase() == 'ONLINE';

  static UnifiDevice? parse(Object? raw) {
    if (raw is! Map) return null;
    final id = '${raw['id'] ?? ''}';
    if (id.isEmpty) return null;
    final interfaces = raw['interfaces'];
    final ports = interfaces is Map ? interfaces['ports'] : null;
    return UnifiDevice(
      id: id,
      name: '${raw['name'] ?? raw['model'] ?? 'Device'}',
      model: '${raw['model'] ?? ''}',
      state: '${raw['state'] ?? ''}',
      ipAddress: '${raw['ipAddress'] ?? ''}',
      macAddress: '${raw['macAddress'] ?? ''}',
      firmwareVersion: '${raw['firmwareVersion'] ?? ''}',
      firmwareUpdatable: raw['firmwareUpdatable'] == true,
      ports: ports is List
          ? ports.map(UnifiPort.parse).whereType<UnifiPort>().toList()
          : const [],
    );
  }
}

/// One physical port on a switch or router.
class UnifiPort {
  const UnifiPort({
    required this.index,
    required this.state,
    this.speedMbps,
    this.maxSpeedMbps,
    this.poeEnabled = false,
  });

  final int index;
  final String state;
  final int? speedMbps;
  final int? maxSpeedMbps;
  final bool poeEnabled;

  bool get up => state.toUpperCase() == 'UP';

  /// Connected below what the port can do — usually a duff cable, and the
  /// sort of thing you only find when something is slow for months.
  bool get negotiatedLow =>
      up &&
      speedMbps != null &&
      maxSpeedMbps != null &&
      speedMbps! < maxSpeedMbps!;

  static UnifiPort? parse(Object? raw) {
    if (raw is! Map) return null;
    final poe = raw['poe'];
    return UnifiPort(
      index: _i(raw['idx']) ?? 0,
      state: '${raw['state'] ?? ''}',
      speedMbps: _i(raw['speedMbps']),
      maxSpeedMbps: _i(raw['maxSpeedMbps']),
      poeEnabled: poe is Map && poe['enabled'] == true,
    );
  }
}

/// Live figures for one device.
class UnifiStats {
  const UnifiStats({
    this.uptimeSec,
    this.cpuPct,
    this.memoryPct,
    this.load1,
    this.txRateBps,
    this.rxRateBps,
    this.radios = const [],
  });

  final int? uptimeSec;
  final double? cpuPct;
  final double? memoryPct;
  final double? load1;

  /// The WAN uplink, on the gateway. Absent on devices that have no uplink of
  /// their own to report.
  final double? txRateBps;
  final double? rxRateBps;

  final List<UnifiRadio> radios;

  static UnifiStats parse(Object? raw) {
    if (raw is! Map) return const UnifiStats();
    final uplink = raw['uplink'];
    final interfaces = raw['interfaces'];
    final radios = interfaces is Map ? interfaces['radios'] : null;
    return UnifiStats(
      uptimeSec: _i(raw['uptimeSec']),
      cpuPct: _d(raw['cpuUtilizationPct']),
      memoryPct: _d(raw['memoryUtilizationPct']),
      load1: _d(raw['loadAverage1Min']),
      txRateBps: uplink is Map ? _d(uplink['txRateBps']) : null,
      rxRateBps: uplink is Map ? _d(uplink['rxRateBps']) : null,
      radios: radios is List
          ? radios.map(UnifiRadio.parse).whereType<UnifiRadio>().toList()
          : const [],
    );
  }
}

/// One radio band, and how much it is having to retransmit.
///
/// Retries are the honest measure of a busy or interfered band — far more
/// telling than client count, which says nothing about whether they are
/// getting through.
class UnifiRadio {
  const UnifiRadio({required this.frequencyGHz, this.txRetriesPct});

  final double frequencyGHz;
  final double? txRetriesPct;

  String get label {
    if (frequencyGHz >= 5.5) return '6 GHz';
    if (frequencyGHz >= 4) return '5 GHz';
    return '2.4 GHz';
  }

  static UnifiRadio? parse(Object? raw) {
    if (raw is! Map) return null;
    final f = _d(raw['frequencyGHz']);
    if (f == null) return null;
    return UnifiRadio(frequencyGHz: f, txRetriesPct: _d(raw['txRetriesPct']));
  }
}

/// Something connected to the network.
class UnifiClient {
  const UnifiClient({
    required this.id,
    required this.name,
    required this.type,
    this.ipAddress = '',
    this.macAddress = '',
    this.connectedAt,
    this.uplinkDeviceId = '',
  });

  final String id;
  final String name;

  /// `WIRED` or `WIRELESS`.
  final String type;

  final String ipAddress;
  final String macAddress;

  /// When this client joined. The API gives no "last seen", so a client
  /// present in the list *is* currently connected — which is what makes a
  /// presence widget possible at all.
  final DateTime? connectedAt;

  /// Which device it is connected through, matching [UnifiDevice.id].
  final String uplinkDeviceId;

  bool get wireless => type.toUpperCase() == 'WIRELESS';

  /// The trailing MAC fragment UniFi appends to unnamed clients, e.g.
  /// "ESP_12D1E9 d1:e9". Stripped for display, since it is noise once the
  /// name is there.
  String get displayName {
    final trimmed = name.trim();
    final m = RegExp(r'^(.*?)\s+[0-9a-f]{2}:[0-9a-f]{2}$', caseSensitive: false)
        .firstMatch(trimmed);
    final base = m == null ? trimmed : m.group(1)!.trim();
    return base.isEmpty ? trimmed : base;
  }

  Duration? get connectedFor =>
      connectedAt == null ? null : DateTime.now().difference(connectedAt!);

  static UnifiClient? parse(Object? raw) {
    if (raw is! Map) return null;
    final id = '${raw['id'] ?? ''}';
    if (id.isEmpty) return null;
    return UnifiClient(
      id: id,
      name: '${raw['name'] ?? raw['macAddress'] ?? 'Unknown'}',
      type: '${raw['type'] ?? ''}',
      ipAddress: '${raw['ipAddress'] ?? ''}',
      macAddress: '${raw['macAddress'] ?? ''}',
      connectedAt: DateTime.tryParse('${raw['connectedAt'] ?? ''}'),
      uplinkDeviceId: '${raw['uplinkDeviceId'] ?? ''}',
    );
  }
}

/// A throughput reading, for the graph.
class ThroughputSample {
  const ThroughputSample(this.at, this.txBps, this.rxBps);
  final DateTime at;
  final double txBps;
  final double rxBps;
}

/// Bits per second as something readable.
String formatBps(double? bps) {
  final v = bps ?? 0;
  if (v >= 1000000000) return '${(v / 1000000000).toStringAsFixed(2)} Gb/s';
  if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)} Mb/s';
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(0)} kb/s';
  return '${v.toStringAsFixed(0)} b/s';
}

/// A duration as the kind of thing a person says out loud.
String formatUptime(Duration d) {
  if (d.inDays >= 1) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes >= 1) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}
