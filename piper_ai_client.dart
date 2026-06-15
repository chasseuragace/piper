import 'dart:io';
import 'package:shared_ecosystem/shared_ecosystem.dart';

// UnifiedAIClient lazy-loaded instance
UnifiedAIClient? _aiClient;

UnifiedAIClient? getAIClient() {
  if (_aiClient == null) {
    try {
      _aiClient = UnifiedAIClient.fromEnvironment();
    } catch (e) {
      stderr.writeln('Error creating UnifiedAIClient from environment: $e');
    }
  }
  return _aiClient;
}
