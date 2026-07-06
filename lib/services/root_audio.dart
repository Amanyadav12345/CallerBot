import 'telephony_service.dart';

/// Root-level audio helpers for injecting the message into the cellular call's
/// uplink (so the far end hears the actual file, not a speaker echo).
///
/// The exact mixer path is device-specific, so we first probe the device with
/// [diagnostics] to discover the available ALSA cards, PCM devices and mixer
/// controls, then wire injection to the route that feeds the voice uplink.
class RootAudio {
  /// Dumps everything needed to map this device's in-call audio routing:
  /// chipset, available tools (tinymix/tinyplay), ALSA cards/PCMs, and the
  /// voice/incall mixer controls.
  static const String _diagnosticsScript = r'''
echo "=== ROOT CHECK ==="
id
echo
echo "=== DEVICE ==="
getprop ro.product.manufacturer
getprop ro.product.model
getprop ro.board.platform
getprop ro.hardware
getprop ro.soc.manufacturer
getprop ro.soc.model
echo
echo "=== AUDIO TOOLS ==="
for t in tinymix tinyplay tinycap tinypcminfo; do
  p=$(command -v $t 2>/dev/null)
  echo "$t: ${p:-not found}"
done
ls -l /system/bin/tinymix /vendor/bin/tinymix /system/bin/tinyplay /vendor/bin/tinyplay 2>/dev/null
echo
echo "=== ALSA CARDS ==="
cat /proc/asound/cards 2>/dev/null
echo
echo "=== ALSA PCM DEVICES ==="
cat /proc/asound/pcm 2>/dev/null
echo
echo "=== MIXER / AUDIO CONFIG FILES ==="
ls -l /vendor/etc/*mixer* /vendor/etc/*audio* /system/etc/*mixer* 2>/dev/null
echo
echo "=== MIXER CONTROLS (tinymix) ==="
tinymix 2>/dev/null | head -n 400
echo
echo "=== INCALL / VOICE / UPLINK ROUTES ==="
grep -riE "incall|voice|voip|uplink|mmap|tx" /vendor/etc/*mixer*.xml 2>/dev/null | head -n 150
echo
echo "=== END ==="
''';

  static Future<RootResult> diagnostics() =>
      TelephonyService.runRoot(_diagnosticsScript);
}
