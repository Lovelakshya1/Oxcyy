import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audio_service/audio_service.dart';
import 'package:oxcy/services/audio_handler.dart';

const String _kBackendBase = 'https://backend-two-beige-92.vercel.app';

// ─── NOTE ON CORS ────────────────────────────────────────────────────────────
// CORS is browser-only. Flutter uses Android's native HTTP stack (dart:io),
// so CORS headers are never enforced here. No special handling needed.
// ─────────────────────────────────────────────────────────────────────────────

class Song {
  final String id;
  final String title;
  final String artist;
  final String thumbUrl;
  final String type;     // 'jiosaavn' | 'local'
  final String? url;     // 320kbps stream URL (JioSaavn only)
  final int? localId;
  final int? albumId;
  final Duration? duration;

  Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.thumbUrl,
    required this.type,
    this.url,
    this.localId,
    this.albumId,
    this.duration,
  });
}

class MusicProvider with ChangeNotifier {
  final OnAudioQuery _audioQuery = OnAudioQuery();

  AudioHandler? _audioHandler;
  AudioHandler? get audioHandler => _audioHandler;

  final Map<String, Uint8List> _artworkCache = {};

  List<Song> _searchResults = [];
  List<Song> get searchResults => _searchResults;

  List<AlbumModel> _localAlbums = [];
  List<AlbumModel> get localAlbums => _localAlbums;

  List<Song> _localSongs = [];
  List<Song> get localSongs => _localSongs;

  List<Song> _shuffledSongs = [];

  bool _isSearching = false;
  bool get isSearching => _isSearching;

  bool _isFetchingLocal = true;
  bool get isFetchingLocal => _isFetchingLocal;

  bool _isPlayerExpanded = false;
  bool get isPlayerExpanded => _isPlayerExpanded;

  bool _isShuffleEnabled = false;
  bool get isShuffleEnabled => _isShuffleEnabled;

  String? _searchError;
  String? get searchError => _searchError;

  AudioServiceRepeatMode _repeatMode = AudioServiceRepeatMode.none;
  AudioServiceRepeatMode get repeatMode => _repeatMode;

  MusicProvider() {
    _init();
  }

  Future<void> _init() async {
    _audioHandler = await AudioService.init(
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
    _audioHandler?.playbackState.listen((state) {
      if (_repeatMode != state.repeatMode) {
        _repeatMode = state.repeatMode;
        notifyListeners();
      }
    });
    fetchLocalMusic();
  }

  // ─── JioSaavn Search ───────────────────────────────────────────────────────
  //
  // rajput-hemant API response (key differences from sumitkolhe):
  //   - image[n].link     (not .url)
  //   - downloadUrl[n].link  (not .url)
  //   - primaryArtists    flat string  (not artists.primary[] array)
  //
  // Full shape:
  // { status, data: { results: [{
  //   id, name, primaryArtists, duration,
  //   image: [{quality, link}],
  //   downloadUrl: [{quality, link}]   ← last entry = 320kbps
  // }] } }

  Future<void> search(String query) async {
    if (query.trim().isEmpty) return;

    _isSearching = true;
    _searchError = null;
    _searchResults = [];
    notifyListeners();

    try {
      final uri = Uri.parse(
        '$_kBackendBase/api/search/songs'
        '?query=${Uri.encodeComponent(query)}&limit=20',
      );

      final response =
          await http.get(uri).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final results = body['data']?['results'] as List<dynamic>? ?? [];

      _searchResults = results
          .map((e) => _parseSong(e as Map<String, dynamic>))
          .whereType<Song>()
          .toList();
    } on TimeoutException {
      _searchError = 'Search timed out. Check your connection.';
    } catch (e) {
      _searchError = 'Search failed. Try again.';
      print('JioSaavn search error: $e');
    } finally {
      _isSearching = false;
      notifyListeners();
    }
  }

  Song? _parseSong(Map<String, dynamic> item) {
    final id = item['id'] as String?;
    if (id == null || id.isEmpty) return null;

    // Thumbnail — last entry = highest resolution
    final images = item['image'] as List<dynamic>? ?? [];
    final thumbUrl = images.isNotEmpty
        ? _linkFrom(images.last as Map<String, dynamic>)
        : '';

    // Stream URL — last entry = 320kbps
    final downloads = item['downloadUrl'] as List<dynamic>? ?? [];
    final streamUrl = downloads.isNotEmpty
        ? _linkFrom(downloads.last as Map<String, dynamic>)
        : '';
    if (streamUrl.isEmpty) return null;

    // Artists — rajput-hemant sends a flat comma-separated string
    String artist = '';
    if (item['primaryArtists'] is String) {
      artist = item['primaryArtists'] as String;
    } else {
      // Defensive fallback for sumitkolhe-style nested array
      final primary =
          item['artists']?['primary'] as List<dynamic>? ?? [];
      artist = primary
          .map((a) => (a as Map)['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .join(', ');
    }

    // Duration can come as int or string
    Duration? duration;
    final raw = item['duration'];
    final secs = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
    if (secs != null) duration = Duration(seconds: secs);

    return Song(
      id: id,
      title: item['name'] as String? ?? 'Unknown',
      artist: artist.isNotEmpty ? artist : 'Unknown',
      thumbUrl: thumbUrl,
      type: 'jiosaavn',
      url: streamUrl,
      duration: duration,
    );
  }

  /// Safely reads "link" from a map, falling back to "url" for compat.
  String _linkFrom(Map<String, dynamic> map) =>
      (map['link'] ?? map['url'] ?? '') as String;

  // ─── Local Music ───────────────────────────────────────────────────────────

  Future<void> fetchLocalMusic() async {
    _isFetchingLocal = true;
    notifyListeners();

    try {
      if (await Permission.audio.request().isGranted ||
          await Permission.storage.request().isGranted) {
        final albums = await _audioQuery.queryAlbums(
          sortType: AlbumSortType.ALBUM,
          orderType: OrderType.ASC_OR_SMALLER,
          uriType: UriType.EXTERNAL,
          ignoreCase: true,
        );
        final songs = await _audioQuery.querySongs(
          sortType: SongSortType.DATE_ADDED,
          orderType: OrderType.DESC_OR_GREATER,
          uriType: UriType.EXTERNAL,
          ignoreCase: true,
        );

        _localAlbums = albums;
        _localSongs = songs
            .where((s) => (s.isMusic ?? false) && (s.duration ?? 0) > 10000)
            .map((s) => Song(
                  id: s.uri!,
                  title: s.title,
                  artist: s.artist ?? 'Unknown',
                  thumbUrl: '',
                  type: 'local',
                  localId: s.id,
                  albumId: s.albumId,
                  duration: Duration(milliseconds: s.duration ?? 0),
                ))
            .toList();

        _shuffledSongs = List.from(_localSongs)..shuffle();
        if (_audioHandler != null) {
          await _updateQueueWithSongs(
              _isShuffleEnabled ? _shuffledSongs : _localSongs);
        }
      }
    } catch (e) {
      print('Error fetching local music: $e');
    } finally {
      _isFetchingLocal = false;
      notifyListeners();
    }
  }

  Future<List<Song>> getLocalSongsByAlbum(int albumId) async {
    final albumSongs = await _audioQuery.queryAudiosFrom(
      AudiosFromType.ALBUM_ID,
      albumId,
      orderType: OrderType.ASC_OR_SMALLER,
    );

    albumSongs.sort((a, b) {
      final ta = int.tryParse(a.track.toString()) ?? 0;
      final tb = int.tryParse(b.track.toString()) ?? 0;
      return ta.compareTo(tb);
    });

    return albumSongs
        .where((s) => (s.isMusic ?? false) && (s.duration ?? 0) > 10000)
        .map((s) => Song(
              id: s.uri!,
              title: s.title,
              artist: s.artist ?? 'Unknown',
              thumbUrl: '',
              type: 'local',
              localId: s.id,
              albumId: s.albumId,
              duration: Duration(milliseconds: s.duration ?? 0),
            ))
        .toList();
  }

  Future<Uint8List?> getArtwork(int id, ArtworkType type) async {
    final key = '${type}_$id';
    if (_artworkCache.containsKey(key)) return _artworkCache[key];
    final art = await _audioQuery.queryArtwork(
      id, type,
      format: ArtworkFormat.PNG,
      size: 2048,
    );
    if (art != null) _artworkCache[key] = art;
    return art;
  }

  // ─── Playback ──────────────────────────────────────────────────────────────

  Future<void> play(Song song, {List<Song>? newQueue}) async {
    if (_audioHandler == null) return;

    try {
      final mediaItem = _songToMediaItem(song);

      if (newQueue != null) {
        await _updateQueueWithSongs(newQueue);
        final index = newQueue.indexWhere((s) => s.id == song.id);
        if (index != -1) await _audioHandler!.skipToQueueItem(index);
      } else if (song.type == 'jiosaavn') {
        await _audioHandler!.addQueueItem(mediaItem);
        await _audioHandler!
            .skipToQueueItem(_audioHandler!.queue.value.length - 1);
      } else {
        final queue = _isShuffleEnabled ? _shuffledSongs : _localSongs;
        final index = queue.indexWhere((s) => s.id == song.id);
        if (index != -1) {
          await _audioHandler!.skipToQueueItem(index);
        } else {
          await _audioHandler!.addQueueItem(mediaItem);
          await _audioHandler!
              .skipToQueueItem(_audioHandler!.queue.value.length - 1);
        }
      }

      _audioHandler!.play();
      if (!_isPlayerExpanded) {
        _isPlayerExpanded = true;
        notifyListeners();
      }
    } catch (e) {
      print('Error playing: $e');
    }
  }

  Future<void> _updateQueueWithSongs(List<Song> songs) async {
    await _audioHandler!.updateQueue(songs.map(_songToMediaItem).toList());
  }

  MediaItem _songToMediaItem(Song s) => MediaItem(
        id: s.id,
        album: s.type == 'local' ? 'Local Music' : 'JioSaavn',
        title: s.title,
        artist: s.artist,
        artUri: (s.type == 'jiosaavn' && s.thumbUrl.isNotEmpty)
            ? Uri.parse(s.thumbUrl)
            : null,
        genre: s.type,
        duration: s.duration,
        extras: {
          if (s.url != null) 'url': s.url,
          'artworkId': s.localId,
          'albumId': s.albumId,
        },
      );

  // ─── Controls ──────────────────────────────────────────────────────────────

  void togglePlayPause() {
    if (_audioHandler?.playbackState.value.playing == true) {
      _audioHandler!.pause();
    } else {
      _audioHandler!.play();
    }
  }

  void next() => _audioHandler?.skipToNext();
  void previous() => _audioHandler?.skipToPrevious();
  void seek(Duration pos) => _audioHandler?.seek(pos);

  void cycleRepeatMode() {
    if (_audioHandler == null) return;
    final next = {
      AudioServiceRepeatMode.none: AudioServiceRepeatMode.all,
      AudioServiceRepeatMode.all: AudioServiceRepeatMode.one,
      AudioServiceRepeatMode.one: AudioServiceRepeatMode.none,
    }[_repeatMode];
    if (next != null) {
      _repeatMode = next;
      notifyListeners();
      _audioHandler!.setRepeatMode(next);
    }
  }

  void toggleShuffle() {
    if (_audioHandler == null) return;
    _isShuffleEnabled = !_isShuffleEnabled;
    _audioHandler!.setShuffleMode(_isShuffleEnabled
        ? AudioServiceShuffleMode.all
        : AudioServiceShuffleMode.none);
    if (_isShuffleEnabled) {
      _shuffledSongs = List.from(_localSongs)..shuffle();
      _updateQueueWithSongs(_shuffledSongs);
    } else {
      _updateQueueWithSongs(_localSongs);
    }
    notifyListeners();
  }

  void togglePlayerView() {
    _isPlayerExpanded = !_isPlayerExpanded;
    notifyListeners();
  }

  void collapsePlayer() {
    if (_isPlayerExpanded) {
      _isPlayerExpanded = false;
      notifyListeners();
    }
  }

  @override
  void dispose() => super.dispose();
}
