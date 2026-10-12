package com.vagell.kv4pht.firmware;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import com.vagell.kv4pht.R;
import org.dkaukov.esp32.chip.Esp32ChipId;
import org.dkaukov.esp32.chip.FlashRegion;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

import java.io.IOException;
import java.io.InputStream;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28)
public class FirmwareUtilsTest {
    @Test public void s3UsesItsOwnImagesAndBootloaderOffset() throws IOException {
        assertEquals(R.raw.bootloader_s3, FirmwareUtils.bootloaderResource(Esp32ChipId.ESP32S3));
        assertEquals(R.raw.firmware_s3_v17, FirmwareUtils.appResource(Esp32ChipId.ESP32S3));
        assertEquals(0, Esp32ChipId.ESP32S3.getRegion(FlashRegion.BOOTLOADER));
        assertImageResource(R.raw.bootloader_s3);
        assertImageResource(R.raw.firmware_s3_v17);
    }

    @Test public void classicEsp32KeepsItsImagesAndBootloaderOffset() {
        assertEquals(R.raw.bootloader, FirmwareUtils.bootloaderResource(Esp32ChipId.ESP32));
        assertEquals(R.raw.firmware_v17, FirmwareUtils.appResource(Esp32ChipId.ESP32));
        assertEquals(0x1000, Esp32ChipId.ESP32.getRegion(FlashRegion.BOOTLOADER));
    }

    private static void assertImageResource(int resource) throws IOException {
        try (InputStream image = RuntimeEnvironment.getApplication()
            .getResources().openRawResource(resource)) {
            assertEquals(0xe9, image.read());
            assertTrue(image.available() > 1024);
        }
    }
}
