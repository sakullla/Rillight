# core_bridge.cpp resolves these Java callbacks and constructors by JNI name.
# R8 cannot see native-to-Java calls; the default native-method rule only
# protects Java-to-native entrypoints and their descriptor class names.
-keep class com.rillight.player.CoreNative { native <methods>; }
-keep class com.rillight.player.CoreIoFactory {
    public com.rillight.player.CoreInput open(java.lang.String);
}
-keep class com.rillight.player.CoreInput {
    public int read(byte[], int);
    public long seek(long, int);
    public void close();
    public void interrupt();
}
-keep class com.rillight.player.CoreAudioFrame {
    public <init>(long, long, long, byte[]);
}
-keep class com.rillight.player.CoreVideoOverlay {
    public <init>(int, int, int, int, int, int, byte[]);
}

-keep class com.rillight.player.CoreTunnelFactory { public *; }
-keep class com.rillight.player.CoreTunnelDecoder { public *; }
