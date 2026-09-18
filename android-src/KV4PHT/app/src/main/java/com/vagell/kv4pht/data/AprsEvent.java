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

package com.vagell.kv4pht.data;

import androidx.room.ColumnInfo;
import androidx.room.Entity;
import androidx.room.Index;
import androidx.room.PrimaryKey;

/** User-facing APRS occurrence assembled from one or more physical packets. */
@Entity(
    tableName = "aprs_events",
    indices = {
        @Index("first_seen_ms"),
        @Index(value = {"internet_only", "first_seen_ms"}),
        @Index(value = {"type", "to_callsign", "first_seen_ms"}),
        @Index(value = {"dedup_key", "last_seen_ms"}),
        @Index(value = {"delivery_state", "next_retry_at_ms"}),
        @Index(value = {"from_callsign", "to_callsign", "message_identifier"})
    }
)
public class AprsEvent {
    public static final int UNKNOWN_TYPE = 0;
    public static final int MESSAGE_TYPE = 1;
    public static final int OBJECT_TYPE = 2;
    public static final int POSITION_TYPE = 3;
    public static final int WEATHER_TYPE = 4;
    public static final int STATUS_TYPE = 5;
    public static final int STATION_CAPABILITIES_TYPE = 6;

    public static final int DELIVERY_NONE = 0;
    public static final int DELIVERY_PENDING = 1;
    public static final int DELIVERY_DELIVERED = 2;
    public static final int DELIVERY_REJECTED = 3;
    public static final int DELIVERY_FAILED = 4;

    @PrimaryKey(autoGenerate = true)
    public long id;

    @ColumnInfo(name = "type", defaultValue = "0")
    public int type;
    /** Stable event time used for history filtering, ordering, and display. */
    @ColumnInfo(name = "first_seen_ms")
    public long firstSeenMs;
    /** Latest associated packet time, used only for aggregation and duplicate detection. */
    @ColumnInfo(name = "last_seen_ms")
    public long lastSeenMs;
    @ColumnInfo(name = "packet_count", defaultValue = "0")
    public int packetCount;
    /** Whether this station retransmitted at least one packet associated with this event. */
    @ColumnInfo(name = "digipeated", defaultValue = "0")
    public boolean digipeated;
    /** Whether every received copy associated with this event came from APRS-IS. */
    @ColumnInfo(name = "internet_only", defaultValue = "0")
    public boolean internetOnly;
    /** Stable controller-generated key used to collapse recent duplicate observations. */
    @ColumnInfo(name = "dedup_key")
    public String dedupKey;

    @ColumnInfo(name = "from_callsign")
    public String fromCallsign;
    @ColumnInfo(name = "to_callsign")
    public String toCallsign;
    @ColumnInfo(name = "message_identifier")
    public String messageIdentifier;
    @ColumnInfo(name = "body")
    public String body;
    @ColumnInfo(name = "position_lat")
    public double positionLat;
    @ColumnInfo(name = "position_long")
    public double positionLong;
    @ColumnInfo(name = "comment")
    public String comment;
    @ColumnInfo(name = "object_name")
    public String objectName;
    @ColumnInfo(name = "temperature")
    public double temperature;
    @ColumnInfo(name = "humidity")
    public double humidity;
    @ColumnInfo(name = "pressure")
    public double pressure;
    @ColumnInfo(name = "rain")
    public double rain;
    @ColumnInfo(name = "snow")
    public double snow;
    @ColumnInfo(name = "wind_force")
    public int windForce;
    @ColumnInfo(name = "wind_direction")
    public String windDirection;
    @ColumnInfo(name = "relay_callsign")
    public String relayCallsign;

    @ColumnInfo(name = "delivery_state", defaultValue = "0")
    public int deliveryState;
    @ColumnInfo(name = "transmit_attempts", defaultValue = "0")
    public int transmitAttempts;
    @ColumnInfo(name = "next_retry_at_ms")
    public Long nextRetryAtMs;
}
