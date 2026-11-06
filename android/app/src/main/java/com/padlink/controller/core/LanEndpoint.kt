package com.padlink.controller.core

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Network
import java.net.Inet4Address
import java.net.Inet6Address

/** Prefer IPv4; preserve numeric IPv6 scope for the native SocketAddr parser. */
data class WifiPairingRoute(val network: Network, val endpoint: String)
fun wifiPairingEndpoint(context: Context): String? = wifiPairingRoute(context)?.endpoint
@Suppress("DEPRECATION") // Includes eligible Wi-Fi when cellular is the default.
fun wifiPairingRoute(context: Context): WifiPairingRoute? {
    val manager = context.getSystemService(ConnectivityManager::class.java)
    val addresses = manager.allNetworks.asSequence()
        .filter { network -> manager.getNetworkCapabilities(network)?.let { it.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) && !it.hasTransport(NetworkCapabilities.TRANSPORT_VPN) } == true }
        .flatMap { network -> manager.getLinkProperties(network)?.linkAddresses.orEmpty().asSequence().map { network to it.address } }
        .filter { (_, address) -> !address.isLoopbackAddress && !address.isAnyLocalAddress && !address.isMulticastAddress }
        .toList()
    addresses.firstOrNull { (_, address) -> address is Inet4Address && !address.isLinkLocalAddress }?.let { (network, address) ->
        return WifiPairingRoute(network, "${address.hostAddress}:41337")
    }
    val (network, addressValue) = addresses.firstOrNull { (_, address) -> address is Inet6Address && (!address.isLinkLocalAddress || address.scopeId > 0) } ?: return null
    val ipv6 = addressValue as Inet6Address
    val address = ipv6.hostAddress?.substringBefore('%') ?: return null
    val scope = if (ipv6.scopeId > 0) "%${ipv6.scopeId}" else ""
    return WifiPairingRoute(network, "[$address$scope]:41337")
}
