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

package com.vagell.kv4pht.ui;

import android.content.Intent;
import android.icu.text.SimpleDateFormat;
import android.net.Uri;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.core.content.ContextCompat;
import androidx.recyclerview.widget.RecyclerView;

import com.vagell.kv4pht.R;
import com.vagell.kv4pht.data.AprsEvent;

import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;

public class APRSAdapter extends RecyclerView.Adapter<APRSAdapter.APRSViewHolder> {
    public List<AprsEvent> aprsEvents;

    static DeliveryStatusStyle deliveryStatusStyle(int deliveryState) {
        switch (deliveryState) {
            case AprsEvent.DELIVERY_PENDING:
                return new DeliveryStatusStyle(R.drawable.ic_pending,
                    R.string.aprs_delivery_pending, R.color.primary_deselected);
            case AprsEvent.DELIVERY_DELIVERED:
                return new DeliveryStatusStyle(R.drawable.ic_check,
                    R.string.aprs_delivery_delivered, R.color.primary);
            case AprsEvent.DELIVERY_REJECTED:
                return new DeliveryStatusStyle(R.drawable.ic_rejected,
                    R.string.aprs_delivery_rejected, R.color.accent);
            case AprsEvent.DELIVERY_FAILED:
                return new DeliveryStatusStyle(R.drawable.ic_failed,
                    R.string.aprs_delivery_failed, R.color.accent);
            case AprsEvent.DELIVERY_NONE:
            default:
                return null;
        }
    }

    static final class DeliveryStatusStyle {
        final int drawable;
        final int description;
        final int color;

        DeliveryStatusStyle(int drawable, int description, int color) {
            this.drawable = drawable;
            this.description = description;
            this.color = color;
        }
    }

    public APRSAdapter() {
        this.aprsEvents = new ArrayList<>();
    }

    @NonNull
    @Override
    public APRSViewHolder onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
        View itemView = null;

        switch (viewType) {
            case AprsEvent.MESSAGE_TYPE:
                itemView = LayoutInflater.from(parent.getContext()).inflate(R.layout.aprs_message, parent, false);
                break;
            case AprsEvent.OBJECT_TYPE:
                itemView = LayoutInflater.from(parent.getContext()).inflate(R.layout.aprs_object, parent, false);
                break;
            case AprsEvent.POSITION_TYPE:
                itemView = LayoutInflater.from(parent.getContext()).inflate(R.layout.aprs_position, parent, false);
                break;
            case AprsEvent.WEATHER_TYPE:
                itemView = LayoutInflater.from(parent.getContext()).inflate(R.layout.aprs_weather, parent, false);
                break;
            case AprsEvent.UNKNOWN_TYPE:
            default:
                itemView = LayoutInflater.from(parent.getContext()).inflate(R.layout.aprs_unknown, parent, false);
        }

        return new APRSViewHolder(itemView);
    }

    public void setAprsEvents(List<AprsEvent> aprsEvents) {
        this.aprsEvents = aprsEvents;
    }

    @Override
    public int getItemViewType(int position) {
        return aprsEvents.get(position).type;
    }

    @Override
    public void onBindViewHolder(@NonNull APRSViewHolder holder, int position) {
        final AprsEvent aprsEvent = aprsEvents.get(position);

        // Some default values any message type can have
        holder.setFromCallsign(aprsEvent.fromCallsign);
        holder.setTimestamp(aprsEvent.firstSeenMs);
        holder.setComment(aprsEvent.comment);
        holder.setPositionLat(aprsEvent.positionLat);
        holder.setPositionLong(aprsEvent.positionLong);
        holder.setDigipeated(aprsEvent.digipeated);

        // Specialized values
        switch (aprsEvent.type) {
            case AprsEvent.WEATHER_TYPE:
                holder.setTemperature(aprsEvent.temperature);
                holder.setHumidity(aprsEvent.humidity);
                holder.setPressure(aprsEvent.pressure);
                holder.setRain(aprsEvent.rain);
                holder.setSnow(aprsEvent.snow);
                holder.setWindForce(aprsEvent.windForce);
                holder.setWindDir(aprsEvent.windDirection);
                break;
            case AprsEvent.MESSAGE_TYPE:
                holder.setToCallsign(aprsEvent.toCallsign);
                holder.setMsgBody(aprsEvent.body);
                holder.setDeliveryState(aprsEvent.deliveryState);
                break;
            case AprsEvent.OBJECT_TYPE:
                holder.setObjName(aprsEvent.objectName);
                break;
            case AprsEvent.POSITION_TYPE: // Can only have default values
            case AprsEvent.UNKNOWN_TYPE: // Ditto
                break;
            default:
                break;
        }
        holder.setRelayCallsign(aprsEvent.relayCallsign);

        // Handle taps on the message's position icon
        final View positionButton = holder.itemView.findViewById(R.id.senderPositionButton);
        positionButton.setOnClickListener(v -> {
            String geoUri = "geo:" + aprsEvent.positionLat + "," + aprsEvent.positionLong
                + "?q=" + aprsEvent.positionLat + "," + aprsEvent.positionLong;
            Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(geoUri));
            v.getContext().startActivity(intent);
        });
    }

    @Override
    public int getItemCount() {
        return aprsEvents.size();
    }

    static class APRSViewHolder extends RecyclerView.ViewHolder {
        TextView textViewFromCallsign;
        TextView textViewTimestamp;
        TextView textViewComment;
        View senderPositionButton;
        TextView textViewTemperature;
        TextView textViewHumidity;
        TextView textViewPressure;
        TextView textViewRain;
        TextView textViewSnow;
        TextView textViewWindForce;
        TextView textViewWindDir;
        TextView textViewToCallsign;
        TextView textViewMsgBody;
        ImageView deliveryStatusIcon;
        TextView textViewObjName;
        TextView textViewRelayCallsign;
        TextView textViewRelayViaLabel;
        TextView textViewDigipeated;

        public APRSViewHolder(@NonNull View itemView) {
            super(itemView);

            // Try to retrieve references to possible fields we can set.
            // Some will be null, depending on the type of this APRS message.
            textViewFromCallsign = itemView.findViewById(R.id.fromCallsign);
            textViewTimestamp = itemView.findViewById(R.id.timestamp);
            textViewComment = itemView.findViewById(R.id.comment);
            senderPositionButton = itemView.findViewById(R.id.senderPositionButton);
            textViewTemperature = itemView.findViewById(R.id.temperature);
            textViewHumidity = itemView.findViewById(R.id.humidity);
            textViewPressure = itemView.findViewById(R.id.pressure);
            textViewRain = itemView.findViewById(R.id.rain);
            textViewSnow = itemView.findViewById(R.id.snow);
            textViewWindForce = itemView.findViewById(R.id.wind);
            textViewWindDir = itemView.findViewById(R.id.windDirection);
            textViewToCallsign = itemView.findViewById(R.id.toCallsign);
            textViewMsgBody = itemView.findViewById(R.id.messageBody);
            deliveryStatusIcon = itemView.findViewById(R.id.messageDeliveryStatus);
            textViewObjName = itemView.findViewById(R.id.objName);
            textViewRelayCallsign = itemView.findViewById(R.id.relayCallsign);
            textViewRelayViaLabel = itemView.findViewById(R.id.relayViaLabel);
            textViewDigipeated = itemView.findViewById(R.id.digipeatedIndicator);
        }

        public void setFromCallsign(String fromCallsign) {
            if (null == textViewFromCallsign || null == fromCallsign) {
                return;
            }
            textViewFromCallsign.setText(fromCallsign);
        }

        public void setTimestamp(long timestamp) {
            if (null == textViewTimestamp) {
                return;
            }
            SimpleDateFormat sdf = new SimpleDateFormat("h:mm a MMM d", Locale.ENGLISH);
            textViewTimestamp.setText(sdf.format(new Date(timestamp)));
        }

        public void setComment(String comment) {
            if (null == textViewComment) {
                return;
            }
            if (null == comment || comment.trim().isEmpty()) {
                itemView.findViewById(R.id.commentHolder).setVisibility(View.GONE);
            } else {
                itemView.findViewById(R.id.commentHolder).setVisibility(View.VISIBLE);
                textViewComment.setText(comment);
            }
        }

        private void setHasPosition(boolean hasPosition) {
            if (null == senderPositionButton) {
                return;
            }
            senderPositionButton.setVisibility(hasPosition ? View.VISIBLE : View.GONE);
        }

        public void setPositionLat(double posLat) {
            setHasPosition(posLat != 0);
        }

        public void setPositionLong(double posLong) {
            setHasPosition(posLong != 0);
        }

        public void setTemperature(double temperature) {
            if (null == textViewTemperature) {
                return;
            }
            textViewTemperature.setText(String.format(Locale.US, "%.1f", temperature));
        }

        public void setHumidity(double humidity) {
            if (null == textViewHumidity) {
                return;
            }
            textViewHumidity.setText(String.format(Locale.US, "%.1f", humidity));
        }

        public void setPressure(double pressure) {
            if (null == textViewPressure) {
                return;
            }
            textViewPressure.setText(String.format(Locale.US, "%.1f", (pressure / 10f)));
        }

        public void setRain(double rain) {
            if (null == textViewRain) {
                return;
            }
            textViewRain.setText(String.format(Locale.US, "%.1f", rain));
        }

        public void setSnow(double snow) {
            if (null == textViewSnow) {
                return;
            }
            textViewSnow.setText(String.format(Locale.US, "%.1f", snow));
        }

        public void setWindForce(int windForce) {
            if (null == textViewWindForce) {
                return;
            }
            textViewWindForce.setText("" + windForce);
        }

        public void setWindDir(String windDir) {
            if (null == textViewWindDir || null == windDir) {
                return;
            }
            textViewWindDir.setText(windDir);
        }

        public void setToCallsign(String toCallsign) {
            if (null == textViewToCallsign || null == toCallsign) {
                return;
            }
            textViewToCallsign.setText(toCallsign);
        }

        public void setMsgBody(String msgBody) {
            if (null == textViewMsgBody || null == msgBody) {
                return;
            }
            textViewMsgBody.setText(msgBody);
        }

        public void setDeliveryState(int deliveryState) {
            if (deliveryStatusIcon == null) return;
            DeliveryStatusStyle style = deliveryStatusStyle(deliveryState);
            if (style == null) {
                deliveryStatusIcon.setVisibility(View.GONE);
                deliveryStatusIcon.setContentDescription(null);
                return;
            }
            deliveryStatusIcon.setImageResource(style.drawable);
            deliveryStatusIcon.setColorFilter(
                ContextCompat.getColor(itemView.getContext(), style.color));
            deliveryStatusIcon.setContentDescription(
                itemView.getContext().getString(style.description));
            deliveryStatusIcon.setVisibility(View.VISIBLE);
        }

        public void setObjName(String objName) {
            if (null == textViewObjName || null == objName) {
                return;
            }
            textViewObjName.setText(objName);
        }

        public void setRelayCallsign(String relayCallsign) {
            // Relay callsigns are intentionally not displayed: they make the status line hard to read.
        }

        public void setDigipeated(boolean digipeated) {
            if (textViewDigipeated != null) {
                textViewDigipeated.setVisibility(digipeated ? View.VISIBLE : View.GONE);
            }
        }
    }
}
