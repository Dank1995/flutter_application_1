// lib/main.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'models/eff_sample.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();
  Hive.registerAdapter(EffSampleAdapter());
  await Hive.openBox<EffSample>('efficiencyBox');

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
// Ride State with Optimiser + History
// -----------------------------
class RideState extends ChangeNotifier {
  int cadence = 0; // RPM
  int power = 0; // W
  int hr = 0; // BPM
  double efficiency = 0; // W/BPM

  final int windowSize = 10;
  final List<Map<String, dynamic>> recentEff = [];

  int optimalCadence = 90;
  String mode = "Cycling"; // Cycling or Running

  // Raw byte log
  final List<String> byteLog = [];

  // For Rally cadence (crank revs)
  int? lastCrankRevs;
  int? lastCrankEventTime;

  final Box<EffSample> _effBox = Hive.box<EffSample>('efficiencyBox');

  // -------- Raw BLE logging ----------
  void logBytes(String device, List<int> bytes) {
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    byteLog.add("${DateTime.now().toIso8601String()} | $device: $hex");
    if (byteLog.length > 1000) byteLog.removeAt(0);
    notifyListeners();
  }

  // -------- Setters ----------
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

  // -------- Efficiency + learning ----------
  void _updateEfficiency() {
    if (hr > 0) {
      efficiency = power / hr;

      // live rolling window
      recentEff.add({"cadence": cadence, "efficiency": efficiency});
      if (recentEff.length > windowSize) recentEff.removeAt(0);

      // store to Hive for last 30 days learning
      if (cadence > 0 && efficiency > 0) {
        _effBox.add(EffSample(DateTime.now(), efficiency, cadence));
      }

      // re-compute optimal cadence using short-term + monthly
      optimalCadence = _computeOptimalCadence();
    }
    notifyListeners();
  }

  int _computeOptimalCadence() {
    final shortTerm = _shortTermBestCadence();
    final monthly = _monthlyBestCadence();

    // combine: 60% short-term (fast response), 40% last 30 days (deep physiology)
    if (monthly == null && shortTerm == null) return 90;
    if (monthly == null) return shortTerm!;
    if (shortTerm == null) return monthly;

    return ((shortTerm * 0.6) + (monthly * 0.4)).round();
  }

  int? _shortTermBestCadence() {
    if (recentEff.isEmpty) return null;

    final Map<int, List<double>> buckets = {};
    for (var e in recentEff) {
      final c = e["cadence"] as int;
      final eff = e["efficiency"] as double;
      buckets.putIfAbsent(c, () => []).add(eff);
    }

    int? bestCad;
    double bestEff = -1;

    buckets.forEach((cad, list) {
      final avg = list.reduce((a, b) => a + b) / list.length;
      if (avg > bestEff) {
        bestEff = avg;
        bestCad = cad;
      }
    });

    return bestCad;
  }

  int? _monthlyBestCadence() {
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(days: 30));

    final samples = _effBox.values.where((e) => e.time.isAfter(cutoff)).toList();
    if (samples.isEmpty) return null;

    final Map<int, List<double>> byCadence = {};
    for (final s in samples) {
      byCadence.putIfAbsent(s.cadence, () => []).add(s.efficiency);
    }

    int? bestCad;
    double bestEff = -1;
    byCadence.forEach((cad, list) {
      final avg = list.reduce((a, b) => a + b) / list.length;
      if (avg > bestEff) {
        bestEff = avg;
        bestCad = cad;
      }
    });

    return bestCad;
  }

  // expose last 30 days for graph
  List<EffSample> get last30DaySamples {
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(days: 30));
    return _effBox.values.where((e) => e.time.isAfter(cutoff)).toList()
      ..sort((a, b) => a.time.compareTo(b.time));
  }

  // -------- UI helper texts ----------
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

  // Heart Rate
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

  int _u16(List<int> b, int offset) =>
      (b[offset] & 0xFF) | ((b[offset + 1] & 0xFF) << 8);

  int _i16(List<int> b, int offset) {
    final v = _u16(b, offset);
    return v >= 0x8000 ? v - 0x10000 : v;
  }

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
          if (data.length > 1) {
            ride.setHr(data[1]);
          }
        });

        // Cycling Power (Rally) - power + cadence
        final powerChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: cyclingPowerService,
          characteristicId: powerMeasurement,
        );
        _ble.subscribeToCharacteristic(powerChar).listen((data) {
          ride.logBytes("Power", data);

          if (data.length >= 4) {
            final p = _i16(data, 2);
            ride.setPower(p);
          }

          // Rally cadence from crank revolution data when in Cycling mode
          if (ride.mode == "Cycling" && data.length >= 8) {
            final flags = _u16(data, 0);
            final crankPresent = (flags & 0x20) != 0; // bit 5

            if (crankPresent) {
              final crankRevs = _u16(data, 4);
              final eventTime = _u16(data, 6); // in 1/1024 sec

              if (ride.lastCrankRevs != null &&
                  ride.lastCrankEventTime != null) {
                int dRevs = crankRevs - ride.lastCrankRevs!;
                int dTimeRaw = eventTime - ride.lastCrankEventTime!;
                if (dTimeRaw < 0) dTimeRaw += 65536; // wrap

                final dt = dTimeRaw / 1024.0; // seconds
                if (dRevs > 0 && dt > 0) {
                  final cad = (dRevs / dt) * 60.0;
                  final cadInt = cad.round();
                  if (cadInt > 0 && cadInt < 200) {
                    ride.setCadence(cadInt);
                  }
                }
              }

              ride.lastCrankRevs = crankRevs;
              ride.lastCrankEventTime = eventTime;
            }
          }
        });

        // RSC / Stryd - running cadence
        final rscChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: rscService,
          characteristicId: rscMeasurement,
        );
        _ble.subscribeToCharacteristic(rscChar).listen((data) {
          ride.logBytes("RSC", data);

          if (ride.mode == "Running" && data.length >= 2) {
            // Byte 1: per-leg cadence -> x2 for total steps per minute
            final raw = data[1] & 0xFF;
            final cad = raw * 2;
            if (cad > 0 && cad < 300) {
              ride.setCadence(cad);
            }
          }
        });
      }
    }, onError: (e) {
      debugPrint("Connection error: $e");
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
    await Permission.locationWhenInUse.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
  }

  @override
  Widget build(BuildContext context) {
    final ride = context.watch<RideState>();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text("Ride Dashboard"),
            const SizedBox(width: 8),
            Icon(
              ride.mode == "Cycling"
                  ? Icons.pedal_bike
                  : Icons.directions_run,
              color: Colors.white,
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) => ride.setMode(v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: "Cycling", child: Text("Cycling Mode")),
              PopupMenuItem(value: "Running", child: Text("Running Mode")),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.show_chart),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const MonthlyEfficiencyPage()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.bluetooth_searching),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BleScannerPage()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.list),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ByteLogPage()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Top: guidance + live metrics
          Expanded(
            flex: 2,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    ride.shiftMessage,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: ride.alertColor,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text("Cadence: ${ride.cadence} RPM"),
                  Text("Power: ${ride.power} W"),
                  Text("Heart Rate: ${ride.hr} BPM"),
                  Text(
                    "Efficiency: ${ride.efficiency.toStringAsFixed(2)} W/BPM",
                  ),
                ],
              ),
            ),
          ),

          // Bottom: recent efficiency graph
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: ride.recentEff.isEmpty
                      ? 1
                      : ride.recentEff.length.toDouble(),
                  minY: 0,
                  maxY: ride.recentEff.isEmpty
                      ? 2
                      : ride.recentEff
                              .map((e) => e["efficiency"] as double)
                              .fold(0.0, (p, e) => e > p ? e : p) +
                          2,
                  lineBarsData: [
                    LineChartBarData(
                      spots: ride.recentEff
                          .asMap()
                          .entries
                          .map((e) => FlSpot(
                                e.key.toDouble(),
                                e.value["efficiency"] as double,
                              ))
                          .toList(),
                      isCurved: true,
                      color: Colors.green,
                      barWidth: 3,
                      dotData: FlDotData(show: false),
                    ),
                  ],
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: true),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------
// BLE Scanner Page (auto-scan)
// -----------------------------
class BleScannerPage extends StatefulWidget {
  const BleScannerPage({super.key});

  @override
  State<BleScannerPage> createState() => _BleScannerPageState();
}

class _BleScannerPageState extends State<BleScannerPage> {
  late Stream<List<DiscoveredDevice>> scanStream;

  @override
  void initState() {
    super.initState();
    final ble = context.read<BleManager>();
    scanStream = ble.scan();
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.read<BleManager>();
    final ride = context.read<RideState>();

    return Scaffold(
      appBar: AppBar(title: const Text("Scan & Connect")),
      body: StreamBuilder<List<DiscoveredDevice>>(
        stream: scanStream,
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
// Raw BLE Byte Log Page
// -----------------------------
class ByteLogPage extends StatelessWidget {
  const ByteLogPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ride = context.watch<RideState>();
    return Scaffold(
      appBar: AppBar(title: const Text("Raw BLE Bytes")),
      body: ListView.builder(
        itemCount: ride.byteLog.length,
        itemBuilder: (context, index) {
          return ListTile(
            title: Text(
              ride.byteLog[index],
              style: const TextStyle(fontSize: 11),
            ),
          );
        },
      ),
    );
  }
}

// -----------------------------
// Monthly Efficiency Page
// -----------------------------
class MonthlyEfficiencyPage extends StatelessWidget {
  const MonthlyEfficiencyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ride = context.watch<RideState>();
    final samples = ride.last30DaySamples;

    return Scaffold(
      appBar: AppBar(title: const Text("Last 30 Days Efficiency")),
      body: samples.isEmpty
          ? const Center(
              child: Text(
                "No efficiency data yet.\nDo some workouts and come back!",
                textAlign: TextAlign.center,
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(8.0),
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: (samples.length - 1).toDouble(),
                  minY: 0,
                  maxY: samples
                          .map((e) => e.efficiency)
                          .fold<double>(0, (p, e) => e > p ? e : p) +
                      2,
                  lineBarsData: [
                    LineChartBarData(
                      spots: samples
                          .asMap()
                          .entries
                          .map(
                            (e) => FlSpot(
                              e.key.toDouble(),
                              e.value.efficiency,
                            ),
                          )
                          .toList(),
                      isCurved: true,
                      color: Colors.blue,
                      barWidth: 3,
                      dotData: FlDotData(show: false),
                    ),
                  ],
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: true),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
