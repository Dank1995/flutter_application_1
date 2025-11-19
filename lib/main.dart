import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() => runApp(const CadenceCoachApp());

class CadenceCoachApp extends StatelessWidget {
  const CadenceCoachApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(title: 'Cadence Coach', theme: ThemeData.dark(), home: const WorkoutScreen());
  }
}

class WorkoutScreen extends StatefulWidget {
  const WorkoutScreen({super.key});
  @override
  State<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends State<WorkoutScreen> {
  // Live metrics
  int cadenceSpm = 0; // Stryd Pod 2
  int hrBpm = 0;      // Garmin HRM-Dual
  int paceSecPerKm = 300; // TODO: add GPS plugin later (5:00 min/km placeholder)
  int powerW = 0;     // Stryd power
  String prompt = "";
  bool premiumEnabled = true;

  @override
  void initState() {
    super.initState();
    _scanAndConnect();
  }

  void _scanAndConnect() async {
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
    FlutterBluePlus.scanResults.listen((results) async {
      for (final r in results) {
        final name = (r.device.name).toLowerCase();
        // Connect to Garmin HRM-Dual
        if (name.contains("garmin")) {
          await r.device.connect();
          final services = await r.device.discoverServices();
          for (final s in services) {
            if (s.uuid.toString().toLowerCase() == "0000180d-0000-1000-8000-00805f9b34fb") {
              for (final c in s.characteristics) {
                if (c.uuid.toString().toLowerCase() == "00002a37-0000-1000-8000-00805f9b34fb") {
                  await c.setNotifyValue(true);
                  c.onValueReceived.listen((data) {
                    if (data.isNotEmpty) {
                      final flags = data[0];
                      int hr;
                      if ((flags & 0x01) == 0x01 && data.length >= 3) {
                        hr = (data[1] | (data[2] << 8));
                      } else {
                        hr = data.length >= 2 ? data[1] : 0;
                      }
                      setState(() => hrBpm = hr);
                      _updatePrompt();
                    }
                  });
                }
              }
            }
          }
        }
        // Connect to Stryd Pod 2 (UUIDs must be discovered with nRF Connect)
        if (name.contains("stryd")) {
          await r.device.connect();
          final services = await r.device.discoverServices();
          for (final s in services) {
            // Replace "fc00"/"fc01"/"fc02" with actual UUIDs from your Stryd Pod 2
            if (s.uuid.toString().toLowerCase().contains("fc00")) {
              for (final c in s.characteristics) {
                final cid = c.uuid.toString().toLowerCase();
                // Running Power characteristic
                if (cid.contains("fc01")) {
                  await c.setNotifyValue(true);
                  c.onValueReceived.listen((data) {
                    // TODO: parse per Stryd spec; placeholder assumes first byte is watts
                    final w = data.isNotEmpty ? data[0] : 0;
                    setState(() => powerW = w);
                    _updatePrompt();
                  });
                }
                // Cadence characteristic
                if (cid.contains("fc02")) {
                  await c.setNotifyValue(true);
                  c.onValueReceived.listen((data) {
                    // TODO: parse per Stryd spec; placeholder assumes first byte is spm
                    final spm = data.isNotEmpty ? data[0] : 0;
                    setState(() => cadenceSpm = spm);
                    _updatePrompt();
                  });
                }
              }
            }
          }
        }
      }
    });
  }

  void _updatePrompt() {
    // Efficiency (premium)
    // Running: min/km per BPM; Cycling: W/BPM
    final paceMinPerKm = paceSecPerKm / 60.0;
    final runEfficiency = hrBpm > 0 ? (paceMinPerKm / hrBpm) : 0.0;
    final rideEfficiency = hrBpm > 0 ? (powerW / hrBpm) : 0.0;

    // Cadence coaching (default targets)
    final optimalRun = 176;
    final optimalRide = 90;
    final optimal = powerW > 0 ? optimalRide : optimalRun; // if power present, assume ride; else run
    final diff = optimal - cadenceSpm;

    if (diff.abs() >= 5) {
      prompt = diff > 0
          ? "Increase cadence (+$diff) → target $optimal"
          : "Reduce cadence (−${diff.abs()}) → target $optimal";
    } else {
      prompt = "Cadence optimal ($optimal)";
    }

    // Update UI labels via setState already done in callers
    // You could also store efficiency values if needed
  }

  String _formatPace(int secPerKm) {
    final m = secPerKm ~/ 60;
    final s = secPerKm % 60;
    return "$m:${s.toString().padLeft(2, '0')} min/km";
  }

  @override
  Widget build(BuildContext context) {
    final paceText = _formatPace(paceSecPerKm);
    final paceMinPerKm = paceSecPerKm / 60.0;
    final runEff = hrBpm > 0 ? (paceMinPerKm / hrBpm) : 0.0;
    final rideEff = hrBpm > 0 ? (powerW / hrBpm) : 0.0;

    return Scaffold(
      appBar: AppBar(title: const Text("Workout")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Metrics
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _stat("Cadence", "$cadenceSpm", "spm"),
                _stat("HR", "$hrBpm", "BPM"),
                _stat("Pace", paceText, ""),
              ],
            ),
            const SizedBox(height: 16),
            // Premium efficiency
            if (premiumEnabled)
              Text(
                powerW > 0
                    ? "Efficiency: ${rideEff.toStringAsFixed(2)} W/BPM"
                    : "Efficiency: ${runEff.toStringAsFixed(3)} min/km per BPM",
                style: const TextStyle(fontSize: 22, color: Colors.green),
              ),
            const SizedBox(height: 16),
            // Prompt
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(prompt, style: const TextStyle(fontSize: 20)),
            ),
            const SizedBox(height: 16),
            // Scan button (re-scan)
            ElevatedButton(
              onPressed: () async {
                await FlutterBluePlus.stopScan();
                await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
              },
              child: const Text("Scan BLE"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String title, String value, String unit) {
    return Column(
      children: [
        Text(title, style: const TextStyle(color: Colors.grey)),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
            if (unit.isNotEmpty) Padding(
              padding: const EdgeInsets.only(left: 4.0),
              child: Text(unit, style: const TextStyle(color: Colors.grey)),
            ),
          ],
        ),
      ],
    );
  }
}
