import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'datadisplay_backend.dart';

typedef _EngineNewNative = Pointer<Void> Function();
typedef _EngineFreeNative = Void Function(Pointer<Void>);
typedef _StringFreeNative = Void Function(Pointer<Utf8>);
typedef _JsonCommandNative =
    Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _EngineNewDart = Pointer<Void> Function();
typedef _EngineFreeDart = void Function(Pointer<Void>);
typedef _StringFreeDart = void Function(Pointer<Utf8>);
typedef _JsonCommandDart = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);

class NativeBackendLoadResult {
  const NativeBackendLoadResult({
    required this.backend,
    required this.statusLabel,
    required this.statusDetail,
    required this.searchedPaths,
  });

  final NativeDatadisplayBackend? backend;
  final String statusLabel;
  final String statusDetail;
  final List<String> searchedPaths;

  bool get available => backend != null;
}

class NativeDatadisplayBackend implements DatadisplayBackendClient {
  NativeDatadisplayBackend._({required this.libraryPath});

  final String libraryPath;
  late final Future<_NativeWorker> _workerFuture = _NativeWorker.spawn(
    libraryPath,
  );

  bool _disposed = false;

  static NativeBackendLoadResult tryLoad() {
    final searchedPaths = _candidateLibraryPaths().toList();
    final failures = <String>[];

    for (final candidate in searchedPaths) {
      final file = File(candidate);
      if (!file.existsSync()) {
        continue;
      }

      try {
        final library = DynamicLibrary.open(candidate);
        _NativeBindings.load(library);
        return NativeBackendLoadResult(
          backend: NativeDatadisplayBackend._(libraryPath: candidate),
          statusLabel: 'Native engine ready',
          statusDetail: candidate,
          searchedPaths: searchedPaths,
        );
      } catch (error) {
        failures.add('$candidate: $error');
      }
    }

    final detail = failures.isEmpty
        ? 'No dd-ffi shared library was found. Set DD_FFI_LIBRARY_PATH or build the Rust cdylib in target/debug.'
        : failures.first;

    return NativeBackendLoadResult(
      backend: null,
      statusLabel: 'Demo backend only',
      statusDetail: detail,
      searchedPaths: searchedPaths,
    );
  }

  @override
  Future<OpenedSource> openSource(String uri) async {
    final data = await _invoke('open_source', {'uri': uri});
    return OpenedSource.fromJson(data);
  }

  @override
  Future<void> closeSource(int sourceId) async {
    await _invoke('close_source', {'source_id': sourceId});
  }

  @override
  Future<CatalogPage> catalog({
    required int sourceId,
    String? text,
    List<String> tags = const [],
    int offset = 0,
    int? limit,
  }) async {
    final data = await _invoke('catalog', {
      'source_id': sourceId,
      'text': text,
      'tags': tags,
      'offset': offset,
      'limit': limit,
    });
    return CatalogPage.fromJson(data, fallbackOffset: offset);
  }

  @override
  Future<DataBlock> read({
    required int sourceId,
    required String channelId,
    required TimeRange timeRange,
    required ReadAggregation aggregation,
    int? maxPoints,
    bool allowGaps = false,
  }) async {
    final data = await _invoke('read', {
      'source_id': sourceId,
      'channel_id': channelId,
      'time_range': timeRange.toJson(),
      'resolution_hint_max_points': maxPoints,
      'aggregation': aggregation.toWireJson(),
      'allow_gaps': allowGaps,
    });
    return DataBlock.fromJson(
      data['block'] as Map<String, dynamic>? ?? const {},
    );
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _workerFuture.then((worker) => worker.shutdown()).catchError((_) {});
  }

  Future<Map<String, dynamic>> _invoke(
    String operation,
    Map<String, Object?> request,
  ) async {
    if (_disposed) {
      throw BackendException(
        'internal',
        'The native backend has been disposed.',
      );
    }

    final worker = await _workerFuture;
    final envelope = await worker.send(operation, request);
    if (envelope['status'] == 'ok') {
      return Map<String, dynamic>.from(
        envelope['data'] as Map<String, dynamic>? ?? const {},
      );
    }

    final error = envelope['error'] as Map<String, dynamic>? ?? const {};
    throw BackendException(
      error['kind'] as String? ?? 'internal',
      error['message'] as String? ?? 'Unknown backend error.',
    );
  }

  static Iterable<String> _candidateLibraryPaths() sync* {
    final envPath = Platform.environment['DD_FFI_LIBRARY_PATH'];
    if (envPath != null && envPath.isNotEmpty) {
      yield envPath;
    }

    final fileName = _libraryFileName();
    final currentDir = Directory.current.path;
    final executableDir = File(Platform.resolvedExecutable).parent.path;
    final executableParent = Directory(executableDir).parent.path;

    final candidates = <String>[
      '$currentDir/../../target/debug/$fileName',
      '$currentDir/../../target/release/$fileName',
      '$currentDir/../..//target/debug/$fileName',
      '$currentDir/../..//target/release/$fileName',
      '$currentDir/$fileName',
      '$executableDir/$fileName',
      '$executableDir/lib/$fileName',
      '$executableParent/lib/$fileName',
    ];

    for (final candidate in candidates) {
      yield _normalizePath(candidate);
    }
  }

  static String _libraryFileName() {
    if (Platform.isMacOS) {
      return 'libdd_ffi.dylib';
    }
    if (Platform.isWindows) {
      return 'dd_ffi.dll';
    }
    return 'libdd_ffi.so';
  }

  static String _normalizePath(String path) {
    return path.replaceAll('//', '/');
  }
}

class _NativeWorker {
  _NativeWorker._({required Isolate isolate, required SendPort commandPort})
    : _isolate = isolate,
      _commandPort = commandPort;

  final Isolate _isolate;
  final SendPort _commandPort;
  bool _closed = false;

  static Future<_NativeWorker> spawn(String libraryPath) async {
    final readyPort = ReceivePort();
    final isolate = await Isolate.spawn(_nativeWorkerMain, {
      'library_path': libraryPath,
      'ready_port': readyPort.sendPort,
    });
    final commandPort = await readyPort.first as SendPort;
    readyPort.close();
    return _NativeWorker._(isolate: isolate, commandPort: commandPort);
  }

  Future<Map<String, dynamic>> send(
    String operation,
    Map<String, Object?> request,
  ) async {
    if (_closed) {
      return _errorEnvelope('internal', 'Native worker is already closed.');
    }

    final replyPort = ReceivePort();
    _commandPort.send({
      'operation': operation,
      'request': request,
      'reply_port': replyPort.sendPort,
    });
    final message = await replyPort.first;
    replyPort.close();
    return Map<String, dynamic>.from(message as Map);
  }

  void shutdown() {
    if (_closed) {
      return;
    }
    _closed = true;
    final replyPort = ReceivePort();
    _commandPort.send({
      'operation': 'shutdown',
      'reply_port': replyPort.sendPort,
    });
    replyPort.first
        .then((_) {
          replyPort.close();
          _isolate.kill(priority: Isolate.immediate);
        })
        .catchError((_) {
          replyPort.close();
          _isolate.kill(priority: Isolate.immediate);
        });
  }
}

class _NativeBindings {
  const _NativeBindings({
    required this.engineNew,
    required this.engineFree,
    required this.stringFree,
    required this.openSourceJson,
    required this.closeSourceJson,
    required this.catalogJson,
    required this.readJson,
  });

  final _EngineNewDart engineNew;
  final _EngineFreeDart engineFree;
  final _StringFreeDart stringFree;
  final _JsonCommandDart openSourceJson;
  final _JsonCommandDart closeSourceJson;
  final _JsonCommandDart catalogJson;
  final _JsonCommandDart readJson;

  static _NativeBindings load(DynamicLibrary library) {
    return _NativeBindings(
      engineNew: library.lookupFunction<_EngineNewNative, _EngineNewDart>(
        'dd_engine_new',
      ),
      engineFree: library.lookupFunction<_EngineFreeNative, _EngineFreeDart>(
        'dd_engine_free',
      ),
      stringFree: library.lookupFunction<_StringFreeNative, _StringFreeDart>(
        'dd_string_free',
      ),
      openSourceJson: library
          .lookupFunction<_JsonCommandNative, _JsonCommandDart>(
            'dd_engine_open_source_json',
          ),
      closeSourceJson: library
          .lookupFunction<_JsonCommandNative, _JsonCommandDart>(
            'dd_engine_close_source_json',
          ),
      catalogJson: library.lookupFunction<_JsonCommandNative, _JsonCommandDart>(
        'dd_engine_catalog_json',
      ),
      readJson: library.lookupFunction<_JsonCommandNative, _JsonCommandDart>(
        'dd_engine_read_json',
      ),
    );
  }
}

void _nativeWorkerMain(Map<String, Object?> init) {
  final libraryPath = init['library_path'] as String;
  final readyPort = init['ready_port'] as SendPort;
  final commandPort = ReceivePort();
  readyPort.send(commandPort.sendPort);

  final library = DynamicLibrary.open(libraryPath);
  final bindings = _NativeBindings.load(library);
  final engineHandle = bindings.engineNew();
  if (engineHandle == nullptr) {
    commandPort.close();
    return;
  }

  commandPort.listen((dynamic rawMessage) {
    final message = Map<String, Object?>.from(rawMessage as Map);
    final replyPort = message['reply_port'] as SendPort;
    final operation = message['operation'] as String;
    final request = Map<String, Object?>.from(
      message['request'] as Map? ?? const <String, Object?>{},
    );

    try {
      switch (operation) {
        case 'open_source':
          replyPort.send(
            _invokeNativeJson(
              bindings.openSourceJson,
              bindings.stringFree,
              engineHandle,
              request,
            ),
          );
        case 'close_source':
          replyPort.send(
            _invokeNativeJson(
              bindings.closeSourceJson,
              bindings.stringFree,
              engineHandle,
              request,
            ),
          );
        case 'catalog':
          replyPort.send(
            _invokeNativeJson(
              bindings.catalogJson,
              bindings.stringFree,
              engineHandle,
              request,
            ),
          );
        case 'read':
          replyPort.send(
            _invokeNativeJson(
              bindings.readJson,
              bindings.stringFree,
              engineHandle,
              request,
            ),
          );
        case 'shutdown':
          replyPort.send(_errorlessEnvelope());
          commandPort.close();
          bindings.engineFree(engineHandle);
        default:
          replyPort.send(
            _errorEnvelope(
              'internal',
              'Unsupported native worker operation `$operation`.',
            ),
          );
      }
    } catch (error) {
      replyPort.send(
        _errorEnvelope('internal', 'Native worker request failed: $error'),
      );
    }
  });
}

Map<String, dynamic> _invokeNativeJson(
  _JsonCommandDart command,
  _StringFreeDart stringFree,
  Pointer<Void> engineHandle,
  Map<String, Object?> request,
) {
  final requestPointer = jsonEncode(request).toNativeUtf8();
  try {
    final responsePointer = command(engineHandle, requestPointer);
    if (responsePointer == nullptr) {
      return _errorEnvelope(
        'internal',
        'Native command returned a null JSON pointer.',
      );
    }

    try {
      final responseJson = responsePointer.toDartString();
      return Map<String, dynamic>.from(
        jsonDecode(responseJson) as Map<String, dynamic>? ?? const {},
      );
    } catch (error) {
      return _errorEnvelope(
        'internal',
        'Failed to decode native JSON response: $error',
      );
    } finally {
      stringFree(responsePointer);
    }
  } finally {
    malloc.free(requestPointer);
  }
}

Map<String, dynamic> _errorEnvelope(String kind, String message) {
  return <String, dynamic>{
    'status': 'error',
    'error': <String, dynamic>{'kind': kind, 'message': message},
  };
}

Map<String, dynamic> _errorlessEnvelope() {
  return const <String, dynamic>{'status': 'ok', 'data': <String, dynamic>{}};
}
