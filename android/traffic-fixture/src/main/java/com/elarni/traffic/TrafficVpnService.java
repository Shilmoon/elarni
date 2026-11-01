package com.elarni.traffic;

import android.content.Intent;
import android.net.VpnService;
import android.os.ParcelFileDescriptor;
import java.io.IOException;

/** Another app's VPN for acceptance checks; it routes only an unused test range. */
public final class TrafficVpnService extends VpnService {
    private ParcelFileDescriptor tunnel;
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (tunnel == null) tunnel = new Builder().setSession("Traffic fixture").addAddress("10.111.0.1", 32).addRoute("10.111.0.0", 24).establish();
        return START_NOT_STICKY;
    }
    @Override public void onRevoke() { close(); stopSelf(); }
    @Override public void onDestroy() { close(); }
    private void close() {
        try { if (tunnel != null) tunnel.close(); } catch (IOException ignored) { }
        tunnel = null;
    }
}
