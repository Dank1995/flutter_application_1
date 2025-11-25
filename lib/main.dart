import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:vibration/vibration.dart';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';

void main() => runApp(const CadenceApp());

class CadenceApp extends StatelessWidget {
  const CadenceApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: Dashboard());
  }
}

class CadenceOptimizerAI {
  int currentCadence = 0;
  int currentPower = 0;
  int currentHR = 0;
  double currentEfficiency = 0.0;
  Map<int, Map<int, List<double>>> efficiencyMap = {};
  late File rideFile;

  CadenceOptimizerAI() {
    _initFile();
  }

  Future<void> _initFile() async {
    final dir = await getApplicationDocumentsDirectory();
    rideFile = File('${dir.path}/ride_data.csv');
    if (!rideFile.existsSync()) {
      rideFile.writeAsStringSync('Time,Cadence,Power,HR,Efficiency,OptimalCadence,W/BPM\n');
    }
  }

  void updateSensors(int cadence, int power, int hr) {
    currentCadence = cadence;
    currentPower = power;
    currentHR = hr;
    currentEfficiency = (hr != 0) ? power / hr : 0.0;
    _learn(cadence, power, currentEfficiency);
  }

  void _learn(int cadence, int power, double efficiency) {
    final powerBucket = (power / 10).round() * 10;
    final cadenceBucket = (cadence / 2).round() * 2;
    efficiencyMap.putIfAbsent(powerBucket, () => {});
    efficiencyMap[powerBucket]!.putIfAbsent(cadenceBucket, () => []);
    efficiencyMap[powerBucket]![cadenceBucket]!.add(efficiency);
  }

  int predictOptimalCadence() {
    final powerBucket = (currentPower / 10).round() * 10;
    if (!efficiencyMap.containsKey(powerBucket)) return 90;
    final cadences = efficiencyMap[powerBucket]!;
    final avgEff = {for (var k in cadences.keys) k: cadences[k]!.reduce((a,b)=>a+b)/cadences[k]!.length};
    return avgEff.entries.reduce((a,b) => a.value > b.value ? a : b).key;
  }

  String shiftPrompt() {
    final optimal = predictOptimalCadence();
    final diff = currentCadence - optimal;
    if (diff.abs() > 5) return 'Shift ${diff>0?'down':'up'} to $optimal RPM';
    return 'Cadence optimal ($optimal RPM)';
  }

  Future<void> logRide(int timeSec) async {
    final optimal = predictOptimalCadence();
    final row = [timeSec, currentCadence, currentPower, currentHR, currentEfficiency.toStringAsFixed(2), optimal, currentEfficiency.toStringAsFixed(2)];
    rideFile.writeAsStringSync(const ListToCsvConverter().convert([row]) + '\n', mode: FileMode.append);
  }
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final CadenceOptimizerAI optimizer = CadenceOptimizerAI();
  final FlutterBluePlus flutterBlue = FlutterBluePlus.instance;
  BluetoothDevice? selectedDevice;
  StreamSubscription? scanSub;
  StreamSubscription? hrSub;
  StreamSubscription? powerSub;

  int cadence = 0;
  int power = 0;
  int hr = 0;
  bool outOfZone = false;

  @override
  void initState() {
    super.initState();
    _scanDevices();
  }

  void _scanDevices() {
    scanSub = flutterBlue.scan(timeout: const Duration(seconds: 5)).listen((result) {
      // show in UI dropdown
    });
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    selectedDevice = device;
    await device.connect(autoConnect: false, timeout: const Duration(seconds: 10));
    final services = await device.discoverServices();
    for (var s in services) {
      for (var c in s.characteristics) {
        if (c.uuid.toString().toLowerCase().contains('2a37')) {
          await c.setNotifyValue(true);
          hrSub = c.value.listen((data) {
            hr = data[1];
            _updateOptimizer();
          });
        } else if (c.uuid.toString().toLowerCase().contains('2a63')) {
          await c.setNotifyValue(true);
          powerSub = c.value.listen((data) {
            power = (data[1] << 8) + data[0];
            cadence = data.length > 3 ? data[3] : cadence;
            _updateOptimizer();
          });
        }
      }
    }
  }

  void _updateOptimizer() {
    optimizer.updateSensors(cadence, power, hr);
    final prompt = optimizer.shiftPrompt();
    setState(() {
      outOfZone = prompt.contains('Shift');
    });
    if (outOfZone) Vibration.vibrate(duration: 200);
    optimizer.logRide(DateTime.now().millisecondsSinceEpoch ~/ 1000);
  }

  @override
  void dispose() {
    scanSub?.cancel();
    hrSub?.cancel();
    powerSub?.cancel();
    selectedDevice?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Cadence Coach v38")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            DropdownButton<BluetoothDevice>(
              hint: const Text("Select BLE Device"),
              value: selectedDevice,
              items: [],
              onChanged: (d) => connectToDevice(d!),
            ),
            const SizedBox(height: 20),
            Text("Cadence: $cadence RPM"),
            Text("Power: $power W"),
            Text("HR: $hr BPM"),
            Text("Status: ${outOfZone?'Out of optimal zone':'Optimal zone'}"),
          ],
        ),
      ),
    );
  }
}
