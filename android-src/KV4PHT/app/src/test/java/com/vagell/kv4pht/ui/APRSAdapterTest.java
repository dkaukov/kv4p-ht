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

package com.vagell.kv4pht.ui;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import com.vagell.kv4pht.R;
import com.vagell.kv4pht.data.AprsEvent;
import org.junit.Test;

public class APRSAdapterTest {
    @Test public void mapsEveryReliableDeliveryStateToItsOwnIndicator() {
        assertStyle(AprsEvent.DELIVERY_PENDING, R.drawable.ic_pending,
            R.string.aprs_delivery_pending);
        assertStyle(AprsEvent.DELIVERY_DELIVERED, R.drawable.ic_check,
            R.string.aprs_delivery_delivered);
        assertStyle(AprsEvent.DELIVERY_REJECTED, R.drawable.ic_rejected,
            R.string.aprs_delivery_rejected);
        assertStyle(AprsEvent.DELIVERY_FAILED, R.drawable.ic_failed,
            R.string.aprs_delivery_failed);
        assertNull(APRSAdapter.deliveryStatusStyle(AprsEvent.DELIVERY_NONE));
    }

    private void assertStyle(int state, int drawable, int description) {
        APRSAdapter.DeliveryStatusStyle style = APRSAdapter.deliveryStatusStyle(state);
        assertEquals(drawable, style.drawable);
        assertEquals(description, style.description);
    }
}
