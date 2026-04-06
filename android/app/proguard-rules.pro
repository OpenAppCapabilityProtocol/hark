# MediaPipe (flutter_gemma inference engine)
-keep class com.google.mediapipe.** { *; }
-dontwarn com.google.mediapipe.**

# Protocol Buffers
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.protobuf.**

# RAG functionality
-keep class com.google.ai.edge.localagents.** { *; }
-dontwarn com.google.ai.edge.localagents.**

# ONNX Runtime (EmbeddingGemma inference)
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**
