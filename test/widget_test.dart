import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:edclass/core/theme/theme.dart';

void main() {
  test('EdClass theme has light and dark variants', () {
    expect(AppTheme.light.brightness, Brightness.light);
    expect(AppTheme.dark.brightness, Brightness.dark);
  });
}