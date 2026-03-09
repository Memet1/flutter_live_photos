import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
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
  String? _selectedVideoPath;

  final _startTimeCtrl = TextEditingController(text: '0');
  final _durationCtrl = TextEditingController(text: '3');

  Future<void> _pickVideo() async {
    final picker = ImagePicker();
    final file = await picker.pickVideo(source: ImageSource.gallery);
    if (file != null) {
      setState(() {
        _selectedVideoPath = file.path;
        _status = 'Video selected';
        _lastResult = null;
      });
    }
  }

  Future<void> _generate() async {
    if (_isProcessing) return;
    if (_selectedVideoPath == null) {
      setState(() => _status = 'Pick a video first');
      return;
    }

    final startTime = int.tryParse(_startTimeCtrl.text.trim()) ?? 0;
    final duration = int.tryParse(_durationCtrl.text.trim()) ?? 3;

    setState(() {
      _isProcessing = true;
      _status = 'Generating (start=$startTime, duration=$duration)…';
      _lastResult = null;
    });

    final result = await LivePhotosPlus.generate(
      localPath: _selectedVideoPath,
      startTime: startTime.toDouble(),
      duration: duration.toDouble(),
    );

    setState(() {
      _isProcessing = false;
      _lastResult = result;
      _status = result.success ? '✅ Saved to Camera Roll!' : '❌ ${result.error}';
    });
  }

  Future<void> _cleanUp() async {
    await LivePhotosPlus.cleanUp();
    setState(() {
      _status = 'Temp files cleaned';
      _lastResult = null;
    });
  }

  @override
  void dispose() {
    _startTimeCtrl.dispose();
    _durationCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Live Photos Test'), centerTitle: true),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Status card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Status', style: Theme.of(context).textTheme.titleSmall),
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
              const SizedBox(height: 16),

              // Video picker
              FilledButton.tonalIcon(
                onPressed: _isProcessing ? null : _pickVideo,
                icon: const Icon(Icons.video_library),
                label: Text(_selectedVideoPath == null
                    ? 'Pick Video from Gallery'
                    : _selectedVideoPath!.split('/').last),
              ),
              const SizedBox(height: 20),

              // Trim inputs
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _startTimeCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Start (sec)',
                        border: OutlineInputBorder(),
                        suffixText: 's',
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextField(
                      controller: _durationCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Duration (sec)',
                        border: OutlineInputBorder(),
                        suffixText: 's',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              if (_isProcessing)
                const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 8),

              FilledButton.icon(
                onPressed: _isProcessing ? null : _generate,
                icon: const Icon(Icons.photo_camera),
                label: const Text('Generate Live Photo'),
              ),
              const SizedBox(height: 40),

              TextButton.icon(
                onPressed: _cleanUp,
                icon: const Icon(Icons.cleaning_services),
                label: const Text('Clean Up Temp Files'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
