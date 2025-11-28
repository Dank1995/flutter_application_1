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

// ===============================
// RIDE STATE
// ===============================

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
      int cad = entry["cadence"];
      double eff = entry["efficiency"];
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

// ===============================
// BLE MANAGER (STRYD + CYCLING)
// ===============================

class BleManager {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  // Standard Services
  final Uuid heartRateService = Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid heartRateMeasurement = Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");

  final Uuid speedCadenceService = Uuid.parse("00001816-0000-1000-8000-00805F9B34FB");
  final Uuid scMeasurement = Uuid.parse("00002A5B-0000-1000-8000-00805F9B34FB");

  final Uuid cyclingPowerService = Uuid.parse("00001818-0000-1000-8000-00805F9B34FB");
  final Uuid powerMeasurement = Uuid.parse("00002A63-0000-1000-8000-00805F9B34FB");

  // STRYD Custom UUIDs
  final Uuid strydService = Uuid.parse("F0000001-0451-4000-B000-000000000000");
  final Uuid strydPower = Uuid.parse("F0000002-0451-4000-B000-000000000000");

  Stream<List<DiscoveredDevice>> scan() {
    final devices = <DiscoveredDevice>[];
    return _ble.scanForDevices(withServices: []).map((d) {
      if (!devices.any((x) => x.id == d.id)) devices.add(d);
      return devices;
    });
  }

  Future<void> connect(String deviceId, RideState ride) async {
    int? lastCrankRevs;
    int? lastEventTime;

    _ble.connectToDevice(id: deviceId).listen((update) {
      if (update.connectionState == DeviceConnectionState.connected) {
        // HEART RATE
        final hrChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: heartRateService,
          characteristicId: heartRateMeasurement,
        );
        _ble.subscribeToCharacteristic(hrChar).listen((data) {
          if (data.length > 1) ride.setHr(data[1]);
        });

        // CADENCE
        final cadChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: speedCadenceService,
          characteristicId: scMeasurement,
        );
        _ble.subscribeToCharacteristic(cadChar).listen((data) {
          if (data.isNotEmpty) {
            final flags = data[0];
            if ((flags & 0x02) != 0 && data.length >= 5) {
              final crankRevs = data[1] | (data[2] << 8);
              final eventTime = data[3] | (data[4] << 8);

              if (lastCrankRevs != null && lastEventTime != null) {
                final revDelta = crankRevs - lastCrankRevs!;
                final timeDelta = (eventTime - lastEventTime!) & 0xFFFF;
                if (timeDelta > 0) {
                  final cadenceRpm = (revDelta * 60.0 * 1024.0) / timeDelta;
                  ride.setCadence(cadenceRpm.round());
                }
              }
              lastCrankRevs = crankRevs;
              lastEventTime = eventTime;
            }
          }
        });

        // CYCLING POWER
        final powerChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: cyclingPowerService,
          characteristicId: powerMeasurement,
        );
        _ble.subscribeToCharacteristic(powerChar).listen((data) {
          if (data.length >= 4) {
            final raw = data[2] | (data[3] << 8);
            final signed = raw >= 0x8000 ? raw - 0x10000 : raw;
            ride.setPower(signed);
          }
        });

        // STRYD RUNNING POWER
        final strydChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: strydService,
          characteristicId: strydPower,
        );
        _ble.subscribeToCharacteristic(strydChar).listen((data) {
          if (data.length >= 2) {
            final watts = data[0] | (data[1] << 8);
            ride.setPower(watts);
          }
        });
      }
    });
  }
}

// ===============================
// DASHBOARD
// ===============================

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
    await Permission.locationWhenInUse.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
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

// ===============================
// SCANNER
// ===============================

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
