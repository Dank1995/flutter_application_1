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
// App Root
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
// Ride State: Optimiser + History + Sensor Memory
// =============================================================
class RideState extends ChangeNotifier {
  int cadence = 0;
  int power = 0;
  int hr = 0;
  double efficiency = 0;

  // For running: remember last good cadence to avoid fake dips
  int? lastValidRunningCadence;

  // For cycling crank-based cadence (CP/CSC)
  int? lastCrankRevs;
  int? lastCrankEventTime; // 1/1024 s ticks

  // Rolling window + monthly learning
  final int windowSize = 10;
  final List<Map<String, dynamic>> recentEff = [];
  int optimalCadence = 90;

  String mode = "Cycling"; // "Cycling" or "Running"

  // Raw BLE packet log
  final List<String> byteLog = [];

  final Box<EffSample> _effBox = Hive.box<EffSample>('efficiencyBox');

  // ---------------- Raw byte logging ----------------
  void logBytes(String device, List<int> bytes) {
    final hex =
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    byteLog.add("${DateTime.now().toIso8601String()} | $device: $hex");
    if (byteLog.length > 1000) byteLog.removeAt(0);
    notifyListeners();
  }

  // ---------------- Setters ----------------
  void setHr(int v) {
    hr = v;
    _updateEfficiency();
  }

  void setCadence(int v) {
    cadence = v;

    if (mode == "Running" && v > 50) {
      // store only realistic running cadence as valid
      lastValidRunningCadence = v;
    }

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

  // ---------------- Efficiency Engine ----------------
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

      if (cadence > 0 && efficiency > 0) {
        _effBox.add(EffSample(DateTime.now(), efficiency, cadence));
      }

      optimalCadence = _computeOptimalCadence();
    }
    notifyListeners();
  }

  int _computeOptimalCadence() {
    final short = _shortTermBestCadence();
    final monthly = _monthlyBestCadence();

    if (short == null && monthly == null) return 90;
    if (short == null) return monthly!;
    if (monthly == null) return short;

    // blend: 60% recent, 40% last 30 days
    return ((short * 0.6) + (monthly * 0.4)).round();
  }

  int? _shortTermBestCadence() {
    if (recentEff.isEmpty) return null;

    final buckets = <int, List<double>>{};
    for (final e in recentEff) {
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
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    final samples =
        _effBox.values.where((e) => e.time.isAfter(cutoff)).toList();
    if (samples.isEmpty) return null;

    final buckets = <int, List<double>>{};
    for (final s in samples) {
      buckets.putIfAbsent(s.cadence, () => []).add(s.efficiency);
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

  List<EffSample> get last30DaySamples {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    return _effBox.values
        .where((e) => e.time.isAfter(cutoff))
        .toList()
      ..sort((a, b) => a.time.compareTo(b.time));
  }

  // ---------------- UI helpers ----------------
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
// BLE Manager: HR + CP + RSC + CSC (universal sensors)
// =============================================================
class BleManager {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  // Heart Rate
  final Uuid heartRateService =
      Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid heartRateMeasurement =
      Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");

  // Running Speed & Cadence (Stryd etc.)
  final Uuid rscService =
      Uuid.parse("00001814-0000-1000-8000-00805F9B34FB");
  final Uuid rscMeasurement =
      Uuid.parse("00002A53-0000-1000-8000-00805F9B34FB");

  // Cycling Power (Rally, Assioma, etc.)
  final Uuid cyclingPowerService =
      Uuid.parse("00001818-0000-1000-8000-00805F9B34FB");
  final Uuid powerMeasurement =
      Uuid.parse("00002A63-0000-1000-8000-00805F9B34FB");

  // Cycling Speed & Cadence (ANY cadence sensor)
  final Uuid cscService =
      Uuid.parse("00001816-0000-1000-8000-00805F9B34FB");
  final Uuid cscMeasurement =
      Uuid.parse("00002A5B-0000-1000-8000-00805F9B34FB");

  // ---------------- Scanner ----------------
  Stream<List<DiscoveredDevice>> scan() {
    final devices = <DiscoveredDevice>[];
    return _ble.scanForDevices(withServices: []).map((d) {
      if (!devices.any((x) => x.id == d.id)) devices.add(d);
      return devices;
    });
  }

  // ---------------- Helpers ----------------
  int _u16(List<int> b, int o) =>
      (b[o] & 0xFF) | ((b[o + 1] & 0xFF) << 8);

  int _i16(List<int> b, int o) {
    final v = _u16(b, o);
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  // ---------------- Connect + auto-detect services ----------------
  Future<void> connect(String deviceId, RideState ride) async {
    _ble.connectToDevice(id: deviceId).listen((update) async {
      if (update.connectionState == DeviceConnectionState.connected) {
        // Discover services once, then attach based on what the device actually has
        final services = await _ble.discoverServices(deviceId);

        for (final s in services) {
          // HEART RATE
          if (s.serviceId == heartRateService) {
            final ch = s.characteristics.firstWhere(
              (c) => c.characteristicId == heartRateMeasurement,
              orElse: () => s.characteristics.first,
            );
            final hrChar = QualifiedCharacteristic(
              deviceId: deviceId,
              serviceId: s.serviceId,
              characteristicId: ch.characteristicId,
            );
            _ble.subscribeToCharacteristic(hrChar).listen((data) {
              ride.logBytes("HR", data);
              if (data.length > 1) {
                ride.setHr(data[1]);
              }
            });
          }

          // CYCLING POWER (power + possible crank cadence)
          if (s.serviceId == cyclingPowerService) {
            final ch = s.characteristics.firstWhere(
              (c) => c.characteristicId == powerMeasurement,
              orElse: () => s.characteristics.first,
            );
            final pChar = QualifiedCharacteristic(
              deviceId: deviceId,
              serviceId: s.serviceId,
              characteristicId: ch.characteristicId,
            );
            _ble.subscribeToCharacteristic(pChar).listen((data) {
              ride.logBytes("CP", data);

              if (data.length >= 4) {
                final p = _i16(data, 2);
                ride.setPower(p);
              }

              // Rally-style cadence from crank revs (flags bit 5)
              if (ride.mode == "Cycling" && data.length >= 8) {
                final flags = _u16(data, 0);
                final crankPresent = (flags & 0x20) != 0;
                if (crankPresent) {
                  final revs = _u16(data, 4);
                  final t = _u16(data, 6);
                  _updateCrankCadenceFromRevs(ride, revs, t);
                }
              }
            });
          }

          // RSC / STRYD
          if (s.serviceId == rscService) {
            final ch = s.characteristics.firstWhere(
              (c) => c.characteristicId == rscMeasurement,
              orElse: () => s.characteristics.first,
            );
            final rscChar = QualifiedCharacteristic(
              deviceId: deviceId,
              serviceId: s.serviceId,
              characteristicId: ch.characteristicId,
            );
            _ble.subscribeToCharacteristic(rscChar).listen((data) {
              ride.logBytes("RSC", data);

              // Only use for running mode
              if (ride.mode != "Running" || data.length < 4) return;

              // data[1..2] = speed (m/s * 256)
              final speedRaw = _u16(data, 1);
              final speedMs = speedRaw / 256.0;

              // data[3] = single-leg cadence, Stryd uses per-leg
              final singleLeg = data[3] & 0xFF;
              int totalCad = singleLeg * 2;

              // If basically not moving → cadence 0
              if (speedMs < 0.3) {
                ride.setCadence(0);
                return;
              }

              // Fake dips: low raw but previously high cadence
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

          // CSC: generic cadence/speed sensors
          if (s.serviceId == cscService) {
            final ch = s.characteristics.firstWhere(
              (c) => c.characteristicId == cscMeasurement,
              orElse: () => s.characteristics.first,
            );
            final cscChar = QualifiedCharacteristic(
              deviceId: deviceId,
              serviceId: s.serviceId,
              characteristicId: ch.characteristicId,
            );
            _ble.subscribeToCharacteristic(cscChar).listen((data) {
              ride.logBytes("CSC", data);

              if (data.isEmpty) return;
              final flags = data[0];
              int index = 1;

              // Optional wheel data (speed) – not used yet, but ready
              if ((flags & 0x01) != 0 && data.length >= index + 6) {
                // final wheelRevs = (data[index] |
                //    (data[index+1] << 8) |
                //    (data[index+2] << 16) |
                //    (data[index+3] << 24));
                // final wheelEvent = (data[index+4] | (data[index+5] << 8));
                index += 6;
              }

              // Crank cadence
              if ((flags & 0x02) != 0 && data.length >= index + 4) {
                final crankRevs = _u16(data, index);
                final crankEvent = _u16(data, index + 2);
                _updateCrankCadenceFromRevs(ride, crankRevs, crankEvent);
              }
            });
          }
        }
      }
    });
  }

  void _updateCrankCadenceFromRevs(
      RideState ride, int crankRevs, int eventTime) {
    if (ride.lastCrankRevs != null && ride.lastCrankEventTime != null) {
      int dRevs = crankRevs - ride.lastCrankRevs!;
      int dTime = eventTime - ride.lastCrankEventTime!;
      if (dTime < 0) dTime += 65536; // wrap 16-bit

      final dt = dTime / 1024.0; // seconds
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

// =============================================================
// Ride Dashboard UI
// =============================================================
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
            onSelected: ride.setMode,
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
                MaterialPageRoute(
                    builder: (_) => const MonthlyEfficiencyPage()),
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
          // Guidance + metrics
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
                  Text(
                      "Efficiency: ${ride.efficiency.toStringAsFixed(2)} W/BPM"),
                ],
              ),
            ),
          ),
          // Recent efficiency graph
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
// Efficiency Graph
// =============================================================
class EfficiencyGraph extends StatelessWidget {
  final RideState ride;
  const EfficiencyGraph({super.key, required this.ride});

  @override
  Widget build(BuildContext context) {
    final eff = ride.recentEff;

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: eff.isEmpty ? 1 : eff.length.toDouble(),
          minY: 0,
          maxY: eff.isEmpty
              ? 2
              : eff
                      .map((e) => e["efficiency"] as double)
                      .fold<double>(0, (p, e) => e > p ? e : p) +
                  2,
          lineBarsData: [
            LineChartBarData(
              spots: eff
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
            leftTitles:
                AxisTitles(sideTitles: SideTitles(showTitles: true)),
            bottomTitles:
                AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
        ),
      ),
    );
  }
}

// =============================================================
// BLE Scanner Page (auto-scan)
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

// =============================================================
// Raw BLE Bytes Page
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

// =============================================================
// Monthly Efficiency Page
// =============================================================
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
                    leftTitles:
                        AxisTitles(sideTitles: SideTitles(showTitles: true)),
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
