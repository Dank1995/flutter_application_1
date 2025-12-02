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

// =============================================================
// APP ROOT
// =============================================================
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

// =============================================================
// Ride State: Optimiser + Learning + Smoothing
// =============================================================
class RideState extends ChangeNotifier {
  int cadence = 0;
  int power = 0;
  int hr = 0;
  double efficiency = 0;

  int? lastValidRunningCadence;

  final int windowSize = 10;
  final List<Map<String, dynamic>> recentEff = [];

  int optimalCadence = 90;
  String mode = "Cycling";

  final List<String> byteLog = [];

  int? lastCrankRevs;
  int? lastCrankEventTime;

  final Box<EffSample> _effBox = Hive.box<EffSample>('efficiencyBox');

  // ---- Raw logging ----
  void logBytes(String device, List<int> bytes) {
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    byteLog.add("${DateTime.now().toIso8601String()} | $device: $hex");
    if (byteLog.length > 1000) byteLog.removeAt(0);
    notifyListeners();
  }

  // ---- Setters ----
  void setHr(int v) {
    hr = v;
    _updateEfficiency();
  }

  void setCadence(int v) {
    cadence = v;
    if (mode == "Running" && v > 50) lastValidRunningCadence = v;
    _updateEfficiency();
  }

  void setPower(int v) {
    power = v;
    _updateEfficiency();
  }

  void setMode(String m) {
    mode = m;
    notifyListeners();
  }

  // ---- Efficiency engine ----
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
    final short = _shortTermBestCadence();
    final month = _monthlyBestCadence();

    if (month == null && short == null) return 90;
    if (month == null) return short!;
    if (short == null) return month;

    return ((short * 0.6) + (month * 0.4)).round();
  }

  int? _shortTermBestCadence() {
    if (recentEff.isEmpty) return null;

    final map = <int, List<double>>{};
    for (var e in recentEff) {
      map.putIfAbsent(e["cadence"], () => []).add(e["efficiency"]);
    }

    int? best;
    double bestEff = -1;
    map.forEach((cad, list) {
      final avg = list.reduce((a, b) => a + b) / list.length;
      if (avg > bestEff) {
        bestEff = avg;
        best = cad;
      }
    });

    return best;
  }

  int? _monthlyBestCadence() {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    final samples = _effBox.values.where((e) => e.time.isAfter(cutoff)).toList();
    if (samples.isEmpty) return null;

    final map = <int, List<double>>{};
    for (var s in samples) {
      map.putIfAbsent(s.cadence, () => []).add(s.efficiency);
    }

    int? best;
    double bestEff = -1;
    map.forEach((cad, list) {
      final avg = list.reduce((a, b) => a + b) / list.length;
      if (avg > bestEff) {
        bestEff = avg;
        best = cad;
      }
    });

    return best;
  }

  List<EffSample> get last30DaySamples {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    return _effBox.values
        .where((e) => e.time.isAfter(cutoff))
        .toList()
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

// =============================================================
// BLE Manager
// =============================================================
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

  int _u16(List<int> b, int o) =>
      (b[o] & 0xFF) | ((b[o + 1] & 0xFF) << 8);

  int _i16(List<int> b, int o) {
    final v = _u16(b, o);
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  // -------------------------------------------------------------
  // MAIN CONNECT FUNCTION
  // -------------------------------------------------------------
  Future<void> connect(String id, RideState ride) async {
    _ble.connectToDevice(id: id).listen((update) {
      if (update.connectionState == DeviceConnectionState.connected) {
        // ---------------------------------------------------------
        // HEART RATE
        // ---------------------------------------------------------
        final hrChar = QualifiedCharacteristic(
          deviceId: id,
          serviceId: heartRateService,
          characteristicId: heartRateMeasurement,
        );
        _ble.subscribeToCharacteristic(hrChar).listen((data) {
          ride.logBytes("HR", data);
          if (data.length > 1) ride.setHr(data[1]);
        });

        // ---------------------------------------------------------
        // CYCLING POWER (RALLY) → includes power + crank cadence
        // ---------------------------------------------------------
        final pChar = QualifiedCharacteristic(
          deviceId: id,
          serviceId: cyclingPowerService,
          characteristicId: powerMeasurement,
        );
        _ble.subscribeToCharacteristic(pChar).listen((data) {
          ride.logBytes("Power", data);

          if (data.length >= 4) {
            final p = _i16(data, 2);
            ride.setPower(p);
          }

          if (ride.mode == "Cycling" && data.length >= 8) {
            final flags = _u16(data, 0);
            final crank = (flags & 0x20) != 0;

            if (crank) {
              final revs = _u16(data, 4);
              final t = _u16(data, 6);

              if (ride.lastCrankRevs != null &&
                  ride.lastCrankEventTime != null) {
                int dr = revs - ride.lastCrankRevs!;
                int dtRaw = t - ride.lastCrankEventTime!;
                if (dtRaw < 0) dtRaw += 65536;

                final dt = dtRaw / 1024.0;
                if (dr > 0 && dt > 0) {
                  final cad = (dr / dt) * 60.0;
                  if (cad > 0 && cad < 200) ride.setCadence(cad.round());
                }
              }

              ride.lastCrankRevs = revs;
              ride.lastCrankEventTime = t;
            }
          }
        });

        // ---------------------------------------------------------
        // RSC / STRYD — Running cadence (Stryd sends single-leg)
        // ---------------------------------------------------------
        final rscChar = QualifiedCharacteristic(
          deviceId: id,
          serviceId: rscService,
          characteristicId: rscMeasurement,
        );
        _ble.subscribeToCharacteristic(rscChar).listen((data) {
          ride.logBytes("RSC", data);

          if (ride.mode != "Running" || data.length < 4) return;

          // Stryd Format:
          // data[1..2] = speed (m/s * 256)
          // data[3] = single-leg cadence (steps/min)
          final speedRaw = _u16(data, 1);
          final speedMs = speedRaw / 256.0;

          final singleLeg = data[3] & 0xFF;
          int totalCad = singleLeg * 2;

          // Stopped
          if (speedMs < 0.3) {
            ride.setCadence(0);
            return;
          }

          // Fake low dip protection
          if (singleLeg < 40 &&
              ride.lastValidRunningCadence != null &&
              ride.lastValidRunningCadence! > 80) {
            totalCad = ride.lastValidRunningCadence!;
          }

          if (totalCad > 0 && totalCad < 260) {
            ride.setCadence(totalCad);
          }
        });
      }
    });
  }
}

// =============================================================
// DASHBOARD UI
// =============================================================
class RideDashboard extends StatelessWidget {
  const RideDashboard({super.key});
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
            onSelected: ride.setMode,
            itemBuilder: (_) => const [
              PopupMenuItem(value: "Cycling", child: Text("Cycling")),
              PopupMenuItem(value: "Running", child: Text("Running")),
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
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: ride.alertColor,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text("Cadence: ${ride.cadence} RPM"),
                  Text("Power: ${ride.power} W"),
                  Text("Heart Rate: ${ride.hr} BPM"),
                  Text("Efficiency: ${ride.efficiency.toStringAsFixed(2)}"),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: EfficiencyGraph(ride: ride),
          ),
        ],
      ),
    );
  }
}

// =============================================================
// Efficiency graph widget
// =============================================================
class EfficiencyGraph extends StatelessWidget {
  final RideState ride;
  const EfficiencyGraph({super.key, required this.ride});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
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
                      .reduce((a, b) => a > b ? a : b) +
                  2,
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
            leftTitles: AxisTitles(
              sideTitles: SideTitles(showTitles: true),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================
// BLE Scanner (Auto-scan)
// =============================================================
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
            itemBuilder: (context, i) {
              final d = devices[i];
              return ListTile(
                title: Text(d.name.isNotEmpty ? d.name : "Unknown"),
                subtitle: Text(d.id),
                onTap: () {
                  ble.connect(d.id, ride);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Connecting to ${d.name}")),
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

// =============================================================
// BYTE LOG PAGE
// =============================================================
class ByteLogPage extends StatelessWidget {
  const ByteLogPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ride = context.watch<RideState>();

    return Scaffold(
      appBar: AppBar(title: const Text("Raw BLE Bytes")),
      body: ListView.builder(
        itemCount: ride.byteLog.length,
        itemBuilder: (context, i) =>
            ListTile(title: Text(ride.byteLog[i], style: const TextStyle(fontSize: 11))),
      ),
    );
  }
}

// =============================================================
// Monthly Efficiency Page
// =============================================================
class MonthlyEfficiencyPage extends StatelessWidget {
  const MonthlyEfficiencyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ride = context.watch<RideState>();
    final list = ride.last30DaySamples;

    return Scaffold(
      appBar: AppBar(title: const Text("Last 30 Days Efficiency")),
      body: list.isEmpty
          ? const Center(
              child: Text("No data yet – do some workouts!", textAlign: TextAlign.center),
            )
          : Padding(
              padding: const EdgeInsets.all(8),
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: (list.length - 1).toDouble(),
                  minY: 0,
                  maxY: list
                          .map((e) => e.efficiency)
                          .reduce((a, b) => a > b ? a : b) +
                      2,
                  lineBarsData: [
                    LineChartBarData(
                      spots: list
                          .asMap()
                          .entries
                          .map((e) =>
                              FlSpot(e.key.toDouble(), e.value.efficiency))
                          .toList(),
                      isCurved: true,
                      color: Colors.blue,
                      barWidth: 3,
                      dotData: FlDotData(show: false),
                    )
                  ],
                  titlesData: FlTitlesData(
                    leftTitles:
                        AxisTitles(sideTitles: SideTitles(showTitles: true)),
                    bottomTitles:
                        AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                ),
              ),
            ),
    );
  }
}
