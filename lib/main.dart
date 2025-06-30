import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:mediapipe_genai/mediapipe_genai.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// Gemma 3 1B Instruct Model
// https://www.kaggle.com/models/google/gemma-3/tfLite
const String _assetModelPath = 'assets/gemma3-1B-it-int4.task';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ChatApp());
}

class ChatApp extends StatelessWidget {
  const ChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gemma On-Device',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: const ChatScreen(),
    );
  }
}

enum AppState { loadingModel, ready, generatingResponse, error }

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  LlmInferenceEngine? _llmEngine;
  var _appState = AppState.loadingModel;
  String _errorMessage = '';
  final _conversationHistory = StringBuffer();
  String _streamingResponse = '';

  @override
  void initState() {
    super.initState();
    _initializeEngine();
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initializeEngine() async {
    try {
      final modelPath = await _copyModelToLocal();
      final docDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory(p.join(docDir.path, 'gemma_cache'));
      await cacheDir.create(recursive: true);

      final options = LlmInferenceOptions.gpu(
        modelPath: modelPath,
        sequenceBatchSize: 1,
        maxTokens: 2048,
        topK: 40,
        temperature: 0.8,
      );
      _llmEngine = LlmInferenceEngine(options);

      setState(() {
        _appState = AppState.ready;
        _conversationHistory.writeln(
          ">> Gemma: Hello! I'm Gemma, an on-device AI. How can I help you today?\n",
        );
      });
    } catch (e) {
      setState(() {
        _appState = AppState.error;
        _errorMessage = 'Failed to initialize the model:\n$e';
      });
    }
  }

  Future<String> _copyModelToLocal() async {
    final docDir = await getApplicationDocumentsDirectory();
    final localModelPath = p.join(docDir.path, p.basename(_assetModelPath));
    final modelFile = File(localModelPath);

    if (!await modelFile.exists()) {
      final modelBytes = await rootBundle.load(_assetModelPath);
      await modelFile.writeAsBytes(modelBytes.buffer.asUint8List());
    }
    return modelFile.path;
  }

  Future<void> _sendPrompt() async {
    final prompt = _textController.text.trim();
    if (prompt.isEmpty || _llmEngine == null) return;

    setState(() {
      _appState = AppState.generatingResponse;
      _conversationHistory.writeln('>> User: $prompt\n');
      _streamingResponse = '';
    });
    _textController.clear();
    _scrollToBottom();

    try {
      final responseBuffer = StringBuffer();
      final stream = _llmEngine!.generateResponse(prompt);
      await for (final chunk in stream) {
        responseBuffer.write(chunk);
        setState(() {
          _streamingResponse = responseBuffer.toString();
        });
      }
      _conversationHistory.writeln('>> Gemma: $_streamingResponse\n');
      _streamingResponse = '';
      setState(() => _appState = AppState.ready);
    } catch (e) {
      setState(() {
        _appState = AppState.error;
        _errorMessage = 'Failed to generate response:\n$e';
      });
    } finally {
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gemma On-Device Chat')),
      body: Column(
        children: [
          Expanded(
            child: switch (_appState) {
              AppState.loadingModel => const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Initializing model...'),
                  ],
                ),
              ),
              AppState.error => Center(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text(
                    _errorMessage,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
              _ => ListView(
                controller: _scrollController,
                padding: const EdgeInsets.all(16.0),
                children: [
                  SelectableText(_conversationHistory.toString()),
                  if (_streamingResponse.isNotEmpty)
                    Text('>> Gemma: $_streamingResponse'),
                ],
              ),
            },
          ),
          if (_appState == AppState.generatingResponse)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: LinearProgressIndicator(),
            ),
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: _buildUserInput(),
          ),
        ],
      ),
    );
  }

  Widget _buildUserInput() {
    final bool canSubmit = _appState == AppState.ready;

    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _textController,
            enabled: canSubmit,
            decoration: InputDecoration(
              hintText: 'Enter a prompt...',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20.0),
              ),
            ),
            onSubmitted: canSubmit ? (_) => _sendPrompt() : null,
          ),
        ),
        const SizedBox(width: 8.0),
        IconButton(
          icon: const Icon(Icons.send),
          onPressed: canSubmit ? _sendPrompt : null,
        ),
      ],
    );
  }
}
