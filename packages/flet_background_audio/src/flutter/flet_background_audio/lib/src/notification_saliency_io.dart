import "dart:ffi";
import "dart:io";
import "dart:isolate";
import "dart:typed_data";

import "package:flutter/services.dart" show rootBundle;

import "notification_saliency.dart";

const _asset = "packages/flet_background_audio/assets/u2netp_256_int8.tflite";
// Inference is rare, once per new artwork, so a few cores finish it quickly
// without starving playback.
const _threads = 4;
const _inputValues = saliencyModelSize * saliencyModelSize * 3;
const _outputValues = saliencyModelSize * saliencyModelSize;

SaliencyModel createSaliencyModel() => _TfliteSaliencyModel();

class _TfliteSaliencyModel implements SaliencyModel {
  Future<int?>? _interpreter;
  Future<void> _queue = Future.value();

  @override
  Future<Float32List?> predict(Uint8List rgba) {
    // A TensorFlow Lite interpreter must not run two inferences at once.
    final result = _queue.then((_) => _predict(rgba));
    _queue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<Float32List?> _predict(Uint8List rgba) async {
    final interpreter = await (_interpreter ??= _load());
    if (interpreter == null) return null;
    final input = saliencyInput(rgba);
    // The interpreter lives in native memory, so a background isolate can run
    // it by address while the UI isolate keeps drawing frames.
    return Isolate.run(() => _invoke(interpreter, input));
  }

  Future<int?> _load() async {
    // The package bundles the LiteRT runtime only for Android. Elsewhere the
    // pure Dart detector takes over.
    if (!Platform.isAndroid) return null;
    try {
      final model = (await rootBundle.load(_asset)).buffer.asUint8List();
      // Building the interpreter repacks the weights for XNNPACK, which takes
      // long enough to drop frames on the UI isolate.
      return await Isolate.run(() => _create(model));
    } catch (_) {
      // A missing runtime or damaged asset must not break artwork preparation.
      return null;
    }
  }
}

/// Address of a ready interpreter for the [model] flatbuffer, which is int8
/// inside with float32 input and output.
int _create(Uint8List model) {
  final api = _TfLite.instance;
  // The interpreter reads the weights from this buffer for its whole life,
  // which is the life of the app, so the buffer is never freed.
  final data = api.malloc(model.length);
  if (data == nullptr) throw StateError("Out of memory for the model");
  data.asTypedList(model.length).setAll(0, model);
  final handle = api.modelCreate(data.cast(), model.length);
  if (handle == nullptr) throw StateError("Invalid saliency model");
  final options = api.optionsCreate();
  api.optionsSetNumThreads(options, _threads);
  // Unlike the Java and Python APIs, the C API leaves XNNPACK off. Without it
  // this int8 model runs on reference kernels that take seconds, so no
  // XNNPACK means no model. Start from LiteRT's own defaults and change only
  // the thread count. The delegate must outlive the interpreter, so it is
  // never freed either.
  final xnnpack = api.malloc(sizeOf<_XnnpackOptions>()).cast<_XnnpackOptions>();
  if (xnnpack == nullptr) throw StateError("Out of memory for XNNPACK");
  xnnpack.ref = api.xnnpackOptionsDefault();
  xnnpack.cast<Int32>().value = _threads; // num_threads is the first field
  final delegate = api.xnnpackCreate(xnnpack);
  if (delegate == nullptr) throw StateError("XNNPACK is unavailable");
  api.optionsAddDelegate(options, delegate);
  final interpreter = api.interpreterCreate(handle, options);
  api.optionsDelete(options);
  // The interpreter keeps its own reference to the model.
  api.modelDelete(handle);
  if (interpreter == nullptr) throw StateError("No interpreter");
  if (api.allocateTensors(interpreter) != _ok ||
      api.tensorByteSize(api.inputTensor(interpreter, 0)) != _inputValues * 4 ||
      api.tensorByteSize(api.outputTensor(interpreter, 0)) !=
          _outputValues * 4) {
    throw StateError("Unexpected saliency model tensors");
  }
  return interpreter.address;
}

Float32List _invoke(int address, Float32List input) {
  final api = _TfLite.instance;
  final interpreter = Pointer<Void>.fromAddress(address);
  api
      .tensorData(api.inputTensor(interpreter, 0))
      .cast<Float>()
      .asTypedList(_inputValues)
      .setAll(0, input);
  if (api.invoke(interpreter) != _ok) {
    throw StateError("Saliency inference failed");
  }
  final output = api
      .tensorData(api.outputTensor(interpreter, 0))
      .cast<Float>()
      .asTypedList(_outputValues);
  // Copy out of native memory that the next inference reuses.
  return Float32List.fromList(output);
}

const _ok = 0; // kTfLiteOk

typedef _Handle = Pointer<Void>;

/// Storage for TfLiteXNNPackDelegateOptions, which starts with
/// `int32_t num_threads`. It is larger than any LiteRT version of the struct:
/// every Android ABI returns a struct this size through caller memory, so the
/// callee fills in its real fields and the rest stays unused.
final class _XnnpackOptions extends Struct {
  @Array(64)
  external Array<Int64> storage;
}

/// The TensorFlow Lite C API exported by LiteRT's JNI library.
final class _TfLite {
  _TfLite._(DynamicLibrary lite, DynamicLibrary libc)
    : malloc = libc
          .lookupFunction<
            Pointer<Uint8> Function(Size),
            Pointer<Uint8> Function(int)
          >("malloc"),
      modelCreate = lite
          .lookupFunction<
            _Handle Function(_Handle, Size),
            _Handle Function(_Handle, int)
          >("TfLiteModelCreate"),
      modelDelete = lite
          .lookupFunction<Void Function(_Handle), void Function(_Handle)>(
            "TfLiteModelDelete",
          ),
      optionsCreate = lite
          .lookupFunction<_Handle Function(), _Handle Function()>(
            "TfLiteInterpreterOptionsCreate",
          ),
      optionsSetNumThreads = lite
          .lookupFunction<
            Void Function(_Handle, Int32),
            void Function(_Handle, int)
          >("TfLiteInterpreterOptionsSetNumThreads"),
      optionsDelete = lite
          .lookupFunction<Void Function(_Handle), void Function(_Handle)>(
            "TfLiteInterpreterOptionsDelete",
          ),
      optionsAddDelegate = lite
          .lookupFunction<
            Void Function(_Handle, _Handle),
            void Function(_Handle, _Handle)
          >("TfLiteInterpreterOptionsAddDelegate"),
      xnnpackOptionsDefault = lite
          .lookupFunction<
            _XnnpackOptions Function(),
            _XnnpackOptions Function()
          >("TfLiteXNNPackDelegateOptionsDefault"),
      xnnpackCreate = lite
          .lookupFunction<
            _Handle Function(Pointer<_XnnpackOptions>),
            _Handle Function(Pointer<_XnnpackOptions>)
          >("TfLiteXNNPackDelegateCreate"),
      interpreterCreate = lite
          .lookupFunction<
            _Handle Function(_Handle, _Handle),
            _Handle Function(_Handle, _Handle)
          >("TfLiteInterpreterCreate"),
      allocateTensors = lite
          .lookupFunction<Int32 Function(_Handle), int Function(_Handle)>(
            "TfLiteInterpreterAllocateTensors",
          ),
      inputTensor = lite
          .lookupFunction<
            _Handle Function(_Handle, Int32),
            _Handle Function(_Handle, int)
          >("TfLiteInterpreterGetInputTensor"),
      outputTensor = lite
          .lookupFunction<
            _Handle Function(_Handle, Int32),
            _Handle Function(_Handle, int)
          >("TfLiteInterpreterGetOutputTensor"),
      invoke = lite
          .lookupFunction<Int32 Function(_Handle), int Function(_Handle)>(
            "TfLiteInterpreterInvoke",
          ),
      tensorByteSize = lite
          .lookupFunction<Size Function(_Handle), int Function(_Handle)>(
            "TfLiteTensorByteSize",
          ),
      tensorData = lite
          .lookupFunction<_Handle Function(_Handle), _Handle Function(_Handle)>(
            "TfLiteTensorData",
          );

  /// One binding per isolate; the library itself is loaded once per process.
  static final instance = _TfLite._(
    DynamicLibrary.open("libtensorflowlite_jni.so"),
    DynamicLibrary.process(),
  );

  final Pointer<Uint8> Function(int) malloc;
  final _Handle Function(_Handle, int) modelCreate;
  final void Function(_Handle) modelDelete;
  final _Handle Function() optionsCreate;
  final void Function(_Handle, int) optionsSetNumThreads;
  final void Function(_Handle) optionsDelete;
  final void Function(_Handle, _Handle) optionsAddDelegate;
  final _XnnpackOptions Function() xnnpackOptionsDefault;
  final _Handle Function(Pointer<_XnnpackOptions>) xnnpackCreate;
  final _Handle Function(_Handle, _Handle) interpreterCreate;
  final int Function(_Handle) allocateTensors;
  final _Handle Function(_Handle, int) inputTensor;
  final _Handle Function(_Handle, int) outputTensor;
  final int Function(_Handle) invoke;
  final int Function(_Handle) tensorByteSize;
  final _Handle Function(_Handle) tensorData;
}
