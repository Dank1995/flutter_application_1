import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:collection';
import 'package:fl_chart/fl_chart.dart';

// -----------------------------
// Optimizer logic
// -----------------------------
class CadenceOptimizer {
  int currentCadence = 0;
  int currentPower = 0;
  int currentHR = 0;

  final int tolerance = 5; // ±RPM range for optimal

  // Efficiency map: power bucket -> cadence bucket -> list of efficiencies
  Map<int, Map<int, List<double>>> efficiencyMap = {};

  double currentEfficiency = 0.0;

  void updateSensorData(int cadence, int power, int hr) {
    currentCadence = cadence;
    currentPower = power;
    currentHR = hr;

    currentEfficiency = calculateEfficiency();
    learnCadence(power, cadence, currentEfficiency);
  }

  double calculateEfficiency() {
    if (currentHR == 0) return 0;
    return currentPower / currentHR; // W/BPM
  }

  void learnCadence(int power, int cadence, double efficiency) {
    int powerBucket = (power / 10).round() * 10;
    int cadenceBucket = (cadence / 2).round() * 2;

    efficiencyMap.putIfAbsent(powerBucket, () => {});
    efficiencyMap[powerBucket]!.putIfAbsent(cadenceBucket, () => []);
    efficiencyMap[powerBucket]![cadenceBucket]!.add(efficiency);
  }

  int predictOptimalCadence() {
    int powerBucket = (currentPower / 10).round() * 10;
    var cadences = efficiencyMap[powerBucket] ?? {};

    if (cadences.isEmpty) return 90; // default
    Map<int, double> avgEff = {};
    cadences.forEach((cad, effs) {
      avgEff[cad] = effs.reduce((a, b) => a + b) / effs.length;
    });
    int optimal = avgEff.entries.reduce((a, b) => a.value > b.value ? a : b).key;
    return optimal;
  }

  bool isCadenceOptimal() {
    int optimal = predictOptimalCadence();
    return (currentCadence - optimal).abs() <= tolerance;
  }
}

// -----------------------------
// BLE Sensor Integration
// -----------------------------
class BleManager {
  FlutterBluePlus flutterBlue = FlutterBluePlus.instance;

  StreamSubscription<ScanResult>? scanSub;
  BluetoothDevice? hrDevice;
  BluetoothDevice? powerDevice;

  BluetoothCharacteristic? hrChar;
  BluetoothCharacteristic? powerChar;

  final void Function(int cadence, int power, int hr) onData;

  BleManager({required this.onData});

  Future<void> startScan() async {
    scanSub = flutterBlue.scan(timeout: const Duration(seconds: 5)).listen((result) {
      if (hrDevice == null && (result.device.name.contains("HRM") || result.device.name.contains("HR"))) {
        hrDevice = result.device;
      }
      if (powerDevice == null && result.device.name.contains("RS200")) {
        powerDevice = result.device;
      }
    }, onDone: () async {
      await connectDevices();
    });
  }

  Future<void> connectDevices() async {
    if (hrDevice != null) {
      await hrDevice!.connect();
      var services = await hrDevice!.discoverServices();
      for (var s in services) {
        for (var c in s.characteristics) {
          if (c.uuid.toString().toLowerCase().contains("2a37")) {
            hrChar = c;
            await c.setNotifyValue(true);
            c.value.listen((data) {
              int hr = data.length > 1 ? data[1] : 0;
              onData(0, 0, hr); // cadence/power updated separately
            });
          }
        }
      }
    }

    if (powerDevice != null) {
      await powerDevice!.connect();
      var services = await powerDevice!.discoverServices();
      for (var s in services) {
        for (var c in s.characteristics) {
          if (c.uuid.toString().toLowerCase().contains("2a63")) {
            powerChar = c;
            await c.setNotifyValue(true);
            c.value.listen((data) {
              int flags = data[0];
              int power = data.length > 2 ? data[1] | (data[2] << 8) : 0;
              int cadence = (flags & 0x01) != 0 && data.length > 3 ? data[3] : 0;
              onData(cadence, power, 0);
            });
          }
        }
      }
    }
  }

  Future<void> stop() async {
    await scanSub?.cancel();
    if (hrDevice != null) await hrDevice!.disconnect();
    if (powerDevice != null) await powerDevice!.disconnect();
  }
}

// -----------------------------
// Flutter UI
// -----------------------------
void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  final CadenceOptimizer optimizer = CadenceOptimizer();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoldilocksAI',
      home: Scaffold(
        appBar: AppBar(title: Text('GoldilocksAI Cadence Optimizer')),
        body: OptimizerDashboard(optimizer: optimizer),
      ),
    );
  }
}

class OptimizerDashboard extends StatefulWidget {
  final CadenceOptimizer optimizer;
  OptimizerDashboard({required this.optimizer});

  @override
  _OptimizerDashboardState createState() => _OptimizerDashboardState();
}

class _OptimizerDashboardState extends State<OptimizerDashboard> {
  int currentCadence = 0;
  int currentPower = 0;
  int currentHR = 0;
  double currentEfficiency = 0;

  late BleManager bleManager;

  // History for graphing
  final int maxPoints = 30;
  final Queue<FlSpot> efficiencySpots = Queue<FlSpot>();
  int timeCounter = 0;

  @override
  void initState() {
    super.initState();
    bleManager = BleManager(onData: (cad, power, hr) {
      setState(() {
        currentCadence = cad > 0 ? cad : currentCadence;
        currentPower = power > 0 ? power : currentPower;
        currentHR = hr > 0 ? hr : currentHR;

        widget.optimizer.updateSensorData(currentCadence, currentPower, currentHR);
        currentEfficiency = widget.optimizer.currentEfficiency;

        // Add point to graph
        efficiencySpots.add(FlSpot(timeCounter.toDouble(), currentEfficiency));
        if (efficiencySpots.length > maxPoints) efficiencySpots.removeFirst();
        timeCounter++;
      });
    });
    bleManager.startScan();
  }

  @override
  void dispose() {
    bleManager.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool optimal = widget.optimizer.isCadenceOptimal();
    int optimalCad = widget.optimizer.predictOptimalCadence();

    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(height: 10),
          Text('Current Cadence: $currentCadence RPM', style: TextStyle(fontSize: 24)),
          Text('Optimal Cadence: $optimalCad RPM', style: TextStyle(fontSize: 24)),
          SizedBox(height: 10),
          Text('Power: $currentPower W', style: TextStyle(fontSize: 20)),
          Text('Heart Rate: $currentHR BPM', style: TextStyle(fontSize: 20)),
          SizedBox(height: 20),
          Text('Efficiency (W/BPM): ${currentEfficiency.toStringAsFixed(2)}',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          SizedBox(height: 20),
          Container(
            width: 150,
            height: 150,
            decoration: BoxDecoration(
              color: optimal ? Colors.green : Colors.red,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                optimal ? 'OPTIMAL' : 'ADJUST',
                style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          SizedBox(height: 30),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: SizedBox(
              height: 250,
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: maxPoints.toDouble(),
                  minY: 0,
                  maxY: 5, // adjust dynamically if needed
                  lineBarsData: [
                    LineChartBarData(
                      spots: efficiencySpots.toList(),
                      isCurved: true,
                      colors: [Colors.blue],
                      barWidth: 3,
                      belowBarData: BarAreaData(show: true, colors: [Colors.blue.withOpacity(0.3)]),
                      dotData: FlDotData(show: false),
                    ),
                  ],
                  titlesData: FlTitlesData(
                    bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true)),
                  ),
                  gridData: FlGridData(show: true),
                  borderData: FlBorderData(show: true),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}