// lib/main.dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';

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
  int power = 0; // W
  int hr = 0; // BPM
  double efficiency = 0;

  final int windowSize = 10;
  final List<Map<String, dynamic>> recentEff = [];
  final List<double> monthlyEff = [];

  int optimalCadence = 90;
  String mode = "Cycling"; // Cycling or Running

  // Raw byte log
  final List<String> byteLog = [];

  void logBytes(String device, List<int> bytes) {
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    byteLog.add("${DateTime.now().toIso8601String()} | $device: $hex");
    if (byteLog.length > 1000) byteLog.removeAt(0);
    notifyListeners();
  }

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

  void setMode(String newMode) {
    mode = newMode;
    notifyListeners();
  }

  void _updateEfficiency() {
    if (hr > 0) {
      efficiency = power / hr;

      recentEff.add({"cadence": cadence, "efficiency": efficiency});
      if (recentEff.length > windowSize) recentEff.removeAt(0);

      monthlyEff.add(efficiency);
    }

    // Optimal cadence prediction
    optimalCadence = _predictOptimalCadence();
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
// BLE Manager
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

  int _i16(List<int> b, int offset) => (b[offset] & 0xFF) | ((b[offset + 1] & 0xFF) << 8);

  Future<void> connect(String deviceId, RideState ride) async {
    _ble.connectToDevice(id: deviceId).listen((update) {
      if (update.connectionState == DeviceConnectionState.connected) {
        // Heart Rate
        final hrChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: heartRateService,
          characteristicId: heartRateMeasurement,
        );
        _ble.subscribeToCharacteristic(hrChar).listen((data) {
          ride.logBytes("HR", data);
          if (data.length > 1) ride.setHr(data[1]);
        });

        // Cycling Power
        final powerChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: cyclingPowerService,
          characteristicId: powerMeasurement,
        );
        _ble.subscribeToCharacteristic(powerChar).listen((data) {
          ride.logBytes("Power", data);
          if (data.length >= 4) ride.setPower(_i16(data, 2));
        });

        // Cadence / RSC
        final rscChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: rscService,
          characteristicId: rscMeasurement,
        );
        _ble.subscribeToCharacteristic(rscChar).listen((data) {
          ride.logBytes("RSC", data);
          int cadenceValue = 0;
          if (data.isNotEmpty) {
            if (ride.mode == "Running") {
              cadenceValue = (data[1] & 0xFF) * 2; // Stryd rough correction
            } else {
              cadenceValue = data[1] & 0xFF; // Cycling / Rally pedals
            }
          }
          ride.setCadence(cadenceValue);
        });
      }
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
          PopupMenuButton<String>(
            onSelected: (v) => ride.setMode(v),
            itemBuilder: (_) => [
              const PopupMenuItem(value: "Cycling", child: Text("Cycling Mode")),
              const PopupMenuItem(value: "Running", child: Text("Running Mode")),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.bluetooth_searching),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => BleScannerPage()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.list),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => ByteLogPage()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 2,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    ride.shiftMessage,
                    style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: ride.alertColor),
                  ),
                  const SizedBox(height: 10),
                  Text("Cadence: ${ride.cadence} RPM"),
                  Text("Power: ${ride.power} W"),
                  Text("Heart Rate: ${ride.hr} BPM"),
                  Text(
                      "Efficiency: ${ride.efficiency.toStringAsFixed(2)} W/BPM"),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: LineChart(LineChartData(
                minX: 0,
                maxX: ride.recentEff.length.toDouble(),
                minY: 0,
                maxY: ride.recentEff
                        .map((e) => e["efficiency"] as double)
                        .fold<double>(0, (prev, e) => e > prev ? e : prev) +
                    10,
                lineBarsData: [
                  LineChartBarData(
                    spots: ride.recentEff
                        .asMap()
                        .entries
                        .map((e) =>
                            FlSpot(e.key.toDouble(), e.value["efficiency"]))
                        .toList(),
                    isCurved: true,
                    color: Colors.green,
                    barWidth: 3,
                    dotData: FlDotData(show: false),
                  ),
                ],
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true)),
                  bottomTitles:
                      AxisTitles(sideTitles: SideTitles(showTitles: true)),
                ),
              )),
            ),
          ),
        ],
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

// -----------------------------
// Byte Log Page
// -----------------------------
class ByteLogPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final ride = context.watch<RideState>();
    return Scaffold(
      appBar: AppBar(title: const Text("Raw BLE Bytes")),
      body: ListView.builder(
        itemCount: ride.byteLog.length,
        itemBuilder: (context, index) {
          return ListTile(
            title: Text(ride.byteLog[index],
                style: const TextStyle(fontSize: 12)),
          );
        },
      ),
    );
  }
}
