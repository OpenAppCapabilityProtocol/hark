Architecture & Implementation Plan: hark_platform Plugin

1. The Problem

Hark's native Android integration is expanding rapidly (Wake Word Service, OACP discovery, etc.). Currently, native communication relies on a single MethodChannel registered in MainActivity.

This breaks down when introducing a second FlutterEngine (e.g., for background services or a separate Overlay Activity). A channel registered on the main engine is isolated; calls from a second engine will return null. This is a hard constraint of Flutter's architecture.

2. The Solution: Plugin + EngineGroup + Pigeon

To safely support multiple engines, we will:

Create a Flutter plugin package (hark_platform) that registers shared APIs during onAttachedToEngine(). This guarantees the API exists on every engine.

Use FlutterEngineGroup to share resources (VM, GPU context) between engines, reducing the memory overhead of the overlay.

Replace stringly-typed MethodChannel calls with Pigeon for type-safe, generated Dart/Kotlin bindings.

Move the overlay to a dedicated OverlayActivity, eliminating the fragile "dual-mode" single-activity hacks.

3. Architecture Overview

┌──────────────────────────────────────────────────────┐
│                 HarkApplication                      │
│  FlutterEngineGroup (singleton, process lifecycle)   │
│                                                      │
│  mainEngine ──► FlutterEngineCache["main"]           │
│    └─ Created in onCreate()                          │
│    └─ GeneratedPluginRegistrant.registerWith()       │
│                                                      │
│  overlayEngine ──► FlutterEngineCache["overlay"]     │
│    └─ Created LAZILY (on first use or deferred)      │
│    └─ GeneratedPluginRegistrant.registerWith()       │
└──────┬──────────────────────────────┬────────────────┘
       │                              │
┌──────▼──────────────────────────────▼────────────────┐
│                    Android OS                        │
│  VoiceInteractionService  ·  WakeWordService         │
└──────────┬───────────────────────┬───────────────────┘
           │                       │  Requires SYSTEM_ALERT_WINDOW
           │  assist gesture       │  "Hey Hark" (Intent)
           ▼                       ▼
┌──────────────────────────────────────────────────────┐
│            OverlayActivity (Kotlin)                  │
│            translucent=true (static XML theme)       │
│                                                      │
│  ┌────────────────────────────────────────────────┐  │
│  │  FlutterFragment (cached "overlay" engine)     │  │
│  │  RenderMode.texture / Transparency transparent │  │
│  │  Dart entrypoint: overlayMain()                │  │
│  │                                                │  │
│  │  APIs registered:                              │  │
│  │    HarkCommonApi  → by plugin (auto)           │  │
│  │    HarkOverlayApi → by OverlayActivity         │  │
│  │    HarkOverlayFlutterApi ← to Dart (Session)   │  │
│  └────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────┐
│              MainActivity (Flutter host)             │
│              Normal opaque Flutter app               │
│                                                      │
│  ┌────────────────────────────────────────────────┐  │
│  │  FlutterEngine (cached "main" engine)          │  │
│  │  Dart entrypoint: main()                       │  │
│  │                                                │  │
│  │  APIs registered:                              │  │
│  │    HarkCommonApi  → by plugin (auto)           │  │
│  │    HarkMainApi    → by MainActivity            │  │
│  └────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────┘



4. API Responsibility Split

APIs are strictly split by where they are registered to prevent circular dependencies and memory leaks.

API

Registered by

Scope

Needs Activity?

HarkCommonApi

HarkPlatformPlugin

all engines

No (ApplicationContext only)

HarkOverlayApi

OverlayActivity

overlay only

Yes (finish(), etc.)

HarkMainApi

MainActivity

main only

Yes (startActivity())

HarkOverlayFlutterApi

OverlayActivity

overlay only

No (Native calling Dart)

5. Critical Technical Guardrails

These principles must be followed to avoid memory leaks, crashes, and OS restrictions:

Lazy Engine Startup: Do not pre-warm both engines synchronously in Application.onCreate(). Create the main engine immediately. Create the overlay engine lazily on the first invocation, or defer it to a background thread seconds after app launch to preserve Time-To-First-Frame (TTFF).

Mandatory Activity Teardown: Cached engines outlive Activities. OverlayActivity and MainActivity must unregister their specific APIs in onDestroy() by passing null to the setup method. Failure to do this will cause the cached engine to hold a strong reference to a dead Activity (Memory Leak) and route subsequent calls into the void.

Session Nonce for State Reset: Do not rely on WidgetsBindingObserver for overlay lifecycle resets. The native layer must generate a unique sessionId (e.g., UUID) on every overlay launch and pass it to Dart using the @FlutterApi. Dart monitors this nonce and wipes the transcript/state when it changes.

Background Launch & Service Permissions: Android 10+ restricts background services from launching Activities. WakeWordService must check for and request the SYSTEM_ALERT_WINDOW (Display over other apps) permission to reliably fire the Intent that launches OverlayActivity. Additionally, for Android 14+ (API 34), the background listener must explicitly declare android:foregroundServiceType="microphone" in the manifest.

6. Pigeon Schema (pigeons/messages.dart)

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/src/messages.g.dart',
  kotlinOut: 'android/src/main/kotlin/com/oacp/hark_platform/Messages.g.kt',
  kotlinOptions: KotlinOptions(package: 'com.oacp.hark_platform'),
))

enum LlmProvider { claude, openai, selfhosted }

class LlmConfig {
  final LlmProvider provider;
  final String? apiKey;
  final String? endpoint;
}

// ── Cross-engine API (registered by plugin on every engine) ──
@HostApi()
abstract class HarkCommonApi {
  LlmConfig getLlmConfig();
  @async bool isDefaultAssistant();
  void startWakeWordService();
  void stopWakeWordService();
  @async bool isWakeWordRunning();
}

// ── Native calling Dart (registered in Dart, called by Kotlin) ──
@FlutterApi()
abstract class HarkOverlayFlutterApi {
  // Pass session nonce from Native to Dart to force overlay state reset
  void onNewSession(String sessionId);
}

// ── Activity-specific APIs (registered explicitly by Activities) ──
@HostApi()
abstract class HarkOverlayApi {
  void dismiss();
  void openFullApp();
}

@HostApi()
abstract class HarkMainApi {
  void openAssistantSettings();
}



7. Implementation Templates

A. Engine Teardown Example (OverlayActivity.kt)

class OverlayActivity : FragmentActivity() {
    private var engine: FlutterEngine? = null
    private var flutterApi: HarkOverlayFlutterApi? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_overlay)

        engine = FlutterEngineCache.getInstance().get("overlay")
        
        engine?.let {
            // 1. Register Activity-bound HostApi
            HarkOverlayApi.setUp(it.dartExecutor.binaryMessenger, OverlayApiHandler())
            
            // 2. Setup FlutterApi to talk to Dart
            flutterApi = HarkOverlayFlutterApi(it.dartExecutor.binaryMessenger)
            
            // 3. Notify Dart of the new session so it can clear state
            val sessionId = java.util.UUID.randomUUID().toString()
            flutterApi?.onNewSession(sessionId) {}
        }

        // ... attach FlutterFragment with transparency ...
    }

    override fun onDestroy() {
        // CRITICAL: Teardown API so cached engine drops Activity reference
        engine?.let {
            HarkOverlayApi.setUp(it.dartExecutor.binaryMessenger, null)
        }
        flutterApi = null
        super.onDestroy()
    }
}



B. Plugin Implementation (HarkPlatformPlugin.kt)

class HarkPlatformPlugin : FlutterPlugin, HarkCommonApi {
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        context = binding.applicationContext
        HarkCommonApi.setUp(binding.binaryMessenger, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {
        // Drop references
        HarkCommonApi.setUp(binding.binaryMessenger, null)
        context = null
    }
    
    // ... Implement getLlmConfig (EncryptedSharedPreferences), WakeWord starts, etc. ...
}



8. Rollout & Migration Plan

Step 1: Scaffold packages/hark_platform, define messages.dart, and run Pigeon generator.

Step 2: Implement HarkCommonApi inside HarkPlatformPlugin and migrate existing global features (like LLM Config & Default Assistant checks). Remove old MethodChannels.

Step 3: Setup HarkApplication and FlutterEngineGroup. Initialize the main engine. Wire up MainActivity with HarkMainApi and ensure explicit onDestroy teardown.

Step 4: Implement lazy initialization for the overlay engine.

Step 5: Create OverlayActivity (translucent), overlayMain() Dart entrypoint, and HarkOverlayApi (with explicit teardown).

Step 6: Strip out old Phase 4 "dual-mode" code (Riverpod OverlayController, GoRouter redirects, transparency hacks).

Step 7: Implement native WakeWordService. Add the permission flow for SYSTEM_ALERT_WINDOW so the service can fire the OverlayActivity Intent from the background. Make sure to declare android:foregroundServiceType="microphone".

Step 8: Audit all external third-party plugins (audio, permissions) to ensure they do not crash when registered across multiple engines simultaneously.
cd