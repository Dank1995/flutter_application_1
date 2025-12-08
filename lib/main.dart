import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:vibration/vibration.dart';
import 'dart:io';

// ------------------------------------------------------------
// MAIN
// ------------------------------------------------------------
void main() {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => OptimiserState()),
        ChangeNotifierProvider(create: (_) => BleManager()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Physiological Optimiser',
      debugShowCheckedModeBanner: false,
      home: const OptimiserDashboard(),
    );
  }
}

// ============================================================
// FEEDBACK (HAPTIC ONLY)
// ============================================================
enum FeedbackMode { haptic }

// ============================================================
// OPTIMISER CORE (HR ONLY, NO AUDIO)
// ============================================================
class OptimiserState extends ChangeNotifier {
  double hr = 0;
  bool recording = false;

  final List<double> hrHistory = [];

  void _addHr(double bpm) {
    hrHistory.add(bpm);
    if (hrHistory.length > 60) hrHistory.removeAt(0);
  }

  double sensitivity = 3.0;
  void setSensitivity(double v) {
    sensitivity = v;
    notifyListeners();
  }

  FeedbackMode feedbackMode = FeedbackMode.haptic;

  void _signalUp() => _buzz(150);
  void _signalDown() => _buzz(800);

  void _buzz(int duration) async {
    final ok = await Vibration.hasVibrator() ?? false;
    if (!ok) return;
    Vibration.vibrate(duration: duration, intensities: [255]);
  }

  Timer? _loopTimer;
  DateTime? _lastTest;
  bool _testing = false;
  DateTime? _testStart;
  String? _dir;
  double? _hrBefore;
  bool _plateau = false;
  double? _plateauHr;

  double _avgUp = 0;
  double _avgDown = 0;
  int _upN = 0;
  int _downN = 0;

  String _advice = "Tap ▶ to start workout";

  // Toggle recording
  void toggleRecording() {
    recording = !recording;

    if (recording) {
      _reset();
      _startLoop();
      _advice = "Learning rhythm...";
    } else {
      _stopLoop();
      _advice = "Tap ▶ to start workout";
    }
    notifyListeners();
  }

  void _reset() {
    _plateau = false;
    _plateauHr = null;
    _lastTest = null;
    _testing = false;
    _testStart = null;
    _dir = null;
    _hrBefore = null;

    _avgUp = 0;
    _avgDown = 0;
    _upN = 0;
    _downN = 0;
  }

  void _startLoop() {
    _loopTimer?.cancel();
    _loopTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _stopLoop() {
    _loopTimer?.cancel();
    _loopTimer = null;
  }

  void setHr(double bpm) {
    if (bpm <= 0) return;
    hr = bpm;
    _addHr(bpm);
    notifyListeners();
  }

  // ============================================================
  // GRADIENT LOOP
  // ============================================================
  void _tick() {
    if (!recording || hr <= 0) return;

    final now = DateTime.now();
    const int interval = 15;
    const int delay = 15;

    if (_testing) {
      if (_testStart != null &&
          now.difference(_testStart!).inSeconds >= delay) {
        _evaluate();
      }
      return;
    }

    if (_lastTest != null &&
        now.difference(_lastTest!).inSeconds < interval) {
      return;
    }

    if (_plateau && _plateauHr != null) {
      if ((hr - _plateauHr!).abs() < sensitivity) {
        _advice = "Optimal rhythm";
        notifyListeners();
        return;
      }
      _plateau = false;
    }

    String dir;
    const double eps = 0.2;

    if (_upN + _downN < 2) {
      dir = (_dir == "up") ? "down" : "up";
    } else {
      if (_avgUp < _avgDown - eps) {
        dir = "up";
      } else if (_avgDown < _avgUp - eps) {
        dir = "down";
      } else {
        dir = (_dir == "up") ? "down" : "up";
      }
    }

    _startTest(dir);
  }

  void _startTest(String dir) {
    _testing = true;
    _dir = dir;
    _testStart = DateTime.now();
    _lastTest = _testStart;
    _hrBefore = hr;

    if (dir == "up") {
      _advice = "Increase rhythm";
      _signalUp();
    } else {
      _advice = "Ease rhythm";
      _signalDown();
    }

    notifyListeners();
  }

  void _evaluate() {
    _testing = false;
    if (_hrBefore == null) return;

    final delta = hr - _hrBefore!;
    final double plate = sensitivity;

    if (delta.abs() < plate) {
      _plateau = true;
      _plateauHr = hr;
      _advice = "Optimal rhythm";
      notifyListeners();
      return;
    }

    if (_dir == "up") {
      _upN++;
      _avgUp = ((_avgUp * (_upN - 1)) + delta) / _upN;
    } else {
      _downN++;
      _avgDown = ((_avgDown * (_downN - 1)) + delta) / _downN;
    }

    notifyListeners();
  }

  String get rhythmAdvice => recording ? _advice : "Tap ▶ to start workout";

  Color get rhythmColor {
    if (!recording) return Colors.grey;
    if (_advice == "Optimal rhythm") return Colors.green;
    if (_advice == "Learning rhythm...") return Colors.grey;
    return Colors.orange;
  }
}

// ============================================================
// BLE MANAGER — FULLY FIXED
// ============================================================
class BleManager extends ChangeNotifier {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  final Uuid hrService = Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid hrMeasurement = Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _hrSub;

  String? connectedId;
  String? connectedName;
  bool scanning = false;

  // Correct permissions on each OS
  Future<void> ensurePermissions() async {
    if (Platform.isAndroid) {
      await Permission.bluetoothScan.request();
      await Permission.bluetoothConnect.request();
      await Permission.locationWhenInUse.request();
    }
    // iOS requires NO runtime BT permissions
  }

  Future<List<DiscoveredDevice>> scanDevices(
      {Duration timeout = const Duration(seconds: 5)}) async {
    await ensurePermissions();
    scanning = true;
    notifyListeners();

    final devices = <DiscoveredDevice>[];
    final completer = Completer<List<DiscoveredDevice>>();

    _scanSub =
        _ble.scanForDevices(withServices: null).listen((d) {
      if (!devices.any((x) => x.id == d.id)) {
        devices.add(d);
        notifyListeners();
      }
    });

    Future.delayed(timeout, () async {
      await _scanSub?.cancel();
      scanning = false;
      notifyListeners();
      if (!completer.isCompleted) completer.complete(devices);
    });

    return completer.future;
  }

  Future<void> connect(String id, String name, OptimiserState opt) async {
    _connSub?.cancel();
    _hrSub?.cancel();

    _connSub = _ble.connectToDevice(id: id).listen((event) {
      if (event.connectionState == DeviceConnectionState.connected) {
        connectedId = id;
        connectedName = name.isEmpty ? "(unknown)" : name;
        notifyListeners();

        final c = QualifiedCharacteristic(
            deviceId: id, serviceId: hrService, characteristicId: hrMeasurement);

        _hrSub = _ble.subscribeToCharacteristic(c).listen((data) {
          final bpm = _parseHr(data);
          if (bpm != null) opt.setHr(bpm.toDouble());
        });
      } else if (event.connectionState == DeviceConnectionState.disconnected) {
        connectedId = null;
        connectedName = null;
        notifyListeners();
      }
    });
  }

  Future<void> disconnect() async {
    await _scanSub?.cancel();
    await _connSub?.cancel();
    await _hrSub?.cancel();
    connectedId = null;
    connectedName = null;
    notifyListeners();
  }

  // ------------------------------------------------------------
  // UNIVERSAL HR PARSER (works with all sensors)
  // ------------------------------------------------------------
  int? _parseHr(List<int> data) {
    if (data.isEmpty) return null;

    final flags = data[0];
    final bool hr16 = (flags & 0x01) != 0;

    if (hr16 && data.length >= 3) {
      return data[1] | (data[2] << 8);
    } else if (!hr16 && data.length >= 2) {
      return data[1];
    }
    return null;
  }
}

// ============================================================
// UI DASHBOARD
// ============================================================
class OptimiserDashboard extends StatelessWidget {
  const OptimiserDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    final opt = context.watch<OptimiserState>();
    final ble = context.watch<BleManager>();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Physiological Optimiser"),
        leading: IconButton(
          icon: Icon(
            ble.connectedId == null ? Icons.bluetooth : Icons.bluetooth_connected,
          ),
          onPressed: () => _openBleSheet(context),
        ),
      ),
      body: Column(
        children: [
          const SizedBox(height: 20),
          Text(
            opt.rhythmAdvice,
            style:
                TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: opt.rhythmColor),
          ),
          const SizedBox(height: 10),
          Text("HR: ${opt.hr.toStringAsFixed(0)} bpm"),
          const SizedBox(height: 20),
          SizedBox(height: 200, child: HrGraph(opt: opt)),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: opt.recording ? Colors.red : Colors.green,
        child: Icon(opt.recording ? Icons.stop : Icons.play_arrow),
        onPressed: () => opt.toggleRecording(),
      ),
    );
  }

  void _openBleSheet(BuildContext ctx) {
    final ble = ctx.read<BleManager>();
    showModalBottomSheet(
      context: ctx,
      builder: (_) => ChangeNotifierProvider.value(
        value: ble,
        child: const _BleBottomSheet(),
      ),
    );
  }
}

// ============================================================
// BLE DEVICE PICKER SHEET
// ============================================================
class _BleBottomSheet extends StatefulWidget {
  const _BleBottomSheet();

  @override
  State<_BleBottomSheet> createState() => _BleBottomSheetState();
}

class _BleBottomSheetState extends State<_BleBottomSheet> {
  List<DiscoveredDevice> devices = [];

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    final ble = context.read<BleManager>();
    devices = await ble.scanDevices();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleManager>();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.bluetooth),
                const SizedBox(width: 8),
                Text(
                  ble.scanning ? "Scanning…" : "Bluetooth Devices",
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (ble.connectedId != null)
                  IconButton(
                    icon: const Icon(Icons.link_off),
                    onPressed: () => ble.disconnect(),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 250,
              child: devices.isEmpty
                  ? const Center(child: Text("No devices found"))
                  : ListView.builder(
                      itemCount: devices.length,
                      itemBuilder: (_, i) {
                        final d = devices[i];
                        final name = d.name.isNotEmpty ? d.name : "(unknown)";
                        return ListTile(
                          leading: const Icon(Icons.favorite),
                          title: Text(name),
                          subtitle: Text(d.id),
                          onTap: () async {
                            final opt = context.read<OptimiserState>();
                            await ble.connect(d.id, name, opt);
                            if (mounted) Navigator.pop(context);
                          },
                        );
                      },
                    ),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: _scan,
              icon: const Icon(Icons.refresh),
              label: const Text("Rescan"),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// HR GRAPH
// ============================================================
class HrGraph extends StatelessWidget {
  final OptimiserState opt;
  const HrGraph({super.key, required this.opt});

  @override
  Widget build(BuildContext context) {
    final pts = opt.hrHistory
        .asMap()
        .entries
        .map((e) => FlSpot(e.key.toDouble(), e.value))
        .toList();

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: pts.isEmpty ? 1 : pts.length.toDouble(),
        minY: pts.isEmpty ? 60 : (pts.reduce((a, b) => a.y < b.y ? a : b).y - 5),
        maxY: pts.isEmpty ? 160 : (pts.reduce((a, b) => a.y > b.y ? a : b).y + 5),
        lineBarsData: [
          LineChartBarData(
            spots: pts,
            isCurved: true,
            barWidth: 3,
            color: Colors.green,
            dotData: FlDotData(show: false),
          )
        ],
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(show: false),
        gridData: FlGridData(show: false),
      ),
    );
  }
}
