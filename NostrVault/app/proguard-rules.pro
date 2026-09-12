# Nostr Vault ProGuard Rules

# Keep JNI bridge methods (called from native code)
-keep class com.nostrvault.relay.HavenBridge { *; }
-keep class com.nostrvault.fips.FipsBridge { *; }

# Keep Kotlin serialization
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt

-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.nostrvault.**$$serializer { *; }
-keepclassmembers class com.nostrvault.** {
    *** Companion;
}
-keepclasseswithmembers class com.nostrvault.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Keep data classes used with serialization
-keep class com.nostrvault.data.model.** { *; }
-keep class com.nostrvault.relay.HavenConfig { *; }
