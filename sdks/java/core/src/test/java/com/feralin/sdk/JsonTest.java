package com.feralin.sdk;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

class JsonTest {
    @Test
    void writesScalarsAndContainers() {
        Map<String, Object> value = new LinkedHashMap<>();
        value.put("text", "şöğüİı \"q\" \\ \n\t\u0001 😀");
        value.put("int", 3);
        value.put("double", 12.5);
        value.put("decimal", new BigDecimal("19.90"));
        value.put("bool", true);
        value.put("none", null);
        value.put("list", List.of(1, "a"));
        value.put("array", new int[] {1, 2});
        assertEquals(
                "{\"text\":\"şöğüİı \\\"q\\\" \\\\ \\n\\t\\u0001 😀\",\"int\":3,\"double\":12.5,\"decimal\":19.90,\"bool\":true,\"none\":null,"
                        + "\"list\":[1,\"a\"],\"array\":[1,2]}",
                Json.write(value));
    }

    @Test
    void escapesLoneSurrogate() {
        assertEquals("\"a\\ud83d\"", Json.write("a\uD83D"));
    }

    @Test
    void rejectsValuesWithoutJsonForm() {
        assertThrows(IllegalArgumentException.class, () -> Json.write(Double.NaN));
        assertThrows(IllegalArgumentException.class, () -> Json.write(Float.POSITIVE_INFINITY));
        assertThrows(IllegalArgumentException.class, () -> Json.write(new Object()));
        assertThrows(IllegalArgumentException.class, () -> Json.write(Map.of(1, "non-string key")));
        List<Object> cycle = new ArrayList<>();
        cycle.add(cycle);
        assertThrows(IllegalArgumentException.class, () -> Json.write(cycle));
    }

    @Test
    void parsesAck() {
        Object parsed = Json.parse(" {\"batch_id\":\"01A\",\"accepted\":2,\"rate\":1.5,\"x\":null,\"ok\":true,\"list\":[1,{\"a\":\"\\u00e7\\n\"}]} ");
        Map<?, ?> map = (Map<?, ?>) parsed;
        assertEquals("01A", map.get("batch_id"));
        assertEquals(2L, map.get("accepted"));
        assertEquals(1.5, map.get("rate"));
        assertNull(map.get("x"));
        assertEquals(true, map.get("ok"));
        assertEquals(Arrays.asList(1L, Map.of("a", "ç\n")), map.get("list"));
    }

    @Test
    void rejectsInvalidInput() {
        for (String bad : List.of("", "{", "{\"a\"}", "[1,", "tru", "{\"a\":1} x", "\"unterminated", "\"\\q\"", "-")) {
            assertThrows(IllegalArgumentException.class, () -> Json.parse(bad), bad);
        }
        assertThrows(IllegalArgumentException.class, () -> Json.parse("[".repeat(100)));
    }
}
