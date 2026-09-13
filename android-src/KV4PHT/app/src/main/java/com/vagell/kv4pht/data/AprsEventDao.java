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

import androidx.room.Dao;
import androidx.room.Insert;
import androidx.room.Query;
import androidx.room.Update;
import java.util.List;

@Dao
public interface AprsEventDao {
    String MESSAGE_DESTINATION_BRANCH = "UNION ALL SELECT * FROM aprs_events "
        + "WHERE type = :messageType AND to_callsign ";
    String WITHIN_WINDOW = " AND last_seen_ms >= :sinceMs ";

    @Query("SELECT * FROM aprs_events WHERE last_seen_ms >= :sinceMs "
        + "ORDER BY last_seen_ms, id")
    List<AprsEvent> getSince(long sinceMs);

    @Query("SELECT * FROM aprs_events WHERE type != :messageType AND last_seen_ms >= :sinceMs "
        + MESSAGE_DESTINATION_BRANCH + "= :localCallsign" + WITHIN_WINDOW
        + MESSAGE_DESTINATION_BRANCH + "= 'ALL'" + WITHIN_WINDOW
        + MESSAGE_DESTINATION_BRANCH + "= 'QST'" + WITHIN_WINDOW
        + MESSAGE_DESTINATION_BRANCH + "= 'CQ'" + WITHIN_WINDOW
        + MESSAGE_DESTINATION_BRANCH + ">= 'BLN' AND to_callsign < 'BLO'" + WITHIN_WINDOW
        + "ORDER BY last_seen_ms, id")
    List<AprsEvent> getMineSince(long sinceMs, int messageType, String localCallsign);

    @Query("SELECT * FROM aprs_events WHERE delivery_state = :pendingState "
        + "AND next_retry_at_ms IS NOT NULL AND next_retry_at_ms <= :now")
    List<AprsEvent> getDueReliableEvents(int pendingState, long now);

    @Query("SELECT * FROM aprs_events WHERE from_callsign = :localCallsign "
        + "AND to_callsign = :remoteCallsign AND message_identifier = :messageIdentifier "
        + "AND delivery_state = :pendingState ORDER BY id DESC LIMIT 1")
    AprsEvent getPendingOutgoingEvent(String localCallsign, String remoteCallsign,
                                      String messageIdentifier, int pendingState);

    @Query("SELECT * FROM aprs_events WHERE id = :id LIMIT 1")
    AprsEvent getById(long id);

    @Query("SELECT * FROM aprs_events WHERE dedup_key = :dedupKey "
        + "AND last_seen_ms >= :sinceMs ORDER BY last_seen_ms DESC LIMIT 1")
    AprsEvent getRecentByDedupKey(String dedupKey, long sinceMs);

    @Insert
    long insert(AprsEvent event);

    @Update
    void update(AprsEvent event);
}
