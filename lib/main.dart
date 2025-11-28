// lib/main.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:logging/logging.dart';

void main() {
  _setupLogging();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => RideState()),
        Provider(create: (_) => BleManager()),
      ],
      child: const MyApp(),
    ),
  );
}

void _setupLogging() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((rec) {
    // simple console logging
    // In debug, this shows up in the IDE console
    print('${rec.level.name}: ${rec.loggerName}: ${rec.time}: ${rec.message}');
  });
}

final _log = Logger('Main');

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PhysiologicalOptimiser',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const RideDashboard(),
    );
  }
}

// -----------------------------
// Ride State with Optimiser
// -----------------------------
class RideState extends ChangeNotifier {
  int cadence = 0;
  int power = 0;
  int hr = 0;
  double efficiency = 0;

  final int windowSize = 5;
  final List<Map<String, dynamic>> recentEff = [];

  int optimalCadence = 90;

  void setHr(int value) {
    hr = value;
    _updateEfficiency();
  }

  void setCadence(int value) {
    cadence = value;
    _updateEfficiency();
  }

  void setPower(int value) {
    power = value;
    _updateEfficiency();
  }

  void _updateEfficiency() {
    if (hr > 0) {
      efficiency = power / hr;

      recentEff.add({
        "cadence": cadence,
        "efficiency": efficiency,
      });
      if (recentEff.length > windowSize) {
        recentEff.removeAt(0);
      }

      optimalCadence = _predictOptimalCadence();
    }
    notifyListeners();
  }

  int _predictOptimalCadence() {
    if (recentEff.isEmpty) return 90;

    final Map<int, List<double>> cadEff = {};
    for (var entry in recentEff) {
      int cad = entry["cadence"] ?? 0;
      double eff = entry["efficiency"] ?? 0.0;
      cadEff.putIfAbsent(cad, () => []).add(eff);
    }

    int optimalCad = cadEff.entries
        .map((e) => MapEntry(e.key, e.value.reduce((a, b) => a + b) / e.value.length))
        .reduce((a, b) => a.value > b.value ? a : b)
        .key;

    return optimalCad;
  }

  String get shiftMessage {
    final diff = cadence - optimalCadence;
    if (diff.abs() > 5) {
      return diff > 0
          ? "Shift to higher gear ($optimalCadence RPM)"
          : "Shift to lower gear ($optimalCadence RPM)";
    }
    return "Cadence optimal ($optimalCadence RPM)";
  }

  Color get alertColor =>
      (cadence - optimalCadence).abs() > 5 ? Colors.red : Colors.green;
}

// -----------------------------
// BLE Manager (supports Stryd heuristic)
// -----------------------------
class BleManager {
  final FlutterReactiveBle _ble = FlutterReactiveBle();
  final Logger log = Logger('BleManager');

  // Standard services
  final Uuid heartRateService = Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid heartRateMeasurement = Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");

  final Uuid speedCadenceService = Uuid.parse("00001814-0000-1000-8000-00805F9B34FB"); // Running Speed & Cadence (0x1814)
  final Uuid scMeasurement = Uuid.parse("00002A5B-0000-1000-8000-00805F9B34FB");

  final Uuid cyclingPowerService = Uuid.parse("00001818-0000-1000-8000-00805F9B34FB");
  final Uuid powerMeasurement = Uuid.parse("00002A63-0000-1000-8000-00805F9B34FB");

  // Candidate Stryd custom UUIDs (community / reverse-engineered patterns)
  // NOTE: If Stryd changes firmware/UUIDs this may differ.
  final Uuid strydPowerService = Uuid.parse("f0000001-0451-4000-b000-000000000000");
  final Uuid strydPowerCharacteristic = Uuid.parse("f0000002-0451-4000-b000-000000000000");

  Stream<List<DiscoveredDevice>> scan() {
    final devices = <DiscoveredDevice>[];
    return _ble.scanForDevices(withServices: []).map((d) {
      if (!devices.any((x) => x.id == d.id)) devices.add(d);
      return devices;
    });
  }

  StreamSubscription<ConnectionStateUpdate>? _connSub;
  final Map<String, StreamSubscription<List<int>>> _charSubs = {};

  Future<void> connect(String deviceId, RideState ride) async {
    _log.info('Request connect to $deviceId');
    // Ensure any previous connection subscription is cancelled for same device
    _connSub?.cancel();

    _connSub = _ble.connectToDevice(
      id: deviceId,
      connectionTimeout: const Duration(seconds: 10),
    ).listen((update) async {
      log.info('Connection update: ${update.connectionState} for $deviceId');

      if (update.connectionState == DeviceConnectionState.connected) {
        // Wait a short while — flutter_reactive_ble sometimes needs this on iOS/Android
        await Future.delayed(const Duration(milliseconds: 300));

        // Discover services/characteristics (returns List<DiscoveredService>)
        List<DiscoveredService> services = [];
        try {
          services = await _ble.discoverServices(deviceId);
        } catch (e) {
          log.warning('discoverServices failed: $e');
        }

        // map of service -> characteristic uuids
        final foundChars = <Uuid, List<Uuid>>{};
        for (var s in services) {
          final chars = s.characteristics.map((c) => c.characteristicId).toList();
          foundChars[s.serviceId] = chars;
          log.info('Service ${s.serviceId} chars: $chars');
        }

        // HEART RATE (standard)
        try {
          if (foundChars.containsKey(heartRateService) &&
              foundChars[heartRateService]!.contains(heartRateMeasurement)) {
            final hrChar = QualifiedCharacteristic(
              deviceId: deviceId,
              serviceId: heartRateService,
              characteristicId: heartRateMeasurement,
            );
            _subscribeChar(deviceId, hrChar, (data) {
              if (data.length >= 2) {
                final int flags = data[0];
                // HR value 8-bit or 16-bit
                int hrValue;
                if ((flags & 0x01) == 0) {
                  hrValue = data[1];
                } else {
                  hrValue = data[1] | (data[2] << 8);
                }
                ride.setHr(hrValue);
                log.info('HR: $hrValue');
              }
            });
          }
        } catch (e) {
          log.warning('HR subscription failed: $e');
        }

        // SPEED / CADENCE (running speed & cadence)
        try {
          if (foundChars.containsKey(speedCadenceService) &&
              foundChars[speedCadenceService]!.contains(scMeasurement)) {
            final scChar = QualifiedCharacteristic(
              deviceId: deviceId,
              serviceId: speedCadenceService,
              characteristicId: scMeasurement,
            );
            int? lastCrankRevs;
            int? lastEventTime;
            _subscribeChar(deviceId, scChar, (data) {
              if (data.isNotEmpty) {
                final flags = data[0];
                // For running pod the format varies; attempt parsing like cadence
                // If Crank/Revolution-based:
                if ((flags & 0x02) != 0 && data.length >= 5) {
                  final crankRevs = data[1] | (data[2] << 8);
                  final eventTime = data[3] | (data[4] << 8);
                  if (lastCrankRevs != null && lastEventTime != null) {
                    final revDelta = (crankRevs - lastCrankRevs!);
                    final timeDelta = (eventTime - lastEventTime!) & 0xFFFF;
                    if (timeDelta > 0) {
                      final cadenceRpm = (revDelta * 60.0 * 1024.0) / timeDelta;
                      ride.setCadence(cadenceRpm.round());
                      log.info('Cadence (calc): ${cadenceRpm.round()}');
                    }
                  }
                  lastCrankRevs = crankRevs;
                  lastEventTime = eventTime;
                } else {
                  // if not crank-based, try other heuristics (e.g., stride frequency -> cadence)
                  // Not implemented here — we rely on crank parsing if present.
                }
              }
            });
          }
        } catch (e) {
          log.warning('SC subscription failed: $e');
        }

        // CYCLING POWER SERVICE (standard)
        if (foundChars.containsKey(cyclingPowerService) &&
            foundChars[cyclingPowerService]!.contains(powerMeasurement)) {
          final powerChar = QualifiedCharacteristic(
            deviceId: deviceId,
            serviceId: cyclingPowerService,
            characteristicId: powerMeasurement,
          );
          _subscribeChar(deviceId, powerChar, (data) {
            // Cycling power measurement: varies, but raw power often at bytes 2..3 (16-bit)
            if (data.length >= 4) {
              final rawPower = data[2] | (data[3] << 8);
              final signedPower = rawPower >= 0x8000 ? rawPower - 0x10000 : rawPower;
              ride.setPower(signedPower);
              log.info('Cycling power measured: $signedPower');
            }
          });
        }

        // STRYD CUSTOM SERVICE (candidate)
        if (foundChars.containsKey(strydPowerService) &&
            foundChars[strydPowerService]!.contains(strydPowerCharacteristic)) {
          final sChar = QualifiedCharacteristic(
            deviceId: deviceId,
            serviceId: strydPowerService,
            characteristicId: strydPowerCharacteristic,
          );
          _subscribeChar(deviceId, sChar, (data) {
            // Heuristic parsing for Stryd: try uint16 little-endian -> watts
            if (data.length >= 2) {
              final watts = data[0] | (data[1] << 8);
              if (watts >= 0 && watts < 5000) {
                ride.setPower(watts);
                log.info('Stryd candidate power: $watts');
                return;
              }
            }
            log.info('Stryd char data (raw): $data');
          });
        }

        // FALLBACK: subscribe to any NOTIFY characteristic not yet subscribed and attempt to parse a uint16
        // This increases chances when Stryd uses a custom char not included above.
        for (var s in services) {
          for (var c in s.characteristics) {
            final cid = c.characteristicId;
            // Avoid re-subscribing known ones
            if (_isKnownCharacteristic(s.serviceId, cid)) continue;
            if (c.isNotifiable || c.isIndicatable) {
              final fallbackChar = QualifiedCharacteristic(
                deviceId: deviceId,
                serviceId: s.serviceId,
                characteristicId: cid,
              );
              _subscribeChar(deviceId, fallbackChar, (data) {
                if (data.length >= 2) {
                  final candidate = data[0] | (data[1] << 8);
                  if (candidate >= 0 && candidate < 5000) {
                    // plausibility check => treat as watts
                    ride.setPower(candidate);
                    log.info('Fallback parsed power from ${cid.toString()}: $candidate');
                    return;
                  }
                }
                log.fine('Fallback raw data ${cid.toString()}: $data');
              });
            }
          }
        }

        // If none of the above found cadence or power, we still logged the services for manual debugging.
        log.info('Connected and subscriptions attempted for $deviceId.');
      }

      if (update.connectionState == DeviceConnectionState.disconnected) {
        // cleanup characteristic subscriptions for this device
        log.info('Disconnected from $deviceId, cleaning up subs.');
        _cancelCharSubsForDevice(deviceId);
      }
    }, onError: (e) {
      log.warning('Connection stream error: $e');
    });
  }

  bool _isKnownCharacteristic(Uuid serviceId, Uuid characteristicId) {
    final known = <MapEntry<Uuid, Uuid>>[
      MapEntry(heartRateService, heartRateMeasurement),
      MapEntry(speedCadenceService, scMeasurement),
      MapEntry(cyclingPowerService, powerMeasurement),
      MapEntry(strydPowerService, strydPowerCharacteristic),
    ];
    return known.any((entry) =>
        entry.key == serviceId && entry.value == characteristicId);
  }

  void _subscribeChar(String deviceId, QualifiedCharacteristic qc, void Function(List<int>) onData) {
    final key = '${deviceId}_${qc.serviceId}_${qc.characteristicId}';
    if (_charSubs.containsKey(key)) return;
    log.info('Subscribing to ${qc.characteristicId} on ${qc.serviceId}');

    final sub = _ble.subscribeToCharacteristic(qc).listen((data) {
      try {
        onData(data);
      } catch (e) {
        log.warning('Error in characteristic onData: $e');
      }
    }, onError: (e) {
      log.warning('Characteristic subscription error for $key: $e');
    });

    _charSubs[key] = sub;
  }

  void _cancelCharSubsForDevice(String deviceId) {
    final keys = _charSubs.keys.where((k) => k.startsWith('$deviceId_')).toList();
    for (var k in keys) {
      _charSubs[k]?.cancel();
      _charSubs.remove(k);
    }
  }

  void dispose() {
    _connSub?.cancel();
    for (var s in _charSubs.values) {
      s.cancel();
    }
    _charSubs.clear();
  }
}

// -----------------------------
// Ride Dashboard
// -----------------------------
class RideDashboard extends StatefulWidget {
  const RideDashboard({super.key});
  @override
  State<RideDashboard> createState() => _RideDashboardState();
}

class _RideDashboardState extends State<RideDashboard> {
  @override
  void initState() {
    super.initState();
    _ensurePermissions();
  }

  Future<void> _ensurePermissions() async {
    // Location required for BLE scanning on many platforms
    if (await Permission.locationWhenInUse.isDenied) {
      await Permission.locationWhenInUse.request();
    }
    if (await Permission.bluetoothScan.isDenied) {
      await Permission.bluetoothScan.request();
    }
    if (await Permission.bluetoothConnect.isDenied) {
      await Permission.bluetoothConnect.request();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ride = Provider.of<RideState>(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text("Ride Dashboard"),
        actions: [
          IconButton(
            icon: const Icon(Icons.bluetooth_searching),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => BleScannerPage()),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              ride.shiftMessage,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: ride.alertColor,
              ),
            ),
            const SizedBox(height: 20),
            Text("Cadence: ${ride.cadence} RPM"),
            Text("Power: ${ride.power} W"),
            Text("Heart Rate: ${ride.hr} BPM"),
            Text("Efficiency: ${ride.efficiency.toStringAsFixed(2)} W/BPM"),
          ],
        ),
      ),
    );
  }
}

// -----------------------------
// BLE Scanner Page
// -----------------------------
class BleScannerPage extends StatelessWidget {
  BleScannerPage({super.key});
  @override
  Widget build(BuildContext context) {
    final ble = context.read<BleManager>();
    final ride = context.read<RideState>();

    return Scaffold(
      appBar: AppBar(title: const Text("Scan & Connect")),
      body: StreamBuilder<List<DiscoveredDevice>>(
        stream: ble.scan(),
        builder: (context, snapshot) {
          final devices = snapshot.data ?? [];
          return ListView.builder(
            itemCount: devices.length,
            itemBuilder: (context, index) {
              final d = devices[index];
              final name = d.name.isNotEmpty ? d.name : "Unknown";
              final isStryd = name.toLowerCase().contains('stryd');
              return ListTile(
                title: Text(name + (isStryd ? " (Stryd candidate)" : "")),
                subtitle: Text(d.id),
                trailing: Text(d.id.substring(0, 4)),
                onTap: () {
                  ble.connect(d.id, ride);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Connecting to $name")),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
