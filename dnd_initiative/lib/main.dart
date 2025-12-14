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

    final espIndex = _players.length; // entry order = ESP mapping

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
            ElevatedButton(onPressed: _addPlayer, child: const Text("Add Player")),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: _players.length,
                itemBuilder: (_, i) => Card(
                  child: ListTile(
                    title: Text(_players[i].name),
                    subtitle: Text("ESP ${_players[i].espIndex + 1}"),
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
  StreamSubscription<ConnectionStateUpdate>? _connectionSubscription;

  final Uuid serviceUuid =
      Uuid.parse("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  final Uuid characteristicUuid =
      Uuid.parse("6E400002-B5A3-F393-E0A9-E50E24DCCA9E");

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

        _connectionSubscription = flutterReactiveBle
            .connectToDevice(
          id: device.id,
          connectionTimeout: const Duration(seconds: 5),
        )
            .listen((state) {
          if (state.connectionState ==
              DeviceConnectionState.connected) {
            ledCharacteristic = QualifiedCharacteristic(
              serviceId: serviceUuid,
              characteristicId: characteristicUuid,
              deviceId: device.id,
            );
            setState(() => _isConnected = true);
          }
        });
      }
    });
  }

  // -------- BLE TURN SEND --------
Future<void> sendEspTurn(int currentIndex) async {
  if (_initiativeOrder.isEmpty || ledCharacteristic == null) return;

  final Player currentPlayer = _initiativeOrder[currentIndex];
  final Player? nextPlayer =
      _initiativeOrder[(_initiativeOrder.indexOf(currentPlayer) + 1) %
          _initiativeOrder.length];

  // Packet for all 6 ESPs (0 = HUB)
  final packet = List<int>.filled(6, 0x00);

  for (final player in _initiativeOrder) {
    int idx = player.espIndex;

    // DM always uses hub LED (idx 0)
    if (player.name == "DM") idx = 0;

    if (idx < 0 || idx >= packet.length) continue;

    if (currentPlayer.name == "DM") {
      // DM's turn: DM red, everyone else red except next player handled below
      packet[idx] = 0x03;
    } else if (player == currentPlayer) {
      // Current normal player: green
      packet[idx] = 0x01;
    } else if (player == nextPlayer && nextPlayer!.name != "DM") {
      // Next normal player: blue
      packet[idx] = 0x02;
    } else if (currentPlayer.name == "DM" && player != currentPlayer) {
      // Everyone else when DM's turn: red
      packet[idx] = 0x03;
    } else {
      // Everyone else off
      packet[idx] = 0x00;
    }
  }

  // Ensure hub LED (idx 0) is correct
  if (packet[0] == 0x00) {
    if (currentPlayer.name == "DM") {
      packet[0] = 0x03; // red for DM
    } else if (currentPlayer.espIndex == 0) {
      packet[0] = 0x01; // green if hub player
    } else if (nextPlayer != null && nextPlayer.espIndex == 0 && nextPlayer.name != "DM") {
      packet[0] = 0x02; // blue if hub is next
    }
  }

  try {
    await flutterReactiveBle.writeCharacteristicWithResponse(
      ledCharacteristic!,
      value: packet,
    );
    debugPrint("Sent turn packet to HUB: $packet");
  } catch (e) {
    debugPrint("BLE write failed: $e");
  }
}



  // -------- Initiative Logic --------
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
      _currentIndex =
          (_currentIndex + 1) % _initiativeOrder.length;
    });
    sendEspTurn(_currentIndex);
  }

  void _previousTurn() {
    if (_initiativeOrder.isEmpty) return;
    setState(() {
      _currentIndex =
          (_currentIndex - 1 + _initiativeOrder.length) %
              _initiativeOrder.length;
    });
    sendEspTurn(_currentIndex);
  }

  void _clearOrder() {
  setState(() {
    _initiativeOrder.clear();
    _currentIndex = 0;
    _dmInsertMode = false;
    _availablePlayers = List.from(widget.initialPlayers);
  });

  // Send "all off" packet to hub
  _sendAllOff();
}

Future<void> _sendAllOff() async {
  if (ledCharacteristic == null) return;

  final packet = List<int>.filled(6, 0x00); // all off

  try {
    await flutterReactiveBle.writeCharacteristicWithResponse(
      ledCharacteristic!,
      value: packet,
    );
    debugPrint("Sent all-off packet to HUB: $packet");
  } catch (e) {
    debugPrint("BLE write failed: $e");
  }
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(onPressed: _previousTurn, child: const Text("Previous")),
                ElevatedButton(onPressed: _nextTurn, child: const Text("Next")),
                ElevatedButton(onPressed: _clearOrder, child: const Text("Clear")),
              ],
            ),
            const SizedBox(height: 16),

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
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
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

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isConnected
                    ? () async {
                        await flutterReactiveBle
                            .writeCharacteristicWithResponse(
                          ledCharacteristic!,
                          value: [0x01],
                        );
                      }
                    : null,
                child: const Text("TEST HUB GREEN"),
              ),
            ),

            const SizedBox(height: 16),

            Expanded(
              child: ListView.builder(
                itemCount: _initiativeOrder.length,
                itemBuilder: (_, i) {
                  final player = _initiativeOrder[i];
                  final isCurrent = i == _currentIndex;

                  return GestureDetector(
                    onTap: () {
                      if (player == dmPlayer && !_dmInsertMode) {
                        _removeDm(i);
                      } else if (_dmInsertMode && player != dmPlayer) {
                        _insertDmUnder(i);
                      }
                    },
                    child: Card(
                      color: isCurrent
                          ? Colors.green[300]
                          : Colors.white,
                      child: ListTile(
                        title: Text(
                          player.name,
                          style: TextStyle(
                            fontWeight: player == dmPlayer
                                ? FontWeight.bold
                                : FontWeight.normal,
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
