import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:charts_flutter/flutter.dart' as charts;

void main() {
  runApp(const GoldilocksApp());
}

class GoldilocksApp extends StatelessWidget {
  const GoldilocksApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoldilocksAI',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const RideDashboard(),
    );
  }
}

// -------------------
// Sensor Abstraction
// -------------------
abstract class SensorProvider {
  Stream<int> get cadenceStream;
  Stream<int> get powerStream;
  Stream<int> get hrStream;
}

// -------------------
// BLE Implementation
// -------------------
class BleSensorProvider implements SensorProvider {
  final FlutterBluePlus flutterBlue = FlutterBluePlus.instance;

  final _cadenceController = StreamController<int>.broadcast();
  final _powerController = StreamController<int>.broadcast();
  final _hrController = StreamController<int>.broadcast();

  BleSensorProvider() {
    _init();
  }

  void _init() async {
    try {
      final devices = await flutterBlue.scan(timeout: const Duration(seconds: 5)).toList();
      // Replace with actual device selection logic
      // For demo purposes, simulate scan data
    } catch (e) {
      print("BLE init error: $e");
    }
    // Simulate BLE update loop
    Timer.periodic(const Duration(seconds: 1), (_) {
      _cadenceController.add(Random().nextInt(40) + 60); // 60-100 RPM
      _powerController.add(Random().nextInt(150) + 100); // 100-250 W
      _hrController.add(Random().nextInt(40) + 120); // 120-160 bpm
    });
  }

  @override
  Stream<int> get cadenceStream => _cadenceController.stream;
  @override
  Stream<int> get powerStream => _powerController.stream;
  @override
  Stream<int> get hrStream => _hrController.stream;
}

// -------------------
// Mock Sensors for Simulator / Codemagic
// -------------------
class MockSensorProvider implements SensorProvider {
  final _cadenceController = StreamController<int>.broadcast();
  final _powerController = StreamController<int>.broadcast();
  final _hrController = StreamController<int>.broadcast();

  MockSensorProvider() {
    Timer.periodic(const Duration(seconds: 1), (_) {
      _cadenceController.add(Random().nextInt(40) + 60);
      _powerController.add(Random().nextInt(150) + 100);
      _hrController.add(Random().nextInt(40) + 120);
    });
  }

  @override
  Stream<int> get cadenceStream => _cadenceController.stream;
  @override
  Stream<int> get powerStream => _powerController.stream;
  @override
  Stream<int> get hrStream => _hrController.stream;
}

// -------------------
// Cadence Optimizer
// -------------------
class CadenceOptimizerAI {
  int currentCadence = 0;
  int currentPower = 0;
  int currentHr = 0;
  double currentEfficiency = 0;

  final Map<int, Map<int, List<double>>> efficiencyMap = {};

  void updateSensors(int cadence, int power, int hr) {
    currentCadence = cadence;
    currentPower = power;
    currentHr = hr;
    currentEfficiency = hr == 0 ? 0 : power / hr;
    _learnCadence(power, cadence, currentEfficiency);
  }

  void _learnCadence(int power, int cadence, double efficiency) {
    int pBucket = (power / 10).round() * 10;
    int cBucket = (cadence / 2).round() * 2;
    efficiencyMap.putIfAbsent(pBucket, () => {});
    efficiencyMap[pBucket]!.putIfAbsent(cBucket, () => []);
    efficiencyMap[pBucket]![cBucket]!.add(efficiency);
  }

  int predictOptimalCadence() {
    int pBucket = (currentPower / 10).round() * 10;
    if (!efficiencyMap.containsKey(pBucket)) return 90;
    final cadences = efficiencyMap[pBucket]!;
    final avgEff = cadences.map((c, effs) => MapEntry(c, effs.reduce((a, b) => a + b) / effs.length));
    return avgEff.entries.reduce((a, b) => a.value > b.value ? a : b).key;
  }

  String shiftPrompt() {
    int optimal = predictOptimalCadence();
    int diff = currentCadence - optimal;
    if ((diff).abs() > 5) {
      return diff > 0 ? "Shift to higher gear ($optimal RPM)" : "Shift to lower gear ($optimal RPM)";
    }
    return "Cadence optimal ($optimal RPM)";
  }

  bool isOptimal() {
    int optimal = predictOptimalCadence();
    return (currentCadence - optimal).abs() <= 5;
  }
}

// -------------------
// Ride Dashboard
// -------------------
class RideDashboard extends StatefulWidget {
  const RideDashboard({super.key});

  @override
  State<RideDashboard> createState() => _RideDashboardState();
}

class _RideDashboardState extends State<RideDashboard> {
  late SensorProvider sensors;
  final optimizer = CadenceOptimizerAI();

  int currentCadence = 0;
  int currentPower = 0;
  int currentHr = 0;
  double currentEfficiency = 0;

  final List<int> cadenceHistory = [];
  final List<int> optimalHistory = [];
  final int historyLen = 15;

  @override
  void initState() {
    super.initState();
    sensors = _chooseSensorProvider();
    _subscribeToSensors();
  }

  SensorProvider _chooseSensorProvider() {
    // Only BLE on real device, fallback to mock for simulator
    return (defaultTargetPlatform == TargetPlatform.iOS) ? BleSensorProvider() : MockSensorProvider();
  }

  void _subscribeToSensors() {
    sensors.cadenceStream.listen((c) {
      setState(() {
        currentCadence = c;
        _updateOptimizer();
      });
    });
    sensors.powerStream.listen((p) {
      setState(() {
        currentPower = p;
        _updateOptimizer();
      });
    });
    sensors.hrStream.listen((hr) {
      setState(() {
        currentHr = hr;
        _updateOptimizer();
      });
    });
  }

  void _updateOptimizer() {
    optimizer.updateSensors(currentCadence, currentPower, currentHr);
    currentEfficiency = optimizer.currentEfficiency;
    cadenceHistory.add(currentCadence);
    if (cadenceHistory.length > historyLen) cadenceHistory.removeAt(0);
    optimalHistory.add(optimizer.predictOptimalCadence());
    if (optimalHistory.length > historyLen) optimalHistory.removeAt(0);
  }

  @override
  Widget build(BuildContext context) {
    final isOptimal = optimizer.isOptimal();
    return Scaffold(
      appBar: AppBar(title: const Text('GoldilocksAI')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Current Metrics + Efficiency Score
            Card(
              color: isOptimal ? Colors.green[300] : Colors.red[300],
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Text("Cadence: $currentCadence RPM"),
                    Text("Power: $currentPower W"),
                    Text("HR: $currentHr bpm"),
                    Text("Efficiency: ${currentEfficiency.toStringAsFixed(2)} W/bpm"),
                    Text(optimizer.shiftPrompt(),
                        style: TextStyle(fontWeight: FontWeight.bold))
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Simple Line Graph for Cadence
            SizedBox(
              height: 200,
              child: charts.LineChart([
                charts.Series<int, int>(
                  id: 'Cadence',
                  colorFn: (_, __) => charts.MaterialPalette.blue.shadeDefault,
                  domainFn: (idx, _) => idx,
                  measureFn: (val, _) => val,
                  data: List.generate(cadenceHistory.length, (i) => cadenceHistory[i]),
                ),
                charts.Series<int, int>(
                  id: 'Optimal',
                  colorFn: (_, __) => charts.MaterialPalette.green.shadeDefault,
                  domainFn: (idx, _) => idx,
                  measureFn: (val, _) => optimalHistory[val],
                  data: List.generate(optimalHistory.length, (i) => i),
                )
              ], animate: true),
            )
          ],
        ),
      ),
    );
  }
}
