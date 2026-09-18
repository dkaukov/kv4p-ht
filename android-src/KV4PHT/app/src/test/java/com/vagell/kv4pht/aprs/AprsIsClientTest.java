/*
kv4p HT (see http://kv4p.com)
Copyright (C) 2024 Vance Vagell

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

package com.vagell.kv4pht.aprs;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.Test;

public class AprsIsClientTest {
    @Test public void passcodeUsesBaseCallsign() {
        assertEquals(13023, AprsIsClient.passcode("N0CALL"));
        assertEquals(13023, AprsIsClient.passcode("n0call-10"));
        assertEquals(13023, AprsIsClient.passcode("N0CALL-0"));
    }

    @Test public void normalizesServerAndSuppliesDefaultPort() {
        assertEquals(AprsIsClient.DEFAULT_SERVER, AprsIsClient.normalizeServer(""));
        assertEquals("aunz.aprs2.net:14580",
            AprsIsClient.normalizeServer("aunz.aprs2.net"));
        assertEquals("example.net:12345",
            AprsIsClient.normalizeServer("example.net:12345"));
        assertEquals("[2001:db8::1]:14580",
            AprsIsClient.normalizeServer("[2001:db8::1]"));
        assertNull(AprsIsClient.normalizeServer("https://example.net:14580/"));
        assertNull(AprsIsClient.normalizeServer("user@example.net:14580"));
        assertNull(AprsIsClient.normalizeServer("example.net:70000"));
    }

    @Test public void persistentSessionLogsInAndSendsQueuedPackets() throws Exception {
        List<String> received = Collections.synchronizedList(new ArrayList<>());
        CountDownLatch packetsReceived = new CountDownLatch(2);
        CountDownLatch callbacks = new CountDownLatch(2);
        ExecutorService serverWorker = Executors.newSingleThreadExecutor();
        try (ServerSocket server = new ServerSocket(0)) {
            serverWorker.execute(() -> serveVerifiedSession(server, received, packetsReceived));
            try (AprsIsClient client = new AprsIsClient("2.0 test")) {
                assertTrue(client.setServer("127.0.0.1:" + server.getLocalPort()));
                client.setCallsign("vk3abc-9");
                client.setTransmitEnabled(true);
                client.setEnabled(true);

                assertTrue(client.send("VK3ABC-9", "VK3RF>APRS,qAO,VK3ABC-9:>one",
                    callbacks::countDown));
                assertTrue(client.send("VK3ABC-9", "VK3RF>APRS,qAO,VK3ABC-9:>two",
                    callbacks::countDown));

                assertTrue(packetsReceived.await(5, TimeUnit.SECONDS));
                assertTrue(callbacks.await(5, TimeUnit.SECONDS));
                assertEquals("user VK3ABC-9 pass " + AprsIsClient.passcode("VK3ABC-9")
                    + " vers KV4PHT 2.0_test", received.get(0));
                assertEquals("VK3RF>APRS,qAO,VK3ABC-9:>one", received.get(1));
                assertEquals("VK3RF>APRS,qAO,VK3ABC-9:>two", received.get(2));
            }
        } finally {
            serverWorker.shutdownNow();
        }
    }

    @Test public void disabledInvalidCallsignAndMultilinePacketsAreRejected() {
        try (AprsIsClient client = new AprsIsClient("2.0")) {
            assertFalse(client.send("VK3ABC", "VK3RF>APRS:>disabled", null));
            client.setEnabled(true);
            assertFalse(client.send("VK3ABC", "VK3RF>APRS:>receive only", null));
            assertFalse(client.send("", "VK3RF>APRS:>test", null));
            assertFalse(client.send("VK3ABC", "VK3RF>APRS:>test\r\nsecond", null));
        }
    }

    @Test public void loginUsesAprsIsSyntax() {
        assertEquals("user VK3ABC pass 21675 vers KV4PHT 2.0",
            AprsIsClient.loginLine("VK3ABC", 21675, "2.0", false, null, null));
        assertEquals("user VK3ABC pass 21675 vers KV4PHT 2.0 filter m/50",
            AprsIsClient.loginLine("VK3ABC", 21675, "2.0", true, null, null));
        assertEquals("user VK3ABC pass -1 vers KV4PHT 2.0 "
                + "filter r/-37.81360/144.96310/50",
            AprsIsClient.loginLine("VK3ABC", -1, "2.0", true,
                -37.8136, 144.9631));
    }

    @Test public void receiveModeRequestsNearbyFeedAndDeliversOnlyPackets() throws Exception {
        List<String> received = Collections.synchronizedList(new ArrayList<>());
        CountDownLatch packetDelivered = new CountDownLatch(1);
        ExecutorService serverWorker = Executors.newSingleThreadExecutor();
        try (ServerSocket server = new ServerSocket(0)) {
            serverWorker.execute(() -> serveIncomingPacket(server, received));
            try (AprsIsClient client = new AprsIsClient("2.0", packet -> {
                received.add(packet);
                packetDelivered.countDown();
            })) {
                assertTrue(client.setServer("127.0.0.1:" + server.getLocalPort()));
                client.setCallsign("VK3ABC");
                client.setReceiveEnabled(true);
                client.setEnabled(true);

                assertTrue(packetDelivered.await(5, TimeUnit.SECONDS));
                assertEquals("user VK3ABC pass -1 vers KV4PHT 2.0 filter m/50",
                    received.get(0));
                assertEquals("VK3RF>APRS,qAO,VK3ABC:>nearby", received.get(1));
            }
        } finally {
            serverWorker.shutdownNow();
        }
    }

    private static void serveVerifiedSession(ServerSocket server, List<String> received,
                                             CountDownLatch packetsReceived) {
        try (Socket socket = server.accept()) {
            socket.setSoTimeout(5_000);
            BufferedReader reader = new BufferedReader(new InputStreamReader(
                socket.getInputStream(), StandardCharsets.ISO_8859_1));
            BufferedWriter writer = new BufferedWriter(new OutputStreamWriter(
                socket.getOutputStream(), StandardCharsets.ISO_8859_1));
            writer.write("# aprsc test server\r\n");
            writer.flush();
            received.add(reader.readLine());
            writer.write("# logresp VK3ABC-9 verified, server TEST\r\n");
            writer.flush();
            for (int i = 0; i < 2; i++) {
                received.add(reader.readLine());
                packetsReceived.countDown();
            }
        } catch (Exception ignored) {
            // The assertions time out with the captured context if the test server fails.
        }
    }

    private static void serveIncomingPacket(ServerSocket server, List<String> received) {
        try (Socket socket = server.accept()) {
            socket.setSoTimeout(5_000);
            BufferedReader reader = new BufferedReader(new InputStreamReader(
                socket.getInputStream(), StandardCharsets.ISO_8859_1));
            BufferedWriter writer = new BufferedWriter(new OutputStreamWriter(
                socket.getOutputStream(), StandardCharsets.ISO_8859_1));
            writer.write("# aprsc test server\r\n");
            writer.flush();
            received.add(reader.readLine());
            writer.write("# logresp VK3ABC unverified, server TEST\r\n");
            writer.write("# keepalive\r\n");
            writer.write("VK3RF>APRS,qAO,VK3ABC:>nearby\r\n");
            writer.flush();
        } catch (Exception ignored) {
            // The assertion times out with the captured context if the test server fails.
        }
    }
}
