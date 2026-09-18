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

import android.util.Log;
import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.net.URISyntaxException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Pattern;

/** Persistent APRS-IS transport for packets accepted by the controller's iGate policy. */
public final class AprsIsClient implements AutoCloseable {
    private static final String TAG = "AprsIsClient";
    public static final String DEFAULT_SERVER = "rotate.aprs2.net:14580";
    private static final int DEFAULT_PORT = 14580;
    private static final int MAX_PACKET_BYTES = 510;
    private static final int MAX_PENDING_PACKETS = 4;
    private static final int CONNECT_TIMEOUT_MS = 10_000;
    private static final int LOGIN_TIMEOUT_MS = 10_000;
    private static final int READ_POLL_MS = 1_000;
    private static final long INITIAL_RECONNECT_DELAY_MS = 1_000;
    private static final long MAX_RECONNECT_DELAY_MS = 60_000;
    private static final double MIN_FILTER_MOVE_KM = 5.0;
    private static final Pattern AX25_CALLSIGN = Pattern.compile(
        "^[A-Z0-9]{3,6}(?:-[A-Z0-9]{1,2})?$");

    private final Object lock = new Object();
    private final String softwareVersion;
    private final IncomingPacketListener incomingPacketListener;
    private final ArrayDeque<PendingPacket> pendingPackets = new ArrayDeque<>();
    private final ExecutorService worker;
    private ServerAddress server = parseServer(DEFAULT_SERVER);
    private String callsign = "";
    private boolean enabled;
    private boolean receiveEnabled;
    private boolean transmitEnabled;
    private Double filterLatitude;
    private Double filterLongitude;
    private boolean closed;
    private long configurationGeneration;
    private Socket activeSocket;

    public AprsIsClient(String softwareVersion) {
        this(softwareVersion, packet -> { });
    }

    public AprsIsClient(String softwareVersion, IncomingPacketListener incomingPacketListener) {
        this.softwareVersion = singleWord(softwareVersion);
        this.incomingPacketListener = incomingPacketListener;
        worker = Executors.newSingleThreadExecutor(runnable -> {
            Thread thread = new Thread(runnable, "APRS-IS connection");
            thread.setDaemon(true);
            return thread;
        });
        worker.execute(this::runConnectionLoop);
    }

    /** Receives non-comment APRS-IS packets from the configured filtered feed. */
    public interface IncomingPacketListener {
        void onPacket(String packet);
    }

    /** Enables or disables the persistent connection. Disabling also discards queued packets. */
    public void setEnabled(boolean enabled) {
        synchronized (lock) {
            if (this.enabled == enabled) return;
            this.enabled = enabled;
            configurationGeneration++;
            if (!enabled) pendingPackets.clear();
            disconnectLocked();
            lock.notifyAll();
        }
    }

    /** Selects the APRSdroid-compatible nearby feed and whether received packets are exposed. */
    public void setReceiveEnabled(boolean enabled) {
        synchronized (lock) {
            if (receiveEnabled == enabled) return;
            receiveEnabled = enabled;
            configurationGeneration++;
            disconnectLocked();
            lock.notifyAll();
        }
    }

    /** Selects whether this session must authenticate for APRS-IS packet injection. */
    public void setTransmitEnabled(boolean enabled) {
        synchronized (lock) {
            if (transmitEnabled == enabled) return;
            transmitEnabled = enabled;
            configurationGeneration++;
            disconnectLocked();
            lock.notifyAll();
        }
    }

    /** Updates the explicit receive-filter center after meaningful phone movement. */
    public void setFilterLocation(Double latitude, Double longitude) {
        boolean valid = isValidLocation(latitude, longitude);
        Double nextLatitude = valid ? latitude : null;
        Double nextLongitude = valid ? longitude : null;
        synchronized (lock) {
            if (sameFilterLocation(nextLatitude, nextLongitude)) return;
            filterLatitude = nextLatitude;
            filterLongitude = nextLongitude;
            configurationGeneration++;
            disconnectLocked();
            lock.notifyAll();
        }
    }

    /** Changes the APRS-IS host and optional port, reconnecting if necessary. */
    public boolean setServer(String value) {
        ServerAddress parsed = parseServer(value);
        if (parsed == null) return false;
        synchronized (lock) {
            if (parsed.normalized.equals(server.normalized)) return true;
            server = parsed;
            configurationGeneration++;
            disconnectLocked();
            lock.notifyAll();
        }
        return true;
    }

    /** Updates the callsign used for APRS-IS authentication. */
    public void setCallsign(String value) {
        String normalized = normalizeCallsign(value);
        synchronized (lock) {
            if (normalized.equals(callsign)) return;
            callsign = normalized;
            configurationGeneration++;
            disconnectLocked();
            lock.notifyAll();
        }
    }

    /** Queues one packet without blocking the radio/controller thread. */
    public boolean send(String value, String packet, Runnable onSuccess) {
        String normalized = normalizeCallsign(value);
        if (!isValidPacket(packet) || !AX25_CALLSIGN.matcher(normalized).matches()) {
            return false;
        }
        synchronized (lock) {
            if (closed || !enabled || !transmitEnabled
                    || pendingPackets.size() >= MAX_PENDING_PACKETS) {
                return false;
            }
            if (!normalized.equals(callsign)) {
                callsign = normalized;
                configurationGeneration++;
                disconnectLocked();
            }
            pendingPackets.addLast(new PendingPacket(packet, onSuccess));
            lock.notifyAll();
            return true;
        }
    }

    /** Returns a normalized {@code host:port}, or {@code null} when the value is invalid. */
    public static String normalizeServer(String value) {
        ServerAddress parsed = parseServer(value);
        return parsed == null ? null : parsed.normalized;
    }

    static int passcode(String value) {
        String baseCall = normalizeCallsign(value).split("-", 2)[0];
        int hash = 0x73e2;
        for (int i = 0; i < baseCall.length(); i += 2) {
            hash ^= baseCall.charAt(i) << 8;
            if (i + 1 < baseCall.length()) hash ^= baseCall.charAt(i + 1);
        }
        return hash & 0x7fff;
    }

    static String loginLine(String callsign, int passcode, String softwareVersion,
                            boolean receiveEnabled, Double latitude, Double longitude) {
        String login = "user " + callsign + " pass " + passcode
            + " vers KV4PHT " + softwareVersion;
        if (!receiveEnabled) return login;
        if (isValidLocation(latitude, longitude)) {
            return login + String.format(Locale.US, " filter r/%.5f/%.5f/50",
                latitude, longitude);
        }
        return login + " filter m/50";
    }

    private void runConnectionLoop() {
        long reconnectDelay = INITIAL_RECONNECT_DELAY_MS;
        while (true) {
            ConnectionConfiguration configuration = awaitConfiguration();
            if (configuration == null) return;
            boolean loggedIn = runSession(configuration);
            if (loggedIn) {
                reconnectDelay = INITIAL_RECONNECT_DELAY_MS;
            }
            clearActiveSocket();
            if (!loggedIn) {
                logInfo("Reconnecting to APRS-IS in " + reconnectDelay + " ms");
            }
            if (!awaitReconnect(reconnectDelay)) return;
            if (!loggedIn) {
                reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY_MS);
            }
        }
    }

    private ConnectionConfiguration awaitConfiguration() {
        synchronized (lock) {
            while (!closed && (!enabled || server == null
                    || !AX25_CALLSIGN.matcher(callsign).matches())) {
                try {
                    lock.wait();
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return null;
                }
            }
            return closed ? null
                : new ConnectionConfiguration(server, callsign, receiveEnabled,
                    transmitEnabled, filterLatitude, filterLongitude,
                    configurationGeneration);
        }
    }

    private boolean runSession(ConnectionConfiguration configuration) {
        // Port 14580 is APRS-IS's standardized plaintext feed; its passcode is not a secret.
        Socket socket = new Socket(); // NOSONAR
        boolean loggedIn = false;
        try {
            logInfo("Connecting to APRS-IS " + configuration.server.normalized
                + " as " + configuration.callsign + ", receive="
                + configuration.receiveEnabled + ", transmit="
                + configuration.transmitEnabled + ", filter="
                + filterDescription(configuration));
            synchronized (lock) {
                if (!isCurrent(configuration)) return false;
                activeSocket = socket;
            }
            socket.connect(new InetSocketAddress(configuration.server.host,
                configuration.server.port), CONNECT_TIMEOUT_MS);
            socket.setKeepAlive(true);
            socket.setTcpNoDelay(true);
            socket.setSoTimeout(LOGIN_TIMEOUT_MS);

            BufferedReader reader = new BufferedReader(new InputStreamReader(
                socket.getInputStream(), StandardCharsets.ISO_8859_1));
            BufferedWriter writer = new BufferedWriter(new OutputStreamWriter(
                socket.getOutputStream(), StandardCharsets.ISO_8859_1));
            if (reader.readLine() == null) throw new IOException("APRS-IS closed before login");
            int loginPasscode = configuration.transmitEnabled
                ? passcode(configuration.callsign) : -1;
            writeLine(writer, loginLine(configuration.callsign, loginPasscode, softwareVersion,
                configuration.receiveEnabled, configuration.filterLatitude,
                configuration.filterLongitude));
            awaitLogin(reader, configuration.callsign, configuration.transmitEnabled);
            loggedIn = true;
            logInfo("APRS-IS login accepted for " + configuration.callsign);
            socket.setSoTimeout(READ_POLL_MS);
            drainSession(reader, writer, configuration);
        } catch (IOException error) {
            if (isCurrent(configuration)) {
                logWarning("APRS-IS session failed: " + error.getMessage(), error);
            } else {
                logDebug("APRS-IS session closed after configuration change");
            }
        } finally {
            closeQuietly(socket);
        }
        return loggedIn;
    }

    private void awaitLogin(BufferedReader reader, String expectedCallsign,
                            boolean requireVerified)
            throws IOException {
        String expected = "# LOGRESP " + expectedCallsign.toUpperCase(Locale.ROOT) + " ";
        while (true) {
            String line = reader.readLine();
            if (line == null) throw new IOException("APRS-IS closed during login");
            String normalized = line.toUpperCase(Locale.ROOT);
            if (normalized.startsWith(expected)) {
                if (normalized.contains(" VERIFIED") || (!requireVerified
                        && normalized.contains(" UNVERIFIED"))) return;
                throw new IOException("APRS-IS login was not verified");
            }
            if (normalized.startsWith("# LOGRESP ")) {
                throw new IOException("Unexpected APRS-IS login response: " + line);
            }
            if (normalized.startsWith("# LOGIN") || normalized.startsWith("# ERROR")) {
                throw new IOException("APRS-IS rejected login: " + line);
            }
        }
    }

    private void drainSession(BufferedReader reader, BufferedWriter writer,
                              ConnectionConfiguration configuration) throws IOException {
        boolean receivingLogged = false;
        while (isCurrent(configuration)) {
            PendingPacket pending;
            synchronized (lock) {
                pending = pendingPackets.pollFirst();
            }
            if (pending != null) {
                writeLine(writer, pending.packet);
                runSuccessCallback(pending.onSuccess);
                continue;
            }
            try {
                String line = reader.readLine();
                if (line == null) throw new IOException("APRS-IS connection closed");
                if (configuration.receiveEnabled && !line.startsWith("#")
                        && isValidPacket(line)) {
                    deliverIncomingPacket(line);
                    if (!receivingLogged) {
                        logInfo("Receiving APRS-IS packets");
                        receivingLogged = true;
                    }
                }
            } catch (SocketTimeoutException ignored) {
                // Poll configuration and the outgoing queue again.
            }
        }
    }

    private boolean isCurrent(ConnectionConfiguration configuration) {
        synchronized (lock) {
            return !closed && enabled
                && configuration.generation == configurationGeneration;
        }
    }

    private boolean awaitReconnect(long delayMs) {
        synchronized (lock) {
            if (closed) return false;
            try {
                lock.wait(delayMs);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return false;
            }
            return !closed;
        }
    }

    private void clearActiveSocket() {
        synchronized (lock) {
            activeSocket = null;
        }
    }

    private void disconnectLocked() {
        if (activeSocket != null) closeQuietly(activeSocket);
    }

    private static void runSuccessCallback(Runnable callback) {
        if (callback == null) return;
        try {
            callback.run();
        } catch (RuntimeException ignored) {
            // A persistence callback must not terminate the APRS-IS connection worker.
        }
    }

    private void deliverIncomingPacket(String packet) {
        if (incomingPacketListener == null) return;
        try {
            incomingPacketListener.onPacket(packet);
        } catch (RuntimeException ignored) {
            // A parser/UI failure must not terminate the APRS-IS connection worker.
        }
    }

    private static void writeLine(BufferedWriter writer, String line) throws IOException {
        writer.write(line);
        writer.write("\r\n");
        writer.flush();
    }

    private static String filterDescription(ConnectionConfiguration configuration) {
        if (!configuration.receiveEnabled) return "none";
        if (isValidLocation(configuration.filterLatitude, configuration.filterLongitude)) {
            return String.format(Locale.US, "r/%.5f/%.5f/50",
                configuration.filterLatitude, configuration.filterLongitude);
        }
        return "m/50";
    }

    private static void logDebug(String message) {
        try {
            Log.d(TAG, message);
        } catch (RuntimeException ignored) {
            // android.util.Log is unavailable in local JVM unit tests.
        }
    }

    private static void logInfo(String message) {
        try {
            Log.i(TAG, message);
        } catch (RuntimeException ignored) {
            // android.util.Log is unavailable in local JVM unit tests.
        }
    }

    private static void logWarning(String message, Throwable error) {
        try {
            Log.w(TAG, message, error);
        } catch (RuntimeException ignored) {
            // android.util.Log is unavailable in local JVM unit tests.
        }
    }

    private static boolean isValidPacket(String packet) {
        return packet != null && !packet.contains("\r") && !packet.contains("\n")
            && packet.getBytes(StandardCharsets.ISO_8859_1).length <= MAX_PACKET_BYTES;
    }

    private static String normalizeCallsign(String value) {
        if (value == null) return "";
        String normalized = value.trim().toUpperCase(Locale.ROOT);
        return normalized.endsWith("-0")
            ? normalized.substring(0, normalized.length() - 2) : normalized;
    }

    private static String singleWord(String value) {
        if (value == null || value.trim().isEmpty()) return "unknown";
        return value.trim().replaceAll("\\s+", "_");
    }

    private boolean sameFilterLocation(Double latitude, Double longitude) {
        if (latitude == null || longitude == null
                || filterLatitude == null || filterLongitude == null) {
            return latitude == null && longitude == null
                && filterLatitude == null && filterLongitude == null;
        }
        return distanceKm(filterLatitude, filterLongitude, latitude, longitude)
            < MIN_FILTER_MOVE_KM;
    }

    private static boolean isValidLocation(Double latitude, Double longitude) {
        return latitude != null && longitude != null
            && Double.isFinite(latitude) && Double.isFinite(longitude)
            && latitude >= -90 && latitude <= 90
            && longitude >= -180 && longitude <= 180;
    }

    private static double distanceKm(double fromLatitude, double fromLongitude,
                                     double toLatitude, double toLongitude) {
        double latitudeDelta = Math.toRadians(toLatitude - fromLatitude);
        double longitudeDelta = Math.toRadians(toLongitude - fromLongitude);
        double fromRadians = Math.toRadians(fromLatitude);
        double toRadians = Math.toRadians(toLatitude);
        double a = Math.sin(latitudeDelta / 2) * Math.sin(latitudeDelta / 2)
            + Math.cos(fromRadians) * Math.cos(toRadians)
            * Math.sin(longitudeDelta / 2) * Math.sin(longitudeDelta / 2);
        double bounded = Math.max(0, Math.min(1, a));
        return 6371.0 * 2 * Math.atan2(Math.sqrt(bounded), Math.sqrt(1 - bounded));
    }

    private static ServerAddress parseServer(String value) {
        String candidate = value == null || value.trim().isEmpty()
            ? DEFAULT_SERVER : value.trim();
        try {
            URI uri = new URI("aprs://" + candidate);
            if (uri.getHost() == null || uri.getRawUserInfo() != null
                    || uri.getRawQuery() != null || uri.getRawFragment() != null
                    || (uri.getRawPath() != null && !uri.getRawPath().isEmpty())) {
                return null;
            }
            int port = uri.getPort() < 0 ? DEFAULT_PORT : uri.getPort();
            if (port < 1 || port > 65_535) return null;
            String host = uri.getHost();
            if (host.startsWith("[") && host.endsWith("]")) {
                host = host.substring(1, host.length() - 1);
            }
            String displayHost = host.contains(":") ? "[" + host + "]" : host;
            return new ServerAddress(host, port, displayHost + ":" + port);
        } catch (URISyntaxException | IllegalArgumentException ignored) {
            return null;
        }
    }

    private static void closeQuietly(Socket socket) {
        try {
            socket.close();
        } catch (IOException ignored) {
            // Best-effort shutdown during reconfiguration or service destruction.
        }
    }

    @Override public void close() {
        synchronized (lock) {
            closed = true;
            enabled = false;
            pendingPackets.clear();
            disconnectLocked();
            lock.notifyAll();
        }
        worker.shutdownNow();
    }

    private static final class PendingPacket {
        private final String packet;
        private final Runnable onSuccess;

        private PendingPacket(String packet, Runnable onSuccess) {
            this.packet = packet;
            this.onSuccess = onSuccess;
        }
    }

    private static final class ServerAddress {
        private final String host;
        private final int port;
        private final String normalized;

        private ServerAddress(String host, int port, String normalized) {
            this.host = host;
            this.port = port;
            this.normalized = normalized;
        }
    }

    private static final class ConnectionConfiguration {
        private final ServerAddress server;
        private final String callsign;
        private final boolean receiveEnabled;
        private final boolean transmitEnabled;
        private final Double filterLatitude;
        private final Double filterLongitude;
        private final long generation;

        private ConnectionConfiguration(ServerAddress server, String callsign,
                                        boolean receiveEnabled, boolean transmitEnabled,
                                        Double filterLatitude, Double filterLongitude,
                                        long generation) {
            this.server = server;
            this.callsign = callsign;
            this.receiveEnabled = receiveEnabled;
            this.transmitEnabled = transmitEnabled;
            this.filterLatitude = filterLatitude;
            this.filterLongitude = filterLongitude;
            this.generation = generation;
        }
    }
}
