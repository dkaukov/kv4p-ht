package com.vagell.kv4pht.firmware;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbManager;
import android.os.SystemClock;

import com.hoho.android.usbserial.driver.UsbSerialDriver;
import com.hoho.android.usbserial.driver.UsbSerialPort;
import com.hoho.android.usbserial.driver.UsbSerialProber;

import org.dkaukov.esp32.io.SerialTransport;

import java.io.IOException;

/** Keeps the flasher's serial connection open across native USB re-enumeration. */
final class FirmwareUsbSerialTransport implements SerialTransport, AutoCloseable {
    private static final long RECONNECT_TIMEOUT_MS = 10000;
    private static final String USB_PERMISSION_ACTION =
        "com.vagell.kv4pht.FIRMWARE_USB_PERMISSION";

    private final Context context;
    private final UsbManager usbManager;
    private final int vendorId;
    private final int productId;
    private final boolean nativeEspUsb;
    private final UsbSerialPort initialPort;
    private UsbSerialPort port;
    private int baudRate = 115200;

    FirmwareUsbSerialTransport(Context context, UsbSerialPort port) {
        this.context = context.getApplicationContext();
        this.usbManager = (UsbManager) context.getSystemService(Context.USB_SERVICE);
        this.initialPort = port;
        this.port = port;
        UsbDevice device = port.getDriver().getDevice();
        vendorId = device.getVendorId();
        productId = device.getProductId();
        nativeEspUsb = vendorId == 0x303a && productId == 0x1001;
    }

    void setBaudRate(int baudRate) throws IOException {
        this.baudRate = baudRate;
        ensurePort();
        port.setParameters(baudRate, UsbSerialPort.DATABITS_8,
            UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE);
    }

    @Override
    public int read(byte[] buffer, int length) throws IOException {
        checkInterrupted();
        ensurePort();
        try {
            return port.read(buffer, length, 100);
        } catch (IOException error) {
            if (!nativeEspUsb) throw error;
            reattach();
            return port.read(buffer, length, 100);
        }
    }

    @Override
    public void write(byte[] buffer, int length) throws IOException {
        checkInterrupted();
        ensurePort();
        try {
            port.write(buffer, length, 0);
        } catch (IOException error) {
            if (!nativeEspUsb) throw error;
            reattach();
            port.write(buffer, length, 0);
        }
    }

    @Override
    public void setControlLines(boolean dtr, boolean rts) throws IOException {
        checkInterrupted();
        try {
            port.setDTRandRTS(dtr, rts);
        } catch (IOException error) {
            // A reset can remove the S3 USB device before the final control-line write.
            if (!nativeEspUsb) throw error;
        }
    }

    private void ensurePort() throws IOException {
        if (nativeEspUsb && !isCurrentDeviceAttached()) reattach();
    }

    private boolean isCurrentDeviceAttached() {
        int id = port.getDriver().getDevice().getDeviceId();
        for (UsbDevice device : usbManager.getDeviceList().values()) {
            if (device.getDeviceId() == id) return true;
        }
        return false;
    }

    private void reattach() throws IOException {
        int previousId = port.getDriver().getDevice().getDeviceId();
        long deadline = SystemClock.elapsedRealtime() + RECONNECT_TIMEOUT_MS;
        int permissionRequestedFor = -1;
        while (SystemClock.elapsedRealtime() < deadline) {
            checkInterrupted();
            UsbDevice replacement = null;
            for (UsbDevice device : usbManager.getDeviceList().values()) {
                if (device.getVendorId() == vendorId && device.getProductId() == productId
                    && device.getDeviceId() != previousId) {
                    if (replacement != null) {
                        throw new IOException("Multiple ESP USB devices re-enumerated");
                    }
                    replacement = device;
                }
            }
            if (replacement == null) {
                pause();
                continue;
            }
            if (!usbManager.hasPermission(replacement)) {
                if (permissionRequestedFor != replacement.getDeviceId()) {
                    PendingIntent permissionIntent = PendingIntent.getBroadcast(context, 0,
                        new Intent(USB_PERMISSION_ACTION).setPackage(context.getPackageName()),
                        PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
                    usbManager.requestPermission(replacement, permissionIntent);
                    permissionRequestedFor = replacement.getDeviceId();
                }
                pause();
                continue;
            }
            UsbSerialDriver driver = UsbSerialProber.getDefaultProber().probeDevice(replacement);
            if (driver == null || driver.getPorts().isEmpty()) {
                throw new IOException("No USB serial port on ESP bootloader device");
            }
            UsbDeviceConnection connection = usbManager.openDevice(replacement);
            if (connection == null) throw new IOException("Could not open ESP bootloader device");
            UsbSerialPort replacementPort = driver.getPorts().get(0);
            try {
                replacementPort.open(connection);
                replacementPort.setParameters(baudRate, UsbSerialPort.DATABITS_8,
                    UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE);
            } catch (IOException error) {
                try { replacementPort.close(); } catch (IOException ignored) { }
                throw error;
            }
            if (port != initialPort) {
                try { port.close(); } catch (IOException ignored) { }
            }
            port = replacementPort;
            return;
        }
        throw new IOException("ESP USB device did not re-enumerate for flashing");
    }

    private static void checkInterrupted() throws IOException {
        if (Thread.currentThread().isInterrupted()) throw new IOException("Flashing interrupted");
    }

    private static void pause() throws IOException {
        try {
            Thread.sleep(50);
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new IOException("Flashing interrupted", error);
        }
    }

    @Override
    public void close() {
        if (port != initialPort) {
            try { port.close(); } catch (IOException ignored) { }
        }
    }
}
