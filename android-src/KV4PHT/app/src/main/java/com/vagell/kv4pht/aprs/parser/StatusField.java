/*
kv4p HT (see http://kv4p.com)
Copyright (C) 2026 Vance Vagell

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

package com.vagell.kv4pht.aprs.parser;

import java.nio.charset.StandardCharsets;

/** Text carried by an APRS status report (data type identifier {@code >}). */
public final class StatusField extends APRSData {
    private static final long serialVersionUID = 1L;
    private final String statusText;

    public StatusField(byte[] rawBytes) {
        super(rawBytes);
        type = APRSTypes.T_STATUS;
        int textOffset = statusTextOffset(rawBytes);
        statusText = rawBytes.length <= textOffset ? "" : new String(
            rawBytes, textOffset, rawBytes.length - textOffset,
            StandardCharsets.ISO_8859_1).trim();
        comment = statusText;
        setLastCursorPosition(rawBytes.length);
    }

    /**
     * Skips the optional APRS status timestamp ({@code DDHHMMz}). The timestamp says when the
     * status was authored; event arrival time remains the appropriate feed ordering time.
     */
    private static int statusTextOffset(byte[] rawBytes) {
        if (rawBytes.length < 8 || (rawBytes[7] != 'z' && rawBytes[7] != 'Z')) {
            return 1;
        }
        for (int i = 1; i <= 6; i++) {
            if (rawBytes[i] < '0' || rawBytes[i] > '9') {
                return 1;
            }
        }
        return 8;
    }

    public String getStatusText() {
        return statusText;
    }

    @Override public String toString() {
        return statusText;
    }

    @Override public boolean hasFault() {
        return false;
    }
}
