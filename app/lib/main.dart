import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const MotorcycleTelemetryApp());
}

class MotorcycleTelemetryApp extends StatelessWidget {
  const MotorcycleTelemetryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MotoGuard Sensor Station',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF020617),
      ),
      home: const MapTelemetryHomePage(),
    );
  }
}

// Built-in Egypt & Cairo Landmarks for Instant Zero-Latency Autocomplete (Arabic & English)
const List<Map<String, dynamic>> kEgyptLandmarks = [
  {
    'name': 'Faculty of Engineering, Ain Shams University (كلية الهندسة جامعة عين شمس - العباسية)',
    'keywords': 'كلية هندسة عين شمس كليه الهندسه جامعه عين شمس عباسية العباسيه ain shams engineering faculty abbassia',
    'lat': 30.0647,
    'lon': 31.2789,
  },
  {
    'name': 'Ain Shams University Main Campus (جامعة عين شمس - الخليفة المأمون)',
    'keywords': 'جامعة عين شمس جامعه عين شمس الخليفة المأمون ain shams university',
    'lat': 30.0761,
    'lon': 31.2858,
  },
  {
    'name': 'Abbassia Square & Metro (ميدان العباسية ومحطة المترو)',
    'keywords': 'ميدان العباسية مترو العباسيه abbassia square metro',
    'lat': 30.0725,
    'lon': 31.2839,
  },
  {
    'name': 'Roxy Square, Heliopolis (ميدان روكسي - مصر الجديدة)',
    'keywords': 'روكسي ميدان روكسى مصر الجديدة مصر الجديده roxy square heliopolis',
    'lat': 30.0914,
    'lon': 31.3145,
  },
  {
    'name': 'Baron Empain Palace (قصر البارون - مصر الجديدة)',
    'keywords': 'قصر البارون مصر الجديدة baron palace heliopolis',
    'lat': 30.0866,
    'lon': 31.3283,
  },
  {
    'name': 'Nasr City — Abbas El-Akkad (مدينة نصر - عباس العقاد)',
    'keywords': 'مدينة نصر مدينه نصر عباس العقاد nasr city abbas el akkad',
    'lat': 30.0618,
    'lon': 31.3369,
  },
  {
    'name': 'Tahrir Square, Downtown Cairo (ميدان التحرير - وسط البلد)',
    'keywords': 'ميدان التحرير وسط البلد tahrir square downtown cairo',
    'lat': 30.0444,
    'lon': 31.2357,
  },
  {
    'name': 'Faculty of Engineering, Cairo University (كلية الهندسة جامعة القاهرة)',
    'keywords': 'كلية هندسة القاهرة كليه الهندسه جامعه القاهره الجيزة cairo university engineering',
    'lat': 30.0262,
    'lon': 31.2118,
  },
];

String normalizeArabic(String input) {
  return input
      .toLowerCase()
      .replaceAll(RegExp(r'[أإآ]'), 'ا')
      .replaceAll('ة', 'ه')
      .replaceAll('ى', 'ي')
      .trim();
}

class MapTelemetryHomePage extends StatefulWidget {
  const MapTelemetryHomePage({super.key});

  @override
  State<MapTelemetryHomePage> createState() => _MapTelemetryHomePageState();
}

class _MapTelemetryHomePageState extends State<MapTelemetryHomePage> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();

  static const String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  static const String charUuid    = "beb5483e-36e1-4688-b7f5-ea07361b26a8";

  LatLng _currentGps = const LatLng(30.0914, 31.3145);
  LatLng? _destination = const LatLng(30.0647, 31.2789);
  String _destLabel = "Faculty of Engineering, Ain Shams University";
  List<LatLng> _routePoints = [];
  double _routeDistanceKm = 4.20;
  int _routeEtaMin = 9;
  bool _gpsActive = false;
  StreamSubscription<Position>? _gpsSub;
  List<Map<String, dynamic>> _searchResults = [];
  Timer? _debounce;

  // Bluetooth Module Selection State
  BluetoothDevice? _espDevice;
  StreamSubscription<List<int>>? _bleNotifySub;
  String _bleStatus = "Select BT";
  bool _bleConnected = false;

  // 4 Approved Motorcycle Sensors (Prominent Top Dashboard):
  bool _s1RainWet = false;      // S1 (ON/OFF): Water-Drop Sensor (FC-37) on GPIO 27
  double _s2SteerDeg = 4.0;     // S2 (0-5V Analog): Steering Potentiometer on GPIO 34
  double _s2PotVolts = 2.72;
  double _s3SpeedKmh = 18.0;    // S3 (Conditioned): Wheel Speed Encoder + LPF + Schmitt Trigger on GPIO 18
  int _s3Rpm = 796;
  double _s4RollDeg = 6.5;      // S4 (Extra): MPU6050 Roll Lean Angle (deg)
  double _s4RollRate = 0.5;     // S4 (Extra): MPU6050 Roll Angular Velocity (deg/s)

  @override
  void initState() {
    super.initState();
    _initGpsTracking();
    _fetchOsrmRoute(_currentGps, _destination!);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _gpsSub?.cancel();
    _bleNotifySub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initGpsTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;
    setState(() => _gpsActive = true);
    Position pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    setState(() => _currentGps = LatLng(pos.latitude, pos.longitude));
    _mapController.move(_currentGps, 14.5);

    _gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 2),
    ).listen((Position position) {
      setState(() => _currentGps = LatLng(position.latitude, position.longitude));
      if (_destination != null) _fetchOsrmRoute(_currentGps, _destination!);
    });
  }

  void _onSearchChanged(String query) {
    final qNorm = normalizeArabic(query);
    if (qNorm.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }

    final words = qNorm.split(RegExp(r'\s+'));
    final localMatches = kEgyptLandmarks.where((p) {
      final hay = normalizeArabic("${p['name']} ${p['keywords']}");
      return words.every((w) => hay.contains(w));
    }).map((p) => {
      'display_name': p['name'],
      'lat': p['lat'].toString(),
      'lon': p['lon'].toString(),
    }).toList();

    setState(() => _searchResults = localMatches);

    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      if (qNorm.length < 3) return;
      try {
        final uri = Uri.parse(
          'https://nominatim.openstreetmap.org/search?format=json&countrycodes=eg&q=${Uri.encodeComponent(query)}&limit=5',
        );
        final res = await http.get(uri, headers: {'User-Agent': 'MCT332sMotorcycleApp/1.0'});
        if (res.statusCode == 200) {
          final List remote = json.decode(res.body);
          final combined = List<Map<String, dynamic>>.from(localMatches);
          for (var r in remote) {
            combined.add({
              'display_name': r['display_name'],
              'lat': r['lat'].toString(),
              'lon': r['lon'].toString(),
            });
          }
          if (mounted) {
            setState(() => _searchResults = combined.take(7).toList());
          }
        }
      } catch (_) {}
    });
  }

  Future<void> _fetchOsrmRoute(LatLng start, LatLng dest) async {
    final url = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/${start.longitude},${start.latitude};${dest.longitude},${dest.latitude}?overview=full&geometries=geojson',
    );
    try {
      final res = await http.get(url);
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final routes = data['routes'] as List;
        if (routes.isNotEmpty) {
          final coords = routes[0]['geometry']['coordinates'] as List;
          final distMeters = (routes[0]['distance'] as num).toDouble();
          final durationSec = (routes[0]['duration'] as num).toDouble();
          setState(() {
            _routePoints = coords.map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())).toList();
            _routeDistanceKm = distMeters / 1000.0;
            _routeEtaMin = (durationSec / 60.0).ceil();
          });
          return;
        }
      }
    } catch (_) {}
    setState(() {
      _routePoints = [start, dest];
    });
  }

  void _openBluetoothModulePicker() {
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "🔵 Select Bluetooth Module",
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    TextButton.icon(
                      onPressed: () => FlutterBluePlus.startScan(timeout: const Duration(seconds: 6)),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text("Rescan"),
                    ),
                  ],
                ),
                const Text(
                  "Tap any discovered Bluetooth device below to connect:",
                  style: TextStyle(fontSize: 12, color: Colors.white60),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 260,
                  child: StreamBuilder<List<ScanResult>>(
                    stream: FlutterBluePlus.scanResults,
                    builder: (context, snapshot) {
                      final results = snapshot.data ?? [];
                      if (results.isEmpty) {
                        return const Center(
                          child: Text(
                            "Scanning for nearby Bluetooth modules...\n(Make sure Bluetooth & Location are ON)",
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                        );
                      }
                      return ListView.separated(
                        itemCount: results.length,
                        separatorBuilder: (_, __) => const Divider(color: Color(0xFF1E293B)),
                        itemBuilder: (context, i) {
                          final r = results[i];
                          final dName = r.device.platformName.isNotEmpty
                              ? r.device.platformName
                              : (r.advertisementData.advName.isNotEmpty
                                  ? r.advertisementData.advName
                                  : "Bluetooth Module (${r.device.remoteId})");
                          return ListTile(
                            leading: const Icon(Icons.bluetooth, color: Color(0xFF38BDF8)),
                            title: Text(dName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                            subtitle: Text("ID: ${r.device.remoteId} • RSSI: ${r.rssi} dBm",
                                style: const TextStyle(color: Colors.white54, fontSize: 11)),
                            trailing: ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7)),
                              onPressed: () async {
                                Navigator.pop(ctx);
                                await _connectToChosenDevice(r.device, dName);
                              },
                              child: const Text("Connect", style: TextStyle(color: Colors.white, fontSize: 12)),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _connectToChosenDevice(BluetoothDevice device, String displayName) async {
    try {
      await FlutterBluePlus.stopScan();
      setState(() => _bleStatus = "Connecting...");
      _espDevice = device;
      await device.connect();
      setState(() {
        _bleConnected = true;
        _bleStatus = displayName;
      });
      List<BluetoothService> services = await device.discoverServices();
      for (var s in services) {
        for (var c in s.characteristics) {
          if (c.properties.notify || c.uuid.toString().toLowerCase() == charUuid) {
            await c.setNotifyValue(true);
            _bleNotifySub = c.onValueReceived.listen((bytes) {
              _parseEspSensorJson(utf8.decode(bytes));
            });
          }
        }
      }
    } catch (e) {
      setState(() => _bleStatus = "BT Failed");
    }
  }

  void _parseEspSensorJson(String jsonStr) {
    try {
      final d = json.decode(jsonStr);
      setState(() {
        _s1RainWet  = d['rainWet'] == true || d['rainWet'] == 1;
        _s2SteerDeg = (d['steerDeg'] ?? 0.0).toDouble();
        _s2PotVolts = (d['potVolts'] ?? (2.50 + (_s2SteerDeg / 45.0) * 2.50)).toDouble();
        _s3SpeedKmh = (d['speedKmh'] ?? 0.0).toDouble();
        _s3Rpm      = (d['rpm'] ?? ((_s3SpeedKmh / 3.6 / 0.377) * 60).round()).toInt();
        _s4RollDeg  = (d['rollDeg'] ?? 0.0).toDouble();
        _s4RollRate = (d['rollRate'] ?? 0.0).toDouble();
      });
    } catch (_) {}
  }

  void _applyTestScenario(String type) {
    setState(() {
      if (type == 'safe') {
        _s1RainWet = false;
        _s3SpeedKmh = 18.0;
        _s3Rpm = 796;
        _s4RollDeg = 6.5;
        _s4RollRate = 0.5;
        _s2SteerDeg = 4.0;
        _s2PotVolts = 2.72;
      } else if (type == 'rain') {
        _s1RainWet = true;
        _s3SpeedKmh = 26.0;
        _s3Rpm = 1150;
        _s4RollDeg = 11.5;
        _s4RollRate = 3.0;
        _s2SteerDeg = 9.0;
        _s2PotVolts = 3.00;
      } else if (type == 'fall') {
        _s1RainWet = true;
        _s3SpeedKmh = 32.0;
        _s3Rpm = 1415;
        _s4RollDeg = 21.0;
        _s4RollRate = 12.0;
        _s2SteerDeg = 18.0;
        _s2PotVolts = 3.50;
      }
    });
  }

  Map<String, dynamic> _evaluateStability() {
    final double mu = _s1RainWet ? 0.35 : 0.75;
    final double maxSafeLean = _s1RainWet ? 15.0 : 35.0;
    final double baseMaxSpeed = _s1RainWet ? 20.0 : 45.0;
    final double predRoll = (_s4RollDeg + _s4RollRate * 0.45).abs();
    final double vMs = _s3SpeedKmh / 3.6;
    final double latAccel = (vMs * vMs / 0.55) * math.tan((_s2SteerDeg.abs() * math.pi) / 180.0);
    final double risk = math.min(100.0, math.max(predRoll / maxSafeLean, latAccel / (mu * 9.81)) * 100.0);
    final int recSafeSpeed = math.max(8, (baseMaxSpeed * math.max(0.35, 1.0 - (predRoll / (maxSafeLean * 1.4)))).round());

    if (risk >= 85 || predRoll >= maxSafeLean) {
      return {
        'verdict': '🚨 CRITICAL: MOTORCYCLE WILL FALL / SKID!',
        'solution': 'Steer INTO the lean immediately & slow down to <= $recSafeSpeed km/h!',
        'color': const Color(0xFFF43F5E),
        'risk': risk.round(),
      };
    } else if (risk >= 55 || (_s1RainWet && _s3SpeedKmh > 15)) {
      return {
        'verdict': _s1RainWet ? '🌧️ WET ROAD: REDUCE MOTORCYCLE SPEED!' : '⚠️ CAUTION: HIGH CORNERING LOAD',
        'solution': 'Slow down to <= $recSafeSpeed km/h & keep lean below ±${maxSafeLean.toInt()}°.',
        'color': const Color(0xFFF59E0B),
        'risk': risk.round(),
      };
    }
    return {
      'verdict': '✅ STABLE — MOTORCYCLE WILL HOLD TRACTION',
      'solution': 'Safe to ride (Max safe speed <= $recSafeSpeed km/h, Max lean ±${maxSafeLean.toInt()}°).',
      'color': const Color(0xFF10B981),
      'risk': risk.round(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final pred = _evaluateStability();
    final Color statusColor = pred['color'] as Color;
    final int pulseHz = ((_s3Rpm * 20) / 60).round();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 2,
        title: const Row(
          children: [
            Icon(Icons.two_wheeler, color: Color(0xFF38BDF8), size: 24),
            SizedBox(width: 8),
            Text(
              "MotoGuard Sensor Station",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: _openBluetoothModulePicker,
            icon: Icon(
              _bleConnected ? Icons.bluetooth_connected : Icons.bluetooth,
              color: _bleConnected ? const Color(0xFF10B981) : const Color(0xFF38BDF8),
              size: 18,
            ),
            label: Text(
              _bleStatus,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            onPressed: _initGpsTracking,
            icon: Icon(Icons.my_location, color: _gpsActive ? const Color(0xFF10B981) : Colors.amber, size: 20),
            tooltip: "Enable Live GPS",
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. TOP PROMINENT STABILITY PREDICTION & FALL/RAIN WARNING BANNER
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: statusColor, width: 2),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          pred['verdict'] as String,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: statusColor),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF020617),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          "Risk: ${pred['risk']}%",
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: statusColor),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: (pred['risk'] as int) / 100.0,
                      minHeight: 8,
                      backgroundColor: const Color(0xFF020617),
                      valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "⚡ Solution / Action: ${pred['solution']}",
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 8),
                  // Quick Alarm Test Row for Project Defense
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _applyTestScenario('safe'),
                          child: const Text("✅ Safe", style: TextStyle(fontSize: 11, color: Color(0xFF10B981))),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _applyTestScenario('rain'),
                          child: const Text("🌧️ Wet", style: TextStyle(fontSize: 11, color: Color(0xFFF59E0B))),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _applyTestScenario('fall'),
                          child: const Text("🚨 Fall!", style: TextStyle(fontSize: 11, color: Color(0xFFF43F5E))),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),
            const Text(
              "📊 LIVE 4-SENSOR TELEMETRY STATION (MCT332s)",
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF38BDF8)),
            ),
            const SizedBox(height: 8),

            // 2. LARGE, PROMINENT 2x2 GRID OF THE 4 SENSOR CARDS (RIGHT ON TOP!)
            Row(
              children: [
                Expanded(
                  child: _buildBigSensorCard(
                    badge: "S1 • ON/OFF (GPIO 27)",
                    title: "Rain / Water Sensor",
                    mainValue: _s1RainWet ? "ON (WET 🌧️)" : "OFF (DRY ☀️)",
                    sub1: _s1RainWet ? "Friction μ ≈ 0.35" : "Friction μ ≈ 0.75",
                    sub2: _s1RainWet ? "Max Lean: ±15°" : "Max Lean: ±35°",
                    accent: _s1RainWet ? const Color(0xFF38BDF8) : const Color(0xFF10B981),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _buildBigSensorCard(
                    badge: "S2 • 0–5V (GPIO 34)",
                    title: "Steering Angle (δ)",
                    mainValue: "${_s2SteerDeg >= 0 ? '+' : ''}${_s2SteerDeg.toStringAsFixed(1)}°",
                    sub1: "Output: ${_s2PotVolts.toStringAsFixed(2)} V",
                    sub2: "Range: -45° to +45°",
                    accent: const Color(0xFF38BDF8),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _buildBigSensorCard(
                    badge: "S3 • Cond. (GPIO 18)",
                    title: "Wheel Speed Encoder",
                    mainValue: "${_s3SpeedKmh.toStringAsFixed(1)} km/h",
                    sub1: "$_s3Rpm RPM ($pulseHz Hz)",
                    sub2: "159Hz LPF + Schmitt OK",
                    accent: const Color(0xFFC084FC),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _buildBigSensorCard(
                    badge: "S4 • IMU (I2C 0x68)",
                    title: "MPU6050 Roll Lean (θ)",
                    mainValue: "${_s4RollDeg >= 0 ? '+' : ''}${_s4RollDeg.toStringAsFixed(1)}°",
                    sub1: "Rate: ${_s4RollRate.toStringAsFixed(1)} °/s",
                    sub2: "200Hz Complementary",
                    accent: const Color(0xFFFBBF24),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),
            const Text(
              "🗺️ GPS ROUTE NAVIGATION (SEARCH DESTINATION ONLY)",
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF38BDF8)),
            ),
            const SizedBox(height: 8),

            // 3. DEDICATED GPS MAP & SEARCH SECTION (Map Touch Locked Against Accidental Destination Changes!)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF020617),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.search, color: Color(0xFF38BDF8), size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            onChanged: _onSearchChanged,
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                            decoration: const InputDecoration(
                              hintText: 'Search place (e.g. كلية هندسة عين شمس)...',
                              hintStyle: TextStyle(color: Colors.white54),
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                        if (_searchController.text.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.clear, size: 18, color: Colors.white54),
                            onPressed: () {
                              setState(() {
                                _searchController.clear();
                                _searchResults = [];
                              });
                            },
                          ),
                      ],
                    ),
                  ),

                  if (_searchResults.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 6),
                      constraints: const BoxConstraints(maxHeight: 200),
                      decoration: BoxDecoration(
                        color: const Color(0xFF020617),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF334155)),
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _searchResults.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF1E293B)),
                        itemBuilder: (context, i) {
                          final item = _searchResults[i];
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.place, color: Color(0xFF38BDF8), size: 20),
                            title: Text(
                              item['display_name'] ?? '',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                            ),
                            onTap: () {
                              final lat = double.parse(item['lat']);
                              final lon = double.parse(item['lon']);
                              final dest = LatLng(lat, lon);
                              setState(() {
                                _destination = dest;
                                _destLabel = item['display_name'] ?? '';
                                _searchController.text = _destLabel.split('(').first.trim();
                                _searchResults = [];
                              });
                              _fetchOsrmRoute(_currentGps, dest);
                              _mapController.move(dest, 14.5);
                            },
                          );
                        },
                      ),
                    ),

                  const SizedBox(height: 8),
                  Text(
                    "🏍️ Route to: ${_destLabel.split('(').first.trim()} (${_routeDistanceKm.toStringAsFixed(2)} km • $_routeEtaMin min)",
                    style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.white70),
                  ),
                  const SizedBox(height: 8),

                  // Map Box (NO onTap callback — touching/dragging map ONLY pans/zooms!)
                  SizedBox(
                    height: 260,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: _currentGps,
                          initialZoom: 14.0,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'edu.asu.mct332s.motoguard',
                          ),
                          if (_routePoints.isNotEmpty)
                            PolylineLayer(
                              polylines: [Polyline(points: _routePoints, strokeWidth: 5.0, color: const Color(0xFF0284C7))],
                            ),
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: _currentGps,
                                width: 44,
                                height: 44,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0284C7),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 2.5),
                                  ),
                                  child: const Icon(Icons.two_wheeler, color: Colors.white, size: 24),
                                ),
                              ),
                              if (_destination != null)
                                Marker(
                                  point: _destination!,
                                  width: 44,
                                  height: 44,
                                  child: const Icon(Icons.location_on, color: Color(0xFFEF4444), size: 38),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBigSensorCard({
    required String badge,
    required String title,
    required String mainValue,
    required String sub1,
    required String sub2,
    required Color accent,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E293B), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: accent.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              badge,
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: accent),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF020617),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              mainValue,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: accent),
            ),
          ),
          const SizedBox(height: 8),
          Text(sub1, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white70)),
          Text(sub2, style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
        ],
      ),
    );
  }
}
