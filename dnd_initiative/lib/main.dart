import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

void main() {
  runApp(const MyApp());
}

// ---------------- Root App ----------------
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DND Initiative Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color.fromARGB(255, 59, 97, 223),
        ),
        useMaterial3: true,
      ),
      home: const PlayerEntryPage(),
    );
  }
}

// ---------------- Player Model ----------------
class Player {
  final String name;
  final int espIndex; // 0 = HUB, 1 = ESP2, etc.

  Player({required this.name, required this.espIndex});
}

// ---------------- Page 1: Player Entry ----------------
class PlayerEntryPage extends StatefulWidget {
  const PlayerEntryPage({super.key});

  @override
  State<PlayerEntryPage> createState() => _PlayerEntryPageState();
}

class _PlayerEntryPageState extends State<PlayerEntryPage> {
  final TextEditingController _playerController = TextEditingController();
  final List<Player> _players = [];

  void _addPlayer() {
    final name = _playerController.text.trim();
    if (name.isEmpty) return;

    final espIndex = _players.length;

    setState(() {
      _players.add(Player(name: name, espIndex: espIndex));
      _playerController.clear();
    });
  }

  void _goToInitiative() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => InitiativePage(initialPlayers: _players),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Add Players")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _playerController,
              decoration: const InputDecoration(
                labelText: "Player Name",
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _addPlayer(),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _addPlayer,
              child: const Text("Add Player"),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: _players.length,
                itemBuilder: (_, i) => Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      child: Text("${_players[i].espIndex + 1}"),
                    ),
                    title: Text(_players[i].name),
                    subtitle: Text("ESP Slot ${_players[i].espIndex}"),
                  ),
                ),
              ),
            ),
            ElevatedButton(
              onPressed: _players.isNotEmpty ? _goToInitiative : null,
              child: const Text("Start Initiative"),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------- Page 2: Initiative Tracker ----------------
class InitiativePage extends StatefulWidget {
  final List<Player> initialPlayers;

  const InitiativePage({super.key, required this.initialPlayers});

  @override
  State<InitiativePage> createState() => _InitiativePageState();
}

class _InitiativePageState extends State<InitiativePage> {
  final flutterReactiveBle = FlutterReactiveBle();
  QualifiedCharacteristic? ledCharacteristic;
  QualifiedCharacteristic? turnCharacteristic;

  StreamSubscription<ConnectionStateUpdate>? _connectionSubscription;
  StreamSubscription<List<int>>? _turnSubscription;

  final Uuid serviceUuid =
      Uuid.parse("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  final Uuid ledCharUuid =
      Uuid.parse("6E400002-B5A3-F393-E0A9-E50E24DCCA9E");
  final Uuid turnCharUuid =
      Uuid.parse("6E400004-B5A3-F393-E0A9-E50E24DCCA9E");

  late final Player dmPlayer;

  List<Player> _availablePlayers = [];
  List<Player> _initiativeOrder = [];

  int _currentIndex = 0;
  bool _dmInsertMode = false;
  bool _isConnected = false;

  @override
  void initState() {
    super.initState();
    dmPlayer = Player(name: "DM", espIndex: -1);
    _availablePlayers = List.from(widget.initialPlayers);
    scanAndConnect();
  }

 // ---------- BLE SCAN + CONNECT WITH RECONNECT ----------
void scanAndConnect() {
  StreamSubscription<DiscoveredDevice>? scanSub;

  scanSub = flutterReactiveBle
      .scanForDevices(
        withServices: [serviceUuid],
        scanMode: ScanMode.lowLatency,
      )
      .listen((device) async {
    if (device.name == "ESP32_HUB") {
      await scanSub?.cancel();
      _connectToHub(device.id);
    }
  });
}

// Connect to hub with auto-reconnect and proper service discovery
void _connectToHub(String deviceId) {
  _connectionSubscription = flutterReactiveBle
      .connectToDevice(
        id: deviceId,
        connectionTimeout: const Duration(seconds: 10),
      )
      .listen((state) async {
    switch (state.connectionState) {
      case DeviceConnectionState.connected:
        debugPrint("Connected to hub, discovering services...");
        try {
          // Wait for services to be ready
          await flutterReactiveBle.discoverServices(deviceId);

          ledCharacteristic = QualifiedCharacteristic(
            serviceId: serviceUuid,
            characteristicId: ledCharUuid,
            deviceId: deviceId,
          );

          turnCharacteristic = QualifiedCharacteristic(
            serviceId: serviceUuid,
            characteristicId: turnCharUuid,
            deviceId: deviceId,
          );

          _subscribeToTurnCommands();

          setState(() => _isConnected = true);
          debugPrint("BLE ready for writes/subscriptions");
        } catch (e) {
          debugPrint("Service discovery failed: $e");
        }
        break;

      case DeviceConnectionState.disconnected:
      case DeviceConnectionState.disconnecting:
        debugPrint("Disconnected from hub, retrying in 2s...");
        setState(() => _isConnected = false);

        // Auto-reconnect after delay
        Future.delayed(const Duration(seconds: 2), () => _connectToHub(deviceId));
        break;

      default:
        break;
    }
  }, onError: (error) {
    debugPrint("Connection error: $error");
    setState(() => _isConnected = false);
    // Retry connection after short delay
    Future.delayed(const Duration(seconds: 2), () => _connectToHub(deviceId));
  });
}

// ---------- ENCODER TURN INPUT (unchanged) ----------
void _subscribeToTurnCommands() {
  if (turnCharacteristic == null) return;

  _turnSubscription = flutterReactiveBle
      .subscribeToCharacteristic(turnCharacteristic!)
      .listen((data) {
    if (data.isEmpty) return;

    // Convert from 8-bit signed
    final int dir = data[0] > 127 ? data[0] - 256 : data[0];

    if (dir == 1) _nextTurn();           // clockwise
    else if (dir == -1) _previousTurn(); // counterclockwise
    else if (dir == 2) _toggleDmInsertMode(); // optional button
  }, onError: (e) {
    debugPrint("Turn subscription error: $e");
  });
}




  // ---------- INITIATIVE LOGIC ----------
  void _addPlayerToInitiative(Player player) {
    setState(() {
      _initiativeOrder.add(player);
      _availablePlayers.remove(player);
    });
    sendEspTurn(_currentIndex);
  }

  void _toggleDmInsertMode() {
    setState(() => _dmInsertMode = !_dmInsertMode);
  }

  void _addDmAtEnd() {
    setState(() => _initiativeOrder.add(dmPlayer));
    sendEspTurn(_currentIndex);
  }

  void _insertDmUnder(int index) {
    setState(() {
      _initiativeOrder.insert(index + 1, dmPlayer);
      _dmInsertMode = false;
    });
    sendEspTurn(_currentIndex);
  }

  void _removeDm(int index) {
    if (_initiativeOrder[index] == dmPlayer) {
      setState(() => _initiativeOrder.removeAt(index));
      sendEspTurn(_currentIndex);
    }
  }

  void _nextTurn() {
    if (_initiativeOrder.isEmpty) return;
    setState(() {
      _currentIndex = (_currentIndex + 1) % _initiativeOrder.length;
    });
    sendEspTurn(_currentIndex);
  }

  void _previousTurn() {
    if (_initiativeOrder.isEmpty) return;
    setState(() {
      _currentIndex =
          (_currentIndex - 1 + _initiativeOrder.length) % _initiativeOrder.length;
    });
    sendEspTurn(_currentIndex);
  }

  void _clearOrder() {
    setState(() {
      _initiativeOrder.clear();
      _availablePlayers = List.from(widget.initialPlayers);
      _currentIndex = 0;
      _dmInsertMode = false;
    });
    _sendAllOff();
  }

  // ---------- BLE LED SEND ----------
  Future<void> sendEspTurn(int currentIndex) async {
    if (_initiativeOrder.isEmpty || ledCharacteristic == null) return;

    final int n = _initiativeOrder.length;
    final Player currentPlayer = _initiativeOrder[currentIndex];

    int? greenIndex;
    int? blueIndex;

    final int rawNextIndex = (currentIndex + 1) % n;
    final Player rawNextPlayer = _initiativeOrder[rawNextIndex];

    if (currentPlayer.name == "DM") {
      greenIndex = null;
      int i = rawNextIndex;
      while (_initiativeOrder[i].name == "DM") {
        i = (i + 1) % n;
      }
      blueIndex = i;
    } else {
      greenIndex = currentIndex;
      blueIndex = rawNextPlayer.name != "DM" ? rawNextIndex : null;
    }

    final packet = List<int>.filled(6, 0x00);

    for (int i = 0; i < n; i++) {
      final p = _initiativeOrder[i];
      if (p.espIndex < 0) continue;

      int value = 0x00;
      if (greenIndex != null && i == greenIndex) value = 0x01;
      else if (blueIndex != null && i == blueIndex) value = 0x02;
      else if (currentPlayer.name == "DM") value = 0x03;

      packet[p.espIndex] = value;
    }

    try {
      await flutterReactiveBle.writeCharacteristicWithResponse(
        ledCharacteristic!,
        value: packet,
      );
    } catch (e) {
      debugPrint("BLE write failed: $e");
    }
  }

  Future<void> _sendAllOff() async {
    if (ledCharacteristic == null) return;
    await flutterReactiveBle.writeCharacteristicWithResponse(
      ledCharacteristic!,
      value: List<int>.filled(6, 0x00),
    );
  }

  @override
  void dispose() {
    _turnSubscription?.cancel();
    _connectionSubscription?.cancel();
    super.dispose();
  }

  // -------- UI --------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Initiative Tracker")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Turn buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(onPressed: _previousTurn, child: const Text("Previous")),
                ElevatedButton(onPressed: _nextTurn, child: const Text("Next")),
                ElevatedButton(onPressed: _clearOrder, child: const Text("Clear")),
              ],
            ),
            const SizedBox(height: 16),

            // Available players + DM button
            Wrap(
              spacing: 8,
              children: [
                ..._availablePlayers.map(
                  (p) => ElevatedButton(
                    onPressed: () => _addPlayerToInitiative(p),
                    child: Text(p.name),
                  ),
                ),
                GestureDetector(
                  onTap: _addDmAtEnd,
                  onLongPress: _toggleDmInsertMode,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: _dmInsertMode ? Colors.redAccent : Colors.red,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      "DM",
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Optional BLE test button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isConnected
                    ? () async {
                        await flutterReactiveBle.writeCharacteristicWithResponse(
                          ledCharacteristic!,
                          value: [0x01],
                        );
                      }
                    : null,
                child: const Text("TEST HUB GREEN"),
              ),
            ),
            const SizedBox(height: 16),

            // Initiative list
            Expanded(
              child: ListView.builder(
                itemCount: _initiativeOrder.length,
                itemBuilder: (_, i) {
                  final player = _initiativeOrder[i];
                  final isCurrent = i == _currentIndex;

                  return GestureDetector(
                    onTap: () {
                      if (player == dmPlayer && !_dmInsertMode) _removeDm(i);
                      else if (_dmInsertMode && player != dmPlayer) _insertDmUnder(i);
                    },
                    child: Card(
                      color: isCurrent ? Colors.green[300] : Colors.white,
                      child: ListTile(
                        title: Text(
                          player.name,
                          style: TextStyle(
                            fontWeight: player == dmPlayer ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
