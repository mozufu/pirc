package dev.pirc.pirc_mobile
import org.junit.Assert.*
import org.junit.Test
class NotificationPreferencesTest {
    @Test fun quietHoursWrapMidnightAndExcludeEnd() {
        assertTrue(inQuietHours(23*60,1380,450))
        assertTrue(inQuietHours(0,1380,450))
        assertTrue(inQuietHours(449,1380,450))
        assertFalse(inQuietHours(450,1380,450))
        assertFalse(inQuietHours(800,1380,450))
    }
    @Test fun daytimeAndAllDayRanges() {
        assertFalse(inQuietHours(60,100,200))
        assertTrue(inQuietHours(100,100,200))
        assertFalse(inQuietHours(200,100,200))
        assertTrue(inQuietHours(600,100,100))
    }
}
