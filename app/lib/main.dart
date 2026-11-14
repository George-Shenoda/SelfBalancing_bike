import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      title: 'MotoGuard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF020617),
      ),
      home: const MapTelemetryHomePage(),
    );
  }
}

const List<Map<String, dynamic>> kEgyptLandmarks = [
  {
    'name': 'Tahrir Square, Downtown Cairo (ميدان التحرير - وسط البلد)',
    'keywords': 'ميدان التحرير وسط البلد tahrir square downtown cairo',
    'lat': 30.0444,
    'lon': 31.2357,
  },
  {
    'name': 'Cairo Tower, Zamalek (برج القاهرة - الزمالك)',
    'keywords': 'برج القاهرة برج القاهره الزمالك cairo tower zamalek',
    'lat': 30.0459,
    'lon': 31.2243,
  },
  {
    'name': 'Baron Empain Palace (قصر البارون - مصر الجديدة)',
    'keywords': 'قصر البارون مصر الجديدة baron palace heliopolis',
    'lat': 30.0866,
    'lon': 31.3283,
  },
  {
    'name': 'Roxy Square, Heliopolis (ميدان روكسي - مصر الجديدة)',
    'keywords': 'روكسي ميدان روكسى مصر الجديدة مصر الجديده roxy square heliopolis',
    'lat': 30.0914,
    'lon': 31.3145,
  },
  {
    'name': 'Abbassia Square & Metro (ميدان العباسية ومحطة المترو)',
    'keywords': 'ميدان العباسية مترو العباسيه abbassia square metro',
    'lat': 30.0725,
    'lon': 31.2839,
  },
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
    'name': 'Nasr City — Abbas El-Akkad (مدينة نصر - عباس العقاد)',
    'keywords': 'مدينة نصر مدينه نصر عباس العقاد nasr city abbas el akkad',
    'lat': 30.0618,
    'lon': 31.3369,
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

  LatLng _currentGps = const LatLng(30.0444, 31.2357);
  LatLng? _destination;
  String _destLabel = "Select a destination to start navigation";
  List<LatLng> _routePoints = [];
  double _routeDistanceKm = 0.0;
  int _routeEtaMin = 0;
  bool _gpsActive = false;
  StreamSubscription<Position>? _gpsSub;
  List<Map<String, dynamic>> _searchResults = [];
  Timer? _debounce;

  BluetoothDevice? _espDevice;
  StreamSubscription<List<int>>? _bleNotifySub;
  String _bleStatus = "Pair Vehicle";
  bool _bleConnected = false;

  bool _alarmEnabled = true;
  Timer? _alarmTimer;
  String _currentAlarmMode = "NONE";
  String _sosPhone = "";
  String _sosRiderName = "George Shenoda";
  String _sosApiKey = "";
  bool _autoSosEnabled = true;
  bool _sosTriggeredForCurrentFall = false;

  bool _s1RainWet = false;
  double _s2SteerDeg = 0.0;
  double _s2PotVolts = 0.00;
  double _s3SpeedKmh = 0.0;
  int _s3Rpm = 0;
  double _s4RollDeg = 0.0;
  double _s4RollRate = 0.0;

  @override
  void initState() {
    super.initState();
    _initGpsTracking();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _alarmTimer?.cancel();
    _gpsSub?.cancel();
    _bleNotifySub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _updateAlarmLoop(String mode) {
    if (!_alarmEnabled) mode = "NONE";
    if (mode == _currentAlarmMode) return;
    _currentAlarmMode = mode;
    _alarmTimer?.cancel();

    if (mode == "WARN") {
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.mediumImpact();
      _alarmTimer = Timer.periodic(const Duration(milliseconds: 900), (_) {
        SystemSound.play(SystemSoundType.alert);
        HapticFeedback.mediumImpact();
      });
    } else if (mode == "FALL") {
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.heavyImpact();
      _alarmTimer = Timer.periodic(const Duration(milliseconds: 350), (_) {
        SystemSound.play(SystemSoundType.alert);
        HapticFeedback.heavyImpact();
      });
    }
  }

  Future<void> _dispatchWhatsappSos() async {
    final cleanPhone = _sosPhone.replaceAll(RegExp(r'[^0-9]'), '');
    if (cleanPhone.isEmpty) return;

    final lat = _currentGps.latitude.toStringAsFixed(5);
    final lon = _currentGps.longitude.toStringAsFixed(5);
    final mapsUrl = "https://maps.google.com/?q=$lat,$lon";
    final roadStr = _s1RainWet ? "Wet Surface" : "Dry Road";

    final msg = "🚨 *EMERGENCY MOTORCYCLE FALL ALERT (MotoGuard)* 🚨\n"
        "Rider: $_sosRiderName\n"
        "Status: Fall detected!\n"
        "Lean Angle: ${_s4RollDeg.toStringAsFixed(1)}° (${_s4RollRate.toStringAsFixed(1)} °/s)\n"
        "Steering Angle: ${_s2SteerDeg.toStringAsFixed(1)}° | Road: $roadStr\n"
        "📍 Live Location: $mapsUrl";

    final encodedMsg = Uri.encodeComponent(msg);

    if (_sosApiKey.trim().isNotEmpty) {
      try {
        final apiUri = Uri.parse(
          "https://api.callmebot.com/whatsapp.php?phone=$cleanPhone&text=$encodedMsg&apikey=${Uri.encodeComponent(_sosApiKey.trim())}",
        );
        http.get(apiUri);
      } catch (_) {}
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFFE11D48),
          content: Text("🚨 Auto-WhatsApp SOS dispatched to +$cleanPhone ($mapsUrl)"),
        ),
      );
    }
  }

  void _openSosSetupModal() {
    final phoneCtrl = TextEditingController(text: _sosPhone);
    final nameCtrl = TextEditingController(text: _sosRiderName);
    final keyCtrl = TextEditingController(text: _sosApiKey);
    bool autoCheck = _autoSosEnabled;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "🆘 Emergency WhatsApp SOS",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    "Automatic fall alert & live GPS location sharing via WhatsApp.",
                    style: TextStyle(fontSize: 12, color: Colors.white60),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: "Emergency Contact WhatsApp Number (+20...)",
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: nameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: "Rider Name",
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: keyCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    decoration: const InputDecoration(
                      labelText: "WhatsApp Cloud Gateway Key (Optional)",
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SwitchListTile(
                    value: autoCheck,
                    activeColor: const Color(0xFF10B981),
                    title: const Text(
                      "Automatically send WhatsApp alert when a fall is detected",
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    onChanged: (v) => setModalState(() => autoCheck = v),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
                      onPressed: () {
                        setState(() {
                          _sosPhone = phoneCtrl.text.trim();
                          _sosRiderName = nameCtrl.text.trim().isEmpty ? "George Shenoda" : nameCtrl.text.trim();
                          _sosApiKey = keyCtrl.text.trim();
                          _autoSosEnabled = autoCheck;
                        });
                        Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.save, color: Colors.white),
                      label: const Text("Save Emergency Contact", style: TextStyle(color: Colors.white)),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
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

  void _clearDestination() {
    setState(() {
      _searchController.clear();
      _searchResults = [];
      _destination = null;
      _destLabel = "Select a destination to start navigation";
      _routePoints = [];
      _routeDistanceKm = 0.0;
      _routeEtaMin = 0;
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
        final res = await http.get(uri, headers: {'User-Agent': 'MotoGuardApp/1.0'});
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
                      "🔵 Pair Motorcycle via Bluetooth",
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    TextButton.icon(
                      onPressed: () => FlutterBluePlus.startScan(timeout: const Duration(seconds: 6)),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text("Scan"),
                    ),
                  ],
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
                            "Searching for nearby motorcycle telemetry unit...\n(Ensure Bluetooth & Location are enabled)",
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
                                  : "Vehicle Unit (${r.device.remoteId})");
                          return ListTile(
                            leading: const Icon(Icons.bluetooth, color: Color(0xFF38BDF8)),
                            title: Text(dName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                            subtitle: Text("Signal: ${r.rssi} dBm",
                                style: const TextStyle(color: Colors.white54, fontSize: 11)),
                            trailing: ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7)),
                              onPressed: () async {
                                Navigator.pop(ctx);
                                await _connectToChosenDevice(r.device, dName);
                              },
                              child: const Text("Pair", style: TextStyle(color: Colors.white, fontSize: 12)),
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
      setState(() => _bleStatus = "Pair Vehicle");
    }
  }

  void _parseEspSensorJson(String jsonStr) {
    try {
      final d = json.decode(jsonStr);
      setState(() {
        _bleConnected = true;
        _s1RainWet  = d['rainWet'] == true || d['rainWet'] == 1;
        _s2SteerDeg = (d['steerDeg'] ?? 0.0).toDouble();
        _s2PotVolts = (d['potVolts'] ?? (2.50 + (_s2SteerDeg / 45.0) * 2.50)).toDouble();
        _s3SpeedKmh = (d['speedKmh'] ?? 0.0).toDouble();
        _s3Rpm      = (d['rpm'] ?? ((_s3SpeedKmh / 3.6 / 0.377) * 60).round()).toInt();
        _s4RollDeg  = (d['rollDeg'] ?? 0.0).toDouble();
        _s4RollRate = (d['rollRate'] ?? 0.0).toDouble();
      });
      _checkAlarmAndAutoSos();
    } catch (_) {}
  }

  void _checkAlarmAndAutoSos() {
    final double mu = _s1RainWet ? 0.35 : 0.75;
    final double maxSafeLean = _s1RainWet ? 15.0 : 35.0;
    final double predRoll = (_s4RollDeg + _s4RollRate * 0.45).abs();
    final double vMs = _s3SpeedKmh / 3.6;
    final double latAccel = (vMs * vMs / 0.55) * math.tan((_s2SteerDeg.abs() * math.pi) / 180.0);
    final double risk = math.min(100.0, math.max(predRoll / maxSafeLean, latAccel / (mu * 9.81)) * 100.0);

    if (risk >= 85 || predRoll >= maxSafeLean) {
      _updateAlarmLoop("FALL");
      if (!_sosTriggeredForCurrentFall && _autoSosEnabled && _sosPhone.isNotEmpty) {
        _sosTriggeredForCurrentFall = true;
        _dispatchWhatsappSos();
      }
    } else if (risk >= 55 || (_s1RainWet && _s3SpeedKmh > 15)) {
      _updateAlarmLoop("WARN");
    } else {
      _updateAlarmLoop("NONE");
      if (_s4RollDeg.abs() < 10.0) {
        _sosTriggeredForCurrentFall = false;
      }
    }
  }

  Map<String, dynamic> _evaluateStability() {
    if (!_bleConnected && _s3SpeedKmh == 0.0 && _s4RollDeg == 0.0) {
      return {
        'verdict': '🛡️ VEHICLE STANDBY — CONNECT BLUETOOTH',
        'solution': 'Ready. Tap Pair Vehicle to begin live telemetry.',
        'color': const Color(0xFF64748B),
        'risk': 0,
      };
    }

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
        'verdict': '🚨 CRITICAL FALL DETECTED — EMERGENCY ALERT ACTIVE',
        'solution': 'Steer INTO the lean immediately! Emergency SOS active.',
        'color': const Color(0xFFF43F5E),
        'risk': risk.round(),
      };
    } else if (risk >= 55 || (_s1RainWet && _s3SpeedKmh > 15)) {
      return {
        'verdict': _s1RainWet ? '🌧️ WET ROAD WARNING — REDUCE SPEED' : '⚠️ STABILITY WARNING — HIGH LEAN ANGLE',
        'solution': 'Keep speed <= $recSafeSpeed km/h & lean within ±${maxSafeLean.toInt()}°.',
        'color': const Color(0xFFF59E0B),
        'risk': risk.round(),
      };
    }
    return {
      'verdict': '✅ OPTIMAL STABILITY & TRACTION',
      'solution': 'Normal ride conditions (Safe speed <= $recSafeSpeed km/h, Max lean ±${maxSafeLean.toInt()}°).',
      'color': const Color(0xFF10B981),
      'risk': risk.round(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final pred = _evaluateStability();
    final Color statusColor = pred['color'] as Color;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 2,
        toolbarHeight: 48,
        title: const Row(
          children: [
            Icon(Icons.two_wheeler, color: Color(0xFF38BDF8), size: 22),
            SizedBox(width: 8),
            Text(
              "MotoGuard",
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Colors.white),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () {
              setState(() {
                _alarmEnabled = !_alarmEnabled;
                if (!_alarmEnabled) _updateAlarmLoop("NONE");
              });
            },
            icon: Icon(
              _alarmEnabled ? Icons.volume_up : Icons.volume_off,
              color: _alarmEnabled ? Colors.amber : Colors.white54,
              size: 20,
            ),
            tooltip: "Alert Sound",
          ),
          IconButton(
            onPressed: _openSosSetupModal,
            icon: Icon(
              Icons.sos,
              color: _sosPhone.isNotEmpty ? const Color(0xFF10B981) : Colors.redAccent,
              size: 22,
            ),
            tooltip: "Emergency SOS",
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
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            onPressed: _initGpsTracking,
            icon: Icon(Icons.my_location, color: _gpsActive ? const Color(0xFF10B981) : Colors.amber, size: 20),
            tooltip: "GPS",
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 50,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _currentGps,
                    initialZoom: 13.5,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.shenodev.motoguard',
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

                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A).withOpacity(0.95),
                          borderRadius: BorderRadius.circular(14),
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
                                  hintText: 'Search destination...',
                                  hintStyle: TextStyle(color: Colors.white54),
                                  border: InputBorder.none,
                                ),
                              ),
                            ),
                            if (_searchController.text.isNotEmpty || _destination != null)
                              IconButton(
                                icon: const Icon(Icons.clear, size: 18, color: Colors.white54),
                                onPressed: _clearDestination,
                              ),
                          ],
                        ),
                      ),

                      if (_searchResults.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(top: 4),
                          constraints: const BoxConstraints(maxHeight: 160),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A).withOpacity(0.97),
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
                                leading: const Icon(Icons.place, color: Color(0xFF38BDF8), size: 18),
                                title: Text(
                                  item['display_name'] ?? '',
                                  maxLines: 1,
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
                    ],
                  ),
                ),

                Align(
                  alignment: Alignment.bottomLeft,
                  child: Container(
                    margin: const EdgeInsets.all(8),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A).withOpacity(0.92),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: Text(
                      _destination == null
                          ? "🏍️ $_destLabel"
                          : "🏍️ ${_destLabel.split('(').first.trim()} • ${_routeDistanceKm.toStringAsFixed(2)} km ($_routeEtaMin min)",
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            flex: 50,
            child: Container(
              color: const Color(0xFF020617),
              padding: const EdgeInsets.all(8.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: statusColor, width: 1.8),
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
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: statusColor),
                              ),
                            ),
                            Text(
                              "Risk: ${pred['risk']}%",
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: statusColor),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "⚡ ${pred['solution']}",
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 6),

                  Expanded(
                    child: Column(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: _buildBigSensorCard(
                                  badge: "SURFACE GRIP",
                                  title: "Road Condition",
                                  mainValue: _s1RainWet ? "WET ROAD" : "DRY ROAD",
                                  sub: _s1RainWet ? "Max Lean: ±15°" : "Max Lean: ±35°",
                                  accent: _s1RainWet ? const Color(0xFF38BDF8) : const Color(0xFF10B981),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _buildBigSensorCard(
                                  badge: "HANDLEBAR",
                                  title: "Steering Angle",
                                  mainValue: "${_s2SteerDeg > 0 ? '+' : ''}${_s2SteerDeg.toStringAsFixed(1)}°",
                                  sub: "Level: ${_s2PotVolts.toStringAsFixed(2)} V",
                                  accent: const Color(0xFF38BDF8),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: _buildBigSensorCard(
                                  badge: "VELOCITY",
                                  title: "Wheel Speed",
                                  mainValue: "${_s3SpeedKmh.toStringAsFixed(1)} km/h",
                                  sub: "$_s3Rpm RPM",
                                  accent: const Color(0xFFC084FC),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _buildBigSensorCard(
                                  badge: "CHASSIS TILT",
                                  title: "Lean Angle",
                                  mainValue: "${_s4RollDeg > 0 ? '+' : ''}${_s4RollDeg.toStringAsFixed(1)}°",
                                  sub: "Rate: ${_s4RollRate.toStringAsFixed(1)} °/s",
                                  accent: const Color(0xFFFBBF24),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBigSensorCard({
    required String badge,
    required String title,
    required String mainValue,
    required String sub,
    required Color accent,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1E293B), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            badge,
            style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: accent),
          ),
          Text(
            title,
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.white),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF020617),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              mainValue,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: accent),
            ),
          ),
          Text(
            sub,
            style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: Colors.white70),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
