import 'package:flutter/material.dart';
import 'package:live_photos_plus/live_photos_plus.dart';

void main() {
  runApp(const LivePhotosPlusTestApp());
}

class LivePhotosPlusTestApp extends StatelessWidget {
  const LivePhotosPlusTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Live Photos Test',
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const TestPage(),
    );
  }
}

class TestPage extends StatefulWidget {
  const TestPage({super.key});

  @override
  State<TestPage> createState() => _TestPageState();
}

class _TestPageState extends State<TestPage> {
  String _status = 'Ready';
  LivePhotoResult? _lastResult;
  bool _isProcessing = false;

  // Local test video from user
  static const _testLocalPath = '/Users/memet/Downloads/bg_compressed.mp4';

  Future<void> _generateFromLocal() async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
      _status = 'Generating Live Photo (3s trim)…';
      _lastResult = null;
    });

    final result = await LivePhotosPlus.generate(
      localPath: _testLocalPath,
      startTime: 0.0,
      duration: 3.0,
    );

    setState(() {
      _isProcessing = false;
      _lastResult = result;
      _status =
          result.success ? '✅ Saved to Camera Roll!' : '❌ ${result.error}';
    });
  }

  Future<void> _cleanUp() async {
    await LivePhotosPlus.cleanUp();
    setState(() {
      _status = '🧹 Temp files cleaned';
      _lastResult = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Live Photos Test'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Status',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Text(_status),
                    if (_lastResult != null) ...[
                      const Divider(),
                      if (_lastResult!.heicPath != null)
                        Text('HEIC: ${_lastResult!.heicPath}',
                            style: Theme.of(context).textTheme.bodySmall),
                      if (_lastResult!.movPath != null)
                        Text('MOV: ${_lastResult!.movPath}',
                            style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            if (_isProcessing) const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _isProcessing ? null : _generateFromLocal,
              icon: const Icon(Icons.video_file),
              label: const Text('Generate 3s Live Photo (Local)'),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _cleanUp,
              icon: const Icon(Icons.cleaning_services),
              label: const Text('Clean Up Temp Files'),
            ),
          ],
        ),
      ),
    );
  }
}
