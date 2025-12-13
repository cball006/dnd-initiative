import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

void main() {
  runApp(const MyApp());
}

// ---------------- Page 1 & 2: Root App ----------------
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DND Initiative Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color.fromARGB(255, 59, 97, 223)),
        useMaterial3: true,
      ),
      home: const PlayerEntryPage(),
    );
  }
}

// ---------------- Page 1: Player Entry ----------------
class PlayerEntryPage extends StatefulWidget {
  const PlayerEntryPage({super.key});

  @override
  State<PlayerEntryPage> createState() => _PlayerEntryPageState();
}

class _PlayerEntryPageState extends State<PlayerEntryPage> {
  final TextEditingController _playerController = TextEditingController();
  final List<String> _players = [];

  void _addPlayer() {
    final name = _playerController.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _players.add(name);
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
                  labelText: "Player Name", border: OutlineInputBorder()),
              onSubmitted: (_) => _addPlayer(),
            ),
            const SizedBox(height: 8),
            ElevatedButton(onPressed: _addPlayer, child: const Text("Add Player")),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: _players.length,
                itemBuilder: (_, i) => Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(title: Text(_players[i])),
                ),
              ),
            ),
            ElevatedButton(
                onPressed: _players.isNotEmpty ? _goToInitiative : null,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text("Start Initiative")),
          ],
        ),
      ),
    );
  }
}

// ---------------- Page 2: Initiative Tracker ----------------
class InitiativePage extends StatefulWidget {
  final List<String> initialPlayers;
  const InitiativePage({super.key, required this.initialPlayers});

  @override
  State<InitiativePage> createState() => _InitiativePageState();
}

class _InitiativePageState extends State<InitiativePage> {
  final flutterReactiveBle = FlutterReactiveBle();
  DiscoveredDevice? espDevice;
  QualifiedCharacteristic? ledCharacteristic;

  final Uuid serviceUuid =
      Uuid.parse("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  final Uuid characteristicUuid =
      Uuid.parse("6E400002-B5A3-F393-E0A9-E50E24DCCA9E");

  List<String> _availablePlayers = [];
  List<String> _initiativeOrder = [];
  int _currentIndex = 0;

  bool _dmInsertMode = false;
  bool _isConnected = false;



  // ESP mapping: Player 1 = hub, Player 2-6 = other ESP32s
  final Map<int, String> espIds = {
    0: "HUB",
    1: "ESP2",
    2: "ESP3",
    3: "ESP4",
    4: "ESP5",
    5: "ESP6",
  };

  @override
  void initState() {
    super.initState();
    _availablePlayers = List.from(widget.initialPlayers);
    scanAndConnect();
  }



void scanAndConnect() async {
  debugPrint("Starting BLE scan...");

  // Make subscription nullable
  StreamSubscription<DiscoveredDevice>? subscription;

  subscription = flutterReactiveBle
      .scanForDevices(
          withServices: [serviceUuid], scanMode: ScanMode.lowLatency)
      .listen((device) async {
    debugPrint("Found device: ${device.name} (${device.id})");

    if (device.name == "ESP32_Hub") {
      // Stop scanning as soon as we find the hub
      await subscription?.cancel();
      debugPrint("ESP32 Hub found. Attempting connection...");

      try {
        // Connect to hub
        flutterReactiveBle
            .connectToDevice(
          id: device.id,
          connectionTimeout: const Duration(seconds: 5),
        )
            .listen((connectionState) {
          debugPrint("Connection state: ${connectionState.connectionState}");

          if (connectionState.connectionState ==
              DeviceConnectionState.connected) {
            ledCharacteristic = QualifiedCharacteristic(
              serviceId: serviceUuid,
              characteristicId: characteristicUuid,
              deviceId: device.id,
            );

            setState(() {
              _isConnected = true; // now button can be enabled
            });

            debugPrint(
                "Connected to ESP32 hub. LED characteristic ready!");
          }
        }, onError: (e) {
          debugPrint("Connection failed: $e");
        });
      } catch (e) {
        debugPrint("Connection exception: $e");
      }
    }
  }, onError: (e) => debugPrint("Scan error: $e"));
}





  // -------- Send turn bytes to hub & prepare for other ESP32s --------
  Future<void> sendEspTurn(int currentIndex) async {
    if (_initiativeOrder.isEmpty) return;

    for (int i = 0; i < _initiativeOrder.length; i++) {
      int value;
      if (i == currentIndex) {
        value = _initiativeOrder[i] == "DM" ? 0x03 : 0x01; // current turn
      } else if (i == (currentIndex + 1) % _initiativeOrder.length) {
        value = 0x02; // next player
      } else {
        value = 0x00; // off
      }

      // Send to correct ESP
      if (espIds[i] == "HUB") {
        // send to hub via BLE
        if (ledCharacteristic != null) {
          try {
            await flutterReactiveBle.writeCharacteristicWithResponse(
              ledCharacteristic!,
              value: [value],
            );
          } catch (e) {
            print("Error sending to hub: $e");
          }
        }
      } else {
        // TODO: Implement hub forwarding to other ESP32s
        print("Send to ${espIds[i]}: $value"); 
      }
    }
  }

  // -------- Initiative functions --------
  void _addPlayerToInitiative(String name) {
    setState(() {
      _initiativeOrder.add(name);
      _availablePlayers.remove(name);
    });
    sendEspTurn(_currentIndex);
  }

  void _toggleDmInsertMode() {
    setState(() {
      _dmInsertMode = !_dmInsertMode;
    });
  }

  void _addDmAtEnd() {
    setState(() {
      _initiativeOrder.add("DM");
    });
    sendEspTurn(_currentIndex);
  }

  void _insertDmUnder(int playerIndex) {
    setState(() {
      _initiativeOrder.insert(playerIndex + 1, "DM");
      _dmInsertMode = false;
    });
    sendEspTurn(_currentIndex);
  }

  void _removeDm(int index) {
    if (_initiativeOrder[index] == "DM") {
      setState(() {
        _initiativeOrder.removeAt(index);
      });
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
      _currentIndex = 0;
      _dmInsertMode = false;
      _availablePlayers = List.from(widget.initialPlayers);
    });
    sendEspTurn(_currentIndex);
  }

  // -------- Build UI --------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(title: const Text("Initiative Tracker")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // ---- Top Buttons ----
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(onPressed: _previousTurn, child: const Text("Previous")),
                ElevatedButton(onPressed: _nextTurn, child: const Text("Next")),
                ElevatedButton(onPressed: _clearOrder, child: const Text("Clear Order")),
              ],
            ),
            const SizedBox(height: 16),

            // ---- Player Buttons + DM inline ----
            Wrap(
              spacing: 8,
              children: [
                ..._availablePlayers.map(
                  (p) => ElevatedButton(
                    onPressed: () => _addPlayerToInitiative(p),
                    style: ElevatedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      backgroundColor: Colors.blueAccent,
                    ),
                    child: Text(
                      p,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
                // DM button inline
                GestureDetector(
                  onLongPress: _toggleDmInsertMode,
                  onTap: _addDmAtEnd,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: _dmInsertMode ? Colors.redAccent : Colors.red,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      "DM",
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),


// ----------TEST LED Button ----------
SizedBox(
  width: double.infinity, // take full width
  child: ElevatedButton(
    style: ElevatedButton.styleFrom(
      backgroundColor: Colors.green,
      foregroundColor: Colors.white,
    ),
    onPressed: _isConnected
        ? () async {
            final testPacket = [
              0x01, // Hub / Player 1 = GREEN
              0x00,
              0x00,
              0x00,
              0x00,
              0x00,
            ];

            try {
              await flutterReactiveBle.writeCharacteristicWithResponse(
                ledCharacteristic!,
                value: testPacket,
              );
              debugPrint("Sent test packet: $testPacket");
            } catch (e) {
              debugPrint("BLE write failed: $e");
            }
          }
        : null, // disabled if not connected
    child: const Text("TEST HUB GREEN"),
  ),
),
const SizedBox(height: 16), // spacing


            // ---- Initiative Order List ----
            Expanded(
              child: ListView.builder(
                itemCount: _initiativeOrder.length,
                itemBuilder: (_, i) {
                  final name = _initiativeOrder[i];
                  final isCurrent = i == _currentIndex;
                  return GestureDetector(
                    onTap: () {
                      if (name == "DM" && !_dmInsertMode) {
                        _removeDm(i);
                      } else if (_dmInsertMode && name != "DM") {
                        _insertDmUnder(i);
                      }
                    },
                    child: Card(
                      elevation: isCurrent ? 6 : 2,
                      color: isCurrent
                          ? Colors.green[300]
                          : (_dmInsertMode && name != "DM"
                              ? Colors.blue.withOpacity(0.3)
                              : Colors.white),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        title: Text(
                          name,
                          style: TextStyle(
                              fontWeight: name == "DM"
                                  ? FontWeight.bold
                                  : FontWeight.normal),
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
