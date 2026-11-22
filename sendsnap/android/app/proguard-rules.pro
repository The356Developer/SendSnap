# Suppress compile-time JDK annotation processor references pulled in transitively by MediaPipe/AutoValue
-dontwarn javax.lang.model.**

# Suppress optional MediaPipe profiler/template proto classes referenced by kept framework classes
-dontwarn com.google.mediapipe.proto.**

# Preserve MediaPipe JNI classes and callbacks in release builds
-keep class com.google.mediapipe.** { *; }

# Preserve Google Flogger (MediaPipe Graph.<clinit> uses FluentLogger.forEnclosingClass() stack walking)
-keep class com.google.common.flogger.** { *; }
-dontwarn com.google.common.flogger.**

# Preserve Protobuf Lite classes used by MediaPipe Tasks Vision
-keep class * extends com.google.protobuf.GeneratedMessageLite { *; }
