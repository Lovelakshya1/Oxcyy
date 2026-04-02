import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import 'dart:async';

Future<AudioHandler> initAudioService() async {
  return await AudioService.init(
    builder: () => MyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.oxcy.channel.audio',
      androidNotificationChannelName: 'Music Playback',
      androidNotificationIcon: 'mipmap/ic_launcher',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidShowNotificationBadge: true,
    ),
  );
}

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  final ConcatenatingAudioSource _playlist =
      ConcatenatingAudioSource(children: []);

  final _mediaItemStreamController = BehaviorSubject<MediaItem?>.seeded(null);

  MyAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    await _player.setAudioSource(_playlist, preload: false);

    _player.playbackEventStream.map(_transformEvent).pipe(playbackState);
    _player.sequenceStateStream.listen((sequenceState) {
      final currentItem = sequenceState?.currentSource?.tag as MediaItem?;
      if (currentItem != null) mediaItem.add(currentItem);
    });
  }

  /// Builds an AudioSource from a MediaItem.
  ///
  /// - genre == 'jiosaavn': direct URL stored in extras['url']
  /// - genre == 'local':    item.id is the file URI
  Future<AudioSource> _createAudioSource(MediaItem item) async {
    if (item.genre == 'jiosaavn') {
      final url = item.extras?['url'] as String?;
      if (url == null || url.isEmpty) {
        throw Exception('No stream URL for JioSaavn song "${item.title}"');
      }
      return AudioSource.uri(Uri.parse(url), tag: item);
    } else {
      // Local file — id is the content URI
      return AudioSource.uri(Uri.parse(item.id), tag: item);
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    switch (repeatMode) {
      case AudioServiceRepeatMode.none:
        await _player.setLoopMode(LoopMode.off);
        break;
      case AudioServiceRepeatMode.one:
        await _player.setLoopMode(LoopMode.one);
        break;
      case AudioServiceRepeatMode.group:
      case AudioServiceRepeatMode.all:
        await _player.setLoopMode(LoopMode.all);
        break;
    }
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
  }

  @override
  Future<void> addQueueItem(MediaItem item) async {
    try {
      final source = await _createAudioSource(item);
      await _playlist.add(source);
      queue.add(List.from(queue.value)..add(item));
    } catch (e) {
      print('Error adding queue item: $e');
    }
  }

  @override
  Future<void> updateQueue(List<MediaItem> newQueue) async {
    try {
      final audioSources =
          await Future.wait(newQueue.map(_createAudioSource));
      await _playlist.clear();
      await _playlist.addAll(audioSources);
      queue.add(newQueue);
    } catch (e) {
      print('Error updating queue: $e');
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    await _player.seek(Duration.zero, index: index);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() => _player.seekToNext();

  @override
  Future<void> skipToPrevious() => _player.seekToPrevious();

  @override
  Future<void> stop() async {
    await _player.stop();
    _player.dispose();
    return super.stop();
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        if (_player.hasPrevious)
          MediaControl.skipToPrevious
        else
          MediaControl.play,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        if (_player.hasNext) MediaControl.skipToNext else MediaControl.play,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: event.currentIndex,
      repeatMode: const {
        LoopMode.off: AudioServiceRepeatMode.none,
        LoopMode.one: AudioServiceRepeatMode.one,
        LoopMode.all: AudioServiceRepeatMode.all,
      }[_player.loopMode]!,
    );
  }
}
