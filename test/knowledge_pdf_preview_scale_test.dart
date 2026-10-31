import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/knowledge/views/knowledge_pdf_preview_page.dart';

void main() {
  test('large PDF page fits the phone instead of inheriting A4 scale', () {
    const page = Size(2246, 3000);
    final scale = knowledgePreviewDpi(page, 360, 3) / 72;
    expect(page.width * scale, closeTo(984, 0.01));
    expect(page.height * scale, lessThan(1400));
  });

  test('A4 keeps the screen resolution', () {
    const page = Size(595, 841);
    final scale = knowledgePreviewDpi(page, 360, 3) / 72;
    expect(page.width * scale, closeTo(984, 0.01));
  });

  test('pixel budget limits very tall pages and high density screens', () {
    for (final page in [const Size(595, 20000), const Size(2246, 3000)]) {
      final scale = knowledgePreviewDpi(page, 1200, 4) / 72;
      expect(page.width * page.height * scale * scale, closeTo(2000000, 0.01));
    }
  });
}
