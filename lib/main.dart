import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:location/location.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

enum WorkoutType { run, cycle }

class CadenceOptimizerAI {
  int currentCadence = 0;
  int currentPower = 0;
  int currentHr = 0;
  double currentEfficiency = 0.0;
  WorkoutType mode = WorkoutType.run;

  void updateSensors({
    required int cadence,
    required int power,
    required int hr,
    required int paceSecPerKm,
  }) {
    currentCadence = cadence;
    currentPower = power;
    currentHr = hr;
    currentEfficiency = calculateEfficiency(paceSecPerKm);
  }

  double calculateEfficiency(int paceSecPerKm) {
    if (currentHr == 0) return 0;
    if (mode == WorkoutType.run) {
      final paceMinPerKm = paceSecPerKm / 60.0;
      return paceMinPerKm / currentHr;
    } else {
      return currentPower / currentHr;
    }
  }

  String shiftPrompt() {
    final optimal = mode == WorkoutType.cycle ? 90 : 176;
    final diff = optimal - currentCadence;
    if (diff.abs() >= 5) {
      return diff > 0
          ? "Increase cadence (+$diff) → target $optimal"
          : "Reduce cadence (−${diff.abs()}) → target $optimal";
    }
    return "Cadence optimal ($optimal)";
  }
}

class Workout {
  final DateTime date;
  final WorkoutType type;
  final double distanceKm;
  final Duration duration;
  final int avgHr;
  final int avgCadence;
  final double avgPaceMinPerKm;
  final double avgPower;
  final double efficiencyScore;

  Workout({
    required this.date,
    required this.type,
    required this.distanceKm,
    required this.duration,
    required this.avgHr,
    required this.avgCadence,
    required this.avgPaceMinPerKm,
    required this.avgPower,
    required this.efficiencyScore,
  });
}

class WorkoutRepository {
  final List<Workout> _history = [];
  void addWorkout(Workout w) => _history.add(w);
  List<Workout> get history => List.unmodifiable(_history);
}

void main() {
  runApp(const CadenceCoachApp());
}

class CadenceCoachApp extends StatelessWidget {
  const CadenceCoachApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cadence Coach',
      theme: ThemeData.dark(),
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tabIndex = 0;
  final repo = WorkoutRepository();

  @override
  Widget build(BuildContext context) {
    final pages = [
      WorkoutPager(onWorkoutSaved: (w) {
        setState(() => repo.addWorkout(w));
      }),
      HistoryScreen(workouts: repo.history),
      const SettingsScreen(),
    ];
    return Scaffold(
      body: pages[_tabIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tabIndex,
        onTap: (i) => setState(() => _tabIndex = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.directions_run), label: "Workout"),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: "History"),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: "Settings"),
        ],
      ),
    );
  }
}

class WorkoutPager extends StatefulWidget {
  final void Function(Workout) onWorkoutSaved;
  const WorkoutPager({super.key, required this.onWorkoutSaved});
  @override
  State<WorkoutPager> createState() => _WorkoutPagerState();
}

class _WorkoutPagerState extends State<WorkoutPager> {
  final optimizer = CadenceOptimizerAI();
  WorkoutType mode = WorkoutType.run;

  int cadence = 0;
  int hr = 0;
  int power = 0;
  int paceSecPerKm = 300;
  String prompt = "Waiting for sensors...";
  double efficiency = 0.0;

  final Location _location = Location();
  StreamSubscription<LocationData>? _locSub;
  final List<LatLng> _routePoints = [];
  LatLng? _currentPos;
  bool recording = false;
  DateTime? startTime;
  double distanceMeters = 0.0;
  final Distance _haversine = const Distance();

  int _sumHr = 0;
  int _sumCadence = 0;
  int _sumPower = 0;
  int _samples = 0;

  @override
  void initState() {
    super.initState();
    optimizer.mode = mode;
    _initLocation();
  }

  Future<void> _initLocation() async {
    bool serviceEnabled = await _location.serviceEnabled();
    if (!serviceEnabled) serviceEnabled = await _location.requestService();
    var permissionGranted = await _location.hasPermission();
    if (permissionGranted == PermissionStatus.denied) {
      permissionGranted = await _location.requestPermission();
    }
    if (permissionGranted == PermissionStatus.granted ||
        permissionGranted == PermissionStatus.grantedLimited) {
      _locSub = _location.onLocationChanged.listen((LocationData locData) {
        if (locData.latitude == null || locData.longitude == null) return;
        final point = LatLng(locData.latitude!, locData.longitude!);
        setState(() {
          _currentPos = point;
          if (recording) {
            if (_routePoints.isNotEmpty) {
              distanceMeters += _haversine.as(LengthUnit.Meter, _routePoints.last, point);
            }
            _routePoints.add(point);
            if (mode == WorkoutType.run && locData.speed != null && locData.speed! > 0.3) {
              final speedMps = locData.speed!;
              paceSecPerKm = max(180, min(900, (1000 / speedMps).round()));
            }
          }
        });
      });
    }
  }

  void _onSensorUpdate() {
    optimizer.updateSensors(
      cadence: cadence,
      power: power,
      hr: hr,
      paceSecPerKm: paceSecPerKm,
    );
    setState(() {
      efficiency = optimizer.currentEfficiency;
      prompt = optimizer.shiftPrompt();
      if (recording) {
        _sumHr += hr;
        _sumCadence += cadence;
        _sumPower += power;
        _samples += 1;
      }
    });
  }

  void _startStop() {
    setState(() {
      if (!recording) {
        recording = true;
        startTime = DateTime.now();
        distanceMeters = 0.0;
        _routePoints.clear();
        _sumHr = 0;
        _sumCadence = 0;
        _sumPower = 0;
        _samples = 0;
      } else {
        recording = false;
        final endTime = DateTime.now();
        final duration = endTime.difference(startTime!);
        final distanceKm = distanceMeters / 1000.0;
        final avgHr = _samples > 0 ? (_sumHr / _samples).round() : 0;
        final avgCadence = _samples > 0 ? (_sumCadence / _samples).round() : 0;
        final avgPower = mode == WorkoutType.cycle && _samples > 0 ? (_sumPower / _samples) : 0.0;
        final avgPaceMinPerKm = mode == WorkoutType.run && distanceKm > 0
            ? (duration.inSeconds / 60.0) / distanceKm
            : 0.0;
        final efficiencyScore = optimizer.currentEfficiency;

        final workout = Workout(
          date: endTime,
          type: mode,
          distanceKm: distanceKm,
          duration: duration,
          avgHr: avgHr,
          avgCadence: avgCadence,
          avgPaceMinPerKm: avgPaceMinPerKm,
          avgPower: avgPower,
          efficiencyScore: efficiencyScore,
        );
        widget.onWorkoutSaved(workout);
      }
    });
  }

  String _formatPace(int secPerKm) {
    final minutes = secPerKm ~/ 60;
    final seconds = secPerKm % 60;
    return "$minutes:${seconds.toString().padLeft(2, '0')} /km";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Workout")),
      body: Column(
        children: [
          Text("Cadence: $cadence"),
          Text("Heart Rate: $hr"),
          Text("Power: $power"),
          Text("Efficiency: ${efficiency.toStringAsFixed(2)}"),
          Text("Prompt: $prompt"),
          IconButton(
            icon: const Icon(Icons.play_arrow),
            onPressed: recording ? null : _startStop,
          ),
          IconButton(
            icon: const Icon(Icons