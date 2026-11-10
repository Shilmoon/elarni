package com.elarni.traffic;

import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;

/** Each flavor has its own UID so the real Android connection-owner API is exercised. */
public final class TrafficActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView text = new TextView(this); text.setText("Synthetic Elarni traffic check"); setContentView(text);
        String token = getIntent().getStringExtra("token");
        String mode = getIntent().getStringExtra("mode");
        if ("vpn".equals(mode)) {
            // Consent comes from appops; prepare() then makes this app the current VPN.
            if (android.net.VpnService.prepare(this) == null) startService(new android.content.Intent(this, TrafficVpnService.class));
            finish();
            return;
        }
        String address = getIntent().getStringExtra("address");
        int port = getIntent().getIntExtra("port", 0);
        new Thread(() -> {
            JSONObject result = new JSONObject();
            try {
                result.put("token", token);
                if (!android.os.Build.MODEL.contains("sdk_gphone") || token == null || !token.matches("[a-z0-9]+") ||
                    !("10.0.2.2".equals(address) || "198.18.0.81".equals(address) || "fdfe:dcba:9876::10".equals(address)) || port < 1024 || port > 65535) throw new IOException("Invalid fixture scope");
                InetAddress target = InetAddress.getByName(address);
                android.net.ConnectivityManager connectivity = getSystemService(android.net.ConnectivityManager.class);
                android.net.Network active = connectivity.getActiveNetwork();
                android.net.NetworkCapabilities capabilities = connectivity.getNetworkCapabilities(active);
                result.put("network", active == null ? "none" : active.toString());
                result.put("vpn", capabilities != null && capabilities.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN));
                if ("systemDns".equals(mode)) {
                    if (capabilities == null || !capabilities.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) throw new IOException("Resolver fixture requires active VPN");
                    StringBuilder answers = new StringBuilder();
                    for (InetAddress answer : InetAddress.getAllByName(token.substring(0,24) + ".elarni.test")) answers.append(answer.getHostAddress()).append("\n");
                    result.put("body", answers.toString());
                } else if ("tcp".equals(mode) || "httpProxy".equals(mode) || "socksProxy".equals(mode)) {
                    String proxyAddress = getIntent().getStringExtra("proxyAddress");
                    int proxyPort = getIntent().getIntExtra("proxyPort", 0);
                    boolean proxy = !"tcp".equals(mode);
                    if (proxy && (proxyAddress == null || NetworkInterface.getByInetAddress(InetAddress.getByName(proxyAddress)) == null || proxyPort < 1024 || proxyPort > 65535)) throw new IOException("Proxy fixture must be on this emulator");
                    // Off the VPN, Elarni is not on the path: a loaded host that answers late gets one more try,
                    // as a reload would. Through the VPN a stall is what the checks look for, so it fails at once.
                    boolean direct = capabilities == null || !capabilities.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN);
                    for (int attempt = 1; ; attempt++) {
                        try (Socket socket = new Socket()) {
                            socket.setSoTimeout(4000); socket.connect(new InetSocketAddress(proxy ? InetAddress.getByName(proxyAddress) : target, proxy ? proxyPort : port), 4000);
                            if ("socksProxy".equals(mode)) {
                                OutputStream output = socket.getOutputStream(); DataInputStream input = new DataInputStream(socket.getInputStream());
                                output.write(new byte[]{5,1,2});
                                if (input.readUnsignedByte()!=5 || input.readUnsignedByte()!=2) throw new IOException("SOCKS authentication not selected");
                                byte[] user="fixture-user".getBytes(StandardCharsets.US_ASCII), password="fixture-password".getBytes(StandardCharsets.US_ASCII);
                                output.write(1); output.write(user.length); output.write(user); output.write(password.length); output.write(password);
                                if (input.readUnsignedByte()!=1 || input.readUnsignedByte()!=0) throw new IOException("SOCKS login rejected");
                                output.write(new byte[]{5,1,0,1}); output.write(target.getAddress()); output.write(port>>8); output.write(port);
                                if (input.readUnsignedByte()!=5 || input.readUnsignedByte()!=0) throw new IOException("SOCKS connect rejected");
                                input.readByte(); int kind=input.readUnsignedByte(); int length=kind==1?4:kind==4?16:input.readUnsignedByte();
                                input.readFully(new byte[length+2]);
                            }
                            String requestTarget = "httpProxy".equals(mode) ? "http://"+address+":"+port+"/fixture" : "/fixture";
                            String login = "httpProxy".equals(mode) ? "Proxy-Authorization: Basic "+android.util.Base64.encodeToString("fixture-user:fixture-password".getBytes(StandardCharsets.US_ASCII), android.util.Base64.NO_WRAP)+"\r\n" : "";
                            socket.getOutputStream().write(("GET "+requestTarget+" HTTP/1.1\r\nHost: fixture.elarni.test\r\n"+login+"Connection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                            ByteArrayOutputStream bytes = new ByteArrayOutputStream(); byte[] buffer = new byte[1024];
                            int count; while ((count = socket.getInputStream().read(buffer)) > 0) { bytes.write(buffer, 0, count); if (bytes.size() > 8192) throw new IOException("Response too large"); }
                            result.put("body", bytes.toString("UTF-8"));
                            break;
                        } catch (SocketTimeoutException timeout) { if (!direct || attempt == 2) throw timeout; }
                    }
                } else {
                    byte[] payload = "elarni-udp-fixture".getBytes(StandardCharsets.US_ASCII);
                    if ("dns".equals(mode)) payload = new byte[]{0x12,0x34,1,0,0,1,0,0,0,0,0,0,7,'f','i','x','t','u','r','e',4,'t','e','s','t',0,0,1,0,1};
                    try (DatagramSocket socket = new DatagramSocket()) {
                        // Like a stub resolver, send again each second within the 4 s budget: one lost datagram
                        // on a loaded emulator must not fail the check.
                        byte[] bytes = new byte[8192]; DatagramPacket packet = new DatagramPacket(bytes, bytes.length);
                        socket.setSoTimeout(1000);
                        for (int attempt = 1; ; attempt++) {
                            socket.send(new DatagramPacket(payload, payload.length, target, port));
                            try { socket.receive(packet); break; }
                            catch (SocketTimeoutException timeout) { if (attempt == 4) throw timeout; }
                        }
                        if ("dns".equals(mode)) {
                            int offset = packet.getLength() - 4;
                            if (offset < 12 || bytes[0] != 0x12 || bytes[1] != 0x34) throw new IOException("Invalid DNS reply");
                            result.put("body", (bytes[offset]&255)+"."+(bytes[offset+1]&255)+"."+(bytes[offset+2]&255)+"."+(bytes[offset+3]&255));
                        } else result.put("body", new String(bytes, 0, packet.getLength(), StandardCharsets.US_ASCII));
                    }
                }
                result.put("success", true);
            } catch (Exception error) { try { result.put("success", false); result.put("error", error.toString()); } catch (Exception ignored) { } }
            try (FileOutputStream file = openFileOutput("result.json", MODE_PRIVATE)) { file.write(result.toString().getBytes(StandardCharsets.UTF_8)); file.getFD().sync(); }
            catch (Exception ignored) { }
            runOnUiThread(this::finish);
        }, "Synthetic traffic").start();
    }
}
