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
  runApp(const BikeTelemetryApp());
}

class BikeTelemetryApp extends StatelessWidget {
  const BikeTelemetryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MCT332s Smart Bike Sensor Station',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF020617),
      ),
      home: const MapTelemetryHomePage(),
    );
  }
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

  LatLng _currentGps = const LatLng(30.0647, 31.2789);
  LatLng? _destination;
  List<LatLng> _routePoints = [];
  double _routeDistanceKm = 0.0;
  int _routeEtaMin = 0;
  bool _gpsActive = false;
  StreamSubscription<Position>? _gpsSub;
  List<Map<String, dynamic>> _searchResults = [];

  BluetoothDevice? _espDevice;
  StreamSubscription<List<int>>? _bleNotifySub;
  String _bleStatus = "Pair BLE";
  bool _bleConnected = false;

  // 4 Approved Sensors from ESP32:
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
  }

  @override
  void dispose() {
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

  Future<void> _searchPlaces(String query) async {
    if (query.trim().length < 2) {
      setState(() => _searchResults = []);
      return;
    }
    try {
      final uri = Uri.parse('https://nominatim.openstreetmap.org/search?format=json&q=${Uri.encodeComponent(query)}&limit=5');
      final res = await http.get(uri, headers: {'User-Agent': 'MCT332sBikeApp/1.0'});
      if (res.statusCode == 200) {
        final List data = json.decode(res.body);
        setState(() => _searchResults = data.cast<Map<String, dynamic>>());
      }
    } catch (_) {}
  }

  Future<void> _fetchOsrmRoute(LatLng start, LatLng dest) async {
    final url = Uri.parse('https://router.project-osrm.org/route/v1/driving/${start.longitude},${start.latitude};${dest.longitude},${dest.latitude}?overview=full&geometries=geojson');
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
        }
      }
    } catch (_) {}
  }

  Future<void> _scanAndConnectBle() async {
    setState(() => _bleStatus = "Scanning...");
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
      FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult r in results) {
          if (r.device.platformName == "ESP32_BIKE" ||
              r.advertisementData.serviceUuids.contains(Guid(serviceUuid))) {
            await FlutterBluePlus.stopScan();
            _espDevice = r.device;
            await _espDevice!.connect();
            setState(() {
              _bleConnected = true;
              _bleStatus = "BLE Live";
            });
            List<BluetoothService> services = await _espDevice!.discoverServices();
            for (var s in services) {
              if (s.uuid.toString().toLowerCase() == serviceUuid) {
                for (var c in s.characteristics) {
                  if (c.uuid.toString().toLowerCase() == charUuid) {
                    await c.setNotifyValue(true);
                    _bleNotifySub = c.onValueReceived.listen((bytes) {
                      _parseEspSensorJson(utf8.decode(bytes));
                    });
                  }
                }
              }
            }
            break;
          }
        }
      });
    } catch (_) {
      setState(() => _bleStatus = "BLE Error");
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

  // Stability & Fall Prediction Engine
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
        'verdict': '🚨 CRITICAL: BIKE WILL FALL / SKID!',
        'solution': 'Steer INTO the lean immediately & slow down to <= $recSafeSpeed km/h!',
        'color': const Color(0xFFF43F5E),
        'risk': risk.round(),
      };
    } else if (risk >= 55 || (_s1RainWet && _s3SpeedKmh > 15)) {
      return {
        'verdict': _s1RainWet ? '🌧️ WET ROAD: REDUCE SPEED!' : '⚠️ CAUTION: HIGH CORNERING LOAD',
        'solution': 'Slow down to <= $recSafeSpeed km/h & keep lean below ±${maxSafeLean.toInt()}°.',
        'color': const Color(0xFFF59E0B),
        'risk': risk.round(),
      };
    }
    return {
      'verdict': '✅ STABLE — BIKE WILL HOLD TRACTION',
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
              initialZoom: 15.0,
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
                    width: 44,
                    height: 44,
                    child: const Icon(Icons.pedal_bike, color: Color(0xFF38BDF8), size: 32),
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

          // Top Search + Prediction Alert Banner
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(10.0),
              child: Column(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A).withOpacity(0.94),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(width: 12),
                        const Icon(Icons.search, color: Color(0xFF38BDF8)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            onChanged: _searchPlaces,
                            decoration: const InputDecoration(
                              hintText: 'Search destination...',
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(_bleConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                              color: _bleConnected ? const Color(0xFF10B981) : const Color(0xFF38BDF8)),
                          onPressed: _scanAndConnectBle,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Fall Prediction & Solution Banner
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
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: statusColor),
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

          // Bottom 4-Sensor HUD
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.all(10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A).withOpacity(0.94),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  'S1 Rain: ${_s1RainWet ? "WET 🌧️" : "DRY ☀️"} | S2 Steer: ${_s2SteerDeg.toStringAsFixed(1)}° | S3 Speed: ${_s3SpeedKmh.toStringAsFixed(1)} km/h | S4 Roll: ${_s4RollDeg.toStringAsFixed(1)}°',
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
