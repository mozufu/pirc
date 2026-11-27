# ML Kit discovers registrars from Android manifest metadata via reflection.
# AGP 9 / R8 no longer implicitly retain a default constructor with a class-only keep.
-keep class * implements com.google.firebase.components.ComponentRegistrar {
    public <init>();
}
