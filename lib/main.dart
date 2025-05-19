import 'package:flutter/material.dart';
import 'dart:math';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to landscape orientation
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // Hide system UI for immersive mode
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  runApp(const BikeTelemetryApp());
}

class BikeTelemetryApp extends StatelessWidget {
  const BikeTelemetryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Bike Telemetry',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
              fontSize: 64, fontWeight: FontWeight.bold, color: Colors.redAccent),
          headlineMedium: TextStyle(
              fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white70),
          bodyLarge: TextStyle(fontSize: 20, color: Colors.white54),
        ),
      ),
      home: const TelemetryScreen(),
    );
  }
}

class TelemetryScreen extends StatefulWidget {
  const TelemetryScreen({super.key});

  @override
  State<TelemetryScreen> createState() => _TelemetryScreenState();
}

class _TelemetryScreenState extends State<TelemetryScreen> with SingleTickerProviderStateMixin {
  double _speedKmh = 0;

  // These drivetrain values are unused with GPS speed, but left for RPM calculation
  final double wheelRadiusMeters = 0.253;
  final double primaryReduction = 3.35; // 67/20
  final double finalReduction = 3.0; // 42/14
  late final double totalDriveRatio;

  final List<double> gearRatios = [
    0.0,   // Neutral
    2.769, // 1st
    1.5,   // 2nd
    1.095, // 3rd
    0.913, // 4th
  ];

  int currentGear = 0;
  double rpm = 0;
  late AnimationController _rpmAnimationController;
  late Animation<double> _rpmAnimation;
  double _displayedRpm = 0;
  StreamSubscription<Position>? _positionStream;

  @override
  void initState() {
    super.initState();
    totalDriveRatio = primaryReduction * finalReduction;

    _rpmAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _rpmAnimation = Tween<double>(begin: 0, end: 0).animate(
      CurvedAnimation(parent: _rpmAnimationController, curve: Curves.easeOut),
    )..addListener(() {
        setState(() {
          _displayedRpm = _rpmAnimation.value;
        });
      });

    _initLocationStream();
  }

  @override
  void dispose() {
    _rpmAnimationController.dispose();
    _positionStream?.cancel();
    super.dispose();
  }

  Future<void> _initLocationStream() async {
    bool serviceEnabled;
    LocationPermission permission;

    // Check if location services are enabled
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      // Location services are not enabled don't continue
      debugPrint('Location services are disabled.');
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        debugPrint('Location permissions are denied');
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      debugPrint(
          'Location permissions are permanently denied, we cannot request permissions.');
      return;
    }

    // Now start listening to position updates
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        // timeLimit: Duration(seconds: 1), // optional if needed
      ),
    ).listen((Position position) {
      double speedMps = position.speed; // speed in meters/second
      // Sometimes speed can be negative or zero if GPS is not moving or inaccurate
      if (speedMps < 0) speedMps = 0;

      setState(() {
        _speedKmh = speedMps * 3.6; // convert to km/h
        _updateRpm();
      });
    });
  }

  void _updateRpm() {
    double speedMps = _speedKmh / 3.6;

    if (speedMps <= 0) {
      currentGear = 0;
      _setRpm(0);
      return;
    }

    if (currentGear == 0) currentGear = 1;

    double wheelRpm = (speedMps / (2 * pi * wheelRadiusMeters)) * 60;
    double engineRpm = wheelRpm * gearRatios[currentGear] * totalDriveRatio;
    engineRpm = engineRpm.clamp(0, 9000);

    if (engineRpm >= 8500 && currentGear < gearRatios.length - 1) {
      currentGear++;
    } else if (engineRpm <= 4500 && currentGear > 1) {
      currentGear--;
    }

    _setRpm(engineRpm);
  }

  void _setRpm(double newRpm) {
    _rpmAnimation = Tween<double>(begin: _displayedRpm, end: newRpm).animate(
      CurvedAnimation(parent: _rpmAnimationController, curve: Curves.easeOut),
    );
    _rpmAnimationController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(0),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('${_speedKmh.toInt()} km/h', style: Theme.of(context).textTheme.headlineLarge),
                ],
              ),
            ),
            Expanded(
              flex: 4,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('RPM', style: TextStyle(color: Colors.white, fontSize: 20)),
                  Text(_displayedRpm.toInt().toString(), style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 20),
                  CustomPaint(
                    painter: RpmBarPainter(_displayedRpm),
                    size: const Size(double.infinity, 30),
                  ),
                  const SizedBox(height: 30),
                  Text('Gear: ${currentGear == 0 ? 'N' : currentGear.toString()}',
                      style: const TextStyle(color: Colors.white, fontSize: 28)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RpmBarPainter extends CustomPainter {
  final double rpm;
  RpmBarPainter(this.rpm);
  static const double maxRpm = 9000;

  @override
  void paint(Canvas canvas, Size size) {
    final paintBackground = Paint()
      ..color = Colors.white12
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round;

    final Color activeColor = rpm < 5000 ? Colors.greenAccent : Colors.redAccent;

    final paintActive = Paint()
      ..color = activeColor
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round;

    final double width = size.width;
    final double height = size.height;
    final double barHeight = height * 0.9;
    final double yOffset = (height - barHeight) / 2;

    final Rect backgroundRect = Rect.fromLTWH(0, yOffset, width, barHeight);
    canvas.drawRRect(RRect.fromRectAndRadius(backgroundRect, const Radius.circular(12)), paintBackground);

    double activeWidth = (rpm / maxRpm) * width;
    final Rect activeRect = Rect.fromLTWH(0, yOffset, activeWidth, barHeight);
    canvas.drawRRect(RRect.fromRectAndRadius(activeRect, const Radius.circular(12)), paintActive);
  }

  @override
  bool shouldRepaint(covariant RpmBarPainter oldDelegate) {
    return oldDelegate.rpm != rpm;
  }
}
