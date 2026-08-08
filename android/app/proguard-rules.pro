# R8 rules for the release build.
#
# `google_mlkit_text_recognition` compiles one `initialize` method that can
# construct a recognizer for any script — Latin, Chinese, Devanagari, Japanese
# or Korean — and picks between them at runtime. The four non-Latin options come
# from separate Play Services artefacts, and this app depends only on the Latin
# one, because that is what covers English and Indonesian.
#
# So R8 sees four branches referencing classes that are genuinely not on the
# classpath and refuses to shrink. Adding the missing dependencies would ship
# four script models nobody here will use; suppressing the warning is the
# correct half of that trade, and the branches are unreachable at runtime
# because nothing in this app asks for those scripts.
#
# Without these the debug build succeeds and only `--release` fails, which is
# the worst place for it to hide: everyday `flutter run` never touches R8.
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions

# ONNX Runtime reaches its native session through JNI, so the classes on that
# boundary are only ever referenced from C++. R8 cannot see those references and
# would strip them, which fails at model load rather than at build — a crash in
# the one feature this submission is built around.
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**
