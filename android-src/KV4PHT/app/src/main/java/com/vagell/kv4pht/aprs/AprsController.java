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

import androidx.lifecycle.LiveData;
import androidx.lifecycle.MutableLiveData;
import com.vagell.kv4pht.aprs.parser.APRSPacket;
import com.vagell.kv4pht.aprs.parser.APRSTypes;
import com.vagell.kv4pht.aprs.parser.Digipeater;
import com.vagell.kv4pht.aprs.parser.InformationField;
import com.vagell.kv4pht.aprs.parser.MessagePacket;
import com.vagell.kv4pht.aprs.parser.ObjectField;
import com.vagell.kv4pht.aprs.parser.Parser;
import com.vagell.kv4pht.aprs.parser.PositionField;
import com.vagell.kv4pht.aprs.parser.StationCapabilitiesField;
import com.vagell.kv4pht.aprs.parser.StatusField;
import com.vagell.kv4pht.aprs.parser.ThirdPartyField;
import com.vagell.kv4pht.aprs.parser.Utilities;
import com.vagell.kv4pht.aprs.parser.WeatherField;
import com.vagell.kv4pht.data.AprsEvent;
import com.vagell.kv4pht.data.AprsEventDao;
import com.vagell.kv4pht.data.AprsFeedRow;
import com.vagell.kv4pht.data.AprsPacket;
import com.vagell.kv4pht.data.AprsPacketDao;
import com.vagell.kv4pht.data.AprsSource;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executor;
import java.util.concurrent.atomic.AtomicLong;
import java.util.stream.Collectors;

/**
 * Owns APRS parsing, event aggregation, packet history, retries, beacon cadence, and digipeating.
 *
 * <p>{@link AprsPacket} records transport facts and is normally immutable. {@link AprsEvent}
 * records one user-visible occurrence and may aggregate multiple received copies, retries, and a
 * delivery response. The normal UI observes events; packet history remains available for future
 * diagnostics and iGate work.</p>
 */
public final class AprsController {
    public static final String HISTORY_ONE_DAY = "1d";
    public static final String HISTORY_ONE_WEEK = "1w";
    public static final String HISTORY_TWO_WEEKS = "2w";
    public static final String HISTORY_ONE_MONTH = "1m";
    public static final String HISTORY_ALL = "all";
    public static final String DESTINATION_ALL = "all";
    public static final String DESTINATION_MINE = "mine";

    private static final long DAY_MS = 24 * 60 * 60_000L;
    private static final long[] RETRY_DELAYS_MS = {15_000L, 30_000L, 60_000L, 120_000L, 240_000L};
    private static final long FINAL_ACK_GRACE_MS = 30_000L;
    private static final long BEACON_INTERVAL_MS = 5 * 60_000L;
    private static final int MAX_VISIBLE_EVENTS = 5_000;
    private static final long EVENT_DUPLICATE_WINDOW_MS = 30_000L;
    private static final long NUMBERED_MESSAGE_DUPLICATE_WINDOW_MS = 30 * 60_000L;
    private static final long DIGIPEAT_DEDUP_MS = 28_000L;
    private static final long RETRY_SCHEDULE_UNINITIALIZED = Long.MIN_VALUE;
    private static final long NO_RETRY_SCHEDULED = Long.MAX_VALUE;

    /** Persistence boundary for immutable packet history. */
    public interface PacketRepository {
        long insert(AprsPacket packet);
    }

    /** Persistence boundary for user-visible APRS events and delivery state. */
    public interface EventRepository {
        List<AprsFeedRow> loadFeed(long sinceMs, String localCallsign, boolean mineOnly,
                                   int limit);
        List<AprsEvent> loadDueReliableEvents(long now);
        Long loadNextReliableRetryAt();
        long insert(AprsEvent event, String feedKey);
        void update(AprsEvent event);
        AprsEvent findById(long id);
        AprsEvent findRecentByDedupKey(String dedupKey, long sinceMs);
        AprsEvent findPendingOutgoingEvent(String localCallsign, String remoteCallsign,
                                           String messageIdentifier);
    }

    /** A packet accepted by the radio callback, ready to record as transmitted. */
    public static final class Transmission {
        public final APRSPacket packet;
        public final Long frequencyHz;
        public final byte[] rawAx25;

        public Transmission(APRSPacket packet, Long frequencyHz, byte[] rawAx25) {
            this.packet = packet;
            this.frequencyHz = frequencyHz;
            this.rawAx25 = rawAx25 == null ? null : Arrays.copyOf(rawAx25, rawAx25.length);
        }
    }

    /** Android, radio, and notification capabilities supplied by the service. */
    public interface Callbacks {
        String getCallsign();
        void showNotification(String title, String message);
        void sendAcknowledgement(String destination, String messageIdentifier, long eventId);
        Transmission retryMessage(AprsEvent event);
        void requestPositionBeacon();
        Transmission transmitDigipeatedPacket(APRSPacket packet);
        boolean gateToAprsIs(String tnc2, Long eventId);
    }

    public static final class RoomPacketRepository implements PacketRepository {
        private final AprsPacketDao dao;

        public RoomPacketRepository(AprsPacketDao dao) {
            this.dao = dao;
        }

        @Override public long insert(AprsPacket packet) {
            return dao.insert(packet);
        }
    }

    public static final class RoomEventRepository implements EventRepository {
        private final AprsEventDao dao;

        public RoomEventRepository(AprsEventDao dao) {
            this.dao = dao;
        }

        @Override public List<AprsFeedRow> loadFeed(long sinceMs, String localCallsign,
                                                    boolean mineOnly, int limit) {
            if (mineOnly) {
                return dao.getMineFeedSince(
                    sinceMs, AprsEvent.MESSAGE_TYPE, localCallsign, limit);
            }
            return dao.getFeedSince(sinceMs, limit);
        }

        @Override public List<AprsEvent> loadDueReliableEvents(long now) {
            return dao.getDueReliableEvents(AprsEvent.DELIVERY_PENDING, now);
        }

        @Override public Long loadNextReliableRetryAt() {
            return dao.getNextReliableRetryAt(AprsEvent.DELIVERY_PENDING);
        }

        @Override public long insert(AprsEvent event, String feedKey) {
            return dao.insertWithFeed(event, feedKey);
        }

        @Override public void update(AprsEvent event) {
            dao.update(event);
        }

        @Override public AprsEvent findById(long id) {
            return dao.getById(id);
        }

        @Override public AprsEvent findRecentByDedupKey(String dedupKey, long sinceMs) {
            return dao.getRecentByDedupKey(dedupKey, sinceMs);
        }

        @Override public AprsEvent findPendingOutgoingEvent(String localCallsign,
                                                            String remoteCallsign,
                                                            String messageIdentifier) {
            return dao.getPendingOutgoingEvent(localCallsign, remoteCallsign, messageIdentifier,
                AprsEvent.DELIVERY_PENDING);
        }
    }

    private final PacketRepository packetRepository;
    private final EventRepository eventRepository;
    private final Executor executor;
    private final Callbacks callbacks;
    private final MutableLiveData<List<AprsFeedRow>> feed = new MutableLiveData<>();
    private final Map<String, Long> digipeatInputCache = new ConcurrentHashMap<>();
    private final Map<String, Long> digipeatOutputCache = new ConcurrentHashMap<>();
    private volatile boolean positionBeaconingEnabled;
    private volatile long nextPositionBeaconAt;
    private final AtomicLong nextReliableRetryAt = new AtomicLong(RETRY_SCHEDULE_UNINITIALIZED);
    private volatile boolean digipeatingEnabled;
    private volatile boolean igateEnabled;
    private volatile String historyWindow = HISTORY_ALL;
    private volatile String destinationFilter = DESTINATION_ALL;

    public AprsController(PacketRepository packetRepository, EventRepository eventRepository,
                          Executor executor, Callbacks callbacks) {
        this.packetRepository = packetRepository;
        this.eventRepository = eventRepository;
        this.executor = executor;
        this.callbacks = callbacks;
        refreshFeed();
    }

    public LiveData<List<AprsFeedRow>> getFeed() {
        return feed;
    }

    public boolean isPositionBeaconingEnabled() {
        return positionBeaconingEnabled;
    }

    public void setDigipeatingEnabled(boolean enabled) {
        digipeatingEnabled = enabled;
    }

    /** Enables standards-filtered, one-way forwarding from RF to APRS-IS. */
    public void setIgateEnabled(boolean enabled) {
        igateEnabled = enabled;
    }

    /** Selects how much event history is exposed to the normal APRS UI. */
    public void setHistoryWindow(String value) {
        historyWindow = normalizeHistoryWindow(value);
        refreshFeed();
    }

    /** Selects whether the UI shows every message destination or only local/broadcast traffic. */
    public void setDestinationFilter(String value) {
        destinationFilter = DESTINATION_MINE.equalsIgnoreCase(value)
            ? DESTINATION_MINE : DESTINATION_ALL;
        refreshFeed();
    }

    /** Processes one decoded packet and associates it with a user event when possible. */
    public void handle(APRSPacket packet) {
        handle(packet, AprsSource.UNKNOWN, null, null);
    }

    /** Processes one decoded packet together with its transport metadata. */
    public void handle(APRSPacket packet, String source, Long frequencyHz, byte[] rawAx25) {
        handleDecoded(packet, source, frequencyHz, rawAx25, null);
    }

    /** Parses and displays one APRS-IS line without making it eligible for RF transmission. */
    public void handleAprsIsPacket(String tnc2) {
        if (tnc2 == null || tnc2.trim().isEmpty()) return;
        try {
            handleDecoded(Parser.parse(tnc2), AprsSource.RX_APRS_IS, null, null, tnc2);
        } catch (Exception ignored) {
            // Ignore malformed Internet input just as the RF parser ignores malformed frames.
        }
    }

    private void handleDecoded(APRSPacket packet, String source, Long frequencyHz,
                               byte[] rawAx25, String rawTnc2) {
        boolean receivedFromRf = AprsSource.RX_RF.equals(source);
        if (receivedFromRf && isRecentlyDigipeated(packet)) return;
        Transmission digipeated = receivedFromRf ? maybeDigipeat(packet) : null;
        AprsPacket packetRecord = physicalPacket(packet, source, frequencyHz, rawAx25, rawTnc2);
        PacketContext context = unwrap(packet);
        ParsedEvent parsed = context == null ? null : parseEvent(context);
        if (parsed != null && parsed.event != null) {
            parsed.event.internetOnly = AprsSource.RX_APRS_IS.equals(source);
        }
        executor.execute(() -> persistIncoming(packet, packetRecord, parsed, digipeated));
    }

    private void persistIncoming(APRSPacket frame, AprsPacket packet, ParsedEvent parsed,
                                 Transmission digipeated) {
        AprsEvent event = persistPacket(packet, parsed);
        if (digipeated != null) {
            recordTransmissionNow(event == null ? null : event.id, digipeated, true);
        }
        if (AprsSource.RX_RF.equals(packet.source)) {
            maybeGateToAprsIs(frame, event == null ? null : event.id);
        }
        refreshFeed();
    }

    private AprsEvent persistPacket(AprsPacket packet, ParsedEvent parsed) {
        if (parsed == null) {
            packetRepository.insert(packet);
            return null;
        }
        if (parsed.acknowledgement || parsed.rejection) {
            return persistDeliveryResponse(packet, parsed);
        }
        if (parsed.event != null) return persistEvent(packet, parsed.event);
        packetRepository.insert(packet);
        return null;
    }

    private AprsEvent persistDeliveryResponse(AprsPacket packet, ParsedEvent response) {
        AprsEvent event = eventRepository.findPendingOutgoingEvent(response.targetCallsign,
            response.fromCallsign, response.messageIdentifier);
        if (event == null) {
            packetRepository.insert(packet);
            return null;
        }
        event.deliveryState = response.acknowledgement
            ? AprsEvent.DELIVERY_DELIVERED : AprsEvent.DELIVERY_REJECTED;
        event.nextRetryAtMs = null;
        associatePacket(event, packet);
        return event;
    }

    private AprsEvent persistEvent(AprsPacket packet, AprsEvent candidate) {
        AprsEvent event = eventRepository.findRecentByDedupKey(candidate.dedupKey,
            candidate.lastSeenMs - duplicateWindowMs(candidate));
        boolean created = event == null;
        if (created) {
            candidate.packetCount = 1;
            candidate.id = eventRepository.insert(candidate, feedKey(candidate));
            event = candidate;
            packet.eventId = event.id;
            packetRepository.insert(packet);
        } else {
            mergeObservation(event, candidate);
            associatePacket(event, packet);
        }
        if (event.type == AprsEvent.MESSAGE_TYPE) {
            notifyAndAcknowledge(event, created, packet.source);
        }
        return event;
    }

    private void mergeObservation(AprsEvent event, AprsEvent observation) {
        event.lastSeenMs = observation.lastSeenMs;
        event.relayCallsign = observation.relayCallsign;
        event.internetOnly &= observation.internetOnly;
    }

    private void associatePacket(AprsEvent event, AprsPacket packet) {
        packet.eventId = event.id;
        packetRepository.insert(packet);
        event.packetCount++;
        event.lastSeenMs = Math.max(event.lastSeenMs, packet.timestampMs);
        eventRepository.update(event);
    }

    private void notifyAndAcknowledge(AprsEvent event, boolean notifyUser, String source) {
        String callsign = callbacks.getCallsign();
        if (callsign == null || event.toCallsign == null
                || !event.toCallsign.trim().equalsIgnoreCase(callsign.trim())) return;
        if (notifyUser) callbacks.showNotification(event.fromCallsign + " messaged you", event.body);
        if (AprsSource.RX_RF.equals(source) && event.messageIdentifier != null
                && !event.messageIdentifier.trim().isEmpty()) {
            callbacks.sendAcknowledgement(event.fromCallsign.toUpperCase(Locale.ROOT),
                event.messageIdentifier, event.id);
        }
    }

    /** Records a transmitted packet under an existing event, or as unassociated transport data. */
    public void recordTransmission(Long eventId, APRSPacket packet, Long frequencyHz, byte[] rawAx25) {
        Transmission transmission = new Transmission(packet, frequencyHz, rawAx25);
        executor.execute(() -> {
            recordTransmissionNow(eventId, transmission);
            refreshFeed();
        });
    }

    /** Records a packet after it is written to a verified APRS-IS session. */
    public void recordAprsIsTransmission(Long eventId, String tnc2) {
        executor.execute(() -> {
            try {
                APRSPacket frame = Parser.parse(tnc2);
                AprsPacket packet = physicalPacket(frame, AprsSource.TX_APRS_IS, null, null, tnc2);
                if (eventId == null) {
                    packetRepository.insert(packet);
                } else {
                    AprsEvent event = eventRepository.findById(eventId);
                    if (event == null) packetRepository.insert(packet);
                    else associatePacket(event, packet);
                }
                refreshFeed();
            } catch (Exception ignored) {
                // The controller generated and validated this line before transmission.
            }
        });
    }

    private void recordTransmissionNow(Long eventId, Transmission transmission) {
        recordTransmissionNow(eventId, transmission, false);
    }

    private void recordTransmissionNow(Long eventId, Transmission transmission,
                                       boolean digipeated) {
        AprsPacket packet = physicalPacket(transmission.packet, AprsSource.TX_RF,
            transmission.frequencyHz, transmission.rawAx25);
        if (eventId == null) {
            packetRepository.insert(packet);
            return;
        }
        AprsEvent event = eventRepository.findById(eventId);
        if (event == null) {
            packetRepository.insert(packet);
        } else {
            event.digipeated |= digipeated;
            associatePacket(event, packet);
        }
    }

    /** Runs due reliable-message retries and periodic beacon scheduling. */
    public void tick(long now) {
        executor.execute(() -> {
            boolean changed = false;
            initializeReliableRetrySchedule();
            long retryAt = nextReliableRetryAt.get();
            if (retryAt != NO_RETRY_SCHEDULED && now >= retryAt) {
                for (AprsEvent event : eventRepository.loadDueReliableEvents(now)) {
                    retryOrFail(event, now);
                    changed = true;
                }
                reloadReliableRetrySchedule();
            }
            if (positionBeaconingEnabled && now >= nextPositionBeaconAt) {
                nextPositionBeaconAt = now + BEACON_INTERVAL_MS;
                callbacks.requestPositionBeacon();
            }
            if (changed) refreshFeed();
        });
    }

    private void initializeReliableRetrySchedule() {
        if (nextReliableRetryAt.get() == RETRY_SCHEDULE_UNINITIALIZED) {
            reloadReliableRetrySchedule();
        }
    }

    private void reloadReliableRetrySchedule() {
        Long retryAt = eventRepository.loadNextReliableRetryAt();
        nextReliableRetryAt.set(retryAt == null ? NO_RETRY_SCHEDULED : retryAt);
    }

    private void includeInReliableRetrySchedule(Long retryAt) {
        if (retryAt == null) return;
        nextReliableRetryAt.updateAndGet(current -> current == RETRY_SCHEDULE_UNINITIALIZED
            ? current : Math.min(current, retryAt));
    }

    public void setPositionBeaconingEnabled(boolean enabled, long now) {
        positionBeaconingEnabled = enabled;
        nextPositionBeaconAt = enabled ? now : 0;
    }

    private void retryOrFail(AprsEvent event, long now) {
        if (event.transmitAttempts >= RETRY_DELAYS_MS.length + 1) {
            event.deliveryState = AprsEvent.DELIVERY_FAILED;
            event.nextRetryAtMs = null;
        } else {
            Transmission transmission = callbacks.retryMessage(event);
            if (transmission == null) {
                event.nextRetryAtMs = now + RETRY_DELAYS_MS[0];
            } else {
                AprsPacket packet = physicalPacket(transmission.packet, AprsSource.TX_RF,
                    transmission.frequencyHz, transmission.rawAx25);
                packet.eventId = event.id;
                packetRepository.insert(packet);
                event.packetCount++;
                event.lastSeenMs = Math.max(event.lastSeenMs, packet.timestampMs);
                event.transmitAttempts++;
                event.nextRetryAtMs = event.transmitAttempts >= RETRY_DELAYS_MS.length + 1
                    ? now + FINAL_ACK_GRACE_MS
                    : now + RETRY_DELAYS_MS[event.transmitAttempts - 1];
            }
        }
        eventRepository.update(event);
    }

    /** Records a new outgoing chat event and its first transmitted packet. */
    public void recordOutgoingMessage(String from, String to, String text, String messageIdentifier,
                                      Long frequencyHz, APRSPacket packet, byte[] rawAx25) {
        long now = System.currentTimeMillis();
        AprsEvent event = new AprsEvent();
        event.type = AprsEvent.MESSAGE_TYPE;
        event.firstSeenMs = now;
        event.lastSeenMs = now;
        event.packetCount = 1;
        event.fromCallsign = from.toUpperCase(Locale.ROOT).trim();
        event.toCallsign = to.toUpperCase(Locale.ROOT).trim();
        event.body = text.trim();
        if (requiresAcknowledgement(to)) {
            event.messageIdentifier = messageIdentifier;
            event.deliveryState = AprsEvent.DELIVERY_PENDING;
            event.transmitAttempts = 1;
            event.nextRetryAtMs = now + RETRY_DELAYS_MS[0];
        }
        persistOutgoingEvent(event, packet, frequencyHz, rawAx25);
    }

    public static boolean requiresAcknowledgement(String destination) {
        if (destination == null) return false;
        String normalized = destination.trim().toUpperCase(Locale.ROOT);
        return !normalized.startsWith("BLN") && !normalized.equals("ALL")
            && !normalized.equals("QST") && !normalized.equals("CQ");
    }

    /** Records a new outgoing position event and its transmitted packet. */
    public void recordPositionBeacon(String callsign, double latitude, double longitude,
                                     Long frequencyHz, APRSPacket packet, byte[] rawAx25) {
        long now = System.currentTimeMillis();
        AprsEvent event = new AprsEvent();
        event.type = AprsEvent.POSITION_TYPE;
        event.firstSeenMs = now;
        event.lastSeenMs = now;
        event.packetCount = 1;
        event.fromCallsign = callsign;
        event.positionLat = latitude;
        event.positionLong = longitude;
        persistOutgoingEvent(event, packet, frequencyHz, rawAx25);
    }

    private void persistOutgoingEvent(AprsEvent event, APRSPacket frame, Long frequencyHz,
                                      byte[] rawAx25) {
        event.dedupKey = logicalPacketKey(frame);
        AprsPacket packet = physicalPacket(frame, AprsSource.TX_RF, frequencyHz, rawAx25);
        executor.execute(() -> {
            event.id = eventRepository.insert(event, feedKey(event));
            packet.eventId = event.id;
            packetRepository.insert(packet);
            includeInReliableRetrySchedule(event.nextRetryAtMs);
            refreshFeed();
        });
    }

    private AprsPacket physicalPacket(APRSPacket frame, String source, Long frequencyHz,
                                      byte[] rawAx25) {
        return physicalPacket(frame, source, frequencyHz, rawAx25, null);
    }

    private AprsPacket physicalPacket(APRSPacket frame, String source, Long frequencyHz,
                                      byte[] rawAx25, String rawTnc2) {
        AprsPacket packet = new AprsPacket();
        packet.timestampMs = System.currentTimeMillis();
        packet.source = source == null ? AprsSource.UNKNOWN : source;
        packet.frequencyHz = frequencyHz;
        packet.fromCallsign = frame.getSourceCall();
        packet.ax25Destination = frame.getDestinationCall();
        List<Digipeater> digipeaters = frame.getDigipeaters();
        packet.path = digipeaters == null || digipeaters.isEmpty() ? null
            : digipeaters.stream().map(Digipeater::toString).collect(Collectors.joining(","));
        packet.rawAx25 = rawAx25 == null ? null : Arrays.copyOf(rawAx25, rawAx25.length);
        packet.rawTnc2 = rawTnc2;
        return packet;
    }

    private ParsedEvent parseEvent(PacketContext context) {
        APRSPacket packet = context.packet;
        InformationField info = context.info;
        if (info.getDataTypeIdentifier() == ':') {
            MessagePacket message = new MessagePacket(info.getRawBytes(), packet.getDestinationCall());
            if (message.isAck() || message.isRej()) {
                return ParsedEvent.delivery(message.isAck(), message.isRej(), packet.getSourceCall(),
                    message.getTargetCallsign(), message.getMessageNumber());
            }
        }

        AprsEvent event = new AprsEvent();
        event.firstSeenMs = System.currentTimeMillis();
        event.lastSeenMs = event.firstSeenMs;
        event.fromCallsign = packet.getSourceCall();
        event.relayCallsign = context.relayCallsign;
        WeatherField weather = (WeatherField) info.getAprsData(APRSTypes.T_WX);
        PositionField position = (PositionField) info.getAprsData(APRSTypes.T_POSITION);
        ObjectField object = (ObjectField) info.getAprsData(APRSTypes.T_OBJECT);
        StatusField status = (StatusField) info.getAprsData(APRSTypes.T_STATUS);
        StationCapabilitiesField capabilities = (StationCapabilitiesField)
            info.getAprsData(APRSTypes.T_STATCAPA);
        applyPosition(event, position);
        if (position == null && object != null) applyPosition(event, object.getPosition());
        applyComment(event, packet, info, position, object, weather);
        applyPayload(event, packet, info, object, weather, status, capabilities);
        if (packet.hasFault()) return null;
        if (event.type == AprsEvent.UNKNOWN_TYPE) {
            event.comment = "Raw: " + new String(info.getRawBytes(), StandardCharsets.UTF_8);
        }
        event.dedupKey = logicalPacketKey(packet);
        return ParsedEvent.event(event);
    }

    private void applyPosition(AprsEvent event, PositionField position) {
        if (position == null) return;
        event.type = AprsEvent.POSITION_TYPE;
        event.positionLat = position.getPosition().getLatitude();
        event.positionLong = position.getPosition().getLongitude();
    }

    private void applyComment(AprsEvent event, APRSPacket packet, InformationField info,
                              PositionField position, ObjectField object, WeatherField weather) {
        String comment = firstComment(packet.getComment(), info.getComment());
        comment = firstComment(comment, position == null ? null : position.getComment());
        comment = firstComment(comment, object == null ? null : object.getComment());
        event.comment = firstComment(comment, weather == null ? null : weather.getComment());
    }

    private String firstComment(String preferred, String fallback) {
        return preferred == null || preferred.trim().isEmpty() ? fallback : preferred;
    }

    private void applyPayload(AprsEvent event, APRSPacket packet, InformationField info,
                              ObjectField object, WeatherField weather, StatusField status,
                              StationCapabilitiesField capabilities) {
        if (weather != null) {
            applyWeather(event, weather);
            return;
        }
        if (info.getDataTypeIdentifier() == ';') applyObject(event, object);
        if (info.getDataTypeIdentifier() == ':') applyMessage(event, packet, info);
        if (status != null) applyStatus(event, status);
        if (capabilities != null) applyCapabilities(event, capabilities);
    }

    private void applyWeather(AprsEvent event, WeatherField weather) {
        event.type = AprsEvent.WEATHER_TYPE;
        event.temperature = valueOrZero(weather.getTemp());
        event.humidity = valueOrZero(weather.getHumidity());
        event.pressure = valueOrZero(weather.getPressure());
        event.rain = valueOrZero(weather.getRainLast24Hours());
        event.snow = valueOrZero(weather.getSnowfallLast24Hours());
        event.windForce = valueOrZero(weather.getWindSpeed());
        event.windDirection = cardinalDirection(weather.getWindDirection());
    }

    private void applyObject(AprsEvent event, ObjectField object) {
        event.type = AprsEvent.OBJECT_TYPE;
        if (object != null) event.objectName = object.getObjectName();
    }

    private void applyMessage(AprsEvent event, APRSPacket packet, InformationField info) {
        event.type = AprsEvent.MESSAGE_TYPE;
        MessagePacket message = new MessagePacket(info.getRawBytes(), packet.getDestinationCall());
        event.toCallsign = message.getTargetCallsign();
        event.messageIdentifier = message.getMessageNumber();
        event.body = message.getMessageBody();
    }

    private void applyStatus(AprsEvent event, StatusField status) {
        event.type = AprsEvent.STATUS_TYPE;
        event.comment = status.getStatusText();
    }

    private void applyCapabilities(AprsEvent event, StationCapabilitiesField capabilities) {
        event.type = AprsEvent.STATION_CAPABILITIES_TYPE;
        event.comment = capabilities.getDisplayText();
    }

    private double valueOrZero(Double value) {
        return value == null ? 0 : value;
    }

    private int valueOrZero(Integer value) {
        return value == null ? 0 : value;
    }

    private String cardinalDirection(Integer direction) {
        return direction == null ? "" : Utilities.degressToCardinal(direction);
    }

    private long duplicateWindowMs(AprsEvent event) {
        return event.type == AprsEvent.MESSAGE_TYPE
                && event.messageIdentifier != null && !event.messageIdentifier.trim().isEmpty()
            ? NUMBERED_MESSAGE_DUPLICATE_WINDOW_MS : EVENT_DUPLICATE_WINDOW_MS;
    }

    private String logicalPacketKey(APRSPacket packet) {
        return packet.getSourceCall() + "|" + packet.getDestinationCall() + "|"
            + Base64.getEncoder().encodeToString(packet.getPayload().getRawBytes());
    }

    /** Returns the stable feed slot for event types whose history is shown as latest-only. */
    private String feedKey(AprsEvent event) {
        String source = normalizeCallsign(event.fromCallsign);
        if (source.isEmpty()) return null;
        switch (event.type) {
            case AprsEvent.POSITION_TYPE:
                return "position:" + source;
            case AprsEvent.WEATHER_TYPE:
                return "weather:" + source;
            case AprsEvent.STATUS_TYPE:
                return "status:" + source;
            case AprsEvent.STATION_CAPABILITIES_TYPE:
                return "capabilities:" + source;
            case AprsEvent.OBJECT_TYPE:
                String objectName = event.objectName == null
                    ? "" : event.objectName.trim().toUpperCase(Locale.ROOT);
                return objectName.isEmpty() ? null : "object:" + source + ":" + objectName;
            case AprsEvent.MESSAGE_TYPE:
            case AprsEvent.UNKNOWN_TYPE:
            default:
                return null;
        }
    }

    private void refreshFeed() {
        long sinceMs = historyStartMs(historyWindow, System.currentTimeMillis());
        String selectedDestination = destinationFilter;
        String localCallsign = callbacks.getCallsign();
        executor.execute(() -> {
            boolean mineOnly = DESTINATION_MINE.equals(selectedDestination);
            feed.postValue(new ArrayList<>(eventRepository.loadFeed(
                sinceMs, normalizeCallsign(localCallsign), mineOnly, MAX_VISIBLE_EVENTS)));
        });
    }

    private String normalizeHistoryWindow(String value) {
        if (HISTORY_ONE_DAY.equalsIgnoreCase(value)) return HISTORY_ONE_DAY;
        if (HISTORY_ONE_WEEK.equalsIgnoreCase(value)) return HISTORY_ONE_WEEK;
        if (HISTORY_TWO_WEEKS.equalsIgnoreCase(value)) return HISTORY_TWO_WEEKS;
        if (HISTORY_ONE_MONTH.equalsIgnoreCase(value)) return HISTORY_ONE_MONTH;
        return HISTORY_ALL;
    }

    private long historyStartMs(String window, long now) {
        switch (window) {
            case HISTORY_ONE_DAY:
                return now - DAY_MS;
            case HISTORY_ONE_WEEK:
                return now - 7 * DAY_MS;
            case HISTORY_TWO_WEEKS:
                return now - 14 * DAY_MS;
            case HISTORY_ONE_MONTH:
                return now - 30 * DAY_MS;
            case HISTORY_ALL:
            default:
                return 0L;
        }
    }

    private String normalizeCallsign(String callsign) {
        return callsign == null ? "" : callsign.trim().toUpperCase(Locale.ROOT);
    }

    private Transmission maybeDigipeat(APRSPacket packet) {
        String localCallsign = callbacks.getCallsign();
        if (!digipeatingEnabled || localCallsign == null || localCallsign.trim().isEmpty()
                || packet == null || packet.getPayload() == null || packet.hasFault()) return null;
        String key = logicalPacketKey(packet);
        long now = System.currentTimeMillis();
        pruneDigipeatCache(digipeatInputCache, now);
        if (digipeatInputCache.containsKey(key)) return null;
        List<Digipeater> digis = packet.getDigipeaters();
        if (digis == null || digis.isEmpty()) return null;
        int index = firstUnusedDigipeater(digis);
        if (index < 0) return null;
        Digipeater next = digis.get(index);
        String baseCall = APRSPacket.getBaseCall(next.getCallsign());
        int ssid = parseSsid(next);
        boolean ours = normalizeAx25Address(next.toString())
            .equals(normalizeAx25Address(localCallsign));
        boolean wide1 = baseCall.equalsIgnoreCase("WIDE1") && ssid == 1;
        if (!ours && !wide1) return null;
        List<Digipeater> replacement = new ArrayList<>(digis);
        if (ours) {
            replacement.set(index, usedDigipeater(next.toString()));
        } else {
            replacement.set(index, usedDigipeater(localCallsign));
        }
        APRSPacket retransmit = new APRSPacket(packet.getSourceCall(), packet.getDestinationCall(),
            replacement, packet.getPayload().getRawBytes());
        retransmit.setComment(packet.getComment());
        Transmission transmission = callbacks.transmitDigipeatedPacket(retransmit);
        if (transmission != null) {
            digipeatInputCache.put(key, now);
            digipeatOutputCache.put(digipeatOutputKey(retransmit), now);
        }
        return transmission;
    }

    private boolean isRecentlyDigipeated(APRSPacket packet) {
        long now = System.currentTimeMillis();
        pruneDigipeatCache(digipeatOutputCache, now);
        Long previous = digipeatOutputCache.get(digipeatOutputKey(packet));
        return previous != null && now - previous < DIGIPEAT_DEDUP_MS;
    }

    private void pruneDigipeatCache(Map<String, Long> cache, long now) {
        cache.entrySet().removeIf(entry -> now - entry.getValue() >= DIGIPEAT_DEDUP_MS);
    }

    private String digipeatOutputKey(APRSPacket packet) {
        String path = packet.getDigipeaters() == null ? "" : packet.getDigipeaters().stream()
            .map(Digipeater::toString).collect(Collectors.joining(","));
        return packet.getSourceCall() + "|" + packet.getDestinationCall() + "|" + path + "|"
            + Base64.getEncoder().encodeToString(packet.getPayload().getRawBytes());
    }

    private int firstUnusedDigipeater(List<Digipeater> digis) {
        for (int i = 0; i < digis.size(); i++) {
            if (!digis.get(i).isUsed()) return i;
        }
        return -1;
    }

    private int parseSsid(Digipeater digipeater) {
        try {
            return Integer.parseInt(APRSPacket.getSsid(digipeater.toString()));
        } catch (NumberFormatException ignored) {
            return -1;
        }
    }

    private String normalizeAx25Address(String address) {
        String normalized = normalizeCallsign(address);
        String baseCall = APRSPacket.getBaseCall(normalized);
        try {
            int ssid = Integer.parseInt(APRSPacket.getSsid(normalized));
            return ssid == 0 ? baseCall : baseCall + "-" + ssid;
        } catch (NumberFormatException ignored) {
            return normalized;
        }
    }

    private void maybeGateToAprsIs(APRSPacket packet, Long eventId) {
        if (!igateEnabled) return;
        String tnc2 = igateLine(packet, 0);
        String callsign = normalizeAx25Address(callbacks.getCallsign());
        if (tnc2 != null && !callsign.isEmpty()) {
            callbacks.gateToAprsIs(appendIgateConstruct(tnc2, callsign), eventId);
        }
    }

    private String igateLine(APRSPacket packet, int depth) {
        if (packet == null || packet.getPayload() == null || depth > 4
                || containsForbiddenGatePath(packet) || packet.getDti() == '?') return null;
        if (packet.getDti() != '}') return toTnc2(packet);

        byte[] payload = packet.getPayload().getRawBytes();
        if (payload.length < 2) return null;
        String innerLine = new String(payload, 1, payload.length - 1,
            StandardCharsets.ISO_8859_1);
        try {
            return igateLine(Parser.parse(innerLine), depth + 1);
        } catch (Exception ignored) {
            return null;
        }
    }

    private boolean containsForbiddenGatePath(APRSPacket packet) {
        List<Digipeater> path = packet.getDigipeaters();
        if (path == null) return false;
        for (Digipeater digipeater : path) {
            String callsign = digipeater.getCallsign().toUpperCase(Locale.ROOT);
            if ("TCPIP".equals(callsign) || "TCPXX".equals(callsign)
                    || "NOGATE".equals(callsign) || "RFONLY".equals(callsign)
                    || "I".equals(callsign)
                    || APRSPacket.Q_CONSTRUCTS.contains(callsign.toLowerCase(Locale.ROOT))) {
                return true;
            }
        }
        return false;
    }

    static String toTnc2(APRSPacket packet) {
        StringBuilder line = new StringBuilder(packet.getSourceCall()).append('>')
            .append(packet.getDestinationCall());
        List<Digipeater> path = packet.getDigipeaters();
        if (path != null && !path.isEmpty()) {
            line.append(',').append(path.stream().map(Digipeater::toString)
                .collect(Collectors.joining(",")));
        }
        return line.append(':').append(new String(packet.getPayload().getRawBytes(),
            StandardCharsets.ISO_8859_1)).toString();
    }

    private String appendIgateConstruct(String tnc2, String callsign) {
        int payloadSeparator = tnc2.indexOf(':');
        if (payloadSeparator < 0) return null;
        return tnc2.substring(0, payloadSeparator) + ",qAO," + callsign
            + tnc2.substring(payloadSeparator);
    }

    private Digipeater usedDigipeater(String callsign) {
        Digipeater digipeater = new Digipeater(callsign);
        digipeater.setUsed(true);
        return digipeater;
    }

    private PacketContext unwrap(APRSPacket raw) {
        InformationField info = raw.getPayload();
        ThirdPartyField thirdParty = (ThirdPartyField) info.getAprsData(APRSTypes.T_THIRDPARTY);
        if (thirdParty == null) return new PacketContext(raw, info, null);
        APRSPacket inner = thirdParty.getInnerPacket();
        return inner == null || inner.hasFault() ? null
            : new PacketContext(inner, inner.getPayload(), raw.getSourceCall());
    }

    private static final class PacketContext {
        private final APRSPacket packet;
        private final InformationField info;
        private final String relayCallsign;

        private PacketContext(APRSPacket packet, InformationField info, String relayCallsign) {
            this.packet = packet;
            this.info = info;
            this.relayCallsign = relayCallsign;
        }
    }

    private static final class ParsedEvent {
        private final AprsEvent event;
        private final boolean acknowledgement;
        private final boolean rejection;
        private final String fromCallsign;
        private final String targetCallsign;
        private final String messageIdentifier;

        private ParsedEvent(AprsEvent event, boolean acknowledgement, boolean rejection,
                            String fromCallsign, String targetCallsign, String messageIdentifier) {
            this.event = event;
            this.acknowledgement = acknowledgement;
            this.rejection = rejection;
            this.fromCallsign = fromCallsign;
            this.targetCallsign = targetCallsign;
            this.messageIdentifier = messageIdentifier;
        }

        private static ParsedEvent event(AprsEvent event) {
            return new ParsedEvent(event, false, false, null, null, null);
        }

        private static ParsedEvent delivery(boolean acknowledgement, boolean rejection,
                                            String from, String target, String identifier) {
            return new ParsedEvent(null, acknowledgement, rejection, from, target, identifier);
        }
    }
}
