/// A [Call] that records what it was told and reaches no hardware.
///
/// Shared between the tests that assert *when* the app speaks to the media plane
/// — the cluster wiring in `call_cluster_test.dart` and the quality requests in
/// `call_screen_test.dart`. Both care about the same thing: that the right thing
/// is said, once, at the right moment.
library;

import 'dart:async';

import 'package:gather_companion/src/media/call.dart';

class FakeCall implements Call {
  /// Who we asked to hear, in the order asked.
  final List<Set<String>> told = [];

  /// Who we permitted to see us.
  final List<Set<String>> shownTo = [];

  /// The conversation ids we named, nulls included.
  final List<String?> conversations = [];

  /// Who is on screen, and how big.
  final List<({List<String> srcIds, VideoQuality quality})> watching = [];

  final _states = StreamController<CallState>.broadcast();

  @override
  Future<void> setVisibleTo(Set<String> srcIds) async => shownTo.add(srcIds);

  @override
  CallState get state => const CallState();

  @override
  Stream<CallState> get states => _states.stream;

  @override
  Future<void> setListeningTo(Set<String> srcIds) async => told.add(srcIds);

  @override
  Future<void> setConversation(String? clusterId) async =>
      conversations.add(clusterId);

  @override
  Future<void> setWatching(
    List<String> srcIds, {
    required VideoQuality quality,
  }) async =>
      watching.add((srcIds: srcIds, quality: quality));

  @override
  Future<String?> setMicOn(bool on) async => null;

  @override
  Future<String?> setCameraOn(bool on) async => null;

  @override
  Future<void> switchCamera() async {}

  @override
  Future<void> hangUp() async {}

  @override
  Future<void> dispose() async => _states.close();
}
