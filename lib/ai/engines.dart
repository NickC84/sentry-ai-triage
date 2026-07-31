part of '../ai_analyzer.dart';

/// The two ways an analysis actually runs: the `claude` CLI (subscription)
/// or the Anthropic Messages API (metered).
extension AiEngines on AiAnalyzer {
  Future<_EngineResult> _callCli(String prompt, Map<String, dynamic> schema,
      String workingDir, Duration t) async {
    final result = await Process.run(
      cliCommand,
      [
        '-p', prompt,
        '--output-format', 'json',
        '--json-schema', jsonEncode(schema),
        '--model', model,
      ],
      workingDirectory: workingDir,
    ).timeout(t);

    if (result.exitCode != 0) {
      throw Exception(
          '$cliCommand failed (exit ${result.exitCode}): ${result.stderr}');
    }
    final Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(result.stdout.toString()) as Map<String, dynamic>;
    } catch (e) {
      throw Exception('Cannot parse $cliCommand output: $e\n${result.stdout}');
    }
    if (envelope['is_error'] == true) {
      throw Exception('$cliCommand reported an error: ${envelope['result']}');
    }
    final out = envelope['structured_output'] as Map<String, dynamic>?;
    if (out == null) {
      throw Exception('Missing structured_output in: ${result.stdout}');
    }
    return _EngineResult(
      output: out,
      model: _firstModelUsed(envelope) ?? '',
      costUsd: (envelope['total_cost_usd'] as num?)?.toDouble() ?? 0,
    );
  }

  Future<_EngineResult> _callApi(
      String prompt, Map<String, dynamic> schema) async {
    if (apiKey.isEmpty) {
      throw Exception(
          'AI mode is anthropic_api but ANTHROPIC_API_KEY is empty — set it in Settings.');
    }
    final apiModel = _apiModelAliases[model] ?? model;

    final client = HttpClient();
    try {
      final req =
          await client.postUrl(Uri.parse('https://api.anthropic.com/v1/messages'));
      req.headers.set('x-api-key', apiKey);
      req.headers.set('anthropic-version', '2023-06-01');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'model': apiModel,
        'max_tokens': 2048,
        'output_config': {
          'format': {'type': 'json_schema', 'schema': schema},
        },
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      }));
      final res = await req.close().timeout(timeout);
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw Exception('Anthropic API ${res.statusCode}: $body');
      }
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      if (envelope['stop_reason'] == 'refusal') {
        throw Exception('The model declined to analyze this issue.');
      }
      final content = (envelope['content'] as List?) ?? [];
      final text = content
          .whereType<Map<String, dynamic>>()
          .where((b) => b['type'] == 'text')
          .map((b) => (b['text'] ?? '').toString())
          .join();
      final out = jsonDecode(text) as Map<String, dynamic>;

      final usage = envelope['usage'] as Map<String, dynamic>? ?? {};
      final inTok = (usage['input_tokens'] as num?)?.toDouble() ?? 0;
      final outTok = (usage['output_tokens'] as num?)?.toDouble() ?? 0;
      final price = _apiPrices[apiModel];
      final cost = price == null
          ? 0.0
          : (inTok * price[0] + outTok * price[1]) / 1000000;

      return _EngineResult(
        output: out,
        model: (envelope['model'] ?? apiModel).toString(),
        costUsd: cost,
      );
    } finally {
      client.close(force: true);
    }
  }

  String? _firstModelUsed(Map<String, dynamic> envelope) {
    final mu = envelope['modelUsage'];
    if (mu is Map && mu.isNotEmpty) return mu.keys.first.toString();
    return null;
  }
}

const _apiModelAliases = {
  'opus': 'claude-opus-5',
  'sonnet': 'claude-sonnet-5',
  'haiku': 'claude-haiku-4-5',
};

// USD per 1M tokens (input, output) — for cost display only.
const _apiPrices = {
  'claude-opus-5': [5.0, 25.0],
  'claude-sonnet-5': [3.0, 15.0],
  'claude-haiku-4-5': [1.0, 5.0],
};

/// 32-bit FNV-1a — stable across runs (change detection only, not crypto).
String _fnv1a(String s) {
  var hash = 0x811c9dc5;
  for (final c in s.codeUnits) {
    hash ^= c;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
