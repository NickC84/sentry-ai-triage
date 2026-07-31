part of '../ai_analyzer.dart';

/// One AI analysis result for a crash issue.
class AnalysisResult {
  final int severityScore; // 0–100
  final String isAppFixable; // app_fixable | not_fixable | needs_more_data
  final String rootCauseSummary;
  final String recommendedAction;
  final double confidence; // 0–1
  final String model;
  final double costUsd;

  AnalysisResult({
    required this.severityScore,
    required this.isAppFixable,
    required this.rootCauseSummary,
    required this.recommendedAction,
    required this.confidence,
    required this.model,
    required this.costUsd,
  });
}

/// Feature feasibility analysis result.
class FeatureAnalysis {
  final String feasibility; // feasible | hard | blocked | needs_info
  final String effort; // S | M | L | XL
  final int priorityScore; // 0–100
  final String summary;
  final String approach;
  final String affectedAreas;
  final String risks;
  final double confidence;
  final String model;
  final double costUsd;

  FeatureAnalysis({
    required this.feasibility,
    required this.effort,
    required this.priorityScore,
    required this.summary,
    required this.approach,
    required this.affectedAreas,
    required this.risks,
    required this.confidence,
    required this.model,
    required this.costUsd,
  });
}

/// Raw engine output: structured JSON + which model ran + cost.
class _EngineResult {
  final Map<String, dynamic> output;
  final String model;
  final double costUsd;
  _EngineResult({required this.output, required this.model, required this.costUsd});
}
