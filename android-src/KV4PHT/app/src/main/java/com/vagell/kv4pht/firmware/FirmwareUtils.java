package com.vagell.kv4pht.firmware;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.EnumMap;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.stream.IntStream;
import java.util.stream.Stream;

import com.hoho.android.usbserial.driver.UsbSerialPort;
import com.vagell.kv4pht.R;

import org.dkaukov.esp32.chip.FlashRegion;
import org.dkaukov.esp32.chip.Esp32ChipId;
import org.dkaukov.esp32.core.EspFlasherApi;
import org.dkaukov.esp32.core.EspFlasherApi.DetectedStage;
import org.dkaukov.esp32.core.EspFlasherApi.StartStage;
import org.dkaukov.esp32.io.ProgressCallback;
import org.dkaukov.esp32.protocol.EspFlasherProtocol;
import org.slf4j.LoggerFactory;

import android.annotation.SuppressLint;
import android.content.Context;
import android.util.Log;
import lombok.SneakyThrows;
import pl.brightinventions.slf4android.LogLevel;
import pl.brightinventions.slf4android.LoggerConfiguration;

public final class FirmwareUtils {
    private static final String TAG = FirmwareUtils.class.getSimpleName();
    private static final String TAG_ESP32_FLASHER = EspFlasherProtocol.class.getSimpleName();

    private static final AtomicBoolean isFlashing = new AtomicBoolean(false);

    public static final int PACKAGED_FIRMWARE_VER = 17;

    private static final int ESP32_BOOTLOADER = R.raw.bootloader;
    private static final int ESP32_PARTITION_TABLE = R.raw.partitions;
    private static final int ESP32_BOOT_APP_0 = R.raw.boot_app0;
    private static final int ESP32_APP = R.raw.firmware_v17;
    private static final int ESP32S3_BOOTLOADER = R.raw.bootloader_s3;
    private static final int ESP32S3_APP = R.raw.firmware_s3_v17;

    static {
        LoggerFactory.getLogger(EspFlasherProtocol.class).trace("Init..");
        LoggerConfiguration.configuration().setLogLevel(LoggerFactory.getLogger(EspFlasherProtocol.class).getName(),
            LogLevel.DEBUG);
    }

    public static class ResourceLoadingException extends RuntimeException {
        @SuppressLint("DefaultLocale")
        public ResourceLoadingException(int id, IOException cause) {
            super(String.format("Failed to read resource: %d", id), cause);
        }
    }

    private FirmwareUtils() {}

    public interface FirmwareCallback {
        void connectedToBootloader();
        void reportProgress(int percent);
        void doneFlashing(boolean success);
    }

    public static void flashFirmware(Context ctx, UsbSerialPort usbSerialPort, FirmwareCallback callback) {
        if (!isFlashing.compareAndSet(false, true)) {
            Log.w(TAG, "Warning: Already flashing.");
            return;
        }
        FirmwareUsbSerialTransport transport = new FirmwareUsbSerialTransport(ctx, usbSerialPort);
        try {
            setBaudRate(transport, EspFlasherApi.ESP_ROM_BAUD);
            Log.i(TAG, "Starting firmware flash, version: " + PACKAGED_FIRMWARE_VER);
            final ProgressCallback[] progress = new ProgressCallback[1];
            StartStage flasher = EspFlasherApi.connect(transport)
                .withCallBack(new ProgressCallback() {
                    @Override public void onProgress(float pct) {
                        if (progress[0] != null) progress[0].onProgress(pct);
                    }
                    @Override public void onEnd() {
                        if (progress[0] != null) progress[0].onEnd();
                    }
                    @Override public void onInfo(String value) {
                        Log.d(TAG_ESP32_FLASHER, value);
                    }
                });
            DetectedStage detected = flasher.chipDetect();
            Esp32ChipId chip = detected.getChipId();
            int bootloaderResource = bootloaderResource(chip);
            int appResource = appResource(chip);
            if (chip == Esp32ChipId.ESP32) {
                flasher.withBaudRate(EspFlasherApi.ESP_ROM_BAUD_HIGHEST,
                    b -> setBaudRate(transport, b));
            }
            Map<FlashRegion, byte[]> flashRegions = new EnumMap<>(FlashRegion.class);
            flashRegions.put(FlashRegion.BOOTLOADER, readResource(ctx, bootloaderResource));
            flashRegions.put(FlashRegion.PARTITION_TABLE, readResource(ctx, ESP32_PARTITION_TABLE));
            flashRegions.put(FlashRegion.APP_BOOTLOADER, readResource(ctx, ESP32_BOOT_APP_0));
            flashRegions.put(FlashRegion.APP_0, readResource(ctx, appResource));
            progress[0] = getProgressCallback(flashRegions, callback);
            callback.connectedToBootloader();
            detected.loadStub()
                .withCompression(false)
                .writeFlash(chip.getRegion(FlashRegion.BOOTLOADER), flashRegions.get(FlashRegion.BOOTLOADER))
                .writeFlash(chip.getRegion(FlashRegion.PARTITION_TABLE), flashRegions.get(FlashRegion.PARTITION_TABLE))
                .writeFlash(chip.getRegion(FlashRegion.APP_BOOTLOADER), flashRegions.get(FlashRegion.APP_BOOTLOADER))
                .withCompression(true)
                .writeFlash(chip.getRegion(FlashRegion.APP_0), flashRegions.get(FlashRegion.APP_0))
                .reset();
            Log.i(TAG, "Firmware flash completed successfully.");
            callback.doneFlashing(true);
        } catch (Exception e) {
            Log.e(TAG, "Firmware flashing failed", e);
            callback.doneFlashing(false);
        } finally {
            transport.close();
            isFlashing.set(false);
        }
    }

    public static boolean isFlashing() {
        return isFlashing.get();
    }

    static int bootloaderResource(Esp32ChipId chip) {
        if (chip == Esp32ChipId.ESP32) return ESP32_BOOTLOADER;
        if (chip == Esp32ChipId.ESP32S3) return ESP32S3_BOOTLOADER;
        throw new IllegalArgumentException("No bundled firmware for " + chip);
    }

    static int appResource(Esp32ChipId chip) {
        if (chip == Esp32ChipId.ESP32) return ESP32_APP;
        if (chip == Esp32ChipId.ESP32S3) return ESP32S3_APP;
        throw new IllegalArgumentException("No bundled firmware for " + chip);
    }

    @SneakyThrows
    private static void setBaudRate(FirmwareUsbSerialTransport transport, int baudRate) {
        transport.setBaudRate(baudRate);
    }

    private static ProgressCallback getProgressCallback(Map<FlashRegion, byte[]> flashRegions, FirmwareCallback callback) {
        return new ProgressCallback() {
            int part = 0;
            final int[] regionSizes = Stream.of(
                    FlashRegion.BOOTLOADER,
                    FlashRegion.PARTITION_TABLE,
                    FlashRegion.APP_BOOTLOADER,
                    FlashRegion.APP_0)
                .mapToInt(region -> Objects.requireNonNull(flashRegions.get(region)).length).toArray();
            final int totalSize = IntStream.of(regionSizes).sum();
            int completedSoFar = 0;
            @Override
            public void onProgress(float pct) {
                if (part >= regionSizes.length) return;
                callback.reportProgress(Math.round((completedSoFar + regionSizes[part] * (pct / 100.0f)) * 100.0f / totalSize));
            }
            @Override
            public void onInfo(String value) {
                Log.d(TAG_ESP32_FLASHER, value);
            }
            @Override
            public void onEnd() {
                part++;
                completedSoFar = IntStream.of(regionSizes).limit(part).sum();
            }
        };
    }

    private static byte[] readResource(Context ctx, int resourceId) {
        Log.d(TAG, "Reading resource ID: " + resourceId);
        try (InputStream inputStream = ctx.getResources().openRawResource(resourceId);
            ByteArrayOutputStream outputStream = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[1024];
            int bytesRead;
            while ((bytesRead = inputStream.read(buffer)) != -1) {
                outputStream.write(buffer, 0, bytesRead);
            }
            return outputStream.toByteArray();
        } catch (IOException e) {
            throw new ResourceLoadingException(resourceId, e);
        }
    }
}
