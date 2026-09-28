package com.example.sempreiot_central_app

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Environment
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * WIFI_CHANNEL: programmatic join of a device's provisioning SoftAP
 * (POC-BRIEF.md §6.2) via WifiNetworkSpecifier (API 29+ — no location
 * permission needed, unlike the legacy WifiManager APIs). The requested
 * network is bound with bindProcessToNetwork() so the app's own HTTP calls
 * to 192.168.4.1 route over the SoftAP even though it has no internet, while
 * everything else on the phone keeps using the normal default network.
 *
 * "connectToSoftAp" result is a bool (true = connected+bound). Errors:
 * UNSUPPORTED_API (< Android 10, caller should fall back to manual Wi-Fi
 * settings via app_settings), TIMEOUT, UNAVAILABLE.
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val STORAGE_CHANNEL = "com.sempreiot.central/storage"
        private const val WIFI_CHANNEL = "com.sempreiot.central/wifi"
    }

    private var wifiNetworkCallback: ConnectivityManager.NetworkCallback? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInternalStorage" -> {
                        try {
                            val path = Environment.getDataDirectory().absolutePath
                            val stat = StatFs(path)
                            val totalBytes = stat.blockCountLong * stat.blockSizeLong
                            val availableBytes = stat.availableBlocksLong * stat.blockSizeLong
                            result.success(
                                mapOf(
                                    "totalBytes" to totalBytes,
                                    "availableBytes" to availableBytes,
                                )
                            )
                        } catch (e: Exception) {
                            result.error("STORAGE_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIFI_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "connectToSoftAp" -> {
                        val ssid = call.argument<String>("ssid")
                        val password = call.argument<String>("password")
                        if (ssid == null || password == null) {
                            result.error("BAD_ARGS", "ssid/password required", null)
                        } else {
                            connectToSoftAp(ssid, password, result)
                        }
                    }
                    "disconnectFromSoftAp" -> {
                        unbindSoftAp()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun connectToSoftAp(ssid: String, password: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("UNSUPPORTED_API", "WifiNetworkSpecifier requires Android 10+", null)
            return
        }

        unbindSoftAp() // drop any previous request first

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(password)
            .build()

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        val connectivityManager =
            getSystemService(ConnectivityManager::class.java) as ConnectivityManager

        var finished = false
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (finished) return
                finished = true
                connectivityManager.bindProcessToNetwork(network)
                result.success(true)
            }

            override fun onUnavailable() {
                if (finished) return
                finished = true
                result.error("UNAVAILABLE", "Could not join $ssid", null)
            }
        }
        wifiNetworkCallback = callback
        connectivityManager.requestNetwork(request, callback, 30_000)
    }

    private fun unbindSoftAp() {
        val connectivityManager =
            getSystemService(ConnectivityManager::class.java) as ConnectivityManager
        connectivityManager.bindProcessToNetwork(null)
        wifiNetworkCallback?.let {
            try {
                connectivityManager.unregisterNetworkCallback(it)
            } catch (_: IllegalArgumentException) {
                // Already unregistered (timeout/onUnavailable fired first) — fine.
            }
        }
        wifiNetworkCallback = null
    }

    override fun onDestroy() {
        unbindSoftAp()
        super.onDestroy()
    }
}
