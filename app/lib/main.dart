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
      title: 'MCT332s Smart Motorcycle Station',
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
  double _routeDistanceKm = 0.0;
  int _routeEtaMin = 0;
  bool _gpsActive = false;
  StreamSubscription<Position>? _gpsSub;
  List<Map<String, dynamic>> _searchResults = [];
  Timer? _debounce;

  // Bluetooth Module Selection State
  BluetoothDevice? _espDevice;
  StreamSubscription<List<int>>? _bleNotifySub;
  String _bleStatus = "Select BT";
  bool _bleConnected = false;

  // 4 Approved Motorcycle Sensors from ESP32:
  bool _s1RainWet = false;      // S1 (ON/OFF): Water-Drop Sensor (FC-37) on GPIO 27
  double _s2SteerDeg = 0.0;     // S2 (0-5V Analog): Steering Potentiometer on GPIO 34
  double _s2PotVolts = 2.50;
  double _s3SpeedKmh = 0.0;     // S3 (Conditioned): Wheel Speed Encoder + LPF + Schmitt Trigger on GPIO 18
  int _s3Rpm = 0;
  double _s4RollDeg = 0.0;      // S4 (Extra): MPU6050 Roll Lean Angle (deg)
  double _s4RollRate = 0.0;     // S4 (Extra): MPU6050 Roll Angular Velocity (deg/s)

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
    _mapController.move(_currentGps, 15.0);

    _gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 2),
    ).listen((Position position) {
      setState(() => _currentGps = LatLng(position.latitude, position.longitude));
      if (_destination != null) _fetchOsrmRoute(_currentGps, _destination!);
    });
  }

  // Instant Autocomplete Search (Local Egypt Dictionary + Online Nominatim)
  void _onSearchChanged(String query) {
    final qNorm = normalizeArabic(query);
    if (qNorm.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }

    // 1. Instant local match (handles "كلية هندسة عين شمس" with 0 latency)
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

    // 2. Online Nominatim search in background
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

  // Opens Interactive Bluetooth Module Picker Bottom Sheet so user chooses WHICH Bluetooth module to connect!
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
        _s2PotVolts = (d['potVolts'] ?? 2.50).toDouble();
        _s3SpeedKmh = (d['speedKmh'] ?? 0.0).toDouble();
        _s3Rpm      = (d['rpm'] ?? 0).toInt();
        _s4RollDeg  = (d['rollDeg'] ?? 0.0).toDouble();
        _s4RollRate = (d['rollRate'] ?? 0.0).toDouble();
      });
    } catch (_) {}
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

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentGps,
              initialZoom: 14.5,
              onTap: (tapPos, latlng) {
                setState(() {
                  _destination = latlng;
                  _searchResults = [];
                });
                _fetchOsrmRoute(_currentGps, latlng);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'edu.asu.mct332s.bike_telemetry_app',
              ),
              if (_routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [Polyline(points: _routePoints, strokeWidth: 5.0, color: const Color(0xFF0284C7))],
                ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: _currentGps,
                    width: 46,
                    height: 46,
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF0284C7),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2.5),
                      ),
                      child: const Icon(Icons.two_wheeler, color: Colors.white, size: 26),
                    ),
                  ),
                  if (_destination != null)
                    Marker(
                      point: _destination!,
                      width: 44,
                      height: 44,
                      child: const Icon(Icons.location_on, color: Color(0xFFEF4444), size: 40),
                    ),
                ],
              ),
            ],
          ),

          // Top Search Bar + Live Autocomplete Dropdown + Fall Prediction Banner
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(10.0),
              child: Column(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A).withOpacity(0.95),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(width: 10),
                        const Icon(Icons.two_wheeler, color: Color(0xFF38BDF8)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            onChanged: _onSearchChanged,
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                            decoration: const InputDecoration(
                              hintText: 'Search (e.g. كلية هندسة عين شمس)...',
                              hintStyle: TextStyle(color: Colors.white54),
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _openBluetoothModulePicker,
                          icon: Icon(
                            _bleConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                            color: _bleConnected ? const Color(0xFF10B981) : const Color(0xFF38BDF8),
                            size: 18,
                          ),
                          label: Text(
                            _bleStatus,
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Autocomplete Dropdown Results
                  if (_searchResults.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 6),
                      constraints: const BoxConstraints(maxHeight: 220),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A).withOpacity(0.97),
                        borderRadius: BorderRadius.circular(14),
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
                  // Motorcycle Stability & Fall-Prediction Banner
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A).withOpacity(0.94),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: statusColor, width: 2),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "${pred['verdict']} (Risk: ${pred['risk']}%)",
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: statusColor),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          "⚡ Action: ${pred['solution']}",
                          style: const TextStyle(fontSize: 11, color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Bottom 4-Sensor Motorcycle HUD
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.all(10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A).withOpacity(0.94),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: Text(
                  '🏍️ S1 Rain: ${_s1RainWet ? "WET 🌧️" : "DRY ☀️"} | S2 Steer: ${_s2SteerDeg.toStringAsFixed(1)}° | S3 Speed: ${_s3SpeedKmh.toStringAsFixed(1)} km/h | S4 Roll: ${_s4RollDeg.toStringAsFixed(1)}°',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
