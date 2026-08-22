# TensorFlow Lite's GPU delegate can reference this optional API even when the
# GPU delegate artifact is not bundled. The app uses the standard CPU
# Interpreter, so R8 may safely ignore that unavailable optional class.
-dontwarn org.tensorflow.lite.gpu.GpuDelegateFactory$Options
