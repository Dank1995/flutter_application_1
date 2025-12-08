import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:vibration/vibration.dart';

// ------------------------------------------------------------
// ENTRY POINT
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
      title: "Physiological Optimiser",
      debugShowCheckedModeBanner: false,
      home: const OptimiserDashboard(),
      theme: ThemeData(
        primarySwatch: Colors.blue,
        appBarTheme: const AppBarTheme(centerTitle: true),
      ),
    );
  }
}

// ===========================================================================
// HAPTIC FEEDBACK ONLY
// ===========================================================================
enum FeedbackMode { haptic }

// ===========================================================================
// OPTIMISER STATE — HR-BASED LEARNING WITH HAPTIC PROMPTS
// ===========================================================================
class OptimiserState extends ChangeNotifier {
  double hr = 0;
  bool recording = false;
  double sensitivity = 3.0;

  List<double> hrHistory = [];

  // Gradient loop internals
  Timer? _loop;
  String _advice = "Tap ▶ to start workout";

  bool _testInProgress = false;
  String? _direction;
  DateTime? _lastTest;
  DateTime? _testStart;
  double? _hrBefore;

  double _avgUp = 0;
  double _avgDown = 0;
  int _nUp = 0;
  int _nDown = 0;

  bool _plateau = false;
  double? _plateauHr;

  // ---------------------------------------------------------------------------
  // PUBLIC HELPERS
  // ---------------------------------------------------------------------------
  void setSensitivity(double v) {
    sensitivity = v;
    notifyListeners();
  }

  String get advice => recording ? _advice : "Tap ▶ to start workout";

  Color get adviceColor {
    if (!recording) return Colors.grey;
    if (_advice == "Optimal rhythm") return Colors.green;
    if (_advice == "Learning rhythm...") return Colors.grey;
    return Colors.orange;
  }

  // ---------------------------------------------------------------------------
  // RECORDING CONTROL
  // ---------------------------------------------------------------------------
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
    _avgUp = 0;
    _avgDown = 0;
    _nUp = 0;
    _nDown = 0;

    _plateau = false;
    _plateauHr = null;

    _testInProgress = false;
    _lastTest = null;
    _testStart = null;
    _direction = null;
    _hrBefore = null;
  }

  void _startLoop() {
    _loop?.cancel();
    _loop = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _stopLoop() {
    _loop?.cancel();
    _loop = null;
  }

  // ---------------------------------------------------------------------------
  // HEART RATE INPUT
  // ---------------------------------------------------------------------------
  void setHr(double bpm) {
    if (bpm <= 0) return;
    hr = bpm;
    hrHistory.add(bpm);
    if (hrHistory.length > 80) hrHistory.removeAt(0);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // CORE GRADIENT TICK LOGIC
  // ---------------------------------------------------------------------------
  void _tick() {
    if (!recording || hr <= 0) return;

    final now = DateTime.now();
    const interval = 15; // secs between tests
    const delay = 15; // wait time to evaluate

    // If currently evaluating a perturbation
    if (_testInProgress) {
      if (_testStart != null &&
          now.difference(_testStart!).inSeconds >= delay) {
        _evaluateTest();
      }
      return;
    }

    // Wait enough time before next test
    if (_lastTest != null &&
        now.difference(_lastTest!).inSeconds < interval) return;

    // Plateau handling
    if (_plateau && _plateauHr != null) {
      if ((hr - _plateauHr!).abs() < sensitivity) {
        _advice = "Optimal rhythm";
        notifyListeners();
        return;
      }
      _plateau = false;
    }

    // Choose direction
    String dir;
    const eps = 0.2;

    if (_nUp + _nDown < 2) {
      dir = (_direction == "up") ? "down" : "up";
    } else {
      if (_avgUp < _avgDown - eps) {
        dir = "up";
      } else if (_avgDown < _avgUp - eps) {
        dir = "down";
      } else {
        dir = (_direction == "up") ? "down" : "up";
      }
    }

    _startTest(dir);
  }

  void _startTest(String dir) {
    _testInProgress = true;
    _direction = dir;
    _testStart = DateTime.now();
    _lastTest = _testStart;
    _hrBefore = hr;

    if (dir == "up") {
      _advice = "Increase rhythm";
      _buzzShort();
    } else {
      _advice = "Ease rhythm";
      _buzzLong();
    }

    notifyListeners();
  }

  void _evaluateTest() {
    _testInProgress = false;

    if (_hrBefore == null) return;
    final delta = hr - _hrBefore!;
    final plate = sensitivity;

    // Plateau detection
    if (delta.abs() < plate) {
      _plateau = true;
      _plateauHr = hr;
      _advice = "Optimal rhythm";
      notifyListeners();
      return;
    }

    // Reinforcement
    if (_direction == "up") {
      _nUp++;
      _avgUp = ((_avgUp * (_nUp - 1)) + delta) / _nUp;
    } else {
      _nDown++;
      _avgDown = ((_avgDown * (_nDown - 1)) + delta) / _nDown;
    }

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // HAPTIC SIGNALS
  // ---------------------------------------------------------------------------
  Future<void> _buzzShort() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 150, intensities: [255]);
    }
  }

  Future<void> _buzzLong() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 700, intensities: [255]);
    }
  }
}

// ===========================================================================
// BLE MANAGER — SCAN, CONNECT, SUBSCRIBE TO HR
// ===========================================================================
class BleManager extends ChangeNotifier {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  final Uuid hrService =
      Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB"); // HR service
  final Uuid hrChar =
      Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB"); // HR measurement

  StreamSubscription<DiscoveredDevice>? _scan;
  StreamSubscription<ConnectionStateUpdate>? _conn;
  StreamSubscription<List<int>>? _hrStream;

  bool scanning = false;
  String? connectedId;
  String? connectedName;

  // ---------------------------------------------------------------------------
  // PERMISSIONS
  // ---------------------------------------------------------------------------
  Future<void> _permissions() async {
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.locationWhenInUse.request();
  }

  // ---------------------------------------------------------------------------
  // SCAN
  // ---------------------------------------------------------------------------
  Future<List<DiscoveredDevice>> scanDevices(
      {Duration timeout = const Duration(seconds: 5)}) async {
    await _permissions();

    final List<DiscoveredDevice> results = [];
    scanning = true;
    notifyListeners();

    final completer = Completer<List<DiscoveredDevice>>();

    _scan = _ble.scanForDevices(withServices: []).listen((d) {
      if (!results.any((x) => x.id == d.id)) {
        results.add(d);
        notifyListeners();
      }
    }, onError: (_) {
      if (!completer.isCompleted) completer.complete(results);
    });

    Future.delayed(timeout, () async {
      await _scan?.cancel();
      scanning = false;
      notifyListeners();
      if (!completer.isCompleted) completer.complete(results);
    });

    return completer.future;
  }

  // ---------------------------------------------------------------------------
  // CONNECT
  // ---------------------------------------------------------------------------
  Future<void> connect(String id, String name, OptimiserState opt) async {
    await _conn?.cancel();
    await _hrStream?.cancel();

    _conn = _ble.connectToDevice(id: id).listen((state) {
      if (state.connectionState == DeviceConnectionState.connected) {
        connectedId = id;
        connectedName = name.isEmpty ? "(unknown)" : name;
        notifyListeners();

        final characteristic = QualifiedCharacteristic(
          deviceId: id,
          serviceId: hrService,
          characteristicId: hrChar,
        );

        _hrStream = _ble.subscribeToCharacteristic(characteristic).listen((data) {
          if (data.length > 1) {
            final bpm = data[1].toDouble();
            opt.setHr(bpm);
          }
        });
      }

      if (state.connectionState == DeviceConnectionState.disconnected) {
        connectedId = null;
        connectedName = null;
        notifyListeners();
      }
    });
  }

  Future<void> disconnect() async {
    await _hrStream?.cancel();
    await _conn?.cancel();
    connectedId = null;
    connectedName = null;
    notifyListeners();
  }
}

// ===========================================================================
// UI — DASHBOARD
// ===========================================================================
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
              ble.connectedId == null ? Icons.bluetooth : Icons.bluetooth_connected),
          onPressed: () => _openBle(context),
        ),
      ),

      body: Column(
        children: [
          const SizedBox(height: 20),

          Text(
            opt.advice,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: opt.adviceColor,
            ),
          ),

          const SizedBox(height: 10),
          Text("HR: ${opt.hr.toStringAsFixed(0)} bpm",
              style: const TextStyle(fontSize: 18)),

          // SENSITIVITY
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text("Sensitivity: "),
              DropdownButton<double>(
                value: opt.sensitivity,
                items: const [
                  DropdownMenuItem(value: 1, child: Text("1 bpm")),
                  DropdownMenuItem(value: 2, child: Text("2 bpm")),
                  DropdownMenuItem(value: 3, child: Text("3 bpm")),
                  DropdownMenuItem(value: 4, child: Text("4 bpm")),
                  DropdownMenuItem(value: 5, child: Text("5 bpm")),
                ],
                onChanged: (v) => opt.setSensitivity(v!),
              ),
            ],
          ),

          const SizedBox(height: 15),
          SizedBox(height: 200, child: HrGraph(opt: opt)),

          const SizedBox(height: 10),
          if (ble.connectedName != null)
            Text("Connected to: ${ble.connectedName}",
                style: const TextStyle(color: Colors.black54)),
        ],
      ),

      floatingActionButton: FloatingActionButton(
        backgroundColor: opt.recording ? Colors.red : Colors.green,
        child: Icon(opt.recording ? Icons.stop : Icons.play_arrow),
        onPressed: () => opt.toggleRecording(),
      ),
    );
  }

  void _openBle(BuildContext context) {
    final ble = context.read<BleManager>();
    showModalBottomSheet(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: ble,
        child: const BleSheet(),
      ),
    );
  }
}

// ===========================================================================
// BLE DEVICE PICKER SHEET
// ===========================================================================
class BleSheet extends StatefulWidget {
  const BleSheet({super.key});
  @override
  State<BleSheet> createState() => _BleSheetState();
}

class _BleSheetState extends State<BleSheet> {
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
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(ble.scanning ? Icons.search : Icons.bluetooth),
                const SizedBox(width: 8),
                Text(
                  ble.scanning ? "Scanning…" : "Bluetooth Devices",
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (ble.connectedId != null)
                  IconButton(
                    icon: const Icon(Icons.link_off),
                    onPressed: () => ble.disconnect(),
                  ),
              ],
            ),

            const SizedBox(height: 12),

            Flexible(
              child: devices.isEmpty
                  ? const Center(
                      child: Text("No devices found.\nTurn on your HR monitor."),
                    )
                  : ListView.separated(
                      itemCount: devices.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final d = devices[i];
                        final name = d.name.isEmpty ? "(unknown)" : d.name;
                        return ListTile(
                          leading: const Icon(Icons.favorite),
                          title: Text(name),
                          subtitle: Text(d.id),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            final opt = context.read<OptimiserState>();
                            await ble.connect(d.id, name, opt);
                            if (mounted) Navigator.pop(context);
                          },
                        );
                      },
                    ),
            ),

            Row(
              children: [
                TextButton.icon(
                  onPressed: _scan,
                  icon: const Icon(Icons.refresh),
                  label: const Text("Rescan"),
                ),
                const Spacer(),
                TextButton(
                  child: const Text("Close"),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// HR GRAPH
// ===========================================================================
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

    if (pts.isEmpty) {
      return const Center(child: Text("HR data will appear here"));
    }

    final values = pts.map((e) => e.y).toList();
    final min = (values.reduce((a, b) => a < b ? a : b) - 5).clamp(40, 200);
    final max = (values.reduce((a, b) => a > b ? a : b) + 5).clamp(60, 220);

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: pts.length.toDouble(),
        minY: min,
        maxY: max,
        lineBarsData: [
          LineChartBarData(
            spots: pts,
            isCurved: true,
            barWidth: 3,
            color: Colors.green,
            dotData: FlDotData(show: false),
          ),
        ],
        gridData: FlGridData(show: false),
        titlesData: FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
      ),
    );
  }
}
