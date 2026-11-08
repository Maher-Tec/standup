import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';

const navy = Color(0xFF0F172A);
const cyan = Color(0xFF38BDF8);
const mint = Color(0xFF34D399);
const peach = Color(0xFFFB923C);
const honey = Color(0xFFFBBF24);
const white = Color(0xFFF8FAFC);
const petSize = Size(280, 400);

/// Direct Win32 user32.dll / kernel32.dll helper for 0ms synchronous
/// multi-monitor dragging, cursor tracking, and per-monitor work-area detection.
class _Win32 {
  static final _Win32 instance = _Win32._();

  late final ffi.DynamicLibrary _user32;
  late final ffi.DynamicLibrary _kernel32;
  late final ffi.Pointer<ffi.Int32> _buf;
  late final ffi.Pointer<ffi.Uint16> _className;

  late final int Function() _getCurrentProcessId;
  late final int Function() _getForegroundWindow;
  late final int Function(
          int, int, ffi.Pointer<ffi.Uint16>, ffi.Pointer<ffi.Uint16>)
      _findWindowExW;
  late final int Function(int, ffi.Pointer<ffi.Uint32>)
      _getWindowThreadProcessId;
  late final int Function(int) _isWindow;
  late final int Function(ffi.Pointer<ffi.Int32>) _getCursorPos;
  late final int Function(int, ffi.Pointer<ffi.Int32>) _getWindowRect;
  late final int Function(int, int, int, int, int, int, int) _setWindowPos;
  late final int Function(int) _getAsyncKeyState;
  late final int Function(int, int) _monitorFromWindow;
  late final int Function(int, ffi.Pointer<ffi.Int32>) _getMonitorInfoW;
  late final int Function(int, ffi.Pointer<ffi.Uint16>, int) _getWindowTextW;
  late final ffi.Pointer<ffi.Uint16> _titleBuf;

  int _hwnd = 0;

  _Win32._() {
    _user32 = ffi.DynamicLibrary.open('user32.dll');
    _kernel32 = ffi.DynamicLibrary.open('kernel32.dll');

    final localAlloc = _kernel32.lookupFunction<
        ffi.Pointer<ffi.Int32> Function(ffi.Uint32, ffi.IntPtr),
        ffi.Pointer<ffi.Int32> Function(int, int)>('LocalAlloc');
    _buf = localAlloc(0x0040, 128);
    _titleBuf = localAlloc(0x0040, 520).cast<ffi.Uint16>();

    const cls = 'FLUTTER_RUNNER_WIN32_WINDOW';
    _className = localAlloc(0x0040, (cls.length + 1) * 2).cast<ffi.Uint16>();
    for (int i = 0; i < cls.length; i++) {
      _className[i] = cls.codeUnitAt(i);
    }
    _className[cls.length] = 0;

    _getCurrentProcessId = _kernel32
        .lookupFunction<ffi.Uint32 Function(), int Function()>(
            'GetCurrentProcessId');
    _getForegroundWindow = _user32
        .lookupFunction<ffi.IntPtr Function(), int Function()>(
            'GetForegroundWindow');
    _findWindowExW = _user32.lookupFunction<
        ffi.IntPtr Function(ffi.IntPtr, ffi.IntPtr, ffi.Pointer<ffi.Uint16>,
            ffi.Pointer<ffi.Uint16>),
        int Function(int, int, ffi.Pointer<ffi.Uint16>,
            ffi.Pointer<ffi.Uint16>)>('FindWindowExW');
    _getWindowThreadProcessId = _user32.lookupFunction<
        ffi.Uint32 Function(ffi.IntPtr, ffi.Pointer<ffi.Uint32>),
        int Function(int, ffi.Pointer<ffi.Uint32>)>('GetWindowThreadProcessId');
    _isWindow = _user32.lookupFunction<ffi.Int32 Function(ffi.IntPtr),
        int Function(int)>('IsWindow');
    _getCursorPos = _user32.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Int32>),
        int Function(ffi.Pointer<ffi.Int32>)>('GetCursorPos');
    _getWindowRect = _user32.lookupFunction<
        ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<ffi.Int32>),
        int Function(int, ffi.Pointer<ffi.Int32>)>('GetWindowRect');
    _setWindowPos = _user32.lookupFunction<
        ffi.Int32 Function(ffi.IntPtr, ffi.IntPtr, ffi.Int32, ffi.Int32,
            ffi.Int32, ffi.Int32, ffi.Uint32),
        int Function(int, int, int, int, int, int, int)>('SetWindowPos');
    _getAsyncKeyState = _user32.lookupFunction<ffi.Int16 Function(ffi.Int32),
        int Function(int)>('GetAsyncKeyState');
    _monitorFromWindow = _user32.lookupFunction<
        ffi.IntPtr Function(ffi.IntPtr, ffi.Uint32),
        int Function(int, int)>('MonitorFromWindow');
    _getMonitorInfoW = _user32.lookupFunction<
        ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<ffi.Int32>),
        int Function(int, ffi.Pointer<ffi.Int32>)>('GetMonitorInfoW');
    _getWindowTextW = _user32.lookupFunction<
        ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<ffi.Uint16>, ffi.Int32),
        int Function(int, ffi.Pointer<ffi.Uint16>, int)>('GetWindowTextW');
  }

  int get hwnd {
    if (_hwnd != 0 && _isWindow(_hwnd) != 0) return _hwnd;
    final myPid = _getCurrentProcessId();
    final pidPtr = _buf.cast<ffi.Uint32>();
    int cur = 0;
    while (true) {
      cur = _findWindowExW(0, cur, _className, ffi.nullptr);
      if (cur == 0) break;
      _getWindowThreadProcessId(cur, pidPtr);
      if (pidPtr[0] == myPid) {
        _hwnd = cur;
        return _hwnd;
      }
    }
    _hwnd = _getForegroundWindow();
    return _hwnd;
  }

  Offset getCursorPos() {
    _getCursorPos(_buf);
    return Offset(_buf[0].toDouble(), _buf[1].toDouble());
  }

  Rect getWindowRect() {
    final h = hwnd;
    if (h == 0) return const Rect.fromLTWH(80, 350, 250, 300);
    _getWindowRect(h, _buf);
    return Rect.fromLTRB(
      _buf[0].toDouble(),
      _buf[1].toDouble(),
      _buf[2].toDouble(),
      _buf[3].toDouble(),
    );
  }

  void setWindowPos(int x, int y) {
    final h = hwnd;
    if (h == 0) return;
    // SWP_NOSIZE (0x0001) | SWP_NOZORDER (0x0004) | SWP_NOACTIVATE (0x0010)
    _setWindowPos(h, 0, x, y, 0, 0, 0x0015);
  }

  bool isLeftButtonDown() => (_getAsyncKeyState(0x01) & 0x8000) != 0;

  int _lastTypingMask = 0;

  /// Detects live keyboard typing activity across common coding & alphanumeric keys
  /// via Win32 GetAsyncKeyState without installing any global hooks.
  bool isUserTyping() {
    int mask = 0;
    // Check Space (0x20), Enter (0x0D), Backspace (0x08), Tab (0x09)
    const specialKeys = [0x20, 0x0D, 0x08, 0x09, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xDB, 0xDD];
    for (int i = 0; i < specialKeys.length; i++) {
      if ((_getAsyncKeyState(specialKeys[i]) & 0x8000) != 0) {
        mask |= (1 << i);
      }
    }
    // Check A-Z (0x41..0x5A) and 0-9 (0x30..0x39)
    for (int vk = 0x30; vk <= 0x5A; vk += 2) {
      if ((_getAsyncKeyState(vk) & 0x8000) != 0) {
        mask |= (1 << (12 + ((vk - 0x30) & 15)));
      }
      if ((_getAsyncKeyState(vk + 1) & 0x8000) != 0) {
        mask |= (1 << (13 + ((vk - 0x30) & 15)));
      }
    }
    final newlyPressed = (mask & ~_lastTypingMask) != 0;
    _lastTypingMask = mask;
    return newlyPressed;
  }

  /// Returns the work area (excluding taskbar) of whichever monitor the pet is currently on!
  Rect getMonitorWorkArea() {
    final h = hwnd;
    if (h != 0) {
      // MONITOR_DEFAULTTONEAREST = 2
      final hMon = _monitorFromWindow(h, 2);
      if (hMon != 0) {
        _buf[0] = 40; // sizeof(MONITORINFO)
        if (_getMonitorInfoW(hMon, _buf) != 0) {
          return Rect.fromLTRB(
            _buf[5].toDouble(),
            _buf[6].toDouble(),
            _buf[7].toDouble(),
            _buf[8].toDouble(),
          );
        }
      }
    }
    return const Rect.fromLTWH(0, 0, 1920, 1080);
  }

  /// Reads the active Windows foreground window title 100% locally via GetWindowTextW.
  String getForegroundWindowTitle() {
    final fg = _getForegroundWindow();
    if (fg == 0 || fg == _hwnd) return '';
    final len = _getWindowTextW(fg, _titleBuf, 255);
    if (len <= 0) return '';
    final codes = <int>[];
    for (int i = 0; i < len; i++) {
      codes.add(_titleBuf[i]);
    }
    return String.fromCharCodes(codes);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: petSize,
      title: 'StandUp! Desktop Pet',
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.transparent,
      skipTaskbar: true,
      alwaysOnTop: true,
      center: true,
    ),
    () async {
      await windowManager.setAsFrameless();
      await windowManager.setResizable(false);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.show();
    },
  );
  runApp(const StandUpApp());
}

class StandUpApp extends StatelessWidget {
  const StandUpApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: cyan,
            brightness: Brightness.dark,
          ),
        ),
        home: const PetHome(),
      );
}

enum Mood {
  idle,
  walking,
  typing,
  sleeping,
  alert,
  stretching,
  exercising,
  celebrating,
  dragged,
  landing,
  petting,
}

enum ExerciseType {
  squats,
  jumpingJacks,
  dumbbells,
  stretch,
}

enum BubblePrompt {
  none,
  moveAfterWork,
  coachCheckIn,
  activeWorkout,
  setGoal,
  breathingActive,
}

enum DrinkProp {
  none,
  water,
  espresso,
}

/// 100% offline procedural warm Lo-Fi synthesizer loop generator (PCM 16-bit WAV in RAM).
class _LoFiBeatGenerator {
  static Uint8List? _cachedWav;

  static Uint8List generateWav() {
    if (_cachedWav != null) return _cachedWav!;
    const sampleRate = 22050;
    const durationSecs = 8; // 8-second seamless 4-bar Lo-Fi chill chord & beat loop
    const numSamples = sampleRate * durationSecs;
    final byteData = ByteData(44 + numSamples * 2);

    void writeStr(int offset, String s) {
      for (int i = 0; i < s.length; i++) {
        byteData.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    // RIFF WAVE Header
    writeStr(0, 'RIFF');
    byteData.setUint32(4, 36 + numSamples * 2, Endian.little);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    byteData.setUint32(16, 16, Endian.little);
    byteData.setUint16(20, 1, Endian.little); // PCM
    byteData.setUint16(22, 1, Endian.little); // Mono
    byteData.setUint32(24, sampleRate, Endian.little);
    byteData.setUint32(28, sampleRate * 2, Endian.little);
    byteData.setUint16(32, 2, Endian.little);
    byteData.setUint16(34, 16, Endian.little);
    writeStr(36, 'data');
    byteData.setUint32(40, numSamples * 2, Endian.little);

    // Warm Rhodes-style Lo-Fi jazz chords: Fmaj7 -> Em7 -> Dm7 -> Cmaj7
    const chords = <List<double>>[
      [174.61, 220.00, 261.63, 329.63], // Fmaj7
      [164.81, 196.00, 246.94, 293.66], // Em7
      [146.83, 174.61, 220.00, 261.63], // Dm7
      [130.81, 164.81, 196.00, 246.94], // Cmaj7
    ];

    final rng = math.Random(42);
    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      final bar = (t ~/ 2.0).clamp(0, 3);
      final barT = t % 2.0;
      final beatT = t % 0.5; // 120 BPM eighth-feel / 60 BPM lo-fi groove
      final chord = chords[bar];

      // Warm electric piano chord pad with gentle tremolo & envelope
      final env = math.exp(-barT * 0.85) * (1.0 - math.exp(-barT * 35.0));
      final tremolo = 0.88 + 0.12 * math.sin(2 * math.pi * 3.5 * t);
      double pad = 0.0;
      for (final f in chord) {
        pad += math.sin(2 * math.pi * f * t) * 0.22;
        pad += math.sin(2 * math.pi * (f * 2.0) * t) * 0.04;
      }
      pad *= env * tremolo;

      // Deep warm sub-bass root note
      final bassFreq = chord[0] * 0.5;
      final bassEnv = math.exp(- (t % 1.0) * 2.8);
      final bass = math.sin(2 * math.pi * bassFreq * t) * 0.28 * bassEnv;

      // Soft lo-fi kick on beats 0.0 and 1.0 of each 2s bar
      double kick = 0.0;
      final kickPhase = t % 1.0;
      if (kickPhase < 0.16) {
        final kFreq = 110.0 * math.exp(-kickPhase * 24.0) + 42.0;
        final kEnv = math.exp(-kickPhase * 18.0);
        kick = math.sin(2 * math.pi * kFreq * kickPhase) * 0.35 * kEnv;
      }

      // Soft brushed hi-hat / vinyl warmth tick on off-beats
      double hat = 0.0;
      if (beatT > 0.24 && beatT < 0.32) {
        final hEnv = math.exp(-(beatT - 0.24) * 55.0);
        hat = (rng.nextDouble() * 2.0 - 1.0) * 0.06 * hEnv;
      }

      final sample = ((pad + bass + kick + hat) * 0.42).clamp(-0.95, 0.95);
      byteData.setInt16(44 + i * 2, (sample * 32767).round(), Endian.little);
    }

    _cachedWav = byteData.buffer.asUint8List();
    return _cachedWav!;
  }
}

class Particle {
  Offset position;
  Offset velocity;
  double life;
  final Color color;
  final double size;
  final int type; // 0: heart, 1: star, 2: dust ring, 3: sparkle

  Particle({
    required this.position,
    required this.velocity,
    this.life = 1.0,
    required this.color,
    required this.size,
    required this.type,
  });

  void update() {
    position += velocity;
    velocity = Offset(velocity.dx * 0.96, velocity.dy * 0.96 - 0.04);
    life -= 0.024;
  }
}

class PetHome extends StatefulWidget {
  const PetHome({super.key});
  @override
  State<PetHome> createState() => _PetHomeState();
}

class _PetHomeState extends State<PetHome>
    with TickerProviderStateMixin, WindowListener, TrayListener {
  AnimationController? _animController;
  AnimationController? _squashController;
  AnimationController? _petController;

  AnimationController get animController => _animController ??=
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 2400),
      )
        ..addListener(_onFrame)
        ..repeat();

  AnimationController get squashController => _squashController ??=
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 480),
      );

  AnimationController get petController => _petController ??=
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1400),
      );

  final player = AudioPlayer();
  final musicPlayer = AudioPlayer();
  final TextEditingController goalController = TextEditingController();
  Timer? tick;
  Timer? blinkTimer;

  DateTime? nextBreak, breakEnds;
  int interval = 15, breakMinutes = 5, snoozeMinutes = 10, completed = 0;
  int longBreakMinutes = 15;
  int pomodoroSprint = 1;
  bool pomodoroMode = true, isLongBreak = false;
  bool snapToEdges = true;
  int waterGlasses = 0, waterGoal = 8, coffeeCups = 0;
  DrinkProp activeDrinkProp = DrinkProp.none;
  int drinkPropSeconds = 0;
  bool musicMode = false;
  bool windowAwareness = true;
  String activeAppContext = '';
  int _lastNudgeEpochSec = 0;
  String currentGoal = '';
  int goalsCompleted = 0;
  bool cyberGlasses = false;
  bool nightOwlMode = true;
  int _lastNightNudgeEpochSec = 0;
  bool breathingMode = false;
  DateTime? _breathingStartedAt;
  int breathingSessions = 0;
  double get _breathingElapsedSec =>
      breathingMode && _breathingStartedAt != null
          ? DateTime.now().difference(_breathingStartedAt!).inMilliseconds /
              1000.0
          : 0.0;
  int elapsed = 0, moodSeconds = 0;
  bool sound = true, enabled = true, inBreak = false, reminder = false;
  bool dashboard = false, wandering = true, loaded = false, dragging = false;
  bool beeTheme = false;
  bool showBubble = false, trayReady = false;
  bool isBlinking = false;
  double blinkProgress = 0.0;

  // Live Win32 Keyboard & Mouse Activity / AFK Tracking
  double _typingEnergy = 0.0;
  Offset _lastObservedCursor = Offset.zero;
  int _afkIdleSeconds = 0;
  bool _isAfkSleeping = false;

  String bubble = 'Hey! Ready to write some clean code? 💻✨';
  Mood mood = Mood.idle;
  Mood? _previousMood;
  ExerciseType currentExercise = ExerciseType.squats;
  BubblePrompt bubblePrompt = BubblePrompt.none;
  int exerciseReps = 0;
  int exerciseTargetReps = 12;

  Offset location = const Offset(80, 350);
  Offset lookOffset = Offset.zero;
  double direction = 1.0;
  double currentTilt = 0.0;
  double targetTilt = 0.0;

  // Win32 Virtual-Desktop multi-screen drag & 60fps wandering state
  bool _pointerDown = false;
  Offset _pointerDownCursor = Offset.zero;
  Offset _grabWin32Offset = Offset.zero;
  Offset _exactWinPos = const Offset(80, 350);
  Offset _dragVelocity = Offset.zero;
  Offset _smoothedDragVelocity = Offset.zero;
  Offset _throwVelocity = Offset.zero;
  DateTime? _lastTapTime;

  final List<Particle> particles = [];
  final math.Random _random = math.Random();

  String get today {
    final d = DateTime.now();
    return '${d.year}-${d.month}-${d.day}';
  }

  @override
  void initState() {
    super.initState();
    // Initialize controllers
    animController;
    squashController;
    petController;

    windowManager.addListener(this);
    trayManager.addListener(this);
    _initialize();
    _startBlinkLoop();
    tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  @override
  void reassemble() {
    super.reassemble();
    // Ensure animation controllers, timers, and window size stay updated across Hot Reload!
    if (!animController.isAnimating) {
      animController.repeat();
    }
    tick ??= Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    if (!inBreak &&
        nextBreak != null &&
        nextBreak!.difference(DateTime.now()).inSeconds > interval * 60) {
      nextBreak = DateTime.now().add(Duration(minutes: interval));
    }
    if (!dashboard) {
      windowManager.setSize(petSize);
    }
  }

  void _stepWin32Drag() {
    if (!_pointerDown) return;
    if (!_Win32.instance.isLeftButtonDown()) {
      _endPointer();
      return;
    }
    final cursor = _Win32.instance.getCursorPos();
    if (!dragging) {
      if ((cursor - _pointerDownCursor).distance > 2.5) {
        _startDrag();
      } else {
        return;
      }
    }
    final target = cursor - _grabWin32Offset;
    final delta = target - _exactWinPos;
    if (delta.distance > 0.1) {
      _dragVelocity = Offset(
        (_dragVelocity.dx * 0.35 + delta.dx * 0.65).clamp(-75.0, 75.0),
        (_dragVelocity.dy * 0.35 + delta.dy * 0.65).clamp(-75.0, 75.0),
      );
      if (_dragVelocity.dx.abs() > 1.2) {
        direction = _dragVelocity.dx > 0 ? 1.0 : -1.0;
      }
      _exactWinPos = target;
      location = target;
      _Win32.instance.setWindowPos(target.dx.round(), target.dy.round());

      if (_dragVelocity.distance > 14 && _random.nextDouble() < 0.35) {
        particles.add(Particle(
          position: Offset(
            petSize.width * 0.5 + (_random.nextDouble() * 30 - 15),
            petSize.height * 0.55 + (_random.nextDouble() * 30 - 15),
          ),
          velocity: Offset(
            -_dragVelocity.dx * 0.08 + (_random.nextDouble() - 0.5),
            -_dragVelocity.dy * 0.08 + (_random.nextDouble() - 0.5),
          ),
          color: _random.nextBool() ? cyan : honey,
          size: 5 + _random.nextDouble() * 4,
          type: 1,
        ));
      }
    }
  }

  void _onFrame() {
    if (_pointerDown) {
      _stepWin32Drag();
    }

    if (dragging) {
      _smoothedDragVelocity = Offset(
        _smoothedDragVelocity.dx * 0.72 + _dragVelocity.dx * 0.28,
        _smoothedDragVelocity.dy * 0.72 + _dragVelocity.dy * 0.28,
      );
      _dragVelocity = _dragVelocity * 0.82;
      targetTilt = (_smoothedDragVelocity.dx * 0.026).clamp(-0.55, 0.55);
    } else if (_throwVelocity.distance > 0.8) {
      // Elastic throw / momentum glide bounded to the CURRENT monitor!
      final winRect = _Win32.instance.getWindowRect();
      final work = _Win32.instance.getMonitorWorkArea();
      _exactWinPos += _throwVelocity;
      _throwVelocity = _throwVelocity * 0.84;
      _smoothedDragVelocity = _throwVelocity;
      targetTilt = (_throwVelocity.dx * 0.022).clamp(-0.4, 0.4);

      final minX = work.left + 8.0;
      final maxX = math.max(minX, work.right - winRect.width - 8.0);
      final minY = work.top + 8.0;
      final maxY = math.max(minY, work.bottom - winRect.height - 8.0);

      if (_exactWinPos.dx < minX) {
        _exactWinPos = Offset(minX, _exactWinPos.dy);
        _throwVelocity = Offset(-_throwVelocity.dx * 0.6, _throwVelocity.dy);
        direction = 1.0;
      } else if (_exactWinPos.dx > maxX) {
        _exactWinPos = Offset(maxX, _exactWinPos.dy);
        _throwVelocity = Offset(-_throwVelocity.dx * 0.6, _throwVelocity.dy);
        direction = -1.0;
      }
      if (_exactWinPos.dy < minY) {
        _exactWinPos = Offset(_exactWinPos.dx, minY);
        _throwVelocity = Offset(_throwVelocity.dx, -_throwVelocity.dy * 0.6);
      } else if (_exactWinPos.dy > maxY) {
        _exactWinPos = Offset(_exactWinPos.dx, maxY);
        _throwVelocity = Offset(_throwVelocity.dx, -_throwVelocity.dy * 0.6);
      }

      location = _exactWinPos;
      _Win32.instance.setWindowPos(
        _exactWinPos.dx.round(),
        _exactWinPos.dy.round(),
      );

      if (_throwVelocity.distance <= 0.8) {
        _throwVelocity = Offset.zero;
        _smoothedDragVelocity = Offset.zero;
        targetTilt = 0.0;
        _clampToCurrentMonitor();
        _triggerLanding();
      }
    } else {
      _smoothedDragVelocity = _smoothedDragVelocity * 0.8;
      targetTilt = 0.0;

      // Live Win32 Keyboard Typing Detection (60 FPS)
      if (loaded && !dashboard && !inBreak && !reminder) {
        if (_Win32.instance.isUserTyping()) {
          _typingEnergy = (_typingEnergy + 0.55).clamp(0.0, 2.2);
          _afkIdleSeconds = 0;
          if (_isAfkSleeping) {
            _wakeFromAfk();
          } else if (mood != Mood.typing &&
              mood != Mood.petting &&
              mood != Mood.celebrating) {
            mood = Mood.typing;
          }
          // Spawn floating cyan code sparks from the holographic keyboard!
          if (_random.nextDouble() < 0.42) {
            particles.add(Particle(
              position: Offset(
                petSize.width * 0.5 + (_random.nextDouble() * 44 - 22),
                petSize.height * 0.62,
              ),
              velocity: Offset(
                (_random.nextDouble() - 0.5) * 1.1,
                -1.4 - _random.nextDouble() * 1.2,
              ),
              color: _random.nextBool() ? const Color(0xFF00F0FF) : mint,
              size: 4.5 + _random.nextDouble() * 3.5,
              type: 1,
            ));
          }
        } else {
          _typingEnergy = (_typingEnergy - 0.016).clamp(0.0, 2.2);
          if (_typingEnergy <= 0.05 && mood == Mood.typing) {
            mood = wandering ? Mood.walking : Mood.idle;
          }
        }
      }

      // Smooth 60-FPS wandering on whichever monitor the pet is currently on!
      if (loaded &&
          !dashboard &&
          wandering &&
          !reminder &&
          !inBreak &&
          mood == Mood.walking) {
        final winRect = _Win32.instance.getWindowRect();
        final work = _Win32.instance.getMonitorWorkArea();
        final minX = work.left + 14.0;
        final maxX = math.max(minX + 10.0, work.right - winRect.width - 14.0);

        double nextX = _exactWinPos.dx + direction * 1.15;
        if (nextX <= minX) {
          nextX = minX;
          direction = 1.0;
        } else if (nextX >= maxX) {
          nextX = maxX;
          direction = -1.0;
        }
        _exactWinPos = Offset(nextX, winRect.top);
        location = _exactWinPos;
        _Win32.instance.setWindowPos(nextX.round(), winRect.top.round());
      }
    }

    // Smooth tilt lerp
    currentTilt += (targetTilt - currentTilt) * 0.22;

    // Update and prune particles
    if (particles.isNotEmpty) {
      for (final p in particles) {
        p.update();
      }
      particles.removeWhere((p) => p.life <= 0);
    }
  }

  void _startDrag() {
    dragging = true;
    _throwVelocity = Offset.zero;
    _dragVelocity = Offset.zero;
    _smoothedDragVelocity = Offset.zero;
    mood = Mood.dragged;
    _play('tap');
    _say(_pick([
      'Whoosh! Flying across screens! 🚀',
      'Hold on tight! Exploring the desktop! ✨',
      'Wheeeeeee! Multi-screen flight! 💨',
      'Taking off! 🌟',
    ]), seconds: 4);
    setState(() {});
  }

  void _endPointer() {
    if (!_pointerDown && !dragging) return;
    final wasDragging = dragging;
    _pointerDown = false;
    dragging = false;

    if (wasDragging) {
      targetTilt = 0.0;
      if (_smoothedDragVelocity.distance > 4.5) {
        _throwVelocity = _smoothedDragVelocity * 0.7;
      } else {
        _throwVelocity = Offset.zero;
        _smoothedDragVelocity = Offset.zero;
        _clampToCurrentMonitor();
        _triggerLanding();
      }
      _dragVelocity = Offset.zero;
      _play('tap');
      _say(_pick([
        'Touchdown! Safe landing! 🎈',
        'Perfect landing! 10/10! 🏆',
        'I love this screen right here! ✨',
        'Back to coding together! 💻',
      ]), seconds: 5);
      setState(() {});
    } else {
      final now = DateTime.now();
      if (_lastTapTime != null &&
          now.difference(_lastTapTime!).inMilliseconds < 320) {
        _lastTapTime = null;
        mood = Mood.celebrating;
        _say('Double tap dance party! You rock! 💛🎉', seconds: 5);
        _play('success');
        _spawnParticles(18, 1);
        setState(() {});
      } else {
        _lastTapTime = now;
        _petBuddy();
      }
    }
  }

  void _startBlinkLoop() {
    final nextBlinkMs = 2800 + _random.nextInt(3200);
    blinkTimer = Timer(Duration(milliseconds: nextBlinkMs), () async {
      if (!mounted) return;
      if (mood != Mood.sleeping && mood != Mood.petting) {
        setState(() => isBlinking = true);
        await Future.delayed(const Duration(milliseconds: 140));
        if (mounted) setState(() => isBlinking = false);
      }
      _startBlinkLoop();
    });
  }

  Future<void> _initialize() async {
    final p = await SharedPreferences.getInstance();
    const validIntervals = [5, 10, 15, 20, 25, 30, 45, 60, 90, 120];
    final rawInterval = p.getInt('pet_interval') ?? 15;
    interval = validIntervals.contains(rawInterval) ? rawInterval : 15;
    breakMinutes = p.getInt('pet_break') ?? 5;
    snoozeMinutes = p.getInt('pet_snooze') ?? 10;
    pomodoroMode = p.getBool('pet_pomodoro_mode') ?? true;
    pomodoroSprint = (p.getInt('pet_pomodoro_sprint') ?? 1).clamp(1, 4);
    snapToEdges = p.getBool('pet_snap_edges') ?? true;
    enabled = p.getBool('pet_enabled') ?? true;
    sound = p.getBool('pet_sound') ?? true;
    wandering = p.getBool('pet_wandering') ?? true;
    beeTheme = p.getBool('pet_bee_wings_v2') ?? false;
    completed =
        p.getString('pet_day') == today ? (p.getInt('pet_completed') ?? 0) : 0;
    waterGlasses =
        p.getString('pet_day') == today ? (p.getInt('pet_water') ?? 0) : 0;
    coffeeCups =
        p.getString('pet_day') == today ? (p.getInt('pet_coffee') ?? 0) : 0;
    waterGoal = p.getInt('pet_water_goal') ?? 8;
    windowAwareness = p.getBool('pet_window_aware') ?? true;
    currentGoal = p.getString('pet_current_goal') ?? '';
    goalController.text = currentGoal;
    goalsCompleted =
        p.getString('pet_day') == today ? (p.getInt('pet_goals_done') ?? 0) : 0;
    cyberGlasses = p.getBool('pet_cyber_glasses') ?? false;
    nightOwlMode = p.getBool('pet_night_owl') ?? true;
    breathingSessions =
        p.getString('pet_day') == today ? (p.getInt('pet_breathing_done') ?? 0) : 0;
    final stored = p.getInt('pet_due');
    final now = DateTime.now();
    nextBreak = stored == null
        ? now.add(Duration(minutes: interval))
        : DateTime.fromMillisecondsSinceEpoch(stored);
    if (nextBreak!.isBefore(now) ||
        nextBreak!.difference(now).inSeconds > interval * 60) {
      nextBreak = now.add(Duration(minutes: interval));
    }
    try {
      await windowManager.setSize(petSize);
      final work = _Win32.instance.getMonitorWorkArea();
      final startX = work.right - petSize.width - 48.0;
      final startY = work.bottom - petSize.height + 4.0;
      _exactWinPos = Offset(startX, startY);
      location = _exactWinPos;
      _Win32.instance.setWindowPos(startX.round(), startY.round());
      _lastObservedCursor = _Win32.instance.getCursorPos();
    } catch (_) {}
    try {
      await trayManager.setIcon('assets/tray/standup.ico');
      await trayManager.setToolTip('StandUp! — Your desktop pet');
      await _trayMenu();
      trayReady = true;
    } catch (e) {
      debugPrint('Tray setup unavailable: $e');
    }
    if (mounted) setState(() => loaded = true);
  }

  Future<void> _trayMenu() async {
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'pet', label: 'Show desktop pet'),
      MenuItem(key: 'dashboard', label: 'Open dashboard'),
      MenuItem.separator(),
      MenuItem(
        key: 'pin',
        label: wandering
            ? 'Pause moving (Stay in one place)'
            : 'Resume walking around screen',
      ),
      MenuItem(key: 'sport', label: 'Start sport exercise workout 💪'),
      MenuItem(key: 'breathe', label: '30s Box Breathing & Posture Reset 🧘'),
      MenuItem(key: 'water', label: 'Drink water 💧 ($waterGlasses/$waterGoal)'),
      MenuItem(key: 'coffee', label: 'Espresso boost ☕'),
      MenuItem(
        key: 'music',
        label: musicMode ? 'Pause Lo-Fi Vibe Mode 🎵' : 'Play Lo-Fi Vibe Mode 🎵',
      ),
      MenuItem(key: 'break', label: 'Take a break now'),
      MenuItem(key: 'snooze', label: 'Snooze 10 minutes'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit StandUp!'),
    ]));
  }

  @override
  void onTrayIconMouseDown() => _petMode();
  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();
  @override
  void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'pet':
        _petMode();
        break;
      case 'dashboard':
        _dashboardMode();
        break;
      case 'pin':
        _toggleWandering();
        break;
      case 'sport':
        _startSportExercise();
        break;
      case 'breathe':
        _startBreathingReset();
        break;
      case 'water':
        _drinkWater();
        break;
      case 'coffee':
        _drinkEspresso();
        break;
      case 'music':
        _toggleMusicMode();
        break;
      case 'break':
        _startBreak();
        break;
      case 'snooze':
        _snooze();
        break;
      case 'quit':
        _quit();
        break;
    }
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('pet_interval', interval);
    await p.setInt('pet_break', breakMinutes);
    await p.setInt('pet_snooze', snoozeMinutes);
    await p.setBool('pet_enabled', enabled);
    await p.setBool('pet_sound', sound);
    await p.setBool('pet_wandering', wandering);
    await p.setBool('pet_bee_wings_v2', beeTheme);
    await p.setBool('pet_pomodoro_mode', pomodoroMode);
    await p.setInt('pet_pomodoro_sprint', pomodoroSprint);
    await p.setBool('pet_snap_edges', snapToEdges);
    await p.setString('pet_day', today);
    await p.setInt('pet_completed', completed);
    await p.setInt('pet_water', waterGlasses);
    await p.setInt('pet_coffee', coffeeCups);
    await p.setInt('pet_water_goal', waterGoal);
    await p.setBool('pet_window_aware', windowAwareness);
    await p.setString('pet_current_goal', currentGoal);
    await p.setInt('pet_goals_done', goalsCompleted);
    await p.setBool('pet_cyber_glasses', cyberGlasses);
    await p.setBool('pet_night_owl', nightOwlMode);
    await p.setInt('pet_breathing_done', breathingSessions);
    if (nextBreak != null) {
      await p.setInt('pet_due', nextBreak!.millisecondsSinceEpoch);
    }
  }

  Future<void> _play(String name) async {
    if (!sound) return;
    try {
      await player.stop();
      await player.play(AssetSource('audio/$name.wav'), volume: .35);
    } catch (e) {
      debugPrint('Sound unavailable: $e');
    }
  }

  void _say(
    String message, {
    int seconds = 7,
    BubblePrompt prompt = BubblePrompt.none,
  }) {
    bubble = message;
    showBubble = true;
    moodSeconds = seconds;
    bubblePrompt = prompt;
    if (mounted) setState(() {});
  }

  String _pick(List<String> items) => items[_random.nextInt(items.length)];

  String _exerciseLabel(ExerciseType type) {
    switch (type) {
      case ExerciseType.squats:
        return 'Squats 🏋️';
      case ExerciseType.jumpingJacks:
        return 'Jumping Jacks 🤸';
      case ExerciseType.dumbbells:
        return 'Dumbbell Curls 💪';
      case ExerciseType.stretch:
        return 'Power Stretch 🧘';
    }
  }

  /// Toggles whether the pet walks around the PC screen or stays pinned in one spot.
  void _toggleWandering() {
    wandering = !wandering;
    _play('tap');
    if (!wandering) {
      if (mood == Mood.walking) {
        mood = Mood.idle;
      }
      _say(
        '📌 Pinned in place! I\'ll stay right here while you focus.',
        seconds: 5,
      );
    } else {
      if (!inBreak && !reminder && mood == Mood.idle) {
        mood = Mood.walking;
      }
      _say(
        '🚶‍♂️ Unpinned! I\'ll stroll around your screen again.',
        seconds: 5,
      );
    }
    _save();
    _trayMenu();
    setState(() {});
  }

  /// Opens an interactive supportive check-in where the user can reply with 1 click.
  void _askCoachSupport() {
    _play('tap');
    _say(
      _pick([
        'Hey coder! How are you feeling? Need water 💧, coffee ☕, or a sport boost? 💬',
        'Checking in on you! Sit tall, relax your shoulders—want a sip of water? ✨',
        'Coding hard? Tell me how I can support your flow right now! 💻🔥',
      ]),
      seconds: 25,
      prompt: BubblePrompt.coachCheckIn,
    );
  }

  /// Drinks a refreshing glass of water with a 3D sports water bottle prop!
  void _drinkWater() {
    waterGlasses++;
    activeDrinkProp = DrinkProp.water;
    drinkPropSeconds = 9;
    _play('success');
    _spawnParticles(12, 1);
    _say(
      waterGlasses >= waterGoal
          ? '💧 Hydration Goal Reached ($waterGlasses/$waterGoal)! Your brain is at 100% peak power! 🏆✨'
          : '💧 Refreshing sip! ($waterGlasses/$waterGoal glasses today) — stay hydrated, coder! 🌊',
      seconds: 7,
    );
    _save();
    _trayMenu();
    setState(() {});
  }

  /// Takes an espresso boost with a 3D steaming espresso cup prop!
  void _drinkEspresso() {
    coffeeCups++;
    activeDrinkProp = DrinkProp.espresso;
    drinkPropSeconds = 9;
    _play('tap');
    _spawnParticles(10, 1);
    _say(
      '☕ Fresh hot espresso (#$coffeeCups today)! Clean code & high energy incoming! ⚡💻',
      seconds: 7,
    );
    _save();
    setState(() {});
  }

  /// Toggles Headphone Music / Lo-Fi Vibe Mode (head bobbing + 3D earcup equalizer + procedural synth beats).
  Future<void> _toggleMusicMode() async {
    musicMode = !musicMode;
    if (musicMode) {
      if (sound) {
        try {
          await musicPlayer.setReleaseMode(ReleaseMode.loop);
          await musicPlayer.setVolume(0.28);
          await musicPlayer.play(BytesSource(_LoFiBeatGenerator.generateWav()));
        } catch (e) {
          debugPrint('Lo-Fi synth playback error: $e');
        }
      }
      _spawnParticles(8, 3); // Musical notes!
      _say(
        '🎵 Lo-Fi Vibe Mode ON! Vibing to chill focus beats in my </> headphones! 🎧✨',
        seconds: 6,
      );
    } else {
      try {
        await musicPlayer.stop();
      } catch (_) {}
      _say(
        '🎧 Music paused! Quiet deep-focus mode engaged. 💻',
        seconds: 4,
      );
    }
    _trayMenu();
    if (mounted) setState(() {});
  }

  /// Inspects the active Windows foreground window title 100% locally via Win32 FFI.
  void _checkActiveWindowContext() {
    if (!windowAwareness || dashboard || inBreak || reminder || _isAfkSleeping) {
      return;
    }
    final title = _Win32.instance.getForegroundWindowTitle().toLowerCase();
    if (title.isEmpty || title.contains('standup!')) return;

    String newContext = '';
    if (title.contains('visual studio code') ||
        title.contains(' - vs code') ||
        title.contains('cursor') ||
        title.contains('android studio') ||
        title.contains('intellij') ||
        title.contains('pycharm') ||
        title.contains('webstorm') ||
        title.contains('vim') ||
        title.contains('neovim') ||
        title.contains('.dart') ||
        title.contains('.ts') ||
        title.contains('.py')) {
      newContext = 'code';
    } else if (title.contains('youtube') ||
        title.contains('netflix') ||
        title.contains('twitch') ||
        title.contains('tiktok') ||
        title.contains('reddit') ||
        title.contains('instagram') ||
        title.contains('steam')) {
      newContext = 'distraction';
    } else if (title.contains('stack overflow') ||
        title.contains('github') ||
        title.contains('pub.dev') ||
        title.contains('docs') ||
        title.contains('documentation') ||
        title.contains('chatgpt') ||
        title.contains('claude') ||
        title.contains('gemini') ||
        title.contains('chrome') ||
        title.contains('edge') ||
        title.contains('firefox') ||
        title.contains('brave')) {
      newContext = 'research';
    } else if (title.contains('powershell') ||
        title.contains('cmd.exe') ||
        title.contains('terminal') ||
        title.contains('wsl') ||
        title.contains('git bash')) {
      newContext = 'terminal';
    }

    if (newContext.isEmpty) return;
    final prevContext = activeAppContext;
    activeAppContext = newContext;

    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (nowSec - _lastNudgeEpochSec < 75) return; // Respectful cooldown between context reactions

    if (newContext == 'distraction') {
      _lastNudgeEpochSec = nowSec;
      _play('tap');
      _say(
        '👀 Hey! Shouldn\'t we finish this ${interval}m focus sprint first? 😉💻',
        seconds: 8,
        prompt: BubblePrompt.coachCheckIn,
      );
    } else if (newContext != prevContext && !showBubble) {
      _lastNudgeEpochSec = nowSec;
      if (newContext == 'code') {
        _say(
          '💻 Deep in the codebase! Let\'s ship clean, legendary code! 🚀',
          seconds: 6,
        );
      } else if (newContext == 'research') {
        _say(
          '🔍 Research mode! Finding the cleanest architecture & docs! ✨',
          seconds: 6,
        );
      } else if (newContext == 'terminal') {
        _say(
          '⚡ Terminal power user! Compiling & shipping at warp speed! 🔥',
          seconds: 6,
        );
      }
    }
  }

  /// Sets a 1-line sticky focus goal for the current sprint.
  void _setSprintGoal(String goal) {
    final trimmed = goal.trim();
    if (trimmed.isEmpty) return;
    currentGoal = trimmed;
    goalController.text = trimmed;
    _play('tap');
    _spawnParticles(8, 1);
    _say(
      '🎯 Sprint Goal locked in: "$currentGoal"! Let\'s ship it! 🚀💻',
      seconds: 6,
      prompt: BubblePrompt.none,
    );
    _save();
    setState(() {});
  }

  /// Completes the active sticky focus goal with a big confetti celebration!
  void _completeSprintGoal() {
    if (currentGoal.isEmpty) return;
    final finishedGoal = currentGoal;
    currentGoal = '';
    goalController.clear();
    goalsCompleted++;
    mood = Mood.celebrating;
    _play('success');
    _spawnParticles(22, 1);
    _spawnParticles(8, 0);
    _say(
      '🏆 Goal Crushed: "$finishedGoal"! (#$goalsCompleted done today) Legendary coder! 🎉🔥',
      seconds: 8,
      prompt: BubblePrompt.none,
    );
    _save();
    setState(() {});
  }

  /// Opens the quick sticky-goal picker in the speech bubble.
  void _openGoalPrompt() {
    _play('tap');
    _say(
      currentGoal.isEmpty
          ? '🎯 Pick a quick Sprint Goal below (or type a custom one in Dashboard)!'
          : '🎯 Active Goal: "$currentGoal" — tap ✅ Done when finished or switch below!',
      seconds: 25,
      prompt: BubblePrompt.setGoal,
    );
  }

  /// Toggles sleek 3D Blue-Light / Cyber Coding Glasses on the character!
  void _toggleCyberGlasses() {
    cyberGlasses = !cyberGlasses;
    _play('tap');
    _spawnParticles(6, 1);
    _say(
      cyberGlasses
          ? '🕶️ Deep-Flow Cyber Glasses ON! Zero eye strain, 100% laser focus! ⚡💻'
          : '👀 Cyber Glasses off! Natural eyes mode.',
      seconds: 5,
    );
    _save();
    setState(() {});
  }

  bool get _isLateNightHour {
    final h = DateTime.now().hour;
    return h >= 21 || h < 5;
  }

  /// Starts a Guided 30-Second Box Breathing (4s Inhale / 4s Hold / 4s Exhale) & Posture Reset!
  void _startBreathingReset() {
    if (breathingMode) {
      _finishBreathingReset(completedFull: false);
      return;
    }
    breathingMode = true;
    _breathingStartedAt = DateTime.now();
    _isAfkSleeping = false;
    mood = Mood.idle;
    _play('tap');
    _spawnParticles(8, 1);
    _say(
      '🧘 30s Box Breathing & Posture Reset! Sit tall, drop your shoulders & inhale with my glowing ring (4s)... 🌬️',
      seconds: 35,
      prompt: BubblePrompt.breathingActive,
    );
    setState(() {});
  }

  void _finishBreathingReset({bool completedFull = true}) {
    if (!breathingMode) return;
    breathingMode = false;
    _breathingStartedAt = null;
    if (completedFull) {
      breathingSessions++;
      _play('success');
      _spawnParticles(16, 1);
      mood = Mood.celebrating;
      _say(
        '🧘✨ 30s Posture & Mind Reset Complete! ($breathingSessions today) — Stress 0%, Focus 100%! 💻🌊',
        seconds: 7,
      );
      _save();
      _trayMenu();
    } else {
      _play('tap');
      _say(
        '🧘 Breathing reset paused — ready to ship clean code! 💻✨',
        seconds: 4,
      );
    }
    setState(() {});
  }

  /// Wakes the pet up immediately when the user returns from being AFK!
  void _wakeFromAfk() {
    if (!_isAfkSleeping) return;
    _isAfkSleeping = false;
    _afkIdleSeconds = 0;
    mood = Mood.celebrating;
    _play('tap');
    _spawnParticles(10, 1);
    _say(
      '👋 Welcome back, coder! Ready to ship some great code? 🚀✨',
      seconds: 6,
    );
  }

  /// Starts or resets a fresh Pomodoro Focus Sprint (or finishes current break).
  void _onTapMiniHud() {
    _play('tap');
    if (inBreak) {
      _finishBreak();
      return;
    }
    final focusMins = interval;
    nextBreak = DateTime.now().add(Duration(minutes: focusMins));
    reminder = false;
    _spawnParticles(6, 1);
    _say(
      pomodoroMode
          ? '🍅 Pomodoro Sprint $pomodoroSprint/4 started ($focusMins min)! Let\'s lock in! 💻🔥'
          : '⏱️ Focus timer reset ($focusMins min)! Let\'s crush this! 💻',
      seconds: 5,
    );
    _save();
    setState(() {});
  }

  /// Starts an animated sport exercise session right on the desktop!
  void _startSportExercise([ExerciseType? chosen]) {
    if (chosen != null) {
      currentExercise = chosen;
    } else if (mood == Mood.exercising) {
      // Cycle to the next sport exercise when clicked again!
      final nextIdx =
          (ExerciseType.values.indexOf(currentExercise) + 1) %
              ExerciseType.values.length;
      currentExercise = ExerciseType.values[nextIdx];
    }
    inBreak = true;
    reminder = false;
    isLongBreak = pomodoroMode && pomodoroSprint >= 4;
    final currentBreakMins = isLongBreak ? longBreakMinutes : breakMinutes;
    exerciseReps = 0;
    exerciseTargetReps = isLongBreak ? 16 : 12;
    breakEnds = DateTime.now().add(Duration(minutes: currentBreakMins));
    mood = Mood.exercising;
    _play('tap');
    _spawnParticles(8, 1);

    final label = _exerciseLabel(currentExercise);
    _say(
      isLongBreak
          ? '🌴 4/4 Sprints done! $currentBreakMins min Long Break — let\'s do $label! 🏆'
          : 'Let\'s do $label together ($currentBreakMins min)! Match my pace! 🔥',
      seconds: 60,
      prompt: BubblePrompt.activeWorkout,
    );
    setState(() {});
  }

  /// Handles interactive 1-click user replies from the speech bubble.
  void _handleReply(String action) {
    switch (action) {
      case 'squats':
        _startSportExercise(ExerciseType.squats);
        break;
      case 'jacks':
        _startSportExercise(ExerciseType.jumpingJacks);
        break;
      case 'dumbbells':
        _startSportExercise(ExerciseType.dumbbells);
        break;
      case 'stretch':
        _startSportExercise(ExerciseType.stretch);
        break;
      case 'next_sport':
        _startSportExercise();
        break;
      case 'finish_sport':
        _finishBreak();
        break;
      case 'water':
        _drinkWater();
        break;
      case 'coffee':
        _drinkEspresso();
        break;
      case 'music':
        _toggleMusicMode();
        break;
      case 'glasses':
        _toggleCyberGlasses();
        break;
      case 'breathe':
        _startBreathingReset();
        break;
      case 'stop_breathe':
        _finishBreathingReset(completedFull: true);
        break;
      case 'goal_prompt':
        _openGoalPrompt();
        break;
      case 'goal_done':
        _completeSprintGoal();
        break;
      case 'goal_bug':
        _setSprintGoal('Fix Bug 🐛');
        break;
      case 'goal_ui':
        _setSprintGoal('Ship UI ✨');
        break;
      case 'goal_api':
        _setSprintGoal('Build API ⚡');
        break;
      case 'goal_refactor':
        _setSprintGoal('Refactor 🧹');
        break;
      case 'motivate':
        _play('success');
        _spawnParticles(8, 0);
        mood = Mood.celebrating;
        _say(
          _pick([
            'You are building awesome things! One line at a time—keep shining! 🚀🔥',
            'Every bug you solve levels up your engineering mastery! You got this! 💪✨',
            'Clean code, strong body, unstoppable mindset! Proud of your hustle! 🏆',
          ]),
          seconds: 7,
        );
        break;
      case 'focus':
        _play('tap');
        mood = wandering ? Mood.walking : Mood.idle;
        _say(
          'Awesome! Locking in with you—ping me anytime you need a sport break! 💻⚡',
          seconds: 5,
        );
        break;
      case 'snooze':
        _snooze();
        break;
    }
  }

  void _onTick() {
    if (!mounted || !loaded) return;
    final now = DateTime.now();
    elapsed++;

    // Live Win32 Mouse & Keyboard Idle / AFK Detection
    if (!dashboard && !inBreak && !reminder && !dragging) {
      final cur = _Win32.instance.getCursorPos();
      if ((cur - _lastObservedCursor).distance > 2.0 || _typingEnergy > 0.1) {
        _lastObservedCursor = cur;
        if (_isAfkSleeping) {
          _wakeFromAfk();
        } else {
          _afkIdleSeconds = 0;
        }
      } else {
        _afkIdleSeconds++;
        if (_afkIdleSeconds >= 90 && !_isAfkSleeping) {
          _isAfkSleeping = true;
          mood = Mood.sleeping;
          _say(
            'Stepped away from the PC? Napping until you get back... zzz 🌙💤',
            seconds: 30,
          );
        }
      }
    }

    final maxFocusMins = math.max(interval, snoozeMinutes);
    if (!inBreak &&
        nextBreak != null &&
        nextBreak!.difference(now).inSeconds > maxFocusMins * 60) {
      nextBreak = now.add(Duration(minutes: interval));
    }
    if (nextBreak != null &&
        enabled &&
        !inBreak &&
        !reminder &&
        !now.isBefore(nextBreak!)) {
      _remind();
    }
    if (inBreak && breakEnds != null && !now.isBefore(breakEnds!)) {
      _finishBreak();
    }

    // Live rep counting & supportive coaching during Sport Exercises!
    if (inBreak && mood == Mood.exercising && elapsed % 2 == 0) {
      exerciseReps++;
      if (exerciseReps % 4 == 0) {
        _spawnParticles(4, 1);
      }
      final label = _exerciseLabel(currentExercise);
      if (exerciseReps < exerciseTargetReps) {
        bubble =
            '$label · Rep $exerciseReps/$exerciseTargetReps! ${_pick([
              'Keep going, you look strong! 🔥',
              'Breathe steady—great form! ⚡',
              'Feel your energy recharging! 💪',
              'Almost there, champion coder! 🏆',
            ])}';
        showBubble = true;
        moodSeconds = 30;
        bubblePrompt = BubblePrompt.activeWorkout;
      } else if (exerciseReps == exerciseTargetReps) {
        // Automatically switch to the next exercise in the circuit or celebrate!
        _play('success');
        _spawnParticles(12, 1);
        final nextIdx =
            (ExerciseType.values.indexOf(currentExercise) + 1) %
                ExerciseType.values.length;
        currentExercise = ExerciseType.values[nextIdx];
        exerciseReps = 0;
        bubble =
            'Set complete! 🎉 Switching to ${_exerciseLabel(currentExercise)}—or tap Done!';
        showBubble = true;
        moodSeconds = 30;
        bubblePrompt = BubblePrompt.activeWorkout;
      }
    }

    if (showBubble && moodSeconds > 0) {
      moodSeconds--;
      if (moodSeconds == 0) {
        showBubble = false;
        bubblePrompt = BubblePrompt.none;
        if (!inBreak &&
            !reminder &&
            !_isAfkSleeping &&
            mood != Mood.dragged &&
            mood != Mood.typing) {
          mood = wandering ? Mood.walking : Mood.idle;
        }
      }
    }

    if (drinkPropSeconds > 0) {
      drinkPropSeconds--;
      if (drinkPropSeconds == 0) {
        activeDrinkProp = DrinkProp.none;
      }
    }

    // Live 30-Second Guided Box Breathing (4s Inhale / 4s Hold / 4s Exhale) Coaching!
    if (breathingMode) {
      final elapsedSec = _breathingElapsedSec;
      if (elapsedSec >= 30.0) {
        _finishBreathingReset(completedFull: true);
      } else {
        final cyclePos = elapsedSec % 12.0;
        final leftTotal = (30.0 - elapsedSec).ceil();
        final phaseLeft = 4 - (cyclePos % 4.0).floor();
        if (cyclePos < 4.0) {
          bubble =
              '🌬️ INHALE deeply through your nose ($phaseLeft s) · Expand your chest! ($leftTotal s left)';
        } else if (cyclePos < 8.0) {
          bubble =
              '✨ HOLD & SIT TALL ($phaseLeft s) · Drop your shoulders & relax your jaw! ($leftTotal s left)';
        } else {
          bubble =
              '🍃 EXHALE slowly ($phaseLeft s) · Let all coding stress melt away... ($leftTotal s left)';
        }
        showBubble = true;
        moodSeconds = 10;
        bubblePrompt = BubblePrompt.breathingActive;
      }
    }

    if (musicMode && !dashboard && !_isAfkSleeping && elapsed % 2 == 0) {
      _spawnParticles(2, 3); // Floating musical notes around headphones!
    }

    if (elapsed % 3 == 0) {
      _checkActiveWindowContext();
    }

    // Night-Owl / Circadian Eye-Care Check (after 9 PM)
    if (nightOwlMode &&
        _isLateNightHour &&
        !dashboard &&
        !inBreak &&
        !reminder &&
        !_isAfkSleeping &&
        elapsed % 60 == 0) {
      final nowSec = now.millisecondsSinceEpoch ~/ 1000;
      if (nowSec - _lastNightNudgeEpochSec >= 900) {
        _lastNightNudgeEpochSec = nowSec;
        _say(
          _pick([
            '🌙 Night-Owl Session! Relax your eyes, lower screen brightness & sip water 💧🕶️',
            '🦉 Coding past 9 PM! Blue-light Cyber Glasses are on—keep shipping smoothly! ✨💻',
            '🌙 Late-night flow state! Blink softly & relax your shoulders, champion! 🕶️⚡',
          ]),
          seconds: 9,
          prompt: BubblePrompt.coachCheckIn,
        );
      }
    }

    // Periodic interactive supportive check-in after coding for a while
    if (!dashboard &&
        !inBreak &&
        !reminder &&
        !dragging &&
        !_isAfkSleeping &&
        elapsed % 180 == 0) {
      _say(
        _pick([
          'Quick support check! How\'s the code flowing? Remember water & posture! 💧',
          'You\'ve been focused! Want to do 10 quick squats or stretches with me? 🏋️',
          '20-20-20 eye check! Look 20ft away & tell me how you\'re feeling! 👀✨',
        ]),
        seconds: 18,
        prompt: BubblePrompt.coachCheckIn,
      );
    }

    // Smooth walking cycle state machine (actual movement runs at 60 FPS in _onFrame!)
    if (!dashboard &&
        !dragging &&
        _throwVelocity == Offset.zero &&
        wandering &&
        !reminder &&
        !inBreak &&
        !breathingMode &&
        !_isAfkSleeping &&
        mood != Mood.typing &&
        mood != Mood.petting &&
        mood != Mood.landing &&
        mood != Mood.exercising &&
        mood != Mood.celebrating) {
      final cycle = elapsed % 16;
      if (cycle < 10) {
        if (mood != Mood.walking) {
          final winRect = _Win32.instance.getWindowRect();
          _exactWinPos = winRect.topLeft;
          mood = Mood.walking;
        }
      } else if (mood == Mood.walking) {
        mood = Mood.idle;
      }
    }

    if (mounted) setState(() {});
  }

  Future<void> _remind() async {
    reminder = true;
    _isAfkSleeping = false;
    mood = Mood.alert;
    final isFourth = pomodoroMode && pomodoroSprint >= 4;
    _say(
      isFourth
          ? '🍅 Sprint 4/4 Complete! Time for a ${longBreakMinutes}m Long Break & Workout! 🏆'
          : '🍅 Sprint $pomodoroSprint/4 done! Pick a ${breakMinutes}m sport exercise below! 💪',
      seconds: 60,
      prompt: BubblePrompt.moveAfterWork,
    );
    _play('reminder');
    if (!dashboard) await windowManager.show();
    if (mounted) setState(() {});
  }

  void _startBreak() {
    _startSportExercise(ExerciseType.squats);
  }

  void _finishBreak() {
    if (!inBreak) return;
    inBreak = false;
    reminder = false;
    isLongBreak = false;
    completed++;
    if (pomodoroMode) {
      pomodoroSprint = (pomodoroSprint >= 4) ? 1 : (pomodoroSprint + 1);
    }
    final focusMins = interval;
    nextBreak = DateTime.now().add(Duration(minutes: focusMins));
    mood = Mood.celebrating;
    _say(
      pomodoroMode
          ? '🏆 Workout complete! Starting Pomodoro Sprint $pomodoroSprint/4 ($focusMins min)! 🚀'
          : '🏆 Workout complete! Energy +100% — back to writing legendary code! 🎉',
      seconds: 9,
      prompt: BubblePrompt.none,
    );
    _play('success');
    _spawnParticles(18, 1);
    _save();
    setState(() {});
  }

  void _snooze() {
    reminder = false;
    inBreak = false;
    nextBreak = DateTime.now().add(Duration(minutes: snoozeMinutes));
    mood = wandering ? Mood.walking : Mood.idle;
    _say(
      'Got it! Snoozing $snoozeMinutes min so you can finish your thought! 💻💤',
      seconds: 6,
      prompt: BubblePrompt.none,
    );
    _save();
    setState(() {});
  }

  void _petBuddy() {
    _previousMood = (mood == Mood.petting || mood == Mood.dragged)
        ? (wandering ? Mood.walking : Mood.idle)
        : mood;
    mood = Mood.petting;
    _play('tap');
    _spawnParticles(6, 0); // Hearts!
    _say(_pick([
      'Purr... you are the best coding buddy! 💖',
      'Awww, that tickles! Sending bug-free vibes! 🌸',
      'Headpats accepted! Productivity +100! ⚡✨',
      'I believe in you! Keep going! 🚀💛',
    ]), seconds: 5);

    petController.forward(from: 0.0).then((_) {
      if (mounted && mood == Mood.petting) {
        setState(() => mood = _previousMood ?? (wandering ? Mood.walking : Mood.idle));
      }
    });
    setState(() {});
  }

  void _spawnParticles(int count, int type) {
    final center = Offset(petSize.width * 0.5, petSize.height * 0.45);
    for (int i = 0; i < count; i++) {
      final angle = (_random.nextDouble() * 2 * math.pi);
      final speed = 1.2 + _random.nextDouble() * 2.8;
      final pColor = type == 0
          ? [peach, const Color(0xFFFF6584), honey][_random.nextInt(3)]
          : [cyan, mint, honey, white][_random.nextInt(4)];
      particles.add(Particle(
        position: center + Offset(_random.nextDouble() * 20 - 10, -10),
        velocity: Offset(math.cos(angle) * speed, math.sin(angle) * speed - 1.5),
        color: pColor,
        size: 7 + _random.nextDouble() * 6,
        type: type,
      ));
    }
  }

  void _triggerLanding() {
    mood = Mood.landing;
    squashController.forward(from: 0.0).then((_) {
      if (mounted && mood == Mood.landing) {
        setState(() => mood = wandering ? Mood.walking : Mood.idle);
      }
    });
    // Spawn dust ring ripple
    particles.add(Particle(
      position: Offset(petSize.width * 0.5, petSize.height * 0.88),
      velocity: Offset.zero,
      color: cyan.withValues(alpha: 0.8),
      size: 1.0,
      type: 2,
    ));
    particles.add(Particle(
      position: Offset(petSize.width * 0.5, petSize.height * 0.88),
      velocity: Offset.zero,
      color: honey.withValues(alpha: 0.6),
      size: 1.0,
      type: 2,
    ));
  }

  /// Clamps the pet within whichever monitor it was dropped on and applies
  /// magnetic Taskbar & Screen-Edge Gravity Snapping!
  void _clampToCurrentMonitor() {
    final winRect = _Win32.instance.getWindowRect();
    final work = _Win32.instance.getMonitorWorkArea();
    final minX = work.left + 4.0;
    final maxX = math.max(minX, work.right - winRect.width - 4.0);
    final minY = work.top + 4.0;
    final taskbarY = math.max(minY, work.bottom - winRect.height + 4.0);

    double clampedX = winRect.left.clamp(minX, maxX);
    double clampedY = winRect.top.clamp(minY, taskbarY);

    if (snapToEdges) {
      // 1. Magnetic Taskbar Gravity (if dropped within 90px of the Windows Taskbar)
      if ((taskbarY - clampedY).abs() <= 90.0) {
        clampedY = taskbarY;
      } else {
        // 2. Left / Right Screen-Edge Perch Magnet (when dropped higher up near a screen edge)
        if ((clampedX - minX).abs() <= 55.0) {
          clampedX = minX;
          direction = 1.0; // Face inward toward screen
          if (wandering) {
            wandering = false;
            _say('🧲 Perched on your left screen edge! Pinned in place.', seconds: 4);
          }
        } else if ((maxX - clampedX).abs() <= 55.0) {
          clampedX = maxX;
          direction = -1.0; // Face inward toward screen
          if (wandering) {
            wandering = false;
            _say('🧲 Perched on your right screen edge! Pinned in place.', seconds: 4);
          }
        }
      }
    }

    _exactWinPos = Offset(clampedX, clampedY);
    location = _exactWinPos;
    if ((clampedX - winRect.left).abs() > 0.5 ||
        (clampedY - winRect.top).abs() > 0.5) {
      _Win32.instance.setWindowPos(clampedX.round(), clampedY.round());
    }
  }

  Future<void> _petMode() async {
    dashboard = false;
    await windowManager.setMinimumSize(const Size(100, 100));
    await windowManager.setMaximumSize(const Size(1600, 1200));
    await windowManager.setSize(petSize);
    await windowManager.setResizable(false);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setAsFrameless();
    await windowManager.show();
    final winRect = _Win32.instance.getWindowRect();
    _exactWinPos = winRect.topLeft;
    location = _exactWinPos;
    if (mounted) setState(() {});
  }

  Future<void> _dashboardMode() async {
    dashboard = true;
    await windowManager.setResizable(true);
    await windowManager.setMaximumSize(const Size(1600, 1200));
    await windowManager.setMinimumSize(const Size(640, 540));
    await windowManager.setSize(const Size(890, 670));
    await windowManager.setSkipTaskbar(false);
    await windowManager.setAlwaysOnTop(false);
    await windowManager.center();
    await windowManager.show();
    if (mounted) setState(() {});
  }

  Future<void> _quit() async {
    await trayManager.destroy();
    await windowManager.destroy();
  }

  @override
  void onWindowClose() async {
    await windowManager.hide();
  }

  @override
  void dispose() {
    tick?.cancel();
    blinkTimer?.cancel();
    _animController?.dispose();
    _squashController?.dispose();
    _petController?.dispose();
    goalController.dispose();
    player.dispose();
    musicPlayer.dispose();
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    super.dispose();
  }

  String countdown() {
    final d = (inBreak ? breakEnds : nextBreak)?.difference(DateTime.now()) ??
        Duration.zero;
    final seconds = math.max(0, d.inSeconds);
    return '${(seconds ~/ 3600).toString().padLeft(2, '0')}:'
        '${((seconds % 3600) ~/ 60).toString().padLeft(2, '0')}:'
        '${(seconds % 60).toString().padLeft(2, '0')}';
  }

  /// Compact MM:SS countdown for the floating Pomodoro Mini-HUD pill.
  String miniTimerText() {
    final d = (inBreak ? breakEnds : nextBreak)?.difference(DateTime.now()) ??
        Duration.zero;
    final seconds = math.max(0, d.inSeconds);
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  /// Returns 0.0..1.0 progress of the current Pomodoro Sprint or Break.
  double timerProgress() {
    final totalSecs = (inBreak
            ? (isLongBreak ? longBreakMinutes : breakMinutes)
            : interval) *
        60.0;
    if (totalSecs <= 0) return 0.0;
    final rem = (inBreak ? breakEnds : nextBreak)?.difference(DateTime.now()) ??
        Duration.zero;
    final remSecs = rem.inSeconds.clamp(0, totalSecs.toInt());
    return ((totalSecs - remSecs) / totalSecs).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return dashboard ? _dashboard() : _pet();
  }

  Widget _pet() => Scaffold(
        backgroundColor: Colors.transparent,
        body: MouseRegion(
          cursor: dragging
              ? SystemMouseCursors.grabbing
              : SystemMouseCursors.grab,
          onHover: (event) {
            final center = Offset(petSize.width * 0.5, petSize.height * 0.52);
            final diff = event.localPosition - center;
            setState(() {
              lookOffset = Offset(
                (diff.dx / (petSize.width * 0.5)).clamp(-1.0, 1.0) * 4.5,
                (diff.dy / (petSize.height * 0.4)).clamp(-1.0, 1.0) * 3.5,
              );
            });
          },
          onExit: (_) => setState(() => lookOffset = Offset.zero),
          child: Column(
            children: [
              // 1. TOP POPUP SPEECH BUBBLE (In its own dedicated top slot so it NEVER covers the character!)
              if (showBubble)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xF5152238), Color(0xF51E3252)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(
                        color: (reminder
                                ? peach
                                : inBreak
                                    ? mint
                                    : cyan)
                            .withValues(alpha: 0.75),
                        width: 1.3,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.38),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                bubble,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: white,
                                  fontSize: 10.8,
                                  fontWeight: FontWeight.w700,
                                  height: 1.2,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            InkWell(
                              onTap: () => setState(() {
                                showBubble = false;
                                bubblePrompt = BubblePrompt.none;
                              }),
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 13,
                                  color: white.withValues(alpha: 0.6),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (bubblePrompt != BubblePrompt.none) ...[
                          const SizedBox(height: 5),
                          _buildReplyChips(),
                        ],
                      ],
                    ),
                  ),
                ),

              // 2. CHARACTER CANVAS (Always occupies the space below the popup and above the dock!)
              Expanded(
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (event) {
                    if (event.buttons == 2) {
                      _dashboardMode();
                      return;
                    }
                    if (event.buttons == 1) {
                      _pointerDown = true;
                      _pointerDownCursor = _Win32.instance.getCursorPos();
                      final winRect = _Win32.instance.getWindowRect();
                      _exactWinPos = winRect.topLeft;
                      _grabWin32Offset = _pointerDownCursor - _exactWinPos;
                      _throwVelocity = Offset.zero;
                    }
                  },
                  onPointerMove: (event) {
                    if (!_pointerDown) return;
                    _stepWin32Drag();
                  },
                  onPointerUp: (_) => _endPointer(),
                  onPointerCancel: (_) => _endPointer(),
                  child: AnimatedBuilder(
                    animation: Listenable.merge([
                      animController,
                      squashController,
                      petController,
                    ]),
                    builder: (_, __) {
                      double squashY = 1.0;
                      double squashX = 1.0;
                      if (squashController.isAnimating) {
                        final v = squashController.value;
                        final pulse = math.sin(v * math.pi);
                        squashY = 1.0 - pulse * 0.22;
                        squashX = 1.0 + pulse * 0.22;
                      } else if (dragging) {
                        final speed =
                            (_smoothedDragVelocity.distance / 45.0).clamp(0.0, 0.14);
                        squashY = 1.0 + speed * 0.8;
                        squashX = 1.0 - speed * 0.45;
                      }

                      return CustomPaint(
                        painter: PetPainter(
                          time: animController.value,
                          mood: mood,
                          exerciseType: currentExercise,
                          exerciseReps: exerciseReps,
                          timerProgress: timerProgress(),
                          drinkProp: activeDrinkProp,
                          musicMode: musicMode,
                          cyberGlasses: cyberGlasses ||
                              mood == Mood.typing ||
                              (nightOwlMode && _isLateNightHour),
                          lateNight: nightOwlMode && _isLateNightHour,
                          breathingMode: breathingMode,
                          breathingSeconds: _breathingElapsedSec,
                          pinned: !wandering,
                          direction: direction,
                          breakActive: inBreak,
                          tiltAngle: currentTilt,
                          dragVelocity: _smoothedDragVelocity,
                          squash: Offset(squashX, squashY),
                          lookOffset: lookOffset,
                          isBlinking: isBlinking,
                          petProgress: petController.value,
                          beeTheme: beeTheme,
                          particles: particles,
                        ),
                        child: const SizedBox.expand(),
                      );
                    },
                  ),
                ),
              ),

              // 2.2 STICKY MICRO-GOAL BANNER (Or "+ Goal" Quick Pill)
              Padding(
                padding: const EdgeInsets.only(bottom: 2.5),
                child: currentGoal.isNotEmpty
                    ? Container(
                        constraints: const BoxConstraints(maxWidth: 256),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2.5,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xE6142238),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: honey.withValues(alpha: 0.65),
                            width: 1.1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: GestureDetector(
                                onTap: _openGoalPrompt,
                                child: Text(
                                  '🎯 $currentGoal',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: white,
                                    fontSize: 9.6,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 5),
                            Tooltip(
                              message: 'Mark Sprint Goal as Done! ✅',
                              child: InkWell(
                                onTap: _completeSprintGoal,
                                borderRadius: BorderRadius.circular(8),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: mint.withValues(alpha: 0.22),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: mint.withValues(alpha: 0.7),
                                    ),
                                  ),
                                  child: const Text(
                                    '✅ Done',
                                    style: TextStyle(
                                      color: mint,
                                      fontSize: 8.8,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : Tooltip(
                        message: 'Set a 1-line Sprint Goal (Done today: $goalsCompleted)',
                        child: InkWell(
                          onTap: _openGoalPrompt,
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2.0,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xB3111C30),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white24,
                                width: 0.9,
                              ),
                            ),
                            child: Text(
                              goalsCompleted > 0
                                  ? '🎯 + Sprint Goal ($goalsCompleted done 🏆)'
                                  : '🎯 + Set Sprint Goal',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 9.0,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
              ),

              // 2.5 FLOATING POMODORO, HYDRATION & DEEP-WORK MINI-HUD PILL
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Tooltip(
                      message: inBreak
                          ? 'Tap to finish break & start next sprint'
                          : 'Tap to restart ${pomodoroMode ? "${interval}m Pomodoro Sprint $pomodoroSprint/4" : "${interval}m Focus Timer"}',
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _onTapMiniHud,
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 3.5,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xD9111C30),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: (inBreak
                                        ? mint
                                        : mood == Mood.typing
                                            ? const Color(0xFF00F0FF)
                                            : cyan)
                                    .withValues(alpha: 0.55),
                                width: 1.1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 11,
                                  height: 11,
                                  child: CircularProgressIndicator(
                                    value: timerProgress(),
                                    strokeWidth: 2.2,
                                    backgroundColor: Colors.white12,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      inBreak
                                          ? mint
                                          : mood == Mood.typing
                                              ? const Color(0xFF00F0FF)
                                              : honey,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  inBreak
                                      ? '${isLongBreak ? "🌴 Long" : "🏋️ Break"} · ${miniTimerText()}'
                                      : mood == Mood.typing
                                          ? '⌨️ ${miniTimerText()}'
                                          : '${pomodoroMode ? "🍅 $pomodoroSprint/4" : "💻"} · ${miniTimerText()}',
                                  style: const TextStyle(
                                    color: white,
                                    fontSize: 10.0,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                                if (pomodoroMode && !inBreak) ...[
                                  const SizedBox(width: 5),
                                  for (int i = 1; i <= 4; i++)
                                    Container(
                                      width: 4.5,
                                      height: 4.5,
                                      margin: const EdgeInsets.only(left: 2.0),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: i < pomodoroSprint
                                            ? mint
                                            : i == pomodoroSprint
                                                ? honey
                                                : Colors.white24,
                                      ),
                                    ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Tooltip(
                      message: 'Hydration: $waterGlasses/$waterGoal glasses today (Tap to drink water 💧)',
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _drinkWater,
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3.5,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xD9111C30),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: (waterGlasses >= waterGoal ? mint : cyan)
                                    .withValues(alpha: 0.55),
                                width: 1.1,
                              ),
                            ),
                            child: Text(
                              '💧 $waterGlasses/$waterGoal',
                              style: TextStyle(
                                color: waterGlasses >= waterGoal ? mint : white,
                                fontSize: 9.8,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // 3. BOTTOM FLOATING FROSTED GLASS ACTION DOCK
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                child: Container(
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xD80F192C),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: cyan.withValues(alpha: 0.38),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.42),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _actionPill(
                        icon: !wandering
                            ? Icons.push_pin_rounded
                            : Icons.pause_circle_outline_rounded,
                        tooltip: !wandering
                            ? 'Pinned in place! Click to let buddy walk'
                            : 'Pause moving (Stay in one place)',
                        color: !wandering ? honey : white.withValues(alpha: 0.85),
                        active: !wandering,
                        onTap: _toggleWandering,
                      ),
                      _actionPill(
                        icon: breathingMode
                            ? Icons.self_improvement_rounded
                            : Icons.fitness_center_rounded,
                        tooltip: breathingMode
                            ? '30s Box Breathing active 🧘 (Click to finish)'
                            : mood == Mood.exercising
                                ? 'Switch sport exercise (${_exerciseLabel(currentExercise)}) · Right-click: 30s Breathe 🧘'
                                : 'Click: Sport Exercises · Right-click: 30s Box Breathing & Posture Reset 🧘',
                        color: breathingMode ? const Color(0xFFA78BFA) : mint,
                        active: mood == Mood.exercising || breathingMode,
                        onTap: () => breathingMode
                            ? _finishBreathingReset(completedFull: true)
                            : _startSportExercise(),
                        onSecondaryTap: _startBreathingReset,
                      ),
                      _actionPill(
                        icon: activeDrinkProp == DrinkProp.espresso
                            ? Icons.coffee_rounded
                            : Icons.water_drop_rounded,
                        tooltip: 'Click: Drink Water ($waterGlasses/$waterGoal) · Right-click: Espresso ☕',
                        color: activeDrinkProp == DrinkProp.espresso
                            ? peach
                            : const Color(0xFF38BDF8),
                        active: activeDrinkProp != DrinkProp.none,
                        onTap: _drinkWater,
                        onSecondaryTap: _drinkEspresso,
                      ),
                      _actionPill(
                        icon: musicMode
                            ? Icons.graphic_eq_rounded
                            : Icons.headphones_rounded,
                        tooltip: musicMode
                            ? 'Lo-Fi Vibe Mode ON 🎵 (Click to pause)'
                            : 'Toggle Headphone Music / Lo-Fi Vibe Mode 🎵',
                        color: const Color(0xFF00F0FF),
                        active: musicMode,
                        onTap: _toggleMusicMode,
                      ),
                      _actionPill(
                        icon: Icons.chat_bubble_rounded,
                        tooltip: 'Click: Coach Check-in · Right-click: Toggle Cyber Glasses 🕶️',
                        color: cyberGlasses ? const Color(0xFF00F0FF) : cyan,
                        active: bubblePrompt == BubblePrompt.coachCheckIn ||
                            cyberGlasses,
                        onTap: _askCoachSupport,
                        onSecondaryTap: _toggleCyberGlasses,
                      ),
                      _actionPill(
                        icon: Icons.favorite_rounded,
                        tooltip: 'Pet buddy!',
                        color: const Color(0xFFFF6584),
                        onTap: _petBuddy,
                      ),
                      _actionPill(
                        icon: Icons.settings_rounded,
                        tooltip: 'Dashboard & schedule',
                        color: honey,
                        onTap: _dashboardMode,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _buildReplyChips() {
    switch (bubblePrompt) {
      case BubblePrompt.moveAfterWork:
        return Wrap(
          spacing: 5,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: [
            _replyChip('🏋️ Squats', mint, () => _handleReply('squats')),
            _replyChip('🤸 Jacks', cyan, () => _handleReply('jacks')),
            _replyChip('💪 Dumbbells', honey, () => _handleReply('dumbbells')),
            _replyChip('🧘 30s Breathe', const Color(0xFFA78BFA), () => _handleReply('breathe')),
            _replyChip('💤 Snooze', peach, () => _handleReply('snooze')),
          ],
        );
      case BubblePrompt.coachCheckIn:
        return Wrap(
          spacing: 5,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: [
            _replyChip('🧘 30s Breathe', const Color(0xFFA78BFA), () => _handleReply('breathe')),
            _replyChip('🎯 Set Goal', honey, () => _handleReply('goal_prompt')),
            _replyChip('🕶️ Glasses', const Color(0xFF38BDF8), () => _handleReply('glasses')),
            _replyChip('💧 Water ($waterGlasses/$waterGoal)', cyan, () => _handleReply('water')),
            _replyChip('☕ Espresso', peach, () => _handleReply('coffee')),
            _replyChip('🎵 Lo-Fi Vibe', const Color(0xFF00F0FF), () => _handleReply('music')),
            _replyChip('🏋️ Do Sport', mint, () => _handleReply('squats')),
          ],
        );
      case BubblePrompt.breathingActive:
        return Wrap(
          spacing: 6,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: [
            _replyChip('✅ Done Breathing', mint, () => _handleReply('stop_breathe')),
          ],
        );
      case BubblePrompt.setGoal:
        return Wrap(
          spacing: 5,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: [
            if (currentGoal.isNotEmpty)
              _replyChip('✅ Done Goal', mint, () => _handleReply('goal_done')),
            _replyChip('🐛 Fix Bug', peach, () => _handleReply('goal_bug')),
            _replyChip('✨ Ship UI', cyan, () => _handleReply('goal_ui')),
            _replyChip('⚡ Build API', honey, () => _handleReply('goal_api')),
            _replyChip('🧹 Refactor', const Color(0xFFA78BFA), () => _handleReply('goal_refactor')),
            _replyChip('✏️ Custom...', white, _dashboardMode),
          ],
        );
      case BubblePrompt.activeWorkout:
        return Wrap(
          spacing: 6,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: [
            _replyChip('🔄 Next Exercise', cyan, () => _handleReply('next_sport')),
            _replyChip('✅ Done Workout', mint, () => _handleReply('finish_sport')),
          ],
        );
      case BubblePrompt.none:
        return const SizedBox.shrink();
    }
  }

  Widget _replyChip(String label, Color color, VoidCallback onTap) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withValues(alpha: 0.65), width: 1),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 9.8,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      );

  Widget _actionPill({
    required IconData icon,
    required String tooltip,
    required Color color,
    required VoidCallback onTap,
    VoidCallback? onSecondaryTap,
    bool active = false,
  }) =>
      Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            onSecondaryTap: onSecondaryTap,
            borderRadius: BorderRadius.circular(16),
            splashColor: color.withValues(alpha: 0.3),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              decoration: BoxDecoration(
                color: active ? color.withValues(alpha: 0.22) : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                border: active
                    ? Border.all(color: color.withValues(alpha: 0.6), width: 1)
                    : null,
              ),
              child: Icon(icon, color: color, size: 16.5),
            ),
          ),
        ),
      );

  Widget _dashboard() => Scaffold(
        backgroundColor: navy,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, limits) => SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(minHeight: limits.maxHeight - 48),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.pets_rounded, color: honey, size: 30),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'StandUp! · Desktop Pet Companion',
                            style: TextStyle(
                              fontSize: 23,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ),
                        IconButton.filledTonal(
                          onPressed: _petMode,
                          tooltip: 'Back to desktop pet',
                          icon: const Icon(Icons.close_fullscreen_rounded,
                              color: cyan),
                        ),
                      ],
                    ),
                    const Text(
                      'Your animated vector companion living on Windows desktop.',
                      style: TextStyle(color: Colors.white60),
                    ),
                    const SizedBox(height: 22),
                    Wrap(
                      spacing: 14,
                      runSpacing: 14,
                      children: [
                        _statCard('NEXT MOVE', countdown(), Icons.timer_outlined,
                            cyan),
                        _statCard('BREAKS TODAY', '$completed',
                            Icons.favorite_rounded, const Color(0xFFFF6584)),
                        _statCard(
                          'SPRINT GOALS',
                          '🎯 $goalsCompleted Done',
                          Icons.flag_rounded,
                          mint,
                        ),
                        _statCard(
                          'HYDRATION',
                          '💧 $waterGlasses/$waterGoal · ☕ $coffeeCups',
                          Icons.water_drop_rounded,
                          const Color(0xFF38BDF8),
                        ),
                        _statCard(
                          'BUDDY MOOD',
                          inBreak
                              ? 'Stretching 🧘'
                              : reminder
                                  ? 'Alert! ⏰'
                                  : musicMode
                                      ? 'Lo-Fi Vibing 🎵'
                                      : _isLateNightHour
                                          ? 'Night Owl 🦉'
                                          : mood == Mood.sleeping
                                              ? 'Napping 💤'
                                              : 'Happy 🌸',
                          Icons.sentiment_very_satisfied_rounded,
                          honey,
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _card(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '🎯 Sticky Sprint Goal (Floating Mini-Banner)',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: goalController,
                                  style: const TextStyle(fontSize: 14),
                                  decoration: InputDecoration(
                                    hintText:
                                        'e.g., Fix Auth API, Ship Profile UI, Write Unit Tests...',
                                    isDense: true,
                                    filled: true,
                                    fillColor: const Color(0xFF0F172A),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  onSubmitted: (v) {
                                    _setSprintGoal(v);
                                    _petMode();
                                  },
                                ),
                              ),
                              const SizedBox(width: 10),
                              FilledButton.icon(
                                onPressed: () {
                                  _setSprintGoal(goalController.text);
                                  _petMode();
                                },
                                icon: const Icon(Icons.flag_rounded),
                                label: const Text('Pin Goal'),
                              ),
                              if (currentGoal.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                FilledButton.tonalIcon(
                                  onPressed: () {
                                    _completeSprintGoal();
                                    _petMode();
                                  },
                                  icon: const Icon(Icons.check_circle_rounded,
                                      color: mint),
                                  label: const Text('Done ✅'),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    _card(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Buddy controls & Sport Exercises',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              FilledButton.icon(
                                onPressed: () {
                                  _startSportExercise(ExerciseType.squats);
                                  _petMode();
                                },
                                icon: const Icon(Icons.fitness_center_rounded),
                                label: const Text('Do Squats 🏋️'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: () {
                                  _startSportExercise(
                                      ExerciseType.jumpingJacks);
                                  _petMode();
                                },
                                icon: const Icon(Icons.directions_run_rounded),
                                label: const Text('Jumping Jacks 🤸'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: () {
                                  _startSportExercise(ExerciseType.dumbbells);
                                  _petMode();
                                },
                                icon: const Icon(Icons.sports_gymnastics_rounded),
                                label: const Text('Dumbbells 💪'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: () {
                                  _startBreathingReset();
                                  _petMode();
                                },
                                icon: const Icon(Icons.self_improvement_rounded,
                                    color: Color(0xFFA78BFA)),
                                label: Text(
                                    '30s Box Breathing 🧘 ($breathingSessions done)'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: () {
                                  _drinkWater();
                                  _petMode();
                                },
                                icon: const Icon(Icons.water_drop_rounded,
                                    color: cyan),
                                label: Text('Drink Water 💧 ($waterGlasses/$waterGoal)'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: () {
                                  _drinkEspresso();
                                  _petMode();
                                },
                                icon: const Icon(Icons.coffee_rounded,
                                    color: peach),
                                label: const Text('Espresso Boost ☕'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: _toggleMusicMode,
                                icon: Icon(
                                  musicMode
                                      ? Icons.graphic_eq_rounded
                                      : Icons.headphones_rounded,
                                  color: const Color(0xFF00F0FF),
                                ),
                                label: Text(
                                    musicMode ? 'Lo-Fi Vibe: ON 🎵' : 'Play Lo-Fi Vibe 🎵'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: _toggleCyberGlasses,
                                icon: const Icon(Icons.visibility_rounded,
                                    color: cyan),
                                label: Text(cyberGlasses
                                    ? 'Cyber Glasses: ON 🕶️'
                                    : 'Wear Cyber Glasses 🕶️'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _toggleWandering,
                                icon: Icon(!wandering
                                    ? Icons.push_pin_rounded
                                    : Icons.pause_circle_outline_rounded),
                                label: Text(!wandering
                                    ? 'Pinned (Click to Walk)'
                                    : 'Pause Moving (Pin in Place)'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _snooze,
                                icon: const Icon(Icons.snooze_rounded),
                                label: const Text('Snooze'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: _petBuddy,
                                icon: const Icon(Icons.favorite_rounded,
                                    color: Color(0xFFFF6584)),
                                label: const Text('Pet buddy'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _petMode,
                                icon: const Icon(Icons.desktop_windows_rounded),
                                label: const Text('Return pet to screen'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          SwitchListTile(
                            title: const Text('🍅 Pomodoro 4-Sprint Auto-Cycle'),
                            subtitle: Text(
                                '${interval}m Deep Code → ${breakMinutes}m Sport Workout → ${longBreakMinutes}m Long Break after 4 sprints'),
                            value: pomodoroMode,
                            onChanged: (v) {
                              setState(() {
                                pomodoroMode = v;
                                nextBreak = DateTime.now()
                                    .add(Duration(minutes: interval));
                              });
                              _save();
                            },
                          ),
                          SwitchListTile(
                            title: const Text('🧲 Taskbar & Screen-Edge Gravity Snap'),
                            subtitle: const Text(
                                'Snap onto the top of your Windows Taskbar or perch on screen edges'),
                            value: snapToEdges,
                            onChanged: (v) {
                              setState(() => snapToEdges = v);
                              _save();
                            },
                          ),
                          SwitchListTile(
                            title: const Text('🎵 Headphone Lo-Fi Vibe Mode'),
                            subtitle: const Text(
                                'Rhythmic head-bobbing, 3D headphone equalizer & offline chill synth beats'),
                            value: musicMode,
                            onChanged: (_) => _toggleMusicMode(),
                          ),
                          SwitchListTile(
                            title: const Text('🖥️ Active Window / App Context Awareness'),
                            subtitle: const Text(
                                '100% local Win32 reactions for VS Code/IDEs, Chrome/Docs & focus nudges'),
                            value: windowAwareness,
                            onChanged: (v) {
                              setState(() => windowAwareness = v);
                              _save();
                            },
                          ),
                          SwitchListTile(
                            title: const Text('🕶️ Deep-Flow Blue-Light Cyber Glasses'),
                            subtitle: const Text(
                                'Wear 3D blue-light coding glasses permanently (also auto-equips while typing or after 9 PM)'),
                            value: cyberGlasses,
                            onChanged: (_) => _toggleCyberGlasses(),
                          ),
                          SwitchListTile(
                            title: const Text('🦉 Late-Night / Circadian Eye-Care Mode (After 9 PM)'),
                            subtitle: const Text(
                                'Soft indigo night aura, automatic blue-light glasses & gentle 9 PM+ eye-rest nudges'),
                            value: nightOwlMode,
                            onChanged: (v) {
                              setState(() => nightOwlMode = v);
                              _save();
                            },
                          ),
                          SwitchListTile(
                            title: const Text('Bee Mascot Mode'),
                            subtitle: const Text(
                                'Cute honeybee antennae & fluttering wings! 🐝'),
                            value: beeTheme,
                            onChanged: (v) {
                              setState(() => beeTheme = v);
                              _save();
                            },
                          ),
                          SwitchListTile(
                            title: const Text('Movement reminders'),
                            subtitle: const Text(
                                'Friendly nudge when it is time to move'),
                            value: enabled,
                            onChanged: (v) {
                              setState(() => enabled = v);
                              _save();
                            },
                          ),
                          SwitchListTile(
                            title: const Text('Let buddy wander'),
                            subtitle: const Text(
                                'Occasional slow strolls across the desktop'),
                            value: wandering,
                            onChanged: (v) {
                              setState(() => wandering = v);
                              _save();
                            },
                          ),
                          SwitchListTile(
                            title: const Text('Sound effects'),
                            value: sound,
                            onChanged: (v) {
                              setState(() => sound = v);
                              _save();
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _card(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Schedule & Durations',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 12),
                          _setting(
                            'Remind every',
                            interval,
                            [5, 10, 15, 20, 25, 30, 45, 60, 90, 120],
                            (v) {
                              interval = v;
                              inBreak = false;
                              reminder = false;
                              nextBreak =
                                  DateTime.now().add(Duration(minutes: v));
                              _save();
                            },
                          ),
                          _setting(
                            'Break duration',
                            breakMinutes,
                            [1, 3, 5, 10, 15],
                            (v) {
                              breakMinutes = v;
                              _save();
                            },
                          ),
                          _setting(
                            'Snooze duration',
                            snoozeMinutes,
                            [5, 10, 15, 20],
                            (v) {
                              snoozeMinutes = v;
                              _save();
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      '100% Offline · Vector procedural 60fps · Zero telemetry · Windows Frameless',
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  Widget _statCard(String label, String value, IconData icon, Color color) =>
      Container(
        width: math.max(
            175,
            math.min(
                260, MediaQuery.sizeOf(context).width / 3 - 28)),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 19),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              value,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
              ),
            ),
          ],
        ),
      );

  Widget _card(Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white10),
        ),
        child: child,
      );

  Widget _setting(
    String label,
    int value,
    List<int> options,
    ValueChanged<int> onChange,
  ) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            DropdownButton<int>(
              value: value,
              items: options
                  .map((v) => DropdownMenuItem(
                        value: v,
                        child: Text('$v min'),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => onChange(v));
              },
            ),
          ],
        ),
      );
}

/// Richly animated 3D-style Chibi Developer character painted to match the user:
/// curly dark top hair with temple skin fade, thick eyebrows, warm brown almond eyes,
/// groomed beard/mustache/soul patch, matte black headphones with glowing cyan `</>`
/// earcups, matte charcoal hoodie with white `</>` chest logo & white drawstrings,
/// hands-in-kangaroo-pocket pose with gold-bezel smartwatch, charcoal joggers,
/// and chunky white sneakers with two black stripes.
class PetPainter extends CustomPainter {
  final double time;
  final Mood mood;
  final ExerciseType exerciseType;
  final int exerciseReps;
  final double timerProgress;
  final DrinkProp drinkProp;
  final bool musicMode;
  final bool cyberGlasses;
  final bool lateNight;
  final bool breathingMode;
  final double breathingSeconds;
  final bool pinned;
  final double direction;
  final bool breakActive;
  final double tiltAngle;
  final Offset dragVelocity;
  final Offset squash;
  final Offset lookOffset;
  final bool isBlinking;
  final double petProgress;
  final bool beeTheme;
  final List<Particle> particles;

  const PetPainter({
    required this.time,
    required this.mood,
    this.exerciseType = ExerciseType.squats,
    this.exerciseReps = 0,
    this.timerProgress = 0.0,
    this.drinkProp = DrinkProp.none,
    this.musicMode = false,
    this.cyberGlasses = false,
    this.lateNight = false,
    this.breathingMode = false,
    this.breathingSeconds = 0.0,
    this.pinned = false,
    required this.direction,
    required this.breakActive,
    required this.tiltAngle,
    required this.dragVelocity,
    required this.squash,
    required this.lookOffset,
    required this.isBlinking,
    required this.petProgress,
    required this.beeTheme,
    required this.particles,
  });

  Paint brush(Color color) => Paint()
    ..color = color
    ..isAntiAlias = true;

  Paint pen(Color color, double width) => Paint()
    ..color = color
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke
    ..isAntiAlias = true;

  void circle(Canvas c, Offset p, double r, Color color) =>
      c.drawCircle(p, r, brush(color));

  void line(Canvas c, Offset a, Offset b, Color color, double w) =>
      c.drawLine(a, b, pen(color, w));

  void oval(Canvas c, Rect r, Color color) => c.drawOval(r, brush(color));

  /// Draws the signature `</>` developer code emblem centered at [center].
  void _drawCodeSymbol(
    Canvas c,
    Offset center,
    double scale,
    Color color,
    double strokeW,
  ) {
    final p = pen(color, strokeW);
    // Left chevron '<'
    final leftPath = Path()
      ..moveTo(center.dx - 5.5 * scale, center.dy - 5.2 * scale)
      ..lineTo(center.dx - 11.2 * scale, center.dy)
      ..lineTo(center.dx - 5.5 * scale, center.dy + 5.2 * scale);
    c.drawPath(leftPath, p);

    // Right chevron '>'
    final rightPath = Path()
      ..moveTo(center.dx + 5.5 * scale, center.dy - 5.2 * scale)
      ..lineTo(center.dx + 11.2 * scale, center.dy)
      ..lineTo(center.dx + 5.5 * scale, center.dy + 5.2 * scale);
    c.drawPath(rightPath, p);

    // Forward slash '/'
    c.drawLine(
      Offset(center.dx + 2.4 * scale, center.dy - 7.5 * scale),
      Offset(center.dx - 2.4 * scale, center.dy + 7.5 * scale),
      p,
    );
  }

  /// Draws a chunky 3D white sneaker with two bold black stripes, midsole & laces.
  void _drawSneaker(Canvas c, Offset anklePos, {required bool isRight}) {
    c.save();
    c.translate(anklePos.dx, anklePos.dy);
    final dir = isRight ? 1.0 : -1.0;

    // Padded sneaker tongue
    final tongueRect = Rect.fromCenter(
      center: Offset(dir * 2.0, -3.5),
      width: 15,
      height: 11,
    );
    c.drawRRect(
      RRect.fromRectAndRadius(tongueRect, const Radius.circular(5)),
      brush(const Color(0xFFF1F5F9)),
    );

    // Main leather sneaker body
    final shoePath = Path()
      ..moveTo(-14, -4)
      ..lineTo(13, -4)
      ..cubicTo(19 * dir, -2, 24 * dir, 4, 23 * dir, 11)
      ..lineTo(-15 * dir, 11)
      ..cubicTo(-18 * dir, 7, -17 * dir, 0, -14, -4)
      ..close();

    final shoeBounds = const Rect.fromLTWH(-24, -6, 48, 20);
    c.drawPath(
      shoePath,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFFFFF), Color(0xFFE2E8F0)],
        ).createShader(shoeBounds),
    );
    c.drawPath(shoePath, pen(const Color(0xFFCBD5E1), 1.1));

    // Two iconic diagonal black side stripes
    line(
      c,
      Offset(-3 * dir, -0.5),
      Offset(-7 * dir, 8.5),
      const Color(0xFF14161B),
      2.6,
    );
    line(
      c,
      Offset(2.5 * dir, -0.5),
      Offset(-1.5 * dir, 8.5),
      const Color(0xFF14161B),
      2.6,
    );

    // White criss-cross shoelaces
    for (final ly in [-2.5, 0.2, 2.8]) {
      line(
        c,
        Offset(1.0 * dir, ly),
        Offset(9.5 * dir, ly - 0.8),
        const Color(0xFFF8FAFC),
        2.0,
      );
      line(
        c,
        Offset(1.0 * dir, ly),
        Offset(9.5 * dir, ly - 0.8),
        const Color(0xFF94A3B8),
        0.7,
      );
    }

    // Thick sculpted rubber midsole + dark bottom tread
    final soleRect = Rect.fromCenter(
      center: Offset(3.5 * dir, 11.2),
      width: 39,
      height: 5.5,
    );
    c.drawRRect(
      RRect.fromRectAndRadius(soleRect, const Radius.circular(3)),
      brush(const Color(0xFFF8FAFC)),
    );
    c.drawRRect(
      RRect.fromRectAndRadius(soleRect, const Radius.circular(3)),
      pen(const Color(0xFFCBD5E1), 1.0),
    );
    line(
      c,
      Offset(-14 * dir, 13.8),
      Offset(21 * dir, 13.8),
      const Color(0xFF334155),
      1.6,
    );

    c.restore();
  }

  /// Draws the gold/bronze-bezel smartwatch with black OLED face on the right wrist.
  void _drawSmartwatch(Canvas c, Offset wristPos, double angleRad) {
    c.save();
    c.translate(wristPos.dx, wristPos.dy);
    c.rotate(angleRad);

    // Dark matte watch strap
    c.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-7.5, -4.5, 15, 9),
        const Radius.circular(3),
      ),
      brush(const Color(0xFF14161B)),
    );

    // Warm bronze/gold metallic case bezel
    final bezelRect = const Rect.fromLTWH(-5.8, -6.5, 11.6, 13.0);
    c.drawRRect(
      RRect.fromRectAndRadius(bezelRect, const Radius.circular(3.5)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF3B778), Color(0xFFB87333)],
        ).createShader(bezelRect),
    );

    // Deep glossy black OLED screen
    final screenRect = const Rect.fromLTWH(-4.4, -5.1, 8.8, 10.2);
    c.drawRRect(
      RRect.fromRectAndRadius(screenRect, const Radius.circular(2.4)),
      brush(const Color(0xFF090B0E)),
    );

    // Live Pomodoro Progress Ring on the Smartwatch OLED screen!
    final ringRect = Rect.fromCircle(center: Offset.zero, radius: 3.1);
    c.drawOval(ringRect, pen(const Color(0xFF1E293B), 1.1));
    c.drawArc(
      ringRect,
      -math.pi * 0.5,
      math.pi * 2 * timerProgress.clamp(0.05, 1.0),
      false,
      pen(breakActive ? mint : const Color(0xFF00F0FF), 1.2),
    );

    // Subtle glass screen reflection
    line(
      c,
      const Offset(-2.5, -3.2),
      const Offset(2.0, 2.2),
      Colors.white.withValues(alpha: 0.35),
      1.1,
    );

    c.restore();
  }

  /// Draws a 3D perspective glowing cyan Holographic Mechanical Keyboard & Code HUD
  /// when the user is actively typing on their PC!
  void _drawHoloKeyboard(Canvas c, double phase) {
    c.save();
    final hoverY = math.sin(phase * 2) * 1.8;
    c.translate(0, 29 + hoverY);

    // 3D perspective trapezoid keyboard deck
    final boardPath = Path()
      ..moveTo(-42, -6)
      ..lineTo(42, -6)
      ..lineTo(52, 8)
      ..lineTo(-52, 8)
      ..close();

    // Outer neon cyan holographic bloom
    c.drawPath(
      boardPath,
      Paint()
        ..color = const Color(0xFF00F0FF).withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // Semi-transparent dark cyber deck fill
    c.drawPath(
      boardPath,
      brush(const Color(0xFF0B192C).withValues(alpha: 0.86)),
    );
    c.drawPath(
      boardPath,
      pen(const Color(0xFF00F0FF).withValues(alpha: 0.9), 1.6),
    );

    // Illuminated mechanical keycap rows (flashing as keys are pressed!)
    for (int row = 0; row < 3; row++) {
      final ry = -3.2 + row * 3.8;
      final rowHalfW = 37.0 + row * 3.0;
      for (int col = -5; col <= 5; col++) {
        final kx = col * (rowHalfW / 5.8);
        final isActiveKey = ((col + row * 3 + (time * 36).floor()) % 5) == 0;
        final keyColor = isActiveKey
            ? const Color(0xFF34D399)
            : const Color(0xFF00F0FF).withValues(alpha: 0.55);
        line(
          c,
          Offset(kx - 2.1, ry),
          Offset(kx + 2.1, ry),
          keyColor,
          2.0,
        );
      }
    }

    // Floating holographic code projection screen above the keyboard
    final screenPath = Path()
      ..moveTo(-36, -9)
      ..lineTo(36, -9)
      ..lineTo(32, -23)
      ..lineTo(-32, -23)
      ..close();
    c.drawPath(
      screenPath,
      brush(const Color(0xFF00F0FF).withValues(alpha: 0.14)),
    );
    c.drawPath(
      screenPath,
      pen(const Color(0xFF00F0FF).withValues(alpha: 0.55), 1.0),
    );

    // Scrolling holographic code lines inside the projection
    final scroll = (time * 12) % 1.0;
    line(
      c,
      const Offset(-26, -19),
      Offset(-6 + scroll * 12, -19),
      mint.withValues(alpha: 0.85),
      1.6,
    );
    line(
      c,
      const Offset(-22, -15),
      Offset(18 - scroll * 10, -15),
      const Color(0xFF00F0FF).withValues(alpha: 0.85),
      1.6,
    );
    line(
      c,
      const Offset(-26, -11.5),
      const Offset(8, -11.5),
      honey.withValues(alpha: 0.85),
      1.6,
    );

    c.restore();
  }

  /// Draws a 3D metallic hex dumbbell with neon cyan accents gripped in the hand.
  void _drawDumbbell(Canvas c, Offset handPos, double angleRad) {
    c.save();
    c.translate(handPos.dx, handPos.dy);
    c.rotate(angleRad);

    // Chrome knurled handle bar
    line(
      c,
      const Offset(-16, 0),
      const Offset(16, 0),
      const Color(0xFFCBD5E1),
      4.5,
    );

    // Left & right 3D hex weight plates
    for (final side in [-1.0, 1.0]) {
      final plateRect = Rect.fromCenter(
        center: Offset(side * 14.5, 0),
        width: 9.0,
        height: 20.0,
      );
      c.drawRRect(
        RRect.fromRectAndRadius(plateRect, const Radius.circular(3)),
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF333844), Color(0xFF14161C)],
          ).createShader(plateRect),
      );
      c.drawRRect(
        RRect.fromRectAndRadius(plateRect, const Radius.circular(3)),
        pen(const Color(0xFF00F0FF).withValues(alpha: 0.75), 1.2),
      );
    }
    c.restore();
  }

  /// Draws a realistic 3D sports water bottle held in the hand, tilting toward the mouth
  /// with gravity-aligned water and a drinking stream at the peak of each sip!
  void _drawWaterBottle(Canvas c, Offset handPos, double sipWave, double phase) {
    c.save();
    c.translate(handPos.dx, handPos.dy);
    // Tilt the bottle toward the mouth (-0.30 rad at rest -> -0.82 rad when sipping!)
    final tilt = -0.30 - sipWave * 0.52;
    c.rotate(tilt);

    final bodyRect = const Rect.fromLTWH(-10.0, -21.0, 20.0, 34.0);
    final bodyRRect = RRect.fromRectAndRadius(bodyRect, const Radius.circular(6.0));

    // Soft 3D drop shadow behind the bottle
    c.drawRRect(
      bodyRRect.shift(const Offset(-2.0, 2.5)),
      brush(Colors.black.withValues(alpha: 0.35)),
    );

    // Translucent dark-cyan frosted bottle shell
    c.drawRRect(
      bodyRRect,
      brush(const Color(0xFF0B2239).withValues(alpha: 0.88)),
    );

    // Gravity-aligned sloshing water inside the tilted bottle!
    c.save();
    c.clipRRect(bodyRRect);
    c.rotate(-tilt * 0.72); // Counter-rotate water surface so it stays level with gravity!
    final waveY = -2.0 + math.sin(phase * 4.0) * 1.8;
    final waterPath = Path()
      ..moveTo(-24, waveY)
      ..quadraticBezierTo(-8, waveY - 2.8, 0, waveY)
      ..quadraticBezierTo(8, waveY + 2.8, 24, waveY)
      ..lineTo(24, 28)
      ..lineTo(-24, 28)
      ..close();
    c.drawPath(
      waterPath,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF38BDF8), Color(0xFF0284C7), Color(0xFF0369A1)],
        ).createShader(const Rect.fromLTWH(-20, -10, 40, 36)),
    );
    // Bright water surface meniscus highlight
    line(
      c,
      Offset(-16, waveY),
      Offset(16, waveY),
      const Color(0xFFE0F2FE).withValues(alpha: 0.85),
      1.5,
    );
    c.restore();

    // Contoured grip ring & measurement ticks
    c.drawRect(
      const Rect.fromLTWH(-10.0, -14.0, 20.0, 4.0),
      brush(const Color(0xFF1E293B).withValues(alpha: 0.7)),
    );
    c.drawRRect(bodyRRect, pen(const Color(0xFF38BDF8).withValues(alpha: 0.9), 1.4));
    for (final ty in [-7.0, -1.5, 4.0, 9.0]) {
      line(c, Offset(4.2, ty), Offset(7.5, ty), Colors.white60, 1.0);
    }

    // 3D cylindrical specular highlight stripe
    line(
      c,
      const Offset(-6.2, -16),
      const Offset(-6.2, 9),
      Colors.white.withValues(alpha: 0.48),
      2.2,
    );

    // Sculpted dark matte sports cap collar & angled drinking nozzle
    c.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-7.8, -26.0, 15.6, 5.8),
        const Radius.circular(2.5),
      ),
      brush(const Color(0xFF1E293B)),
    );
    c.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-3.0, -31.0, 6.0, 5.5),
        const Radius.circular(2.2),
      ),
      brush(const Color(0xFF00F0FF)),
    );

    // Animated water stream & droplets flowing from the spout into the mouth at peak sip!
    if (sipWave > 0.52) {
      final streamAlpha = ((sipWave - 0.52) / 0.48).clamp(0.0, 1.0);
      final streamPath = Path()
        ..moveTo(0, -31.5)
        ..quadraticBezierTo(-5, -36, -10, -34);
      c.drawPath(
        streamPath,
        pen(const Color(0xFF7DD3FC).withValues(alpha: streamAlpha * 0.9), 2.6),
      );
      circle(
        c,
        Offset(-6 - (time * 18 % 5), -34 + math.sin(phase * 6) * 1.5),
        1.8,
        const Color(0xFFE0F2FE).withValues(alpha: streamAlpha),
      );
    }

    c.restore();
  }

  /// Draws a realistic 3D developer espresso mug with saucer lip, golden crema & rising steam!
  void _drawEspressoCup(Canvas c, Offset handPos, double sipWave, double phase) {
    c.save();
    c.translate(handPos.dx, handPos.dy);
    // Tilt the espresso cup toward the mouth as he sips!
    final tilt = -0.18 - sipWave * 0.42;
    c.rotate(tilt);

    // Soft drop shadow
    c.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-12.5, -12.0, 23.0, 22.0),
        const Radius.circular(6.0),
      ),
      brush(Colors.black.withValues(alpha: 0.35)),
    );

    // Ergonomic D-shaped ceramic handle on the outer right side (gripped by fingers)
    c.drawArc(
      const Rect.fromLTWH(5.5, -10.0, 11.0, 14.0),
      -math.pi * 0.48,
      math.pi * 0.96,
      false,
      pen(const Color(0xFF334155), 3.0),
    );

    // Ceramic mug body
    final cupRect = const Rect.fromLTWH(-11.0, -14.0, 22.0, 21.0);
    final cupRRect = RRect.fromRectAndCorners(
      cupRect,
      topLeft: const Radius.circular(3.0),
      topRight: const Radius.circular(3.0),
      bottomLeft: const Radius.circular(7.5),
      bottomRight: const Radius.circular(7.5),
    );
    c.drawRRect(
      cupRRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Color(0xFF3E4C5E), Color(0xFF1E293B), Color(0xFF0F172A)],
        ).createShader(cupRect),
    );
    c.drawRRect(cupRRect, pen(const Color(0xFFFBBF24).withValues(alpha: 0.75), 1.2));

    // Tiny `</>` logo on the mug!
    _drawCodeSymbol(c, const Offset(-0.5, -2.5), 0.44, honey, 1.4);

    // Rich golden-brown espresso crema at top rim
    oval(c, const Rect.fromLTWH(-10.0, -16.2, 20.0, 5.2), const Color(0xFFD97706));
    oval(c, const Rect.fromLTWH(-7.5, -15.3, 15.0, 3.4), const Color(0xFF78350F));

    // Animated rising warm steam wisps (stay vertical in world space!)
    c.rotate(-tilt);
    for (int i = -1; i <= 1; i++) {
      final sx = i * 4.5 - 3.0;
      final drift = math.sin(phase * 2.5 + i) * 2.5;
      final steamPath = Path()
        ..moveTo(sx, -17)
        ..quadraticBezierTo(sx + drift, -24, sx - drift * 0.6, -31);
      c.drawPath(
        steamPath,
        pen(Colors.white.withValues(alpha: 0.52), 1.6),
      );
    }

    c.restore();
  }

  @override
  void paint(Canvas c, Size s) {
    final phase = time * math.pi * 2;
    final isWalking = mood == Mood.walking;
    final isTyping = mood == Mood.typing;
    final isAsleep = mood == Mood.sleeping;
    final isAlert = mood == Mood.alert;
    final isStretching = mood == Mood.stretching;
    final isExercising = mood == Mood.exercising;
    final isCelebrating = mood == Mood.celebrating;
    final isDragged = mood == Mood.dragged;
    final isPetting = mood == Mood.petting;
    final isLanding = mood == Mood.landing;

    // Sport exercise phase variables (0.0 .. 1.0)
    final squatDepth = (isExercising && exerciseType == ExerciseType.squats)
        ? (math.sin(phase * 2) * 0.5 + 0.5)
        : 0.0;
    final jackPhase =
        (isExercising && exerciseType == ExerciseType.jumpingJacks)
            ? (math.sin(phase * 2).abs())
            : 0.0;
    final curlPhase = (isExercising && exerciseType == ExerciseType.dumbbells)
        ? math.sin(phase * 2)
        : 0.0;
    final stretchBend =
        (isStretching || (isExercising && exerciseType == ExerciseType.stretch))
            ? math.sin(phase) * 0.14
            : 0.0;

    // Guided 30s Box-Breathing Cycle (4.0s Inhale -> 4.0s Hold -> 4.0s Exhale)
    final breathCyclePos = breathingMode ? (breathingSeconds % 12.0) : 0.0;
    final guidedBreathFactor = !breathingMode
        ? 0.0
        : breathCyclePos < 4.0
            ? (0.5 - 0.5 * math.cos((breathCyclePos / 4.0) * math.pi))
            : breathCyclePos < 8.0
                ? 1.0
                : (0.5 +
                    0.5 * math.cos(((breathCyclePos - 8.0) / 4.0) * math.pi));

    // Organic breathing & bouncing
    final idleBreath = breathingMode
        ? -guidedBreathFactor * 5.5
        : math.sin(phase * 0.8) * 2.0;
    final bounce = isCelebrating
        ? -14 - math.sin(phase * 2).abs() * 15
        : (isExercising && exerciseType == ExerciseType.squats)
            ? squatDepth * 22.0 // Body lowers deep into squat!
            : (isExercising && exerciseType == ExerciseType.jumpingJacks)
                ? -jackPhase * 22.0 // Jumps high in the air!
                : (isExercising && exerciseType == ExerciseType.dumbbells)
                    ? math.sin(phase * 4) * 3.0
                    : isWalking
                        ? math.sin(phase * 2) * 5.5
                        : isDragged
                            ? -16 + math.sin(phase * 1.5) * 4
                            : isStretching || isExercising
                                ? -5 + math.sin(phase) * 4.5
                                : isLanding
                                    ? 4.0
                                    : idleBreath;

    final scale = math.min(s.width / 235, s.height / 285);

    // 1. DYNAMIC GROUND SHADOW
    final shadowY = s.height * 0.94;
    final heightRatio = ((-bounce + 18) / 36).clamp(0.0, 1.5);
    final shadowWidth =
        math.max(24.0, 118.0 * scale * (1.0 - heightRatio * 0.32) * squash.dx);
    final shadowHeight =
        math.max(5.0, 14.0 * scale * (1.0 - heightRatio * 0.38) * squash.dx);
    final shadowAlpha = (0.30 * (1.0 - heightRatio * 0.42)).clamp(0.06, 0.36);

    oval(
      c,
      Rect.fromCenter(
        center: Offset(s.width * 0.5, shadowY),
        width: shadowWidth,
        height: shadowHeight,
      ),
      Colors.black.withValues(alpha: shadowAlpha),
    );

    // 2. DRAW GROUND SHOCKWAVE PARTICLES
    for (final p in particles) {
      if (p.type == 2) {
        final radius = (1.0 - p.life) * 58;
        c.drawOval(
          Rect.fromCenter(
            center: Offset(s.width * 0.5, shadowY),
            width: radius * 2,
            height: radius * 0.45,
          ),
          pen(p.color.withValues(alpha: p.life * 0.8), 2.2),
        );
      }
    }

    c.save();
    // Character root anchor: centered inside the Expanded canvas below the popup bubble
    // so the head/curls (-160) never touch the popup at y=0 and sneakers (+104) rest at shadowY!
    c.translate(s.width * 0.5, s.height * 0.58 + bounce * scale * 0.75);
    c.scale(scale);

    // Drag inertia tilt & Squash/Stretch physics
    c.rotate(tiltAngle + stretchBend);
    c.scale(squash.dx, squash.dy);

    // Facing direction
    c.scale(direction >= 0 ? 1.0 : -1.0, 1.0);

    // 3. SUBTLE AMBIENT AURA GLOW (Soft indigo circadian glow after 9 PM!)
    final glowColor = isAlert
        ? peach
        : isExercising
            ? mint
            : isPetting || isCelebrating
                ? honey
                : isAsleep || lateNight
                    ? const Color(0xFF818CF8)
                    : const Color(0xFF00E5FF);

    c.drawCircle(
      const Offset(0, -15),
      118,
      Paint()
        ..shader = RadialGradient(
          colors: [
            glowColor.withValues(
                alpha: isAlert || isCelebrating || isExercising ? 0.22 : 0.08),
            Colors.transparent,
          ],
        ).createShader(const Rect.fromLTWH(-120, -135, 240, 240)),
    );

    // 3B. GUIDED 30-SECOND BOX-BREATHING & POSTURE RESET GLOWING AURA RING
    if (breathingMode) {
      final isInhale = breathCyclePos < 4.0;
      final isHold = breathCyclePos >= 4.0 && breathCyclePos < 8.0;
      final phaseProgress = (breathCyclePos % 4.0) / 4.0;
      final ringColor = isInhale
          ? const Color(0xFF00F0FF)
          : isHold
              ? const Color(0xFF38EF7D)
              : const Color(0xFFA78BFA);
      final ringCenter = const Offset(0, -18);
      final minR = 64.0;
      final maxR = 114.0;
      final curR = minR + guidedBreathFactor * (maxR - minR);

      // Outer target guide ring (max inhale boundary)
      c.drawCircle(
        ringCenter,
        maxR,
        pen(ringColor.withValues(alpha: 0.20), 1.4),
      );
      // Inner baseline ring (exhale rest boundary)
      c.drawCircle(
        ringCenter,
        minR,
        pen(ringColor.withValues(alpha: 0.16), 1.2),
      );

      // Expanding / contracting radial aura fill
      c.drawCircle(
        ringCenter,
        curR + 10,
        Paint()
          ..shader = RadialGradient(
            colors: [
              ringColor.withValues(alpha: 0.04 + guidedBreathFactor * 0.14),
              ringColor.withValues(alpha: 0.22),
              Colors.transparent,
            ],
            stops: const [0.0, 0.78, 1.0],
          ).createShader(Rect.fromCircle(center: ringCenter, radius: curR + 10)),
      );

      // Luminous main breathing aura ring
      c.drawCircle(
        ringCenter,
        curR,
        pen(ringColor.withValues(alpha: 0.78), 3.6),
      );

      // 4-second phase progress arc sweeping 360° around the breathing ring
      c.drawArc(
        Rect.fromCircle(center: ringCenter, radius: curR + 5.5),
        -math.pi / 2,
        phaseProgress * math.pi * 2,
        false,
        pen(white.withValues(alpha: 0.88), 2.4),
      );

      // Floating upright phase badge at the base of the ring
      c.save();
      c.scale(direction >= 0 ? 1.0 : -1.0, 1.0);
      final secsLeft = 4 - (breathCyclePos % 4.0).floor();
      final phaseText = isInhale
          ? '🌬️ INHALE · ${secsLeft}s'
          : isHold
              ? '✨ HOLD & SIT TALL · ${secsLeft}s'
              : '🍃 EXHALE SLOWLY · ${secsLeft}s';
      final tp = TextPainter(
        text: TextSpan(
          text: phaseText,
          style: TextStyle(
            color: ringColor,
            fontSize: 9.5,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.4,
            shadows: const [
              Shadow(color: Colors.black, blurRadius: 6),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final badgeRect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: const Offset(0, 86),
          width: tp.width + 16,
          height: tp.height + 6,
        ),
        const Radius.circular(10),
      );
      c.drawRRect(
        badgeRect,
        brush(const Color(0xE00F172A)),
      );
      c.drawRRect(
        badgeRect,
        pen(ringColor.withValues(alpha: 0.75), 1.2),
      );
      tp.paint(c, Offset(-tp.width * 0.5, 86 - tp.height * 0.5));
      c.restore();
    }

    // 4. OPTIONAL BEE WINGS (Only if enabled in Dashboard)
    if (beeTheme) {
      final flapFreq = (isDragged || isCelebrating) ? 36.0 : 9.0;
      final wingFlap = math.sin(time * flapFreq) * 0.35 + 0.65;

      c.save();
      c.translate(0, 8);
      for (final side in [-1.0, 1.0]) {
        c.save();
        c.scale(side * wingFlap, 1.0);

        final upperWing = Path()
          ..moveTo(18, 0)
          ..cubicTo(55, -45, 78, -30, 68, -5)
          ..cubicTo(58, 15, 30, 12, 18, 5)
          ..close();
        c.drawPath(upperWing, brush(white.withValues(alpha: 0.36)));
        c.drawPath(upperWing, pen(cyan.withValues(alpha: 0.7), 1.5));

        final lowerWing = Path()
          ..moveTo(16, 8)
          ..cubicTo(45, 8, 56, 32, 42, 38)
          ..cubicTo(30, 42, 22, 22, 16, 14)
          ..close();
        c.drawPath(lowerWing, brush(white.withValues(alpha: 0.26)));
        c.drawPath(lowerWing, pen(honey.withValues(alpha: 0.6), 1.2));

        c.restore();
      }
      c.restore();
    }

    // 2D inertia lag in character-local space
    final dirSign = direction >= 0 ? 1.0 : -1.0;
    final lagX = (-dragVelocity.dx * dirSign * 0.75).clamp(-26.0, 26.0);
    final lagY = (-dragVelocity.dy * 0.65).clamp(-18.0, 20.0);

    // 5. CHARCOAL JOGGERS & CHUNKY WHITE SNEAKERS
    final swing = isWalking
        ? math.sin(phase) * 14.0
        : isDragged
            ? math.sin(time * 16) * 8.0
            : 0.0;

    // During squats, feet stay planted on the ground while hips drop (+squatDepth * 22)
    // and knees flare wide! During jumping jacks, legs spread wide apart!
    final spreadX = (isExercising && exerciseType == ExerciseType.jumpingJacks)
        ? jackPhase * 17.0
        : (isExercising && exerciseType == ExerciseType.squats)
            ? 5.0 + squatDepth * 6.0
            : 0.0;
    final squatAnkleLift =
        (isExercising && exerciseType == ExerciseType.squats)
            ? -squatDepth * 22.0
            : 0.0;
    final kneeFlare = (isExercising && exerciseType == ExerciseType.squats)
        ? squatDepth * 16.0
        : 0.0;

    final leftAnkle = Offset(
      -21 - spreadX + swing + (isDragged ? lagX * 0.8 : 0.0),
      90 + squatAnkleLift + (isDragged ? lagY * 0.7 : 0.0),
    );
    final rightAnkle = Offset(
      21 + spreadX - swing + (isDragged ? lagX * 0.8 : 0.0),
      90 + squatAnkleLift + (isDragged ? lagY * 0.7 : 0.0),
    );

    // Upper pelvis bridge of joggers (prevents any gap between legs under the hoodie hem)
    c.drawRect(
      const Rect.fromLTWH(-22, 42, 44, 15),
      brush(const Color(0xFF1D1F27)),
    );

    // Sculpted baggy charcoal jogger legs with knee/ankle fabric folds
    for (final isRight in [false, true]) {
      final hipX = isRight ? 18.0 : -18.0;
      final ankle = isRight ? rightAnkle : leftAnkle;
      final outDir = isRight ? 1.0 : -1.0;

      final legPath = Path()
        ..moveTo(hipX - 13 * outDir, 44)
        ..lineTo(hipX + 14 * outDir, 44)
        ..cubicTo(
          hipX + (19 + kneeFlare) * outDir,
          58 + squatAnkleLift * 0.4,
          ankle.dx + (16 + kneeFlare * 0.6) * outDir,
          68 + squatAnkleLift * 0.6,
          ankle.dx + 12 * outDir,
          ankle.dy - 7,
        )
        ..lineTo(ankle.dx - 11 * outDir, ankle.dy - 7)
        ..cubicTo(
          ankle.dx - 13 * outDir,
          68 + squatAnkleLift * 0.6,
          hipX - (11 - kneeFlare * 0.4) * outDir,
          58 + squatAnkleLift * 0.4,
          hipX - 13 * outDir,
          44,
        )
        ..close();

      final legBounds = Rect.fromLTRB(
        math.min(hipX, ankle.dx) - 22,
        44,
        math.max(hipX, ankle.dx) + 22,
        ankle.dy,
      );
      c.drawPath(
        legPath,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [Color(0xFF323640), Color(0xFF1E2028), Color(0xFF15171C)],
          ).createShader(legBounds),
      );

      // Subtle fabric crease folds near knee & lower shin
      line(
        c,
        Offset(ankle.dx - 6 * outDir, ankle.dy - 21),
        Offset(ankle.dx + 8 * outDir, ankle.dy - 18),
        const Color(0xFF121318),
        1.8,
      );
      line(
        c,
        Offset(ankle.dx - 5 * outDir, ankle.dy - 14),
        Offset(ankle.dx + 7 * outDir, ankle.dy - 12),
        const Color(0xFF121318),
        1.6,
      );

      // Ribbed jogger ankle cuff
      final cuffRect = Rect.fromCenter(
        center: Offset(ankle.dx, ankle.dy - 5),
        width: 21,
        height: 8,
      );
      c.drawRRect(
        RRect.fromRectAndRadius(cuffRect, const Radius.circular(3.5)),
        brush(const Color(0xFF181A20)),
      );

      // Warm tan ankle peek
      oval(
        c,
        Rect.fromCenter(
          center: Offset(ankle.dx, ankle.dy),
          width: 14,
          height: 5,
        ),
        const Color(0xFFD68E67),
      );
    }

    // Center crotch seam shadow on joggers
    final crotchSeam = Path()
      ..moveTo(-4, 46)
      ..quadraticBezierTo(0, 60, 4, 46);
    c.drawPath(crotchSeam, pen(const Color(0xFF121318), 2.2));

    // Chunky white sneakers with two black stripes
    _drawSneaker(c, leftAnkle, isRight: false);
    _drawSneaker(c, rightAnkle, isRight: true);

    // 6. MATTE CHARCOAL-BLACK HOODIE, FOREGROUND SLEEVES & KANGAROO POCKET
    final isDrinking = drinkProp != DrinkProp.none &&
        !isDragged &&
        !isExercising &&
        !isTyping;
    final isHandsInPocket = !isCelebrating &&
        !isDragged &&
        !isPetting &&
        !isStretching &&
        !isExercising &&
        !isTyping &&
        !isAlert;

    // 6A. Main hoodie torso (drawn first so the forearms & cuffs sit in front of the torso!)
    final torsoPath = Path()
      ..moveTo(-36, -12)
      ..lineTo(36, -12)
      ..cubicTo(46, 2, 46, 28, 42, 44)
      ..lineTo(-42, 44)
      ..cubicTo(-46, 28, -46, 2, -36, -12)
      ..close();

    const torsoBounds = Rect.fromLTWH(-46, -14, 92, 62);
    c.drawPath(
      torsoPath,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.2, -0.3),
          radius: 1.0,
          colors: [Color(0xFF383C47), Color(0xFF22252D), Color(0xFF17191F)],
        ).createShader(torsoBounds),
    );
    c.drawPath(torsoPath, pen(const Color(0xFF121419), 1.4));

    // Ribbed bottom waistband hem
    final hemRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(-41, 41, 82, 8.5),
      const Radius.circular(4),
    );
    c.drawRRect(hemRect, brush(const Color(0xFF191B22)));
    c.drawRRect(hemRect, pen(const Color(0xFF101217), 1.1));
    // Subtle vertical ribbing lines on the waistband hem
    for (int hx = -34; hx <= 34; hx += 6) {
      line(
        c,
        Offset(hx.toDouble(), 42.0),
        Offset(hx.toDouble(), 48.5),
        const Color(0xFF12141A),
        1.0,
      );
    }

    // Crisp white `</>` developer emblem on upper chest
    _drawCodeSymbol(
      c,
      const Offset(0, 4.5),
      0.95,
      const Color(0xFFF8FAFC),
      2.5,
    );

    // 6B. Puffy charcoal sleeves, angled ribbed cuffs, warm tan wrists & smartwatch
    // Drawn IN FRONT OF the torso and BEHIND the front kangaroo pocket flap so the hands
    // visibly come forward from the elbows and slide down into the pocket openings!
    if (isHandsInPocket) {
      final armBob = isWalking ? swing * 0.22 : idleBreath * 0.35;

      for (final side in [-1.0, 1.0]) {
        // When drinking water or espresso, the right arm lifts out of the pocket and is drawn IN FRONT of the head/beard!
        if (isDrinking && side > 0) continue;

        // Soft drop shadow cast by the forearm onto the sides of the hoodie torso
        final armShadowPath = Path()
          ..moveTo(side * 30, -2)
          ..cubicTo(
            side * 56,
            6,
            side * 58,
            24 + armBob,
            side * 24,
            34 + armBob,
          )
          ..lineTo(side * 22, 18 + armBob)
          ..close();
        c.drawPath(
          armShadowPath,
          brush(Colors.black.withValues(alpha: 0.35)),
        );

        // Sculpted puffy sleeve curving out at the elbow and angling INWARD across the front
        final sleevePath = Path()
          // Top shoulder seam
          ..moveTo(side * 33, -10)
          // Outer upper arm & puffy elbow
          ..cubicTo(
            side * 54,
            -5,
            side * 64,
            8 + armBob,
            side * 57,
            20 + armBob,
          )
          // Lower/outer forearm leading to the bottom of the wrist cuff
          ..cubicTo(
            side * 53,
            27 + armBob,
            side * 46,
            30 + armBob,
            side * 38,
            28.5 + armBob,
          )
          // Across the wrist cuff opening up to the inner cuff edge
          ..lineTo(side * 29.5, 16.5 + armBob)
          // Inner forearm & elbow bend crease in front of the torso
          ..cubicTo(
            side * 36,
            12 + armBob * 0.6,
            side * 39,
            6 + armBob * 0.4,
            side * 32,
            -2,
          )
          ..close();

        final sleeveBounds = Rect.fromLTRB(
          side < 0 ? -66 : 26,
          -12,
          side < 0 ? -26 : 66,
          34,
        );
        c.drawPath(
          sleevePath,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment(side * -0.4, -0.8),
              end: Alignment(side * 0.6, 0.9),
              colors: const [
                Color(0xFF3D424F),
                Color(0xFF262932),
                Color(0xFF181A20),
              ],
            ).createShader(sleeveBounds),
        );
        c.drawPath(sleevePath, pen(const Color(0xFF111318), 1.4));

        // 3D gathered fabric folds on the puffy sleeve
        final fold1 = Path()
          ..moveTo(side * 36, 4 + armBob * 0.4)
          ..quadraticBezierTo(
            side * 48,
            6 + armBob * 0.5,
            side * 56,
            12 + armBob * 0.5,
          );
        final fold2 = Path()
          ..moveTo(side * 33, 12 + armBob * 0.7)
          ..quadraticBezierTo(
            side * 45,
            15 + armBob * 0.8,
            side * 52,
            21 + armBob * 0.8,
          );
        c.drawPath(fold1, pen(const Color(0xFF15171D), 2.2));
        c.drawPath(fold2, pen(const Color(0xFF15171D), 2.2));
        // Subtle top highlight on the forearm fold
        c.drawPath(
          fold1.shift(const Offset(0, -1.5)),
          pen(const Color(0xFF494E5C).withValues(alpha: 0.45), 1.2),
        );

        // Angled ribbed sleeve cuff wrapping around the wrist
        c.save();
        c.translate(side * 33.8, 22.5 + armBob);
        c.rotate(side * -0.62);
        final cuffRRect = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: 11.0, height: 17.5),
          const Radius.circular(4.2),
        );
        c.drawRRect(
          cuffRRect,
          Paint()
            ..shader = const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF2B2E38), Color(0xFF171920)],
            ).createShader(const Rect.fromLTWH(-6, -9, 12, 18)),
        );
        c.drawRRect(cuffRRect, pen(const Color(0xFF101217), 1.3));
        // Dark interior opening of the cuff where the bare wrist emerges
        oval(
          c,
          Rect.fromCenter(
            center: Offset(side * -2.2, 0),
            width: 5.5,
            height: 14.0,
          ),
          const Color(0xFF0E1014),
        );
        c.restore();

        // Dark pocket interior cavity right behind the wrist
        oval(
          c,
          Rect.fromCenter(
            center: Offset(side * 25.0, 28.5 + armBob),
            width: 12,
            height: 16,
          ),
          const Color(0xFF0F1015),
        );

        // Warm golden-tan wrist & hand emerging from the cuff and sliding into the pocket!
        c.save();
        c.translate(side * 27.5, 27.2 + armBob);
        c.rotate(side * -0.62);
        final handRect = Rect.fromCenter(
          center: Offset.zero,
          width: 18.5,
          height: 12.8,
        );
        c.drawRRect(
          RRect.fromRectAndRadius(handRect, const Radius.circular(6.4)),
          Paint()
            ..shader = const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xFFF3C1A2), // Warm top wrist highlight
                Color(0xFFDE9872), // Golden-tan midtone
                Color(0xFFB86F4C), // Underside wrist shadow
              ],
            ).createShader(handRect),
        );
        c.restore();

        // On the right wrist (side > 0), draw the gold/bronze smartwatch wrapped around the wrist!
        if (side > 0) {
          _drawSmartwatch(c, Offset(29.2, 25.8 + armBob), -0.62);
        }
      }
    }

    // 6C. Front Trapezoid Kangaroo Pocket Flap (drawn ON TOP of the lower hands so the hands
    // are unmistakably tucked INSIDE the pocket!)
    final pocketPath = Path()
      ..moveTo(-19.5, 17.5)
      ..lineTo(19.5, 17.5)
      ..lineTo(29.5, 34.5)
      ..lineTo(26.5, 42.0)
      ..lineTo(-26.5, 42.0)
      ..lineTo(-29.5, 34.5)
      ..close();

    // Subtle shadow cast by the hands onto the pocket opening edge
    c.drawPath(
      pocketPath.shift(const Offset(0, -1.2)),
      brush(Colors.black.withValues(alpha: 0.42)),
    );

    c.drawPath(
      pocketPath,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF2D313B), Color(0xFF1D1F26)],
        ).createShader(const Rect.fromLTWH(-30, 17.5, 60, 25)),
    );
    c.drawPath(pocketPath, pen(const Color(0xFF121419), 1.5));

    // Thick ribbed side pocket lips (where the hands slip under the pocket fabric)
    for (final side in [-1.0, 1.0]) {
      final lipTop = Offset(side * 19.5, 18.0);
      final lipBot = Offset(side * 29.2, 34.2);
      // Dark inner crease just outside the lip over the hand
      line(
        c,
        Offset(lipTop.dx + side * 1.4, lipTop.dy),
        Offset(lipBot.dx + side * 1.4, lipBot.dy),
        Colors.black.withValues(alpha: 0.55),
        2.2,
      );
      // Raised stitched pocket opening hem
      line(c, lipTop, lipBot, const Color(0xFF383C48), 2.8);
      line(
        c,
        Offset(lipTop.dx - side * 1.8, lipTop.dy + 0.5),
        Offset(lipBot.dx - side * 1.8, lipBot.dy + 0.5),
        const Color(0xFF171920),
        1.1,
      );
    }

    // Top horizontal double-stitched pocket seam
    line(
      c,
      const Offset(-18.5, 20.0),
      const Offset(18.5, 20.0),
      const Color(0xFF3E424F),
      1.1,
    );

    // Plush folded charcoal hood collar around neck + warm neck skin
    final hoodCollarOuter = RRect.fromRectAndRadius(
      const Rect.fromLTWH(-38, -24, 76, 20),
      const Radius.circular(11),
    );
    c.drawRRect(
      hoodCollarOuter,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF363A45), Color(0xFF1D2027)],
        ).createShader(const Rect.fromLTWH(-38, -24, 76, 20)),
    );
    c.drawRRect(hoodCollarOuter, pen(const Color(0xFF13151A), 1.4));

    // Inner hood shadow cavity
    oval(c, const Rect.fromLTWH(-27, -22, 54, 13), const Color(0xFF121318));

    // Warm golden-tan neck with chin shadow
    final neckRect = const Rect.fromLTWH(-14, -27, 28, 17);
    c.drawRRect(
      RRect.fromRectAndRadius(neckRect, const Radius.circular(7)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFBA7250), Color(0xFFD99570)],
        ).createShader(neckRect),
    );

    // Overlapping front hood lapels
    final leftLapel = Path()
      ..moveTo(-36, -15)
      ..quadraticBezierTo(-18, -5, 0, -9)
      ..quadraticBezierTo(-20, -14, -36, -20)
      ..close();
    final rightLapel = Path()
      ..moveTo(36, -15)
      ..quadraticBezierTo(18, -5, 0, -9)
      ..quadraticBezierTo(20, -14, 36, -20)
      ..close();
    c.drawPath(leftLapel, brush(const Color(0xFF282B34)));
    c.drawPath(rightLapel, brush(const Color(0xFF282B34)));
    c.drawPath(leftLapel, pen(const Color(0xFF15171C), 1.2));
    c.drawPath(rightLapel, pen(const Color(0xFF15171C), 1.2));

    // Two white hoodie drawstrings hanging from dark metal eyelets
    final stringSwayX = lagX * 0.65 + math.sin(phase * 1.2) * 1.8;
    final stringSwayY = (lagY * 0.4).clamp(-7.0, 7.0);
    for (final sx in [-8.5, 8.5]) {
      circle(c, Offset(sx, -10.5), 2.3, const Color(0xFF101216));
      final start = Offset(sx, -10.5);
      final end = Offset(sx + stringSwayX * 0.7, 2.5 + stringSwayY);
      line(c, start, end, const Color(0xFFF1F5F9), 2.5);
      // Aglet tip
      line(
        c,
        Offset(end.dx, end.dy - 2.2),
        Offset(end.dx, end.dy + 1.2),
        const Color(0xFFCBD5E1),
        2.0,
      );
    }

    // Active arms when celebrating, exercising, typing, dragged, petting, stretching, or alert
    if (!isHandsInPocket) {
      Offset leftHand, rightHand;
      if (isTyping) {
        // Rapid alternating coding hands over the holographic keyboard!
        final keyTap = math.sin(time * 52) * 5.2;
        leftHand = Offset(-24 + math.cos(time * 24) * 3.5, 22 + keyTap);
        rightHand = Offset(24 - math.sin(time * 24) * 3.5, 22 - keyTap);
      } else if (isExercising) {
        switch (exerciseType) {
          case ExerciseType.squats:
            // Arms held out forward/upward for squat balance
            leftHand = Offset(-58, 8 - squatDepth * 34);
            rightHand = Offset(58, 8 - squatDepth * 34);
            break;
          case ExerciseType.jumpingJacks:
            // Arms sweep wide from hips to high overhead clap!
            leftHand = Offset(-62 + jackPhase * 34, 18 - jackPhase * 134);
            rightHand = Offset(62 - jackPhase * 34, 18 - jackPhase * 134);
            break;
          case ExerciseType.dumbbells:
            // Alternating 3D dumbbell curls & shoulder presses!
            leftHand = Offset(-56, -24 - curlPhase * 36);
            rightHand = Offset(56, -24 + curlPhase * 36);
            break;
          case ExerciseType.stretch:
            // High overhead spine-decompression reach
            leftHand = Offset(-54, -92 + math.sin(phase * 2) * 8);
            rightHand = Offset(54, -92 - math.sin(phase * 2) * 8);
            break;
        }
      } else if (isCelebrating) {
        leftHand = Offset(-68, -78 + math.sin(phase * 2) * 10);
        rightHand = Offset(68, -78 - math.sin(phase * 2) * 10);
      } else if (isDragged) {
        leftHand = Offset(
          -64 + lagX * 0.55,
          -52 + math.sin(time * 14) * 7 + lagY * 0.55,
        );
        rightHand = Offset(
          64 + lagX * 0.55,
          -52 - math.sin(time * 14) * 7 + lagY * 0.55,
        );
      } else if (isPetting) {
        leftHand = const Offset(-50, -34);
        rightHand = const Offset(50, -34);
      } else if (isStretching) {
        leftHand = Offset(-78, -36 + math.sin(phase) * 10);
        rightHand = Offset(78, -36 - math.sin(phase) * 10);
      } else {
        // isAlert
        leftHand = const Offset(-58, 22);
        rightHand = const Offset(68, -58);
      }

      // Charcoal sleeves
      line(c, const Offset(-34, -4), leftHand, const Color(0xFF262932), 18);
      line(c, const Offset(34, -4), rightHand, const Color(0xFF262932), 18);

      // Smartwatch on right wrist
      final rightWrist = Offset.lerp(const Offset(34, -4), rightHand, 0.82)!;
      _drawSmartwatch(c, rightWrist, 0.3);

      // Warm tan hands
      circle(c, leftHand, 9.5, const Color(0xFFE09B74));
      circle(c, rightHand, 9.5, const Color(0xFFE09B74));

      // Draw 3D Hex Dumbbells in both hands when doing Dumbbell Curls/Presses!
      if (isExercising && exerciseType == ExerciseType.dumbbells) {
        _drawDumbbell(c, leftHand, -0.15);
        _drawDumbbell(c, rightHand, 0.15);
      }

      // Draw glowing 3D Holographic Keyboard when typing!
      if (isTyping) {
        _drawHoloKeyboard(c, phase);
      }
    }

    // 7. SLIGHT HEAD TILT & 3D SCULPTED HEAD (Matches the charismatic pose + Lo-Fi head bobbing!)
    c.save();
    final musicGrooveTilt = musicMode && !isAsleep
        ? math.sin(phase * 3.0) * 0.068
        : 0.0;
    final musicGrooveNod = musicMode && !isAsleep
        ? math.sin(phase * 6.0).abs() * 3.8
        : 0.0;
    final headTilt = isDragged
        ? (lagX * 0.008).clamp(-0.15, 0.15)
        : -0.055 + math.sin(phase * 0.5) * 0.018 + musicGrooveTilt;
    c.translate(0, -24 + musicGrooveNod);
    c.rotate(headTilt);
    c.translate(0, 24);

    // 7A. BACK OF HEADPHONE BAND
    final headbandRect = const Rect.fromLTWH(-64, -142, 128, 114);
    c.drawArc(
      headbandRect,
      math.pi * 1.03,
      math.pi * 0.94,
      false,
      pen(const Color(0xFF14161B), 12),
    );
    c.drawArc(
      headbandRect,
      math.pi * 1.05,
      math.pi * 0.90,
      false,
      pen(const Color(0xFF2D313B), 5),
    );

    // 7B. SCULPTED 3D HEAD SHAPE (Warm golden-tan skin tone)
    final headPath = Path()
      ..moveTo(0, -133)
      ..cubicTo(38, -133, 56, -112, 54, -78)
      ..cubicTo(53, -46, 40, -19, 0, -18)
      ..cubicTo(-40, -19, -53, -46, -54, -78)
      ..cubicTo(-56, -112, -38, -133, 0, -133)
      ..close();

    const headBounds = Rect.fromLTWH(-56, -135, 112, 120);
    c.drawPath(
      headPath,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.18, -0.32),
          radius: 0.95,
          colors: [
            Color(0xFFF5C5A8), // Forehead/cheekbone 3D highlight
            Color(0xFFE29F7B), // Rich warm tan midtone
            Color(0xFFC57E5A), // Sculpted jaw/temple shading
          ],
          stops: [0.0, 0.62, 1.0],
        ).createShader(headBounds),
    );

    // Soft forehead & cheek 3D studio light reflections
    oval(
      c,
      const Rect.fromLTWH(-32, -118, 56, 24),
      Colors.white.withValues(alpha: 0.14),
    );
    oval(
      c,
      const Rect.fromLTWH(-42, -68, 22, 14),
      const Color(0xFFEDA382).withValues(alpha: 0.45),
    );
    oval(
      c,
      const Rect.fromLTWH(20, -68, 22, 14),
      const Color(0xFFEDA382).withValues(alpha: 0.45),
    );

    // 7C. BARBER TEMPLE SKIN FADE (High fade on sides above the ears)
    for (final side in [-1.0, 1.0]) {
      final fadePath = Path()
        ..moveTo(side * 34, -122)
        ..cubicTo(side * 50, -118, side * 55, -96, side * 53, -72)
        ..lineTo(side * 40, -76)
        ..cubicTo(side * 40, -94, side * 36, -108, side * 34, -122)
        ..close();

      final fadeBounds = Rect.fromLTRB(
        side < 0 ? -56 : 32,
        -124,
        side < 0 ? -32 : 56,
        -70,
      );
      c.drawPath(
        fadePath,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF1A1412).withValues(alpha: 0.92),
              const Color(0xFF2D221E).withValues(alpha: 0.48),
              const Color(0xFFD99570).withValues(alpha: 0.0),
            ],
          ).createShader(fadeBounds),
      );

      // Fine stipple/fade hair texture dots along the temple
      for (int i = 0; i < 14; i++) {
        final fx = side * (37 + (i % 4) * 3.5);
        final fy = -114.0 + (i ~/ 4) * 8.5 + (i % 2) * 2.5;
        circle(
          c,
          Offset(fx, fy),
          0.9,
          const Color(0xFF1C1513).withValues(alpha: 0.35),
        );
      }
    }

    // 7D. WELL-GROOMED BEARD, MUSTACHE & SOUL PATCH WITH HAIR TEXTURE
    // Full boxed jawline beard base
    final beardPath = Path()
      ..moveTo(-52, -70)
      ..cubicTo(-49, -56, -42, -45, -27, -42)
      ..cubicTo(-16, -40, -10, -28, 0, -28)
      ..cubicTo(10, -28, 16, -40, 27, -42)
      ..cubicTo(42, -45, 49, -56, 52, -70)
      ..cubicTo(51, -36, 37, -18, 0, -17)
      ..cubicTo(-37, -18, -51, -36, -52, -70)
      ..close();

    c.drawPath(
      beardPath,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF231B18), Color(0xFF120E0D)],
        ).createShader(const Rect.fromLTWH(-52, -70, 104, 54)),
    );

    // Triangular soul patch right below the lower lip connecting to the chin beard
    final soulPatch = Path()
      ..moveTo(-6.5, -39)
      ..quadraticBezierTo(0, -41, 6.5, -39)
      ..lineTo(3.2, -26)
      ..lineTo(-3.2, -26)
      ..close();
    c.drawPath(soulPatch, brush(const Color(0xFF161110)));

    // Fine realistic beard hair strokes along the cheeks, jaw, and chin
    for (int i = -11; i <= 11; i++) {
      final bx = i * 4.1;
      final distRatio = (i.abs() / 11.0);
      final topY = -30.0 - math.pow(distRatio, 1.55) * 26.0;
      final botY = topY + 9.0 + (1.0 - distRatio) * 4.0;
      line(
        c,
        Offset(bx, topY),
        Offset(bx * 0.93, botY),
        const Color(0xFF120E0D).withValues(alpha: 0.78),
        1.35,
      );
      // Subtle warm bronze/charcoal beard sheen highlights on the chin
      if (i.abs() <= 6 && i.isEven) {
        line(
          c,
          Offset(bx + 1, topY + 4),
          Offset(bx * 0.95 + 1, botY - 1),
          const Color(0xFF3E302B).withValues(alpha: 0.65),
          1.0,
        );
      }
    }

    // Groomed mustache arching over the upper lip
    final mustachePath = Path()
      ..moveTo(0, -52.5)
      ..cubicTo(-10, -54.5, -22, -49.5, -26, -42.5)
      ..cubicTo(-20, -44.5, -10, -48.5, 0, -47.5)
      ..cubicTo(10, -48.5, 20, -44.5, 26, -42.5)
      ..cubicTo(22, -49.5, 10, -54.5, 0, -52.5)
      ..close();
    c.drawPath(mustachePath, brush(const Color(0xFF171210)));

    // Fine mustache hair strokes
    for (int i = -6; i <= 6; i++) {
      if (i == 0) continue;
      final mx = i * 3.4;
      final my = -50.5 + (i.abs() * 0.85);
      line(
        c,
        Offset(mx, my - 2.2),
        Offset(mx + i.sign * 1.5, my + 2.0),
        const Color(0xFF120E0D),
        1.3,
      );
    }

    // 7E. CONFIDENT SMIRK & LIPS
    if (isCelebrating || isPetting) {
      // Joyful open smile
      final smilePath = Path()
        ..moveTo(-15, -45)
        ..quadraticBezierTo(0, -34, 15, -46)
        ..quadraticBezierTo(0, -43, -15, -45)
        ..close();
      c.drawPath(smilePath, brush(const Color(0xFF6E2620)));
      // White upper teeth glint
      final teethPath = Path()
        ..moveTo(-10, -44.5)
        ..quadraticBezierTo(0, -41, 10, -45)
        ..close();
      c.drawPath(teethPath, brush(const Color(0xFFF8FAFC)));
    } else if (isAlert || isDragged) {
      // Surprised 'o' mouth
      oval(
        c,
        const Rect.fromLTWH(-5.5, -46.5, 11, 9.5),
        const Color(0xFF6E2620),
      );
    } else if (isAsleep) {
      // Peaceful sleeping lip line
      line(
        c,
        const Offset(-9, -44.5),
        const Offset(9, -44.5),
        const Color(0xFF8C4237),
        2.2,
      );
    } else if (isDrinking && (math.sin(phase * 1.6) * 0.5 + 0.5) > 0.45) {
      // Realistic sipping mouth at the peak of each drink!
      final sipOpen = ((math.sin(phase * 1.6) * 0.5 + 0.5) - 0.45) / 0.55;
      final sipRect = Rect.fromCenter(
        center: const Offset(2.0, -44.2),
        width: 9.5,
        height: 4.5 + sipOpen * 4.5,
      );
      oval(c, sipRect.inflate(1.4), const Color(0xFFC97865));
      oval(c, sipRect, const Color(0xFF5A1E18));
    } else {
      // Signature charismatic slight smirk from the photo!
      // Plump lower lip
      final lowerLip = Path()
        ..moveTo(-14, -44.2)
        ..quadraticBezierTo(0, -37.2, 15, -45.5)
        ..quadraticBezierTo(0, -42.5, -14, -44.2)
        ..close();
      c.drawPath(lowerLip, brush(const Color(0xFFC97865)));

      // Soft lower lip gloss highlight
      line(
        c,
        const Offset(-5, -41.2),
        const Offset(5, -41.8),
        const Color(0xFFF4B5A4).withValues(alpha: 0.65),
        1.5,
      );

      // Upper lip & confident asymmetrical smirk line (higher on viewer's right)
      final smirkLine = Path()
        ..moveTo(-16.5, -44.0)
        ..cubicTo(-6, -42.2, 6, -43.0, 17.5, -46.2);
      c.drawPath(smirkLine, pen(const Color(0xFF6B2D24), 2.3));

      // Smirk dimple crease at right corner
      final dimple = Path()
        ..moveTo(17.5, -48.2)
        ..quadraticBezierTo(19.8, -46.0, 17.0, -43.8);
      c.drawPath(dimple, pen(const Color(0xFF8C4638), 1.5));
    }

    // 7F. 3D SCULPTED NOSE
    // Soft nose bridge shading
    line(
      c,
      const Offset(-4.5, -74),
      const Offset(-6.5, -60),
      const Color(0xFFC27956).withValues(alpha: 0.55),
      2.2,
    );
    line(
      c,
      const Offset(4.5, -74),
      const Offset(6.5, -60),
      const Color(0xFFC27956).withValues(alpha: 0.45),
      2.0,
    );

    // Rounded 3D nose tip & wings
    oval(
      c,
      const Rect.fromLTWH(-11.5, -63.5, 23, 12.5),
      const Color(0xFFDC946F),
    );
    oval(
      c,
      const Rect.fromLTWH(-8.0, -65.5, 16, 12.0),
      const Color(0xFFEAA987),
    );

    // Nostrils
    oval(
      c,
      const Rect.fromLTWH(-7.8, -55.8, 4.5, 2.8),
      const Color(0xFF6E3824),
    );
    oval(
      c,
      const Rect.fromLTWH(3.3, -55.8, 4.5, 2.8),
      const Color(0xFF6E3824),
    );

    // Nose bridge & button tip 3D specular highlight
    line(
      c,
      const Offset(0, -73),
      const Offset(0, -61),
      const Color(0xFFFCE2D2).withValues(alpha: 0.65),
      2.4,
    );
    circle(
      c,
      const Offset(0, -59.5),
      3.4,
      const Color(0xFFFCE2D2).withValues(alpha: 0.75),
    );

    // 7G. EXPRESSIVE WARM DEEP-BROWN ALMOND EYES
    if (isAsleep || breathingMode) {
      for (final side in [-1.0, 1.0]) {
        final cx = side * 21.5;
        final sleepArc = Path()
          ..moveTo(cx - 11, -72)
          ..quadraticBezierTo(cx, -65, cx + 11, -72);
        c.drawPath(sleepArc, pen(const Color(0xFF1A110E), 3.2));
      }
    } else if (isPetting) {
      // Happy squinting eyes when petted
      for (final side in [-1.0, 1.0]) {
        final cx = side * 21.5;
        final happyArc = Path()
          ..moveTo(cx - 11, -70)
          ..quadraticBezierTo(cx, -80, cx + 11, -70);
        c.drawPath(happyArc, pen(const Color(0xFF1A110E), 3.5));
      }
    } else if (isBlinking) {
      for (final side in [-1.0, 1.0]) {
        final cx = side * 21.5;
        line(
          c,
          Offset(cx - 11.5, -73),
          Offset(cx + 11.5, -73),
          const Color(0xFF1A110E),
          3.2,
        );
      }
    } else {
      for (final side in [-1.0, 1.0]) {
        final eyeCenter = Offset(side * 21.5, -74.0);

        // Upper eyelid crease line (3D depth)
        final creasePath = Path()
          ..moveTo(eyeCenter.dx - 12.5, eyeCenter.dy - 4.5)
          ..quadraticBezierTo(
            eyeCenter.dx,
            eyeCenter.dy - 12.5,
            eyeCenter.dx + 12.5,
            eyeCenter.dy - 3.5,
          );
        c.drawPath(
          creasePath,
          pen(const Color(0xFF9E5A3C).withValues(alpha: 0.75), 1.6),
        );

        // Almond sclera shape
        final scleraPath = Path()
          ..moveTo(eyeCenter.dx - 12.5, eyeCenter.dy + 1.0)
          ..quadraticBezierTo(
            eyeCenter.dx,
            eyeCenter.dy - 10.5,
            eyeCenter.dx + 12.5,
            eyeCenter.dy + 0.5,
          )
          ..quadraticBezierTo(
            eyeCenter.dx,
            eyeCenter.dy + 9.0,
            eyeCenter.dx - 12.5,
            eyeCenter.dy + 1.0,
          )
          ..close();

        // Subtle lower eye bag warmth
        final lowerLidPath = Path()
          ..moveTo(eyeCenter.dx - 10, eyeCenter.dy + 4.5)
          ..quadraticBezierTo(
            eyeCenter.dx,
            eyeCenter.dy + 9.5,
            eyeCenter.dx + 10,
            eyeCenter.dy + 4.0,
          );
        c.drawPath(
          lowerLidPath,
          pen(const Color(0xFFC97E5B).withValues(alpha: 0.55), 1.5),
        );

        // White sclera fill with subtle top shadow
        c.save();
        c.clipPath(scleraPath);
        c.drawPath(scleraPath, brush(const Color(0xFFFDF8F5)));
        c.drawRect(
          Rect.fromLTWH(eyeCenter.dx - 14, eyeCenter.dy - 10, 28, 6),
          brush(const Color(0xFFD8C6BC).withValues(alpha: 0.55)),
        );

        // Rich warm brown iris (tracks cursor via lookOffset, or scans code while typing!)
        final activeLookX = isTyping
            ? math.sin(time * 18) * 3.2
            : (lookOffset.dx * 0.55).clamp(-4.2, 4.2);
        final activeLookY = isTyping
            ? 2.2
            : (lookOffset.dy * 0.45).clamp(-2.8, 2.8) - 0.3;
        final gaze = Offset(
          eyeCenter.dx + activeLookX,
          eyeCenter.dy + activeLookY,
        );
        final irisRadius = (isAlert || isDragged) ? 7.0 : 6.5;
        final irisRect = Rect.fromCircle(center: gaze, radius: irisRadius);

        c.drawCircle(
          gaze,
          irisRadius,
          Paint()
            ..shader = const RadialGradient(
              center: Alignment(0.1, 0.25),
              radius: 0.85,
              colors: [
                Color(0xFF8C4D27), // Warm amber-brown highlight
                Color(0xFF4E2610), // Rich espresso midtone
                Color(0xFF210E05), // Dark outer limbal ring
              ],
              stops: [0.0, 0.68, 1.0],
            ).createShader(irisRect),
        );

        // Deep black pupil
        circle(c, gaze, 3.1, const Color(0xFF0A0605));

        // Dual 3D studio catchlights (crisp upper-left + soft lower-right)
        circle(
          c,
          Offset(gaze.dx - 2.3, gaze.dy - 2.3),
          2.0,
          const Color(0xFFFFFFFF),
        );
        circle(
          c,
          Offset(gaze.dx + 2.0, gaze.dy + 1.8),
          1.0,
          Colors.white.withValues(alpha: 0.88),
        );
        c.restore();

        // Thick expressive dark upper lash line & subtle lower rim
        final upperLash = Path()
          ..moveTo(eyeCenter.dx - 13.0, eyeCenter.dy + 1.2)
          ..quadraticBezierTo(
            eyeCenter.dx,
            eyeCenter.dy - 10.8,
            eyeCenter.dx + 13.0,
            eyeCenter.dy + 0.8,
          );
        c.drawPath(upperLash, pen(const Color(0xFF140D0B), 2.8));

        final lowerRim = Path()
          ..moveTo(eyeCenter.dx - 11.5, eyeCenter.dy + 1.5)
          ..quadraticBezierTo(
            eyeCenter.dx,
            eyeCenter.dy + 8.5,
            eyeCenter.dx + 11.5,
            eyeCenter.dy + 1.0,
          );
        c.drawPath(
          lowerRim,
          pen(const Color(0xFF3B2118).withValues(alpha: 0.65), 1.2),
        );
      }
    }

    // 7G-2. SLEEK 3D BLUE-LIGHT CYBER CODING GLASSES (When typing, toggled on, or Late-Night Mode!)
    if (cyberGlasses && !isAsleep) {
      // Temple arms extending back toward the ears/headphones
      line(
        c,
        const Offset(-47, -75),
        const Offset(-37, -76),
        const Color(0xFF1E293B),
        2.8,
      );
      line(
        c,
        const Offset(37, -76),
        const Offset(47, -75),
        const Color(0xFF1E293B),
        2.8,
      );

      // Center nose bridge
      final bridgePath = Path()
        ..moveTo(-7.5, -75.5)
        ..quadraticBezierTo(0, -78.5, 7.5, -75.5);
      c.drawPath(bridgePath, pen(const Color(0xFF1E293B), 2.8));
      c.drawPath(bridgePath, pen(const Color(0xFF38BDF8).withValues(alpha: 0.65), 1.0));

      for (final side in [-1.0, 1.0]) {
        final lensRect = Rect.fromCenter(
          center: Offset(side * 22.0, -73.8),
          width: 30.5,
          height: 19.5,
        );
        final lensRRect = RRect.fromRectAndCorners(
          lensRect,
          topLeft: const Radius.circular(5.5),
          topRight: const Radius.circular(5.5),
          bottomLeft: const Radius.circular(7.5),
          bottomRight: const Radius.circular(7.5),
        );

        // Soft drop shadow cast by the glasses frame on the cheekbones
        c.drawRRect(
          lensRRect.shift(const Offset(0, 1.8)),
          pen(Colors.black.withValues(alpha: 0.28), 2.0),
        );

        // Translucent anti-glare blue-light filter tint (eyes remain clearly visible!)
        c.drawRRect(
          lensRRect,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF00F0FF).withValues(alpha: 0.20),
                const Color(0xFF6366F1).withValues(alpha: 0.14),
              ],
            ).createShader(lensRect),
        );

        // Diagonal anti-reflective cyan/white studio sheen across each lens
        c.save();
        c.clipRRect(lensRRect);
        final sheenShift = isTyping ? math.sin(time * 16) * 2.5 : 0.0;
        line(
          c,
          Offset(lensRect.left + 5 + sheenShift, lensRect.bottom - 2),
          Offset(lensRect.left + 15 + sheenShift, lensRect.top + 2),
          Colors.white.withValues(alpha: 0.48),
          2.6,
        );
        line(
          c,
          Offset(lensRect.left + 11 + sheenShift, lensRect.bottom - 2),
          Offset(lensRect.left + 21 + sheenShift, lensRect.top + 2),
          const Color(0xFF00F0FF).withValues(alpha: 0.38),
          1.4,
        );
        c.restore();

        // Matte dark titanium outer frame with subtle neon cyan top-bar accent
        c.drawRRect(lensRRect, pen(const Color(0xFF151922), 2.3));
        line(
          c,
          Offset(lensRect.left + 3, lensRect.top + 0.5),
          Offset(lensRect.right - 3, lensRect.top + 0.5),
          const Color(0xFF00F0FF).withValues(alpha: 0.78),
          1.1,
        );
      }
    }

    // 7H. THICK SCULPTED DARK EYEBROWS
    final browLift = (isAlert || isCelebrating)
        ? -3.5
        : isPetting
            ? -1.5
            : 0.0;
    for (final side in [-1.0, 1.0]) {
      // Slight charismatic eyebrow raise on the right side in idle
      final asymLift = (!isAlert && !isAsleep && side > 0) ? -1.4 : 0.0;
      final by = browLift + asymLift;

      final browPath = Path()
        ..moveTo(side * 8.5, -85.5 + by)
        ..quadraticBezierTo(
          side * 22.0,
          -92.5 + by,
          side * 35.5,
          -84.0 + by,
        )
        ..lineTo(side * 33.5, -80.5 + by)
        ..quadraticBezierTo(
          side * 21.5,
          -86.5 + by,
          side * 9.5,
          -80.0 + by,
        )
        ..close();

      c.drawPath(browPath, brush(const Color(0xFF161110)));
    }

    // 7I. VOLUMINOUS CURLY DARK HAIR ON TOP
    // Sharp forehead line-up shadow under the curls
    final hairlineShadow = Path()
      ..moveTo(-36, -112)
      ..quadraticBezierTo(0, -120, 36, -112);
    c.drawPath(
      hairlineShadow,
      pen(const Color(0xFF8C5338).withValues(alpha: 0.45), 3.0),
    );

    // Base dark espresso curl mass
    final hairBase = Path()
      ..moveTo(-38, -112)
      ..cubicTo(-45, -134, -22, -150, 0, -150)
      ..cubicTo(22, -150, 45, -134, 38, -112)
      ..quadraticBezierTo(0, -120, -38, -112)
      ..close();
    c.drawPath(hairBase, brush(const Color(0xFF120E0D)));

    // Sculpted 3D curly clusters with warm bronze/espresso ringlet highlights
    final curlCenters = <Offset>[
      // Top crown ringlets
      const Offset(-20, -138),
      const Offset(-7, -142),
      const Offset(7, -142),
      const Offset(20, -138),
      // Mid-row curls
      const Offset(-30, -128),
      const Offset(-16, -131),
      const Offset(-2, -133),
      const Offset(13, -131),
      const Offset(28, -128),
      // Front hairline curls
      const Offset(-33, -117),
      const Offset(-21, -120),
      const Offset(-8, -122),
      const Offset(6, -122),
      const Offset(19, -120),
      const Offset(32, -117),
    ];

    for (int i = 0; i < curlCenters.length; i++) {
      final cc = curlCenters[i];
      final r = (i < 4) ? 9.5 : (i < 9 ? 9.0 : 8.2);

      // Dark curl shadow base
      circle(c, cc, r, const Color(0xFF14100E));
      // Sculpted midtone curl body
      circle(
        c,
        Offset(cc.dx - 0.5, cc.dy - 0.8),
        r * 0.78,
        const Color(0xFF231B18),
      );

      // Glossy warm bronze-brown S-curve / spiral curl highlight
      final startAngle = (i * 0.85) % (math.pi * 2);
      c.drawArc(
        Rect.fromCircle(center: cc, radius: r * 0.56),
        startAngle,
        math.pi * 1.15,
        false,
        pen(const Color(0xFF543B30), 2.1),
      );
      c.drawArc(
        Rect.fromCircle(center: cc, radius: r * 0.52),
        startAngle + 0.2,
        math.pi * 0.65,
        false,
        pen(const Color(0xFF755343).withValues(alpha: 0.75), 1.1),
      );
    }

    // 7J. OVER-EAR MATTE BLACK HEADPHONES WITH GLOWING CYAN RING & `</>` LOGO
    final ledPulse = (math.sin(time * 5.0) * 0.18 + 0.82).clamp(0.6, 1.0);
    for (final side in [-1.0, 1.0]) {
      c.save();
      c.translate(side * 56.0, -76.0);
      c.rotate(side * -0.10);

      // Headband side hinge bracket
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(side * -2.0, -25.0),
            width: 9,
            height: 12,
          ),
          const Radius.circular(3),
        ),
        brush(const Color(0xFF2B2F3A)),
      );

      // Plush inner ear cushion (presses gently against the head)
      final cushionRect = Rect.fromCenter(
        center: Offset(side * -4.5, 0),
        width: 14,
        height: 44,
      );
      oval(c, cushionRect, const Color(0xFF121419));

      // Matte charcoal outer earcup shell
      final cupRect = Rect.fromCenter(
        center: Offset(side * 2.0, 0),
        width: 20,
        height: 46,
      );
      c.drawOval(
        cupRect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF343946), Color(0xFF1A1D24)],
          ).createShader(cupRect),
      );
      c.drawOval(cupRect, pen(const Color(0xFF101217), 1.4));

      // Outer glowing neon cyan LED ring face
      final ringRect = Rect.fromCenter(
        center: Offset(side * 4.2, 0),
        width: 13.5,
        height: 36,
      );
      // Dark inset plate inside the LED ring
      oval(c, ringRect, const Color(0xFF12151C));

      // Soft neon cyan bloom around the ring
      c.drawOval(
        ringRect.inflate(1.8),
        pen(
          const Color(0xFF00F0FF).withValues(alpha: 0.38 * ledPulse),
          4.2,
        ),
      );
      // Crisp bright cyan LED ring
      c.drawOval(
        ringRect,
        pen(const Color(0xFF00F0FF).withValues(alpha: ledPulse), 2.2),
      );
      c.drawOval(
        ringRect,
        pen(Colors.white.withValues(alpha: 0.55 * ledPulse), 0.9),
      );

      // Glowing cyan `</>` code icon inside the earcup (foreshortened in 3D!)
      c.save();
      c.translate(side * 4.5, 0);
      c.scale(0.36, 0.52);
      _drawCodeSymbol(
        c,
        Offset.zero,
        1.0,
        const Color(0xFF00F0FF).withValues(alpha: ledPulse),
        3.2,
      );
      c.restore();

      // Live 3D Audio Equalizer Bars & Soundwave Arcs when Music / Lo-Fi Vibe Mode is active!
      if (musicMode && !isAsleep) {
        for (int b = -2; b <= 2; b++) {
          final by = b * 5.2;
          final eqLen = 3.5 +
              (math.sin(phase * 6.0 + b * 1.3 + side) * 0.5 + 0.5) * 8.5;
          final barStart = Offset(side * 12.5, by);
          final barEnd = Offset(side * (12.5 + eqLen), by);
          line(
            c,
            barStart,
            barEnd,
            b.abs() == 1 ? mint : const Color(0xFF00F0FF),
            2.3,
          );
        }
        final wavePulse = (time * 3.5) % 1.0;
        final waveRect = Rect.fromCenter(
          center: Offset(side * (10.0 + wavePulse * 8.0), 0),
          width: 10.0 + wavePulse * 8.0,
          height: 26.0 + wavePulse * 14.0,
        );
        c.drawArc(
          waveRect,
          side > 0 ? -math.pi * 0.38 : math.pi * 0.62,
          math.pi * 0.76,
          false,
          pen(
            const Color(0xFF00F0FF).withValues(alpha: (1.0 - wavePulse) * 0.7),
            1.6,
          ),
        );
      }

      c.restore();
    }

    // Optional Bee Antennae if toggled on in Dashboard
    if (beeTheme) {
      final antennaWobbleX = math.sin(time * 10) * 4.0 + lagX * 0.8;
      final antennaWobbleY = (lagY * 0.5).clamp(-10.0, 12.0);

      for (final side in [-1.0, 1.0]) {
        final start = Offset(side * 24, -142);
        final tip = Offset(
          side * 38 + antennaWobbleX,
          -166 + antennaWobbleY,
        );
        final control = Offset(side * 32 + antennaWobbleX * 0.4, -156);

        final antennaPath = Path()
          ..moveTo(start.dx, start.dy)
          ..quadraticBezierTo(control.dx, control.dy, tip.dx, tip.dy);

        c.drawPath(antennaPath, pen(const Color(0xFF1E293B), 3.0));
        c.drawPath(antennaPath, pen(honey, 1.3));
        circle(c, tip, 5.0, honey);
        circle(c, Offset(tip.dx - 1.5, tip.dy - 1.5), 1.8, white);
      }
    }

    c.restore(); // End head tilt group

    // 7K. FOREGROUND HYDRATION / ESPRESSO ARM, ANATOMICAL HAND GRIP & 3D PROP
    // Drawn AFTER the head & beard so the sleeve, wrist, smartwatch, fingers, and bottle/cup
    // form a natural 3D articulated arm holding the drink right up to the mouth!
    if (isDrinking) {
      final sipWave = (math.sin(phase * 1.6) * 0.5 + 0.5);
      const shoulder = Offset(35.0, -8.0);
      // Elbow swings out naturally to the right so the forearm angles up toward the mouth
      final elbow = Offset(61.0 - sipWave * 3.0, 15.0 - sipWave * 5.0);
      // Hand lifts from chest level up to the right side of the mouth so the tilted spout meets the lips!
      final rightHand = Offset(35.0 - sipWave * 9.5, -6.0 - sipWave * 17.5);
      final forearmAngle = math.atan2(
        rightHand.dy - elbow.dy,
        rightHand.dx - elbow.dx,
      );

      // 1. Soft drop shadow cast by the raised arm onto the hoodie torso & beard
      final armSpine = Path()
        ..moveTo(shoulder.dx, shoulder.dy)
        ..lineTo(elbow.dx, elbow.dy)
        ..lineTo(rightHand.dx + 4, rightHand.dy + 6);
      c.drawPath(
        armSpine.shift(const Offset(-3.0, 4.0)),
        pen(Colors.black.withValues(alpha: 0.36), 19.0),
      );

      // 2. Sculpted upper-arm & forearm puffy hoodie sleeve with 3D fabric shading and elbow creases
      c.drawPath(armSpine, pen(const Color(0xFF111318), 21.5));
      c.drawPath(armSpine, pen(const Color(0xFF282C37), 18.5));
      // Top highlight along the forearm sleeve
      line(
        c,
        Offset(elbow.dx - 2, elbow.dy - 3),
        Offset(rightHand.dx + 5, rightHand.dy + 2),
        const Color(0xFF3E4452),
        5.5,
      );
      // Inside elbow bend fabric crease lines
      line(
        c,
        Offset(elbow.dx - 9, elbow.dy - 2),
        Offset(elbow.dx - 2, elbow.dy + 4),
        const Color(0xFF14161D),
        2.0,
      );

      // 3. Angled ribbed sleeve cuff & warm golden-tan wrist emerging from the cuff
      final cuffPos = Offset.lerp(elbow, rightHand, 0.68)!;
      c.save();
      c.translate(cuffPos.dx, cuffPos.dy);
      c.rotate(forearmAngle);
      final cuffRRect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: 10.5, height: 17.0),
        const Radius.circular(4.0),
      );
      c.drawRRect(cuffRRect, brush(const Color(0xFF1D2028)));
      c.drawRRect(cuffRRect, pen(const Color(0xFF101217), 1.2));
      // Bare warm-tan wrist bridge from cuff to palm
      c.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(3.0, -5.8, 12.0, 11.6),
          const Radius.circular(4.5),
        ),
        brush(const Color(0xFFDE9872)),
      );
      c.restore();

      // 4. Gold-bezel smartwatch properly aligned around the bare wrist!
      final watchPos = Offset.lerp(elbow, rightHand, 0.80)!;
      _drawSmartwatch(c, watchPos, forearmAngle + math.pi * 0.5);

      // 5. Back of the palm & thumb supporting the inner side of the bottle/cup
      final bottleTilt = drinkProp == DrinkProp.water
          ? (-0.30 - sipWave * 0.52)
          : (-0.18 - sipWave * 0.42);
      c.save();
      c.translate(rightHand.dx, rightHand.dy);
      c.rotate(bottleTilt);
      // Thumb wrapping around the left/inner side of the bottle
      c.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(-13.5, -5.0, 8.5, 5.2),
          const Radius.circular(2.6),
        ),
        brush(const Color(0xFFD68E67)),
      );
      c.restore();

      // 6. Draw the 3D Water Bottle or Espresso Mug held in the hand!
      if (drinkProp == DrinkProp.water) {
        _drawWaterBottle(c, rightHand, sipWave, phase);
      } else if (drinkProp == DrinkProp.espresso) {
        _drawEspressoCup(c, rightHand, sipWave, phase);
      }

      // 7. Anatomical 3D sculpted fingers wrapping across the FRONT/OUTER side of the bottle/handle!
      c.save();
      c.translate(rightHand.dx, rightHand.dy);
      c.rotate(bottleTilt);
      for (int f = 0; f < 4; f++) {
        final fy = -7.5 + f * 4.3;
        final fw = 11.5 - (f == 3 ? 1.8 : 0.0);
        final fingerRRect = RRect.fromRectAndRadius(
          Rect.fromLTWH(1.5, fy, fw, 3.8),
          const Radius.circular(2.0),
        );
        c.drawRRect(
          fingerRRect,
          Paint()
            ..shader = const LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [Color(0xFFF3C1A2), Color(0xFFDE9872), Color(0xFFC27956)],
            ).createShader(Rect.fromLTWH(1.5, fy, fw, 3.8)),
        );
        c.drawRRect(
          fingerRRect,
          pen(const Color(0xFFB06846).withValues(alpha: 0.65), 0.8),
        );
      }
      c.restore();
    }

    // 8. SLEEPING 'z Z z' FLOATING LETTERS
    if (isAsleep) {
      final zOffset = math.sin(phase) * 6;
      final z = TextPainter(
        text: const TextSpan(
          text: 'z Z z',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w900,
            color: cyan,
            shadows: [
              Shadow(color: Color(0x99000000), blurRadius: 4),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      z.paint(c, Offset(58, -135 + zOffset));
    }

    // 9. ALERT '!' ICON OR LIVE SPORT REP COUNTER
    if (isAlert) {
      final mark = TextPainter(
        text: const TextSpan(
          text: '!',
          style: TextStyle(
            fontSize: 44,
            fontWeight: FontWeight.w900,
            color: peach,
            shadows: [
              Shadow(color: Color(0x99000000), blurRadius: 6),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      mark.paint(c, const Offset(66, -160));
    } else if (isExercising) {
      // Un-flip horizontally so the floating rep badge always reads left-to-right!
      c.save();
      c.scale(direction >= 0 ? 1.0 : -1.0, 1.0);
      final repBadge = TextPainter(
        text: TextSpan(
          text: '💪 ${exerciseReps > 0 ? exerciseReps : 1}',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: mint,
            shadows: [
              Shadow(color: Color(0xCC000000), blurRadius: 6),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      repBadge.paint(c, const Offset(58, -148));
      c.restore();
    }

    c.restore();

    // 10. FOREGROUND FLOATING PARTICLES (Hearts & Confetti)
    for (final p in particles) {
      if (p.type == 0) {
        final heartPath = Path()
          ..moveTo(p.position.dx, p.position.dy)
          ..cubicTo(
            p.position.dx - p.size,
            p.position.dy - p.size,
            p.position.dx - p.size * 1.4,
            p.position.dy + p.size * 0.3,
            p.position.dx,
            p.position.dy + p.size * 1.2,
          )
          ..cubicTo(
            p.position.dx + p.size * 1.4,
            p.position.dy + p.size * 0.3,
            p.position.dx + p.size,
            p.position.dy - p.size,
            p.position.dx,
            p.position.dy,
          )
          ..close();
        c.drawPath(heartPath, brush(p.color.withValues(alpha: p.life)));
      } else if (p.type == 1) {
        c.save();
        c.translate(p.position.dx, p.position.dy);
        c.rotate(time * 10 + p.size);
        c.drawRect(
          Rect.fromCenter(
            center: Offset.zero,
            width: p.size,
            height: p.size * 0.5,
          ),
          brush(p.color.withValues(alpha: p.life)),
        );
        c.restore();
      } else if (p.type == 3) {
        // Floating glowing musical notes (♪ / ♫)
        final notePainter = TextPainter(
          text: TextSpan(
            text: p.size > 9.5 ? '♫' : '♪',
            style: TextStyle(
              fontSize: p.size * 1.45,
              fontWeight: FontWeight.w900,
              color: p.color.withValues(alpha: p.life.clamp(0.0, 1.0)),
              shadows: [
                Shadow(
                  color: const Color(0xFF00F0FF)
                      .withValues(alpha: p.life.clamp(0.0, 1.0) * 0.7),
                  blurRadius: 6,
                ),
              ],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        notePainter.paint(c, p.position);
      }
    }
  }

  @override
  bool shouldRepaint(covariant PetPainter old) => true;
}
