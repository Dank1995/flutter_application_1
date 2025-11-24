import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';

void main() {
  runApp(const CadenceCoachApp());
}

class CadenceCoachApp extends StatelessWidget {
  const CadenceCoachApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cadence Coach',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const WorkoutScreen(),
    );
  }
}

class WorkoutScreen extends StatefulWidget {
  const WorkoutScreen({super.key});

  @override
  State<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends State<WorkoutScreen> {
  final flutterBlue = FlutterBluePlus.instance;
  BluetoothDevice? connectedDevice;

  int cadence = 0;
  int power = 0;
  int heartRate = 0;
  double efficiency = 0.0;
  int optimalCadence = 0;
  double pace = 0.0;
  double distance = 0.0;

  final optimizer = CadenceOptimizerAI();
  StreamSubscription<Position>? positionStream;

  @override
  void initState() {
    super.initState();
    _startBluetoothScan();
    _startLocationTracking();
  }

  void _startBluetoothScan() {
    flutterBlue.startScan(timeout: const Duration(seconds: 5));

    flutterBlue.scanResults.listen((results) async {
      for (ScanResult r in results) {
        if (connectedDevice == null) {
          connectedDevice = r.device;
          await connectedDevice!.connect(
            timeout: const Duration(seconds: 10),
            // If your plugin version requires a license, add it here:
            // license: "demo",
          );
          flutterBlue.stopScan();
        }
      }
    });
  }

  void _startLocationTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    positionStream = Geolocator.getPositionStream().listen((Position pos) {
      setState(() {
        pace = pos.speed; // m/s
        distance += pos.speed; // simplistic accumulation
      });
    });
  }

  void _updateMetrics() {
    efficiency = optimizer.calculateEfficiency(cadence, power, heartRate);
    optimalCadence = optimizer.predictOptimalCadence(power, heartRate);
    _logData();
  }

  Future<void> _logData() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/ride_data.csv');
    final sink = file.openWrite(mode: FileMode.append);
    final timestamp = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    sink.writeln('$timestamp,$cadence,$power,$heartRate,$efficiency,$optimalCadence,$pace,$distance');
    await sink.flush();
    await sink.close();
  }

  @override
  void dispose() {
    positionStream?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _updateMetrics();
    return Scaffold(
      appBar: AppBar(title: const Text('Cadence Coach')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Text('Cadence: $cadence RPM'),
            Text('Power: $power W'),
            Text('Heart Rate: $heartRate BPM'),
            Text('Efficiency: ${efficiency.toStringAsFixed(2)} W/BPM'),
            Text('Optimal Cadence: $optimalCadence RPM'),
            Text('Pace: ${pace.toStringAsFixed(2)} m/s'),
            Text('Distance: ${distance.toStringAsFixed(2)} m'),
            const SizedBox(height: 20),
            Text(
              cadence < optimalCadence - 5
                  ? 'Shift to higher gear'
                  : cadence > optimalCadence + 5
                      ? 'Shift to lower gear'
                      : 'Cadence optimal',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}

class CadenceOptimizerAI {
  final Map<String, double> efficiencyMap = {};

  double calculateEfficiency(int cadence, int power, int heartRate) {
    if (heartRate == 0) return 0.0;
    final eff = power / heartRate;
    final key = '${cadence ~/ 5}_${power ~/ 50}';
    efficiencyMap[key] = (efficiencyMap[key] ?? eff + eff) / 2;
    return eff;
  }

  int predictOptimalCadence(int power, int heartRate) {
    if (efficiencyMap.isEmpty) return 90;
    double bestEff = 0.0;
    int bestCadence = 90;
    efficiencyMap.forEach((key, eff) {
      if (eff > bestEff) {
        bestEff = eff;
        bestCadence = int.parse(key.split('_')[0]) * 5;
      }
    });
    return bestCadence;
  }
}
