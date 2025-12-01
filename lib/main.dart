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

// -----------------------------
// App
// -----------------------------
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
// Ride State with dynamic optimiser (running-only)
// -----------------------------
class RideState extends ChangeNotifier {
  // Running cadence is displayed in strides/min (SPM / 2)
  int cadence = 0; // strides per minute
  int power = 0;   // Watts
  int hr = 0;      // BPM
  double efficiency = 0; // W/BPM

  // Workout-long buckets: cadence (strides/min) -> efficiencies
  final Map<int, List<double>> workoutEffBuckets = {};

  // Keep a short HR history for stability-aware thresholds
  final List<int> recentHr = [];
  final int maxHrHistory = 10;

  // Dynamic optimal cadence (strides/min)
  int optimalCadence = 90;

  // Smoothing for optimal cadence (to avoid jitter)
  double _optimalCadenceSmoothed = 90.0;
  final double smoothingAlpha = 0.4; // higher = react faster

  // Limit per-cadence samples retained (memory control)
  final int maxSamplesPerCadence = 300;

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

      // Update workout buckets
      final list = workoutEffBuckets.putIfAbsent(cadence, () => []);
      list.add(efficiency);
      if (list.length > maxSamplesPerCadence) {
        list.removeRange(0, list.length - maxSamplesPerCadence);
      }

      // Recompute dynamic optimal cadence using recency-weighted efficiency
      final histOptimal = _predictDynamicOptimalCadence();

      // Smooth the target to avoid oscillations
      _optimalCadenceSmoothed =
          smoothingAlpha * histOptimal + (1 - smoothingAlpha) * _optimalCadenceSmoothed;
      optimalCadence = _optimalCadenceSmoothed.round();
    }
    notifyListeners();
  }

  // Weighted average where recent samples count more (exponential decay)
  double _weightedEffForCadence(int cad) {
    final values = workoutEffBuckets[cad];
    if (values == null || values.isEmpty) return 0.0;

    double weight = 1.0;
    const double decay = 0.9; // recent samples get more weight
    double sum = 0.0, totalWeight = 0.0;

    // Iterate from newest to oldest
    for (var i = values.length - 1; i >= 0; i--) {
      final v = values[i];
      sum += v * weight;
      totalWeight += weight;
      weight *= decay;
      if (weight < 1e-6) break; // early stop
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

  // Adaptive threshold: tighter when HR is stable, wider when volatile
  int get _cadenceTolerance {
    if (recentHr.length < 3) return 5;
    final mean = recentHr.reduce((a, b) => a + b) / recentHr.length;
    final variance = recentHr
        .map((x) => (x - mean) * (x - mean))
        .reduce((a, b) => a + b) / recentHr.length;
    final std = math.sqrt(variance);
    return std < 2 ? 3 : 5; // tighten if HR is steady
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
// BLE Manager with running-only cadence parsing
// -----------------------------
class BleManager {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  // Heart Rate (standard)
  final Uuid heartRateService =
      Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid heartRateMeasurement =
      Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");

  // RSC (Running Speed & Cadence)
  final Uuid rscService =
      Uuid.parse("00001814-0000-1000-8000-00805F9B34FB");
  final Uuid rscMeasurement =
      Uuid.parse("00002A53-0000-1000-8000-00805F9B34FB");

  // Cycling Power
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

  // helpers to read integers from byte arrays
  int _u16(List<int> b, int offset) =>
      (b[offset] & 0xFF) | ((b[offset + 1] & 0xFF) << 8);

  int _i16(List<int> b, int offset) {
    final v = _u16(b, offset);
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  int _u32(List<int> b, int offset) {
    return (b[offset] & 0xFF) |
        ((b[offset + 1] & 0xFF) << 8) |
        ((b[offset + 2] & 0xFF) << 16) |
        ((b[offset + 3] & 0xFF) << 24);
  }

  Future<void> connect(String deviceId, RideState ride) async {
    _ble.connectToDevice(id: deviceId).listen((update) async {
      if (update.connectionState == DeviceConnectionState.connected) {
        print("Connected to $deviceId");

        // --- Heart Rate (standard) ---
        final hrChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: heartRateService,
          characteristicId: heartRateMeasurement,
        );
        _ble.subscribeToCharacteristic(hrChar).listen((data) {
          try {
            if (data.length > 1) {
              ride.setHr(data[1]);
            }
          } catch (e) {
            print("HR parse error: $e");
          }
        });

        // --- Cycling Power (correct spec parsing) ---
        final powerChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: cyclingPowerService,
          characteristicId: powerMeasurement,
        );
        _ble.subscribeToCharacteristic(powerChar).listen((data) {
          try {
            if (data.length >= 4) {
              // Flags are 2 bytes (data[0..1]) - we don't need most flags here
              // Instantaneous Power is signed int16 at data[2..3]
              final int16Power = _i16(List<int>.from(data), 2);
              ride.setPower(int16Power);
              print("Power raw: $data -> power=$int16Power W");
            } else {
              print("Power packet too short: $data");
            }
          } catch (e) {
            print("Power parse error: $e  raw:$data");
          }
        });

        // --- RSC Measurement (running-only cadence) ---
        final rscChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: rscService,
          characteristicId: rscMeasurement,
        );

        _ble.subscribeToCharacteristic(rscChar).listen((data) {
          try {
            if (data.isEmpty) return;
            final bytes = List<int>.from(data);
            print("RSC raw: $bytes");

            // Flags (1 byte)
            final flags = bytes[0] & 0xFF;
            final strideLenPresent = (flags & 0x01) != 0;
            final totalDistPresent = (flags & 0x02) != 0;
            // final isRunning = (flags & 0x04) != 0; // running-only app

            int offset = 1;

            // Instantaneous speed (uint16) -- units: m/s * 256
            double speedMs = 0.0;
            if (bytes.length >= offset + 2) {
              final rawSpeed = _u16(bytes, offset);
              speedMs = rawSpeed / 256.0;
            }
            offset += 2;

            // Instantaneous cadence (uint8) - steps per minute
            int? stepsPerMin;
            if (bytes.length > offset) {
              stepsPerMin = bytes[offset] & 0xFF;
            }
            offset += 1;

            // Optional stride length (uint16) in metres with resolution 1/100
            double? strideLengthM;
            if (strideLenPresent && bytes.length >= offset + 2) {
              final rawStride = _u16(bytes, offset);
              strideLengthM = rawStride / 100.0;
              offset += 2;
            }

            // Optional total distance (uint32)
            if (totalDistPresent && bytes.length >= offset + 4) {
              // final totalDistRaw = _u32(bytes, offset);
              offset += 4;
            }

            // Running cadence as strides/min (SPM / 2)
            int finalCadenceStrides = 0;
            if (stepsPerMin != null && stepsPerMin > 0) {
              finalCadenceStrides = (stepsPerMin / 2).round();
            } else if (strideLengthM != null && strideLengthM > 0 && speedMs > 0.0) {
              // Fallback: cadence (steps/min) = (speed / strideLength) * 60
              final stepsPerMinComputed = ((speedMs / strideLengthM) * 60.0).round();
              if (stepsPerMinComputed > 0 && stepsPerMinComputed < 400) {
                finalCadenceStrides = (stepsPerMinComputed / 2).round();
              }
            }

            if (finalCadenceStrides > 0 && finalCadenceStrides < 220) {
              ride.setCadence(finalCadenceStrides);
              print(
                "RSC parsed (running) -> speed=${speedMs.toStringAsFixed(2)} m/s, strideLen=${strideLengthM ?? 'n/a'} m, steps/min=${stepsPerMin ?? 'n/a'}, strides/min=$finalCadenceStrides",
              );
            } else {
              ride.setCadence(0);
              print("RSC cadence invalid (steps/min=$stepsPerMin)");
            }
          } catch (e) {
            print("RSC parse error: $e raw:$data");
          }
        });

        print("Subscribed to HR, Power, RSC notifications");
      }
    }, onError: (e) {
      print("Connection error: $e");
    });
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
        title: const Text("Run Dashboard"),
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
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Text("Cadence: ${ride.cadence} strides/min"),
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
              return ListTile(
                title: Text(name),
                subtitle: Text(d.id),
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
