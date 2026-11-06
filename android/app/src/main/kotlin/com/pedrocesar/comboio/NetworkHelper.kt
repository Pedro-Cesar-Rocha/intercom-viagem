package com.pedrocesar.comboio

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Informações de rede para a descoberta da sala e, nos convidados, a
 * vinculação do processo ao Wi-Fi (para o Android não mandar o tráfego da
 * sala pelos dados móveis quando o hotspot não tem internet).
 */
class NetworkHelper(context: Context) {
    private val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private var boundNetwork: Network? = null

    companion object {
        private val NON_HOTSPOT_PREFIXES = listOf(
            "rmnet", "ccmni", "clat", "v4-", "dummy", "tun", "ppp", "ip6tnl",
            "ipsec", "seth", "radio", "lo", "p2p", "rev_rmnet", "umts", "sit",
        )
    }

    @Suppress("DEPRECATION")
    private fun findWifiNetwork(): Network? {
        var fallback: Network? = null
        for (n in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(n) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
            val lp = cm.getLinkProperties(n) ?: continue
            if (lp.linkAddresses.any { it.address is Inet4Address }) return n
            if (fallback == null) fallback = n
        }
        return fallback
    }

    private fun describe(network: Network?): Map<String, Any?>? {
        if (network == null) return null
        val lp: LinkProperties = cm.getLinkProperties(network) ?: return null
        val la = lp.linkAddresses.firstOrNull { it.address is Inet4Address }
        var gateway: String? = null
        for (route in lp.routes) {
            val gw = route.gateway
            if (route.isDefaultRoute && gw is Inet4Address && !gw.isAnyLocalAddress) {
                gateway = gw.hostAddress
                break
            }
        }
        val dhcp = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            lp.dhcpServerAddress?.hostAddress
        } else {
            null
        }
        val caps = cm.getNetworkCapabilities(network)
        val validated = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) ?: false
        return mapOf(
            "iface" to lp.interfaceName,
            "ip" to la?.address?.hostAddress,
            "prefix" to (la?.prefixLength ?: 24),
            "gateway" to gateway,
            "dhcp" to dhcp,
            "validated" to validated,
            "handle" to network.networkHandle,
        )
    }

    /** Interfaces com IPv4 que não são o Wi-Fi cliente nem dados móveis. */
    private fun hotspotInterfaces(wifiIface: String?): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        val all = try {
            NetworkInterface.getNetworkInterfaces()?.toList() ?: emptyList()
        } catch (e: Exception) {
            emptyList()
        }
        for (ni in all) {
            try {
                if (!ni.isUp || ni.isLoopback) continue
                val name = ni.name ?: continue
                if (name == wifiIface) continue
                if (NON_HOTSPOT_PREFIXES.any { name.startsWith(it) }) continue
                for (ia in ni.interfaceAddresses) {
                    val addr = ia.address
                    if (addr is Inet4Address && !addr.isLoopbackAddress && !addr.isLinkLocalAddress) {
                        out.add(
                            mapOf(
                                "iface" to name,
                                "ip" to addr.hostAddress,
                                "prefix" to ia.networkPrefixLength.toInt(),
                            )
                        )
                    }
                }
            } catch (e: Exception) {
                // interface sumiu no meio da leitura
            }
        }
        return out
    }

    fun info(): Map<String, Any?> {
        val wifi = describe(findWifiNetwork())
        return mapOf(
            "wifi" to wifi,
            "hotspot" to hotspotInterfaces(wifi?.get("iface") as String?),
            "bound" to (boundNetwork != null),
        )
    }

    fun bindToWifi(): Map<String, Any?> {
        val network = findWifiNetwork()
        val wifi = describe(network)
        var bound = false
        if (network != null) {
            bound = try {
                cm.bindProcessToNetwork(network)
            } catch (e: Exception) {
                false
            }
            boundNetwork = if (bound) network else null
        } else if (boundNetwork != null) {
            unbind()
        }
        return mapOf(
            "wifi" to wifi,
            "hotspot" to hotspotInterfaces(wifi?.get("iface") as String?),
            "bound" to bound,
        )
    }

    fun unbind() {
        try {
            cm.bindProcessToNetwork(null)
        } catch (e: Exception) {
        }
        boundNetwork = null
    }
}
