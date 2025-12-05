import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter/services.dart'; // For audio beeps

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final opt = OptimiserState();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => opt),
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
      theme: ThemeData(
        primarySwatch: Colors.blue,
        appBarTheme: const AppBarTheme(centerTitle: true),
      ),
      home: const OptimiserDashboard(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ------------------------------------------------------------
// FEEDBACK MODE (HAPTIC / AUDIO)
// ------------------------------------------------------------

enum FeedbackMode { haptic, audio }

// ============================================================
// HR-ONLY OPTIMISER — GRADIENT ASCENT WITH FEEDBACK MODE
// ============================================================

class OptimiserState extends ChangeNotifier {
  // ---------- Core state ----------
  double hr = 0;
  bool recording = false;

  // HR graph history
  final List<double> hrHistory = [];

  void _addHrToHistory(double bpm) {
    hrHistory.add(bpm);
    if (hrHistory.length > 60) hrHistory.removeAt(0);
  }

  // ---------- Sensitivity (1–5 bpm) ----------
  double sensitivity = 3.0;
  void setSensitivity(double value) {
    sensitivity = value;
    notifyListeners();
  }

  // ---------- Feedback Mode ----------
  FeedbackMode feedbackMode = FeedbackMode.haptic;
  void setFeedbackMode(FeedbackMode m) {
    feedbackMode = m;
    notifyListeners();
  }

  // ---------- Gradient loop ----------
  Timer? _loopTimer;

  DateTime? _lastTestTime;
  bool _testInProgress = false;
  DateTime? _testStartTime;
  String? _testDirection;

  double? _hrBeforeTest;

  // Plateau state
  bool _plateau = false;
  double? _plateauHr;

  // Learning stats
  double _avgUpDelta = 0.0;
  double _avgDownDelta = 0.0;
  int _upCount = 0;
  int _downCount = 0;

  String _currentAdvice = "Tap ▶ to start workout";

  // ---------- Public controls ----------

  void toggleRecording() {
    recording = !recording;

    if (recording) {
      _startLoop();
      _resetState();
      _currentAdvice = "Learning rhythm...";
    } else {
      _stopLoop();
      _currentAdvice = "Tap ▶ to start workout";
    }
    notifyListeners();
  }

  void _resetState() {
    _plateau = false;
    _plateauHr = null;
    _lastTestTime = null;
    _testInProgress = false;
    _testStartTime = null;
    _testDirection = null;
    _hrBeforeTest = null;

    _avgUpDelta = 0.0;
    _avgDownDelta = 0.0;
    _upCount = 0;
    _downCount = 0;
  }

  void _startLoop() {
    _loopTimer?.cancel();
    _loopTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _stopLoop() {
    _loopTimer?.cancel();
    _loopTimer = null;
  }

  // ---------- HR input from BLE ----------
  void setHr(double bpm) {
    if (bpm <= 0 || bpm.isNaN) return;
    hr = bpm;
    _addHrToHistory(bpm);
    notifyListeners();
  }

  // ============================================================
  // HR-ONLY GRADIENT LOOP
  // ============================================================

  void _tick() {
    if (!recording || hr <= 0) return;

    final now = DateTime.now();
    const int testInterval = 15;
    const int evalDelay = 15;

    if (_testInProgress) {
      if (_testStartTime != null &&
          now.difference(_testStartTime!).inSeconds >= evalDelay) {
        _evaluateTest();
      }
      return;
    }

    if (_lastTestTime != null &&
        now.difference(_lastTestTime!).inSeconds < testInterval) {
      return;
    }

    if (_plateau && _plateauHr != null) {
      final hrDiff = (hr - _plateauHr!).abs();
      if (hrDiff < sensitivity) {
        _currentAdvice = "Optimal rhythm";
        notifyListeners();
        return;
      } else {
        _plateau = false;
      }
    }

    // Determine direction
    String dir;
    const double smallDelta = 0.2;

    if (_upCount + _downCount < 2) {
      dir = (_testDirection == "up") ? "down" : "up";
    } else {
      if (_avgUpDelta < _avgDownDelta - smallDelta) {
        dir = "up";
      } else if (_avgDownDelta < _avgUpDelta - smallDelta) {
        dir = "down";
      } else {
        dir = (_testDirection == "up") ? "down" : "up";
      }
    }

    _startTest(dir);
  }

  void _startTest(String dir) {
    _testInProgress = true;
    _testDirection = dir;
    _testStartTime = DateTime.now();
    _lastTestTime = _testStartTime;

    _hrBeforeTest = hr;

    if (dir == "up") {
      _currentAdvice = "Increase rhythm";
      _signalUp();
    } else {
      _currentAdvice = "Ease rhythm";
      _signalDown();
    }

    notifyListeners();
  }

  void _evaluateTest() {
    _testInProgress = false;

    if (_hrBeforeTest == null) return;

    final hrAfter = hr;
    final delta = hrAfter - _hrBeforeTest!;

    // Plateau detection
    if (delta.abs() < sensitivity) {
      _plateau = true;
      _plateauHr = hrAfter;
      _currentAdvice = "Optimal rhythm";
      notifyListeners();
      return;
    }

    // Learning stats
    if (_testDirection == "up") {
      _upCount++;
      _avgUpDelta = ((_avgUpDelta * (_upCount - 1)) + delta) / _upCount;
    } else {
      _downCount++;
      _avgDownDelta =
          ((_avgDownDelta * (_downCount - 1)) + delta) / _downCount;
    }

    notifyListeners();
  }

  // ============================================================
  // FEEDBACK ROUTING (HAPTIC OR AUDIO)
  // ============================================================

  void _signalUp() {
    if (feedbackMode == FeedbackMode.haptic) {
      _vibrateUp();
    } else {
      _audioUp();
    }
  }

  void _signalDown() {
    if (feedbackMode == FeedbackMode.haptic) {
      _vibrateDown();
    } else {
      _audioDown();
    }
  }

  // ---------- HAPTIC VIBRATION ----------
  Future<void> _vibrateUp() async {
    final hasVibrator = await Vibration.hasVibrator() ?? false;
    if (!hasVibrator) return;

    // Long vibration for UP
    Vibration.vibrate(duration: 2000);
  }

  Future<void> _vibrateDown() async {
    final hasVibrator = await Vibration.hasVibrator() ?? false;
    if (!hasVibrator) return;

    Vibration.vibrate(duration: 150);
  }

  // ---------- AUDIO FEEDBACK ----------
  Future<void> _beep() async {
    await SystemSound.play(SystemSoundType.click);
  }

  Future<void> _audioUp() async {
    _beep();
    await Future.delayed(const Duration(milliseconds: 200));
    _beep();
  }

  Future<void> _audioDown() async {
    _beep();
  }

  // ---------- Public getters ----------
  String get rhythmAdvice =>
      !recording ? "Tap ▶ to start workout" : _currentAdvice;

  Color get rhythmColor {
    if (!recording) return Colors.grey;
    if (_currentAdvice == "Optimal rhythm") return Colors.green;
    if (_currentAdvice == "Learning rhythm...") return Colors.grey;
    return Colors.orange;
  }
}

// ============================================================
// BLE MANAGER (HR STRAP CONNECTION)
// ============================================================

class BleManager extends ChangeNotifier {
  final FlutterReactiveBle _ble = FlutterReactiveBle();
  final Uuid hrService =
      Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid hrMeasurement =
      Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _hrSub;

  String? connectedId;
  String? connectedName;
  bool scanning = false;

  Future<void> ensurePermissions() async {
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.locationWhenInUse.request();
  }

  Future<List<DiscoveredDevice>> scanDevices(
      {Duration timeout = const Duration(seconds: 5)}) async {
    await ensurePermissions();
    final List<DiscoveredDevice> devices = [];
    scanning = true;
    notifyListeners();

    final completer = Completer<List<DiscoveredDevice>>();

    _scanSub = _ble.scanForDevices(withServices: []).listen(
      (device) {
        if (!devices.any((d) => d.id == device.id)) {
          devices.add(device);
          notifyListeners();
        }
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(devices);
      },
    );

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

    _connSub = _ble.connectToDevice(id: id).listen(
      (event) {
        if (event.connectionState ==
            DeviceConnectionState.connected) {
          connectedId = id;
          connectedName = name.isEmpty ? "(unknown)" : name;
          notifyListeners();

          final hrChar = QualifiedCharacteristic(
            deviceId: id,
            serviceId: hrService,
            characteristicId: hrMeasurement,
          );

          _hrSub =
              _ble.subscribeToCharacteristic(hrChar).listen((data) {
            if (data.length > 1) {
              opt.setHr(data[1].toDouble());
            }
          });
        } else if (event.connectionState ==
            DeviceConnectionState.disconnected) {
          connectedId = null;
          connectedName = null;
          notifyListeners();
        }
      },
      onError: (_) {
        connectedId = null;
        connectedName = null;
        notifyListeners();
      },
    );
  }

  Future<void> disconnect() async {
    await _hrSub?.cancel();
    await _connSub?.cancel();
    connectedId = null;
    connectedName = null;
    notifyListeners();
  }
}

// ============================================================
// UI — HR-ONLY DASHBOARD + SENSITIVITY + FEEDBACK MODE
// ============================================================

class OptimiserDashboard extends StatelessWidget {
  const OptimiserDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    final opt = context.watch<OptimiserState>();
    final ble = context.watch<BleManager>();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(
            ble.connectedId == null
                ? Icons.bluetooth
                : Icons.bluetooth_connected,
          ),
          tooltip: ble.connectedName == null
              ? 'Bluetooth devices'
              : 'Connected: ${ble.connectedName}',
          onPressed: () => _showBleSheet(context),
        ),
        title: const Text("Physiological Optimiser"),
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            opt.rhythmAdvice,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: opt.rhythmColor,
            ),
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 12),
          Text("HR: ${opt.hr.toStringAsFixed(0)} bpm"),

          // Sensitivity control 1–5 bpm
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("Sensitivity: "),
                DropdownButton<double>(
                  value: opt.sensitivity,
                  items: const [
                    DropdownMenuItem(value: 1.0, child: Text("1 bpm")),
                    DropdownMenuItem(value: 2.0, child: Text("2 bpm")),
                    DropdownMenuItem(value: 3.0, child: Text("3 bpm")),
                    DropdownMenuItem(value: 4.0, child: Text("4 bpm")),
                    DropdownMenuItem(value: 5.0, child: Text("5 bpm")),
                  ],
                  onChanged: (v) => opt.setSensitivity(v!),
                ),
              ],
            ),
          ),

          // Feedback mode: Haptic or Audio
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("Feedback: "),
                DropdownButton<FeedbackMode>(
                  value: opt.feedbackMode,
                  items: const [
                    DropdownMenuItem(
                      value: FeedbackMode.haptic,
                      child: Text("Haptic"),
                    ),
                    DropdownMenuItem(
                      value: FeedbackMode.audio,
                      child: Text("Audio beeps"),
                    ),
                  ],
                  onChanged: (m) => opt.setFeedbackMode(m!),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          SizedBox(height: 200, child: HrGraph(opt: opt)),

          if (ble.connectedName != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                "Connected to: ${ble.connectedName}",
                style: const TextStyle(color: Colors.black54),
              ),
            )
        ],
      ),

      floatingActionButton: FloatingActionButton(
        backgroundColor: opt.recording ? Colors.red : Colors.green,
        child: Icon(opt.recording ? Icons.stop : Icons.play_arrow),
        onPressed: () => opt.toggleRecording(),
      ),
    );
  }

  void _showBleSheet(BuildContext context) {
    final ble = context.read<BleManager>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => ChangeNotifierProvider.value(
        value: ble,
        child: const _BleBottomSheet(),
      ),
    );
  }
}

// ============================================================
// BLE SHEET — device picker
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
    _startScan();
  }

  Future<void> _startScan() async {
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
                const Icon(Icons.bluetooth),
                const SizedBox(width: 8),
                Text(
                  ble.scanning
                      ? "Scanning for devices…"
                      : "Bluetooth devices",
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (ble.connectedId != null)
                  IconButton(
                    icon: const Icon(Icons.link_off),
                    tooltip: "Disconnect",
                    onPressed: () => ble.disconnect(),
                  ),
              ],
            ),

            const SizedBox(height: 12),

            Flexible(
              child: devices.isEmpty
                  ? const Center(
                      child: Text(
                        "No devices found.\nMake sure HR strap is on.",
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.separated(
                      itemCount: devices.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final d = devices[i];
                        final name =
                            d.name.isNotEmpty ? d.name : "(unknown)";
                        return ListTile(
                          leading: const Icon(Icons.watch),
                          title: Text(name),
                          subtitle: Text(d.id),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            final opt =
                                context.read<OptimiserState>();
                            await ble.connect(d.id, name, opt);
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        );
                      },
                    ),
            ),

            const SizedBox(height: 10),

            Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text("Rescan"),
                  onPressed: _startScan,
                ),
                const Spacer(),
                TextButton(
                  child: const Text("Close"),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            )
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
    final points = opt.hrHistory.asMap().entries.map((e) {
      return FlSpot(e.key.toDouble(), e.value);
    }).toList();

    double minY = 40, maxY = 200;

    if (points.isNotEmpty) {
      final ys = points.map((p) => p.y).toList();
      minY = (ys.reduce((a, b) => a < b ? a : b) - 5).clamp(30, 220);
      maxY = (ys.reduce((a, b) => a > b ? a : b) + 5).clamp(40, 240);
    }

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: points.isEmpty ? 1 : points.length.toDouble(),
        minY: minY,
        maxY: maxY,
        lineBarsData: [
          LineChartBarData(
            spots: points,
            isCurved: true,
            barWidth: 3,
            color: Colors.green,
            dotData: FlDotData(show: false),
          ),
        ],
        titlesData: FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        gridData: FlGridData(show: false),
      ),
    );
  }
}
