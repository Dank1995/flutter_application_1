// lib/main.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
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
// Ride state with dynamic optimiser
// -----------------------------
class RideState extends ChangeNotifier {
  int cadence = 0; // strides/min
  int power = 0;   // Watts
  int hr = 0;      // BPM
  double efficiency = 0; // W/BPM

  final Map<int, List<double>> workoutEffBuckets = {};
  final List<int> recentHr = [];
  final int maxHrHistory = 12;

  int optimalCadence = 90;
  double _optimalCadenceSmoothed = 90.0;
  final double smoothingAlpha = 0.4;

  void setHr(int value) {
    hr = value;
    recentHr.add(value);
    if (recentHr.length > maxHrHistory) recentHr.removeAt(0);
    _updateEfficiency();
  }

  void setCadence(int valueStridesPerMin) {
    cadence = valueStridesPerMin;
    _updateEfficiency();
  }

  void setPower(int value) {
    power = value;
    _updateEfficiency();
  }

  void _updateEfficiency() {
    if (hr > 0) {
      efficiency = power / hr;
      final list = workoutEffBuckets.putIfAbsent(cadence, () => []);
      list.add(efficiency);
      if (list.length > 300) {
        list.removeRange(0, list.length - 300);
      }
      final histOptimal = _predictDynamicOptimalCadence();
      _optimalCadenceSmoothed =
          smoothingAlpha * histOptimal + (1 - smoothingAlpha) * _optimalCadenceSmoothed;
      optimalCadence = _optimalCadenceSmoothed.round();
    }
    notifyListeners();
  }

  double _weightedEffForCadence(int cad) {
    final values = workoutEffBuckets[cad];
    if (values == null || values.isEmpty) return 0.0;
    double weight = 1.0;
    const double decay = 0.9;
    double sum = 0.0, totalWeight = 0.0;
    for (var i = values.length - 1; i >= 0; i--) {
      final v = values[i];
      sum += v * weight;
      totalWeight += weight;
      weight *= decay;
      if (weight < 1e-6) break;
    }
    return sum / totalWeight;
  }

  int _predictDynamicOptimalCadence() {
    if (workoutEffBuckets.isEmpty) return optimalCadence;
    int bestCad = optimalCadence;
    double bestEff = -double.infinity;
    for (final cad in workoutEffBuckets.keys) {
      final eff = _weightedEffForCadence(cad);
      if (eff > bestEff) {
        bestEff = eff;
        bestCad = cad;
      }
    }
    return bestCad;
  }

  int get _cadenceTolerance {
    if (recentHr.length < 3) return 3;
    final mean = recentHr.reduce((a, b) => a + b) / recentHr.length;
    final variance = recentHr
        .map((x) => (x - mean) * (x - mean))
        .reduce((a, b) => a + b) / recentHr.length;
    final std = math.sqrt(variance);
    return std < 2 ? 2 : 3;
  }

  String get shiftMessage {
    final diff = cadence - optimalCadence;
    if (diff.abs() > _cadenceTolerance) {
      return diff > 0
          ? "Decrease cadence toward $optimalCadence strides/min"
          : "Increase cadence toward $optimalCadence strides/min";
    }
    return "Cadence optimal ($optimalCadence strides/min)";
  }

  Color get alertColor =>
      (cadence - optimalCadence).abs() > _cadenceTolerance ? Colors.red : Colors.green;
}

// -----------------------------
// BLE manager with corrected cadence parsing (no halving)
// -----------------------------
class BleManager {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  final Uuid heartRateService =
      Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid heartRateMeasurement =
      Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");

  final Uuid rscService =
      Uuid.parse("00001814-0000-1000-8000-00805F9B34FB");
  final Uuid rscMeasurement =
      Uuid.parse("00002A53-0000-1000-8000-00805F9B34FB");

  final Uuid cyclingPowerService =
      Uuid.parse("00001818-0000-1000-8000-00805F9B34FB");
  final Uuid powerMeasurement =
      Uuid.parse("00002A63-0000-1000-8000-00805F9B34FB");

  Stream<List<DiscoveredDevice>> scan() {
    final devices = <DiscoveredDevice>[];
    return _ble.scanForDevices(withServices: []).map((d) {
      if (!devices.any((x) => x.id == d.id)) devices.add(d);
      return devices;
    });
  }

  int _u16(List<int> b, int offset) =>
      (b[offset] & 0xFF) | ((b[offset + 1] & 0xFF) << 8);
  int _i16(List<int> b, int offset) {
    final v = _u16(b, offset);
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  Future<void> connect(String deviceId, RideState ride) async {
    _ble.connectToDevice(id: deviceId).listen((update) async {
      if (update.connectionState == DeviceConnectionState.connected) {
        print("Connected to $deviceId");

        final hrChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: heartRateService,
          characteristicId: heartRateMeasurement,
        );
        _ble.subscribeToCharacteristic(hrChar).listen((data) {
          if (data.length > 1) {
            ride.setHr(data[1]);
          }
        });

        final powerChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: cyclingPowerService,
          characteristicId: powerMeasurement,
        );
        _ble.subscribeToCharacteristic(powerChar).listen((data) {
          if (data.length >= 4) {
            final int16Power = _i16(List<int>.from(data), 2);
            ride.setPower(int16Power);
          }
        });

        final rscChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: rscService,
          characteristicId: rscMeasurement,
        );
        _ble.subscribeToCharacteristic(rscChar).listen((data) {
          if (data.isEmpty) return;
          final bytes = List<int>.from(data);

          // RSC flags at bytes[0]; speed (if present) at [1..2]; cadence at [3]
          // We read cadence defensively in case flags vary.
          final int flags = bytes[0] & 0xFF;
          int offset = 1;

          // If speed present (bit 0), skip speed (u16, 1/256 m/s)
          if ((flags & 0x01) != 0 && bytes.length >= offset + 2) {
            offset += 2;
          }

          // Cadence present (bit 1); single byte, strides or steps per minute depending on device.
          int? rawCadence;
          if ((flags & 0x02) != 0 && bytes.length > offset) {
            rawCadence = bytes[offset] & 0xFF;
            offset += 1;
          }

          int finalCadenceStrides = 0;
          if (rawCadence != null && rawCadence > 0) {
            // Use raw cadence directly as strides/min (no halving).
            finalCadenceStrides = rawCadence;
          }

          if (finalCadenceStrides > 0 && finalCadenceStrides < 220) {
            ride.setCadence(finalCadenceStrides);
            print("Cadence parsed = $finalCadenceStrides strides/min");
          } else {
            ride.setCadence(0);
          }
        });
      }
    });
  }
}

// -----------------------------
// Ride dashboard UI
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
    final ride = context.watch<RideState>();
    final ble = context.read<BleManager>();

    return Scaffold(
      appBar: AppBar(title: const Text('PhysiologicalOptimiser')),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<DiscoveredDevice>>(
              stream: ble.scan(),
              builder: (context, snapshot) {
                final devices = snapshot.data ?? [];
                return ListView.builder(
                  itemCount: devices.length,
                  itemBuilder: (context, i) {
                    final d = devices[i];
                    return ListTile(
                      title: Text(d.name.isEmpty ? d.id : d.name),
                      subtitle: Text(d.id),
                      trailing: ElevatedButton(
                        onPressed: () => ble.connect(d.id, ride),
                        child: const Text('Connect'),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              childAspectRatio: 2.5,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              children: [
                _metricTile("Heart rate", "${ride.hr} BPM"),
                _metricTile("Power", "${ride.power} W"),
                _metricTile("Cadence", "${ride.cadence} spm"),
                _metricTile("Efficiency", ride.efficiency.toStringAsFixed(2)),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            color: ride.alertColor,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            child: Text(
              ride.shiftMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricTile(String label, String value) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Colors.blueGrey.shade50,
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}