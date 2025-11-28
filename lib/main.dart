// lib/main.dart
import 'dart:typed_data';
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
// Ride State with Optimiser
// -----------------------------
class RideState extends ChangeNotifier {
  int cadence = 0; // RPM
  int power = 0; // Watts
  int hr = 0; // BPM
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
      if (recentEff.length > windowSize) recentEff.removeAt(0);

      optimalCadence = _predictOptimalCadence();
    }
    notifyListeners();
  }

  int _predictOptimalCadence() {
    if (recentEff.isEmpty) return 90;
    final Map<int, List<double>> cadEff = {};
    for (var entry in recentEff) {
      int cad = entry["cadence"];
      double eff = entry["efficiency"];
      cadEff.putIfAbsent(cad, () => []).add(eff);
    }
    int optimalCad = cadEff.entries
        .map((e) =>
            MapEntry(e.key, e.value.reduce((a, b) => a + b) / e.value.length))
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
// BLE Manager with robust parsing
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
              final int16Power = _i16(data, 2);
              // Some devices use other offsets; but per BLE spec this is correct.
              ride.setPower(int16Power);
              print("Power raw: $data -> power=$int16Power W");
            } else {
              print("Power packet too short: $data");
            }
          } catch (e) {
            print("Power parse error: $e  raw:$data");
          }
        });

        // --- RSC Measurement (robust parsing and fallback) ---
        final rscChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: rscService,
          characteristicId: rscMeasurement,
        );

        _ble.subscribeToCharacteristic(rscChar).listen((data) {
          try {
            if (data.isEmpty) return;
            // convert to List<int>
            final bytes = List<int>.from(data);
            print("RSC raw: $bytes");

            // Flags (1 byte)
            final flags = bytes[0] & 0xFF;
            final strideLenPresent = (flags & 0x01) != 0;
            final totalDistPresent = (flags & 0x02) != 0;
            final isRunning = (flags & 0x04) != 0;

            int offset = 1;

            // Instantaneous speed (uint16) -- units: m/s * 256
            double speedMs = 0.0;
            if (bytes.length >= offset + 2) {
              final rawSpeed = _u16(bytes, offset);
              speedMs = rawSpeed / 256.0;
            }
            offset += 2;

            // Instantaneous cadence (uint8) - steps per minute (RPM)
            int? cadenceFromRsc;
            if (bytes.length > offset) {
              cadenceFromRsc = bytes[offset] & 0xFF;
            }
            offset += 1;

            // Optional stride length (uint16) in metres with resolution 1/100? (device-dependent)
            double? strideLengthM;
            if (strideLenPresent && bytes.length >= offset + 2) {
              final rawStride = _u16(bytes, offset);
              // Per RSC spec stride length is in metres with resolution 1/100 (i.e. value/100)
              strideLengthM = rawStride / 100.0;
              offset += 2;
            }

            // Optional total distance (uint32) - skip if present
            if (totalDistPresent && bytes.length >= offset + 4) {
              final totalDistRaw = _u32(bytes, offset);
              // totalDistRaw is in metres with resolution 1/100 (device-dependent)
              offset += 4;
            }

            int finalCadence = 0;
            if (cadenceFromRsc != null && cadenceFromRsc > 0) {
              finalCadence = cadenceFromRsc;
            } else {
              // Fallback: if speed and stride length available, compute cadence = (speed / strideLength) * 60
              if (strideLengthM != null && strideLengthM > 0 && speedMs > 0.0) {
                final freqPerSec = speedMs / strideLengthM; // steps per second
                final computedRPM = (freqPerSec * 60.0).round();
                if (computedRPM > 0 && computedRPM < 300) {
                  finalCadence = computedRPM;
                }
              }
            }

            // Only update if plausible
            if (finalCadence > 0 && finalCadence < 300) {
              ride.setCadence(finalCadence);
              print("RSC parsed -> speed=${speedMs.toStringAsFixed(2)} m/s stride=${strideLengthM ?? 'n/a'} m cadence=$finalCadence");
            } else {
              // If invalid, set 0 to indicate none
              ride.setCadence(0);
              print("RSC cadence not available (raw cadence: $cadenceFromRsc, computed: $finalCadence)");
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
