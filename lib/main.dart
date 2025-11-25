import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';               // for haptic vibration
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vibration/vibration.dart';             // vibration plugin
import 'package:geolocator/geolocator.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cadence Coach v40',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const Dashboard(),
    );
  }
}

class CadenceOptimizerAI {
  int currentCadence = 0;
  int currentPower = 0;
  int currentHR = 0;

  Map<int, Map<int, List<double>>> efficiencyMap = {};
  late File rideFile;

  CadenceOptimizerAI() {
    _initFile();
  }

  Future<void> _initFile() async {
    final dir = await getApplicationDocumentsDirectory();
    rideFile = File('${dir.path}/ride_data.csv');
    if (!await rideFile.exists()) {
      await rideFile.writeAsString(
        'Time,Cadence,Power,HR,Efficiency,OptimalCadence\n',
      );
    }
  }

  void updateSensors(int cadence, int power, int hr) {
    currentCadence = cadence;
    currentPower = power;
    currentHR = hr;

    double eff = _calculateEfficiency();
    _learnCadence(power, cadence, eff);
  }

  double _calculateEfficiency() {
    return (currentHR > 0) ? currentPower / currentHR : 0.0;
  }

  void _learnCadence(int power, int cadence, double efficiency) {
    final powerBucket = (power / 10).round() * 10;
    final cadenceBucket = (cadence / 2).round() * 2;

    efficiencyMap.putIfAbsent(powerBucket, () => {});
    efficiencyMap[powerBucket]!
        .putIfAbsent(cadenceBucket, () => [])
        .add(efficiency);
  }

  int predictOptimalCadence() {
    final powerBucket = (currentPower / 10).round() * 10;
    final cadences = efficiencyMap[powerBucket] ?? {};
    if (cadences.isEmpty) return 90;

    final avgEff = {
      for (var e in cadences.entries)
        e.key: e.value.reduce((a, b) => a + b) / e.value.length
    };
    return avgEff.entries.reduce((a, b) => a.value > b.value ? a : b).key;
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

  List<BluetoothDevice> devices = [];
  BluetoothDevice? selectedDevice;

  StreamSubscription? scanSub;
  StreamSubscription? notifySub;

  int currentCadence = 0;
  int currentPower = 0;
  int currentHR = 0;
  int optimalCadence = 90;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  void _startScan() {
    devices.clear();
    scanSub = flutterBlue.startScan(timeout: const Duration(seconds: 5)).listen((result) {
      final device = result.device;
      if (!devices.contains(device)) {
        setState(() => devices.add(device));
      }
    }, onDone: () {
      flutterBlue.stopScan();
    });
  }

  Future<void> _connectDevice(BluetoothDevice device) async {
    try {
      await device.connect(autoConnect: false, timeout: const Duration(seconds: 10));
      setState(() => selectedDevice = device);

      List<BluetoothService> services = await device.discoverServices();
      for (var s in services) {
        for (var c in s.characteristics) {
          if (c.properties.notify) {
            await c.setNotifyValue(true);
            notifySub = c.value.listen((data) {
              // Example parsing: you’ll adjust based on real sensor specification
              if (data.length >= 3) {
                currentPower = data[1] + (data[2] << 8);
                currentCadence = (data.length > 3) ? data[3] : currentCadence;
                currentHR = data[1]; // if HR char
              }
              setState(() {
                optimalCadence = optimizer.predictOptimalCadence();
                optimizer.updateSensors(currentCadence, currentPower, currentHR);
              });

              if ((currentCadence - optimalCadence).abs() > 5) {
                Vibration.vibrate(duration: 200);
              }
            });
          }
        }
      }
    } catch (e) {
      print('Connection error: $e');
    }
  }

  @override
  void dispose() {
    scanSub?.cancel();
    notifySub?.cancel();
    selectedDevice?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cadence Coach v40')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text('Select BLE Device'),
            ...devices.map((d) => ElevatedButton(
                  onPressed: () => _connectDevice(d),
                  child: Text(d.name.isNotEmpty ? d.name : d.id.toString()),
                )),
            const SizedBox(height: 20),
            Text('Cadence: $currentCadence RPM'),
            Text('Power: $currentPower W'),
            Text('HR: $currentHR bpm'),
            Text('Optimal Cadence: $optimalCadence RPM'),
          ],
        ),
      ),
    );
  }
}
