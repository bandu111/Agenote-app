import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 采音设备与识别模型独立替换；模型类型及词表单位必须与导出版本匹配。
class MeetingSpeechModel {
  const MeetingSpeechModel(
    this.id,
    this.assets, {
    this.decoderFile = 'decoder.int8.onnx',
    this.modelType = 'zipformer',
    this.modelingUnit = '',
  });
  final String id, assets, decoderFile, modelType, modelingUnit;
  static const bilingual = MeetingSpeechModel(
    'bilingual-2023-v1',
    'assets/speech',
  );
  static const chinese = MeetingSpeechModel(
    'chinese-2025-06-30-v1',
    'assets/speech_candidate',
    decoderFile: 'decoder.onnx',
    modelType: '',
    modelingUnit: 'cjkchar',
  );
  static const chineseCandidate = chinese;
}

sherpa.OnlineRecognizer createMeetingSpeechEngine(
  String directory, {
  MeetingSpeechModel model = MeetingSpeechModel.chinese,
}) => sherpa.OnlineRecognizer(
  sherpa.OnlineRecognizerConfig(
    model: sherpa.OnlineModelConfig(
      transducer: sherpa.OnlineTransducerModelConfig(
        encoder: '$directory/encoder.int8.onnx',
        decoder: '$directory/${model.decoderFile}',
        joiner: '$directory/joiner.int8.onnx',
      ),
      tokens: '$directory/tokens.txt',
      modelType: model.modelType,
      modelingUnit: model.modelingUnit,
      numThreads: 2,
      debug: false,
    ),
    rule1MinTrailingSilence: 2.4,
    rule2MinTrailingSilence: 1.0,
    rule3MinUtteranceLength: 20,
  ),
);
