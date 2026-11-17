package com.feralin.sdk;

import java.lang.reflect.Array;
import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * JDK'da JSON yok ve SDK çalışma zamanı bağımlılığı taşımaz. Yazıcı olay gövdesini, okuyucu yalnız toplayıcının kısa
 * ack ve problem+json yanıtlarını işler; ikisi de iç içelik sınırı koyar.
 */
final class Json {
    private static final int MAX_DEPTH = 32;

    private Json() {
    }

    /** JSON'a dönüşmeyen değerde (NaN, sonsuz, bilinmeyen tür, döngü) {@link IllegalArgumentException} fırlatır. */
    static String write(Object value) {
        StringBuilder out = new StringBuilder();
        write(out, value, 0);
        return out.toString();
    }

    private static void write(StringBuilder out, Object value, int depth) {
        if (depth > MAX_DEPTH) {
            throw new IllegalArgumentException("iç içelik sınırı aşıldı veya döngüsel veri");
        }
        if (value == null) {
            out.append("null");
        } else if (value instanceof CharSequence || value instanceof Character) {
            writeString(out, value.toString());
        } else if (value instanceof Boolean
                || value instanceof Integer
                || value instanceof Long
                || value instanceof Short
                || value instanceof Byte
                || value instanceof BigInteger
                || value instanceof BigDecimal) {
            out.append(value);
        } else if (value instanceof Double || value instanceof Float) {
            double number = ((Number) value).doubleValue();
            if (Double.isNaN(number) || Double.isInfinite(number)) {
                throw new IllegalArgumentException("NaN veya sonsuz sayı JSON'da yok");
            }
            out.append(value);
        } else if (value instanceof Map) {
            writeMap(out, (Map<?, ?>) value, depth);
        } else if (value instanceof Iterable) {
            out.append('[');
            boolean first = true;
            for (Object item : (Iterable<?>) value) {
                if (!first) {
                    out.append(',');
                }
                first = false;
                write(out, item, depth + 1);
            }
            out.append(']');
        } else if (value.getClass().isArray()) {
            out.append('[');
            int length = Array.getLength(value);
            for (int i = 0; i < length; i++) {
                if (i > 0) {
                    out.append(',');
                }
                write(out, Array.get(value, i), depth + 1);
            }
            out.append(']');
        } else {
            throw new IllegalArgumentException("desteklenmeyen tür: " + value.getClass().getName());
        }
    }

    private static void writeMap(StringBuilder out, Map<?, ?> map, int depth) {
        out.append('{');
        boolean first = true;
        for (Map.Entry<?, ?> entry : map.entrySet()) {
            if (!(entry.getKey() instanceof String)) {
                throw new IllegalArgumentException("JSON anahtarı metin olmalı");
            }
            if (!first) {
                out.append(',');
            }
            first = false;
            writeString(out, (String) entry.getKey());
            out.append(':');
            write(out, entry.getValue(), depth + 1);
        }
        out.append('}');
    }

    private static void writeString(StringBuilder out, String text) {
        out.append('"');
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            switch (c) {
                case '"':
                    out.append("\\\"");
                    break;
                case '\\':
                    out.append("\\\\");
                    break;
                case '\n':
                    out.append("\\n");
                    break;
                case '\r':
                    out.append("\\r");
                    break;
                case '\t':
                    out.append("\\t");
                    break;
                default:
                    if (c < 0x20) {
                        appendUnicodeEscape(out, c);
                    } else if (Character.isHighSurrogate(c) && i + 1 < text.length() && Character.isLowSurrogate(text.charAt(i + 1))) {
                        out.append(c).append(text.charAt(++i));
                    } else if (Character.isSurrogate(c)) {
                        // Eşsiz yarım UTF-8'e kodlanamaz, sessizce '?' olmasın.
                        appendUnicodeEscape(out, c);
                    } else {
                        out.append(c);
                    }
            }
        }
        out.append('"');
    }

    private static void appendUnicodeEscape(StringBuilder out, char c) {
        out.append("\\u");
        String hex = Integer.toHexString(c);
        for (int i = hex.length(); i < 4; i++) {
            out.append('0');
        }
        out.append(hex);
    }

    /** Geçersiz JSON'da {@link IllegalArgumentException} fırlatır. Sayılar Long veya Double, nesneler Map olur. */
    static Object parse(String text) {
        Parser parser = new Parser(text);
        Object value = parser.value(0);
        parser.skipSpace();
        if (parser.position != text.length()) {
            throw new IllegalArgumentException("JSON sonrası fazladan veri");
        }
        return value;
    }

    private static final class Parser {
        private final String text;
        private int position;

        Parser(String text) {
            this.text = text;
        }

        Object value(int depth) {
            if (depth > MAX_DEPTH) {
                throw new IllegalArgumentException("iç içelik sınırı aşıldı");
            }
            skipSpace();
            if (position >= text.length()) {
                throw new IllegalArgumentException("beklenmeyen son");
            }
            char c = text.charAt(position);
            switch (c) {
                case '{':
                    return object(depth);
                case '[':
                    return array(depth);
                case '"':
                    return string();
                case 't':
                    return literal("true", Boolean.TRUE);
                case 'f':
                    return literal("false", Boolean.FALSE);
                case 'n':
                    return literal("null", null);
                default:
                    return number();
            }
        }

        private Map<String, Object> object(int depth) {
            Map<String, Object> out = new LinkedHashMap<>();
            position++;
            skipSpace();
            if (peek() == '}') {
                position++;
                return out;
            }
            while (true) {
                skipSpace();
                if (peek() != '"') {
                    throw new IllegalArgumentException("anahtar bekleniyordu");
                }
                String key = string();
                skipSpace();
                expect(':');
                out.put(key, value(depth + 1));
                skipSpace();
                char next = peek();
                position++;
                if (next == '}') {
                    return out;
                }
                if (next != ',') {
                    throw new IllegalArgumentException("virgül bekleniyordu");
                }
            }
        }

        private List<Object> array(int depth) {
            List<Object> out = new ArrayList<>();
            position++;
            skipSpace();
            if (peek() == ']') {
                position++;
                return out;
            }
            while (true) {
                out.add(value(depth + 1));
                skipSpace();
                char next = peek();
                position++;
                if (next == ']') {
                    return out;
                }
                if (next != ',') {
                    throw new IllegalArgumentException("virgül bekleniyordu");
                }
            }
        }

        private String string() {
            position++;
            StringBuilder out = new StringBuilder();
            while (true) {
                char c = peek();
                position++;
                if (c == '"') {
                    return out.toString();
                }
                if (c < 0x20) {
                    throw new IllegalArgumentException("metinde kontrol karakteri");
                }
                if (c != '\\') {
                    out.append(c);
                    continue;
                }
                char escape = peek();
                position++;
                switch (escape) {
                    case '"':
                    case '\\':
                    case '/':
                        out.append(escape);
                        break;
                    case 'b':
                        out.append('\b');
                        break;
                    case 'f':
                        out.append('\f');
                        break;
                    case 'n':
                        out.append('\n');
                        break;
                    case 'r':
                        out.append('\r');
                        break;
                    case 't':
                        out.append('\t');
                        break;
                    case 'u':
                        if (position + 4 > text.length()) {
                            throw new IllegalArgumentException("eksik \\u kaçışı");
                        }
                        out.append((char) Integer.parseInt(text.substring(position, position + 4), 16));
                        position += 4;
                        break;
                    default:
                        throw new IllegalArgumentException("geçersiz kaçış");
                }
            }
        }

        private Object literal(String word, Object value) {
            if (!text.startsWith(word, position)) {
                throw new IllegalArgumentException("geçersiz değer");
            }
            position += word.length();
            return value;
        }

        private Object number() {
            int start = position;
            boolean integral = true;
            while (position < text.length()) {
                char c = text.charAt(position);
                if (c == '.' || c == 'e' || c == 'E') {
                    integral = false;
                } else if (!(c == '-' || c == '+' || (c >= '0' && c <= '9'))) {
                    break;
                }
                position++;
            }
            String token = text.substring(start, position);
            if (token.isEmpty()) {
                throw new IllegalArgumentException("geçersiz değer");
            }
            if (integral) {
                try {
                    return Long.valueOf(token);
                } catch (NumberFormatException tooLarge) {
                    return Double.valueOf(token);
                }
            }
            return Double.valueOf(token);
        }

        void skipSpace() {
            while (position < text.length() && " \t\r\n".indexOf(text.charAt(position)) >= 0) {
                position++;
            }
        }

        private char peek() {
            if (position >= text.length()) {
                throw new IllegalArgumentException("beklenmeyen son");
            }
            return text.charAt(position);
        }

        private void expect(char wanted) {
            if (peek() != wanted) {
                throw new IllegalArgumentException("'" + wanted + "' bekleniyordu");
            }
            position++;
        }
    }
}
