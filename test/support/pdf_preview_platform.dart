import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
// ignore: implementation_imports
import 'package:printing/src/interface.dart';

/// Test transport only: verifies that actual generated PDF bytes reach the viewer.
/// Pixel rendering remains a native-device check, not a claim made by these tests.
class PdfPreviewTestPlatform extends PrintingPlatform {
  Uint8List? document;
  @override
  Future<PrintingInfo> info() async => const PrintingInfo(canRaster: true);
  @override
  Stream<PdfRaster> raster(Uint8List document, List<int>? pages, double dpi) {
    this.document = document;
    return Stream.value(_TestRaster());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Not used by preview tests');
}

class _TestRaster extends PdfRaster {
  _TestRaster() : super(2, 2, Uint8List.fromList(List.filled(16, 255)));
  @override
  Future<Uint8List> toPng() =>
      PdfRasterBase(width, height, true, pixels).toPng();
}

PrintingPlatform installPdfPreviewTestPlatform(
  PdfPreviewTestPlatform platform,
) {
  final previous = PrintingPlatform.instance;
  PrintingPlatform.instance = platform;
  return previous;
}

void restorePdfPreviewTestPlatform(PrintingPlatform previous) {
  PrintingPlatform.instance = previous;
}
