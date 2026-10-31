import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:yanshu/features/recording_device/ai_voice_product_artwork.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('三张实物照片均作为 Flutter 资产可读取', () async {
    for (final face in ['front', 'back', 'side']) {
      final bytes = await rootBundle.load(
        'assets/images/ai_voice/ai_voice_$face.png',
      );
      expect(bytes.lengthInBytes, greaterThan(1024));
    }
  });
  testWidgets('扫描动效只在需要时运行，系统减少动态效果时停止', (tester) async {
    var phase = AiVoiceArtworkPhase.scanning;
    var reduced = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: Scaffold(
                body: Center(
                  child: AiVoiceProductArtwork(phase: phase, animate: true),
                ),
              ),
            );
          },
        ),
      ),
    );
    AnimationController controller() =>
        tester
                .widget<AnimatedBuilder>(
                  find
                      .descendant(
                        of: find.byType(AiVoiceProductArtwork),
                        matching: find.byType(AnimatedBuilder),
                      )
                      .first,
                )
                .animation
            as AnimationController;
    await tester.pump(const Duration(milliseconds: 800));
    expect(controller().isAnimating, true);
    expect(controller().value, greaterThan(0));
    update(() => phase = AiVoiceArtworkPhase.success);
    await tester.pump();
    expect(controller().isAnimating, false);
    update(() {
      phase = AiVoiceArtworkPhase.scanning;
      reduced = true;
    });
    await tester.pump();
    expect(controller().isAnimating, false);
    await tester.pump(const Duration(seconds: 1));
    expect(controller().isAnimating, false);
    expect(tester.takeException(), isNull);
  });
}
