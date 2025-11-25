import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:vibration/vibration.dart';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';

void main() {
  runApp(const MyApp());
}

// -----------------------------
// Cadence Optimizer AI
// -----------------------------
class CadenceOptimizerAI {
  int currentCadence = 0;
  int currentPower = 0;
  int currentHR = 0;
  double currentEfficiency = 0.0;

  final Map<int, Map<int, List<double>>> efficiencyMap = {};

  final String logFileName = "ride_data.csv";
  late final File rideFile;

  CadenceOptimizerAI() {
    _initLogFile();
  }

  Future<void> _initLogFile() async {
    final dir = await getApplicationDocumentsDirectory();
    rideFile = File('${dir.path}/$logFileName');
    if (!await rideFile.exists()) {
      await rideFile.writeAsString(
          const ListToCsvConverter().convert([
        ["Time", "Cadence", "Power", "HR", "Efficiency", "OptimalCadence", "W/BPM"]
      ]) + '\n');
    }
  }

  void updateSensors(int cadence, int power, int hr) {
    currentCadence = cadence;
    currentPower = power;
    currentHR = hr;
    currentEfficiency = calculateEfficiency();
    learnCadence(power, cadence, currentEfficiency);
  }

  double calculateEfficiency() {
    if (currentHR == 0) return 0;
    return currentPower / currentHR;
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
    final cadences = efficiencyMap[powerBucket];
    if (cadences == null || cadences.isEmpty) return 90;
    final avgEff = cadences.map((c, e) =>
        MapEntry(c, e.reduce((a, b) => a + b) / e.length));
    int optimalCad = avgEff.entries.reduce((a, b) => a.value > b.value ? a : b).key;
    return optimalCad;
  }

  bool isCadenceOutOfRange() {
    int optimal = predictOptimalCadence();
    return (currentCadence - optimal).abs() > 5;
  }

  Future<void> logRide(int timeSec) async {
    int optimal = predictOptimalCadence();
    final row = [
      timeSec,
      currentCadence,
      currentPower,
      currentHR,
      currentEfficiency.toStringAsFixed(2),
      optimal,
      currentEfficiency.toStringAsFixed(2)
    ];
    await rideFile.writeAsString(ListToCsvConverter().convert([row]) + '\n', mode: FileMode.append);
  }
}

// -----------------------------
// Flutter App
// -----------------------------
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cadence Coach',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const Dashboard(),
    );
  }
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final FlutterBluePlus flutterBlue = FlutterBluePlus.instance;
  final CadenceOptimizerAI optimizer = CadenceOptimizerAI();

  List<BluetoothDevice> devices = [];
  BluetoothDevice? hrDevice;
  BluetoothDevice? powerDevice;

  StreamSubscription<List<ScanResult>>? scanSub;
  StreamSubscription<List<int>>? hrSub;
  StreamSubscription<List<int>>? powerSub;

  int cadence = 0;
  int power = 0;
  int hr = 0;

  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    startScan();
    _updateTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateSensors());
  }

  void startScan() {
    scanSub = flutterBlue.scan(timeout: const Duration(seconds: 5)).listen((results) {
      for (var r in results) {
        if (!devices.contains(r.device)) devices.add(r.device);
      }
      setState(() {});
    });
  }

  Future<void> connectDevice(BluetoothDevice device) async {
    await device.connect(timeout: const Duration(seconds: 10), autoConnect: false);
    final services = await device.discoverServices();
    for (var s in services) {
      for (var c in s.characteristics) {
        if (c.properties.notify) {
          await c.setNotifyValue(true);
          c.value.listen((data) {
            if (c.uuid.toString().toLowerCase().contains("2a37")) {
              hr = data[1];
            } else if (c.uuid.toString().toLowerCase().contains("2a63")) {
              power = (data[1] | (data[2] << 8));
              if (data[0] & 0x01 != 0) {
                cadence = data[3];
              }
            }
          });
        }
      }
    }
  }

  void _updateSensors() {
    optimizer.updateSensors(cadence, power, hr);
    optimizer.logRide(DateTime.now().second);
    if (optimizer.isCadenceOutOfRange()) {
      Vibration.vibrate(duration: 200);
    }
    setState(() {});
  }

  @override
  void dispose() {
    scanSub?.cancel();
    hrSub?.cancel();
    powerSub?.cancel();
    _updateTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Cadence Coach v37")),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: DropdownButton<BluetoothDevice>(
              hint: const Text("Select HR Device"),
              value: hrDevice,
              items: devices
                  .map((d) => DropdownMenuItem(value: d, child: Text(d.name ?? d.id.toString())))
                  .toList(),
              onChanged: (d) async {
                hrDevice = d;
                await connectDevice(d!);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: DropdownButton<BluetoothDevice>(
              hint: const Text("Select Power/Cadence Device"),
              value: powerDevice,
              items: devices
                  .map((d) => DropdownMenuItem(value: d, child: Text(d.name ?? d.id.toString())))
                  .toList(),
              onChanged: (d) async {
                powerDevice = d;
                await connectDevice(d!);
              },
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Cadence: $cadence RPM"),
                  Text("Power: $power W"),
                  Text("Heart Rate: $hr BPM"),
                  Text("Optimal Cadence: ${optimizer.predictOptimalCadence()} RPM"),
                  Text("Efficiency: ${optimizer.currentEfficiency.toStringAsFixed(2)}"),
                  Text(
                      "Cadence ${optimizer.isCadenceOutOfRange() ? "OUT OF RANGE!" : "Optimal"}",
                      style: TextStyle(
                          color: optimizer.isCadenceOutOfRange() ? Colors.red : Colors.green,
                          fontWeight: FontWeight.bold))
                ],
              ),
            ),
          )
        ],
      ),
    );
  }
}
