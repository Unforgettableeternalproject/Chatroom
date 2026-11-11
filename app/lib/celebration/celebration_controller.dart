import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'celebration_logic.dart';

final _log = Logger('celebration');

/// 慶祝音效。抽成介面讓測試換掉；播放失敗一律吞掉。
abstract class CelebrationSound {
  Future<void> play();
}

/// audioplayers 的實作。播放器延遲建立：不放音效的人（含測試）不會碰原生層。
class AudioplayersCelebrationSound implements CelebrationSound {
  AudioPlayer? _player;

  @override
  Future<void> play() async {
    try {
      final p = _player ??= AudioPlayer();
      await p.stop();
      await p.play(AssetSource('sounds/partyblower.mp3'));
    } catch (e) {
      _log.fine('慶祝音效播放失敗：$e');
    }
  }
}

/// 慶祝的出口：節流後，同時通知畫面噴彩花並播音效。
class CelebrationController {
  CelebrationController({required this.sound, CelebrationThrottle? throttle})
    : _throttle = throttle ?? CelebrationThrottle();

  final CelebrationSound sound;
  final CelebrationThrottle _throttle;
  final _bursts = StreamController<void>.broadcast();

  /// 每次通過節流就發一次，彩花層訂閱它。
  Stream<void> get bursts => _bursts.stream;

  /// 回傳這次是否真的放了。
  bool celebrate() {
    if (_bursts.isClosed || !_throttle.tryAcquire()) return false;
    _bursts.add(null);
    unawaited(sound.play());
    return true;
  }

  void dispose() => _bursts.close();
}

final celebrationSoundProvider = Provider<CelebrationSound>(
  (ref) => AudioplayersCelebrationSound(),
);

final celebrationControllerProvider = Provider<CelebrationController>((ref) {
  final c = CelebrationController(sound: ref.watch(celebrationSoundProvider));
  ref.onDispose(c.dispose);
  return c;
});
