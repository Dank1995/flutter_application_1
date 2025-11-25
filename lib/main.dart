import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:audioplayers/audioplayers.dart';

void main() => runApp(const MyApp());

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

// -----------------------------
// Cadence Optimizer AI
// -----------------------------
class CadenceOptimizerAI {
  int currentCadence = 0;
  int currentPower = 0;
  int currentHR = 0;
  double currentEfficiency = 0.0;

  final Map<int, Map<int, List<double>>> efficiencyMap = {};

  void updateSensors(int cadence, int power, int hr) {
    currentCadence = cadence;
    currentPower = power;
    currentHR = hr;
    currentEfficiency = _calculateEfficiency();
    _learnCadence(power, cadence, currentEfficiency);
  }

  double _calculateEfficiency() => currentHR == 0 ? 0 : currentPower / currentHR;

  void _learnCadence(int power, int cadence, double efficiency) {
    int powerBucket = (power / 10).round() * 10;
    int cadenceBucket = (cadence / 2).round() * 2;
    efficiencyMap.putIfAbsent(powerBucket, () => {});
    efficiencyMap[powerBucket]!.putIfAbsent(cadenceBucket, () => []);
    efficiencyMap[powerBucket]![cadenceBucket]!.add(efficiency);
  }

  int predictOptimalCadence() {
    int powerBucket = (currentPower / 10).round() * 10;
    if (!efficiencyMap.containsKey(powerBucket)) return 90;
    final cadences = efficiencyMap[powerBucket]!;
    final avgEff = {
      for (var entry in cadences.entries)
        entry.key: entry.value.reduce((a, b) => a + b) / entry.value.length
    };
    return avgEff.entries.reduce((a, b) => a.value > b.value ? a : b).key;
  }
}

// -----------------------------
// BLE Sensor Manager
// -----------------------------
class SensorManager {
  FlutterBluePlus flutterBlue = FlutterBluePlus.instance;
  List<BluetoothDevice> devices = [];
  BluetoothDevice? selectedHRM;
  BluetoothDevice? selectedPowerCadence;

  StreamSubscription? hrSub;
  StreamSubscription? powerSub;

  final Map<String, int> sensorData = {
    "cadence": 0,
    "power": 0,
    "hr": 0,
  };

  Future<void> scanDevices() async {
    devices = await flutterBlue.scan(timeout: const Duration(seconds: 5)).toList();
  }

  Future<void> connectToDevice(BluetoothDevice device, {required bool isHRM}) async {
    await device.connect();
    List<BluetoothService> services = await device.discoverServices();
    if (isHRM) {
      final hrChar = services
          .expand((s) => s.characteristics)
          .firstWhere((c) => c.uuid.toString().toLowerCase() == "00002a37-0000-1000-8000-00805f9b34fb");
      hrSub = device.subscribe(hrChar).listen((data) {
        sensorData["hr"] = data[1];
      });
    } else {
      final powerChar = services
          .expand((s) => s.characteristics)
          .firstWhere((c) => c.uuid.toString().toLowerCase() == "00002a63-0000-1000-8000-00805f9b34fb");
      powerSub = device.subscribe(powerChar).listen((data) {
        sensorData["power"] = int.fromBytes(data.sublist(1, 3), Endian.little);
        sensorData["cadence"] = data.length > 3 ? data[3] : 0;
      });
    }
  }
}

// -----------------------------
// Dashboard
// -----------------------------
class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final optimizer = CadenceOptimizerAI();
  final sensorManager = SensorManager();
  final AudioPlayer audioPlayer = AudioPlayer();

  int seconds = 0;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) => updateSensors());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  void updateSensors() {
    int cadence = sensorManager.sensorData["cadence"]!;
    int power = sensorManager.sensorData["power"]!;
    int hr = sensorManager.sensorData["hr"]!;

    optimizer.updateSensors(cadence, power, hr);
    int optimal = optimizer.predictOptimalCadence();
    bool outOfRange = (cadence - optimal).abs() > 5;

    if (outOfRange) audioPlayer.play(AssetSource('assets/alert.mp3'));

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    int cadence = optimizer.currentCadence;
    int optimal = optimizer.predictOptimalCadence();
    int power = optimizer.currentPower;
    int hr = optimizer.currentHR;

    return Scaffold(
      appBar: AppBar(title: const Text("Cadence Coach")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Text("Cadence: $cadence RPM (Optimal: $optimal)"),
            Text("Power: $power W"),
            Text("Heart Rate: $hr BPM"),
            const SizedBox(height: 20),
            DropdownButton<BluetoothDevice>(
              hint: const Text("Select HRM"),
              items: sensorManager.devices.map((d) => DropdownMenuItem(
                value: d,
                child: Text(d.name ?? "Unknown"),
              )).toList(),
              onChanged: (dev) async {
                if (dev != null) {
                  await sensorManager.connectToDevice(dev, isHRM: true);
                  setState(() {});
                }
              },
            ),
            DropdownButton<BluetoothDevice>(
              hint: const Text("Select Power/Cadence"),
              items: sensorManager.devices.map((d) => DropdownMenuItem(
                value: d,
                child: Text(d.name ?? "Unknown"),
              )).toList(),
              onChanged: (dev) async {
                if (dev != null) {
                  await sensorManager.connectToDevice(dev, isHRM: false);
                  setState(() {});
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
