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

  int? lastCrankRevs;
  int? lastCrankEventTime;

  final int windowSize = 10;
  final List<Map<String, dynamic>> recentEff = [];

  int optimalCadence = 90;
  String mode = "Cycling";

  final List<String> byteLog = [];

  final Box<EffSample> _effBox = Hive.box<EffSample>('efficiencyBox');

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

      if (cadence > 0 && efficiency > 0) {
        _effBox.add(EffSample(DateTime.now(), efficiency, cadence));
      }

      optimalCadence = _computeOptimalCadence();
    }
    notifyListeners();
  }

  int _computeOptimalCadence() {
    final shortTerm = _shortTermBestCadence();
    final monthly = _monthlyBestCadence();

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

  List<EffSample> get last30DaySamples {
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(days: 30));
    return _effBox.values.where((e) => e.time.isAfter(cutoff)).toList()
      ..sort((a, b) => a.time.compareTo(b.time));
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
// BLE Manager (v33: fully fixed cadence)
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

  // -----------------------------
  // UNIVERSAL CYCLING POWER CADENCE PARSER (Rally, Favero, SRM, Stages, Wahoo)
  // -----------------------------
  void _parseCyclingPower(List<int> data, RideState ride) {
    if (data.length < 8) return;

    // Flags 16-bit little endian
    int flags = data[0] | (data[1] << 8);

    // Instant power (2 bytes, signed)
    int power = (data[2] | (data[3] << 8));
    ride.setPower(power);

    // Crank cadence present (bit 5)
    bool hasCrank = (flags & 0x20) != 0;

    if (hasCrank) {
      int crankRevs = data[4] | (data[5] << 8);
      int crankEvent = data[6] | (data[7] << 8);

      if (ride.lastCrankRevs != null) {
        int dRevs = crankRevs - ride.lastCrankRevs!;
        if (dRevs < 0) dRevs += 65536;

        int dTime = crankEvent - ride.lastCrankEventTime!;
        if (dTime < 0) dTime += 65536;

        double secs = dTime / 1024.0;

        if (secs > 0 && dRevs > 0) {
          int cadence = ((dRevs / secs) * 60).round();

          if (cadence > 0 && cadence < 200) {
            ride.setCadence(cadence);
          }
        }
      }

      ride.lastCrankRevs = crankRevs;
      ride.lastCrankEventTime = crankEvent;
    }
  }

  // -----------------------------
  // STRYD RSC (Running Cadence)
  // -----------------------------
  void _parseRsc(List<int> data, RideState ride) {
    if (data.length < 2) return;

    int flags = data[0];
    bool hasCad = (flags & 0x02) != 0;
    if (!hasCad) return;

    int oneFoot = data[1];
    int trueCad = oneFoot * 2;

    if (trueCad > 20 && trueCad < 250) {
      ride.setCadence(trueCad);
    }
  }

  Future<void> connect(String deviceId, RideState ride) async {
    _ble.connectToDevice(id: deviceId).listen((update) {
      if (update.connectionState == DeviceConnectionState.connected) {
        
        // HR
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
          ride.logBytes("CP", data);
          _parseCyclingPower(data, ride);
        });

        // Running Cadence (Stryd)
        final rscChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: rscService,
          characteristicId: rscMeasurement,
        );
        _ble.subscribeToCharacteristic(rscChar).listen((data) {
          ride.logBytes("RSC", data);
          if (ride.mode == "Running") {
            _parseRsc(data, ride);
          }
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
// Scanner Page
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
// Raw BLE Byte Log
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
// Last 30 Days Efficiency Graph
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
